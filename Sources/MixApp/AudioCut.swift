import AppKit
import Foundation
import os
import MixCore
import MixEngine

/// Geschnittene Dateien (neben dem Original, nicht in der Collection): Einträge in `cuts.json` mit den Metadaten.
/// Nur Hauptthread, geschrieben wird im Hintergrund. `url` nil = nur im Speicher (Selbsttest)
@MainActor
final class CutStore {
    private(set) var tracks: [Track] = []
    private(set) var byKey: [String: Track] = [:]
    /// Pfad in Vergleichsform (MusicFolder.match) -> Track: MUSIC FOLDERS zeigt die Datei mit ihren Metadaten
    private(set) var byMatch: [String: Track] = [:]
    private var entries: [CutEntry] = []
    private var missing: Set<String> = []
    let url: URL?
    private let queue = DispatchQueue(label: "minos741.cuts", qos: .utility)

    init(url: URL?) {
        self.url = url
        if let url, let d = try? Data(contentsOf: url), let e = try? JSONDecoder().decode([CutEntry].self, from: d) { entries = e }
        for e in entries { if let o = e.sourcePath { ArtworkCache.shared.alias(e.path, to: o) } }
        rebuild()
    }

    func add(_ e: CutEntry) {
        entries.removeAll { $0.key == e.key || $0.path == e.path }
        entries.append(e)
        missing.remove(e.key)
        if let o = e.sourcePath { ArtworkCache.shared.alias(e.path, to: o) }
        rebuild()
        save()
    }

    /// nach der Prüfung im Hintergrund: fehlende Dateien rot (Eintrag bleibt, das Laufwerk kann nur fehlen)
    func setMissing(_ keys: Set<String>) {
        guard keys != missing else { return }
        missing = keys
        rebuild()
    }

    var paths: [(key: String, path: String)] { entries.map { ($0.key, $0.path) } }

    private func rebuild() {
        tracks = entries.map { e in
            var t = e.track
            t.fileMissing = missing.contains(e.key)
            return t
        }
        byKey = Dictionary(tracks.map { ($0.key, $0) }, uniquingKeysWith: { _, b in b })
        byMatch = Dictionary(tracks.map { (MusicFolder.match($0.path), $0) }, uniquingKeysWith: { _, b in b })
    }

    private func save() {
        guard let url else { return }
        let snapshot = entries
        queue.async {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let d = try? JSONEncoder().encode(snapshot) { try? d.write(to: url, options: .atomic) }
        }
    }

    func flush() { queue.sync {} }
}

/// Abbruch eines Schnitts (✕ in der Statusleiste), von jedem Thread lesbar
private final class CutCancel: @unchecked Sendable {
    private let flag = OSAllocatedUnfairLock(initialState: false)
    var cancelled: Bool { flag.withLock { $0 } }
    func cancel() { flag.withLock { $0 = true } }
}

/// Ein Schnitt läuft auf einer eigenen Queue (nicht Haupt-, nicht Audio-Thread): Quelle (Deck-Puffer oder Datei neu
/// dekodiert), zusammensetzen, Apple Lossless schreiben; danach auf dem Hauptthread nur eintragen und melden
@MainActor
enum CutJob {
    private static let queue = DispatchQueue(label: "minos741.cut", qos: .userInitiated)
    /// läuft gerade einer (einer zur Zeit)
    private(set) static var running = false
    /// Selbsttest: letzter Schnitt (Dauer, Datei) zum Prüfen
    static var lastResult: (seconds: Double, track: Track, fromDeck: Bool)?
    /// Hauptthread-Zeit des Abschlusses (eintragen, melden, ggf. laden)
    private(set) static var mainSeconds = 0.0

    struct Input: Sendable {
        var deck: Int
        var mode: TrackCut.Mode
        var range: TrackRange
        var track: Track
        var grid: BeatGrid?
        var hotcues: [Cue]
        var audio: TrackAudio?
        var load: Bool
        /// Zielordner (nil = neben dem Original)
        var directory: URL?
    }

    static func start(_ input: Input, mix: MixModel, store: LibraryStore) {
        guard !running else {
            StatusCenter.post(.warning, String(localized: "Schneiden läuft schon"), key: "cut")
            return
        }
        running = true
        let cancel = CutCancel()
        let stop: @MainActor @Sendable () -> Void = { cancel.cancel() }
        let t = input.track
        let name = t.title.isEmpty ? t.fileName : (t.artist.isEmpty ? t.title : "\(t.artist) – \(t.title)")
        let text = String(localized: "Schneiden: \(name)")
        StatusCenter.post(.info, text, key: "cut", progress: 0, cancel: stop)
        queue.async {
            let t0 = CACurrentMediaTime()
            var last = 0.0
            let report: (Double) -> Bool = { p in
                if cancel.cancelled { return false }
                let now = CACurrentMediaTime()
                if now - last > 0.1 {
                    last = now
                    StatusCenter.post(.info, text, key: "cut", progress: p, progressText: "\(Int(p * 100)) %", cancel: stop)
                }
                return true
            }
            let result = Result { try run(input, report: report) }
            let secs = CACurrentMediaTime() - t0
            DispatchQueue.main.async {
                MainActor.assumeIsolated { finish(input, result, seconds: secs, mix: mix, store: store) }
            }
        }
    }

    private struct Output: Sendable { var track: Track; var fromDeck: Bool }

    /// Hintergrund: Datei schreiben, Track der neuen Datei bauen
    nonisolated private static func run(_ i: Input, report: (Double) -> Bool) throws -> Output {
        let src = URL(fileURLWithPath: i.track.path)
        let source = try AudioCutWriter.source(url: src, deck: i.audio) { report(0.4 * $0) }
        let rate = source.sampleRate
        let a = Int((i.range.start * rate).rounded()), b = Int((i.range.end * rate).rounded())
        let fade = AudioSplice.fadeFrames(sampleRate: rate)
        let splice = i.mode == .remove ? AudioSplice.removing(a..<max(a, b), frames: source.frames, fade: fade)
                                       : AudioSplice.keeping(a..<max(a, b), frames: source.frames, fade: fade)
        guard Double(splice.frames) >= rate * TrackTrim.minLength else { throw AudioCutWriter.CutError.empty }
        let dir = i.directory ?? src.deletingLastPathComponent()
        let fm = FileManager.default
        let name = TrackCut.fileName(src.lastPathComponent) { fm.fileExists(atPath: dir.appendingPathComponent($0).path) }
        let url = dir.appendingPathComponent(name)
        let base = source.fromDeck ? 0 : 0.4
        try AudioCutWriter.write(splice, source: source, to: url) { report(base + (1 - base) * $0) }
        let duration = Double(splice.frames) / rate
        let vol = MusicFolder.volumeInfo(url.path)
        let key = MusicFolder.nmlKey(url.path, volume: vol.name, mount: vol.mount)
        var t = TrackCut.track(from: i.track, key: key, path: url.path, grid: i.grid, hotcues: i.hotcues, mode: i.mode,
                               range: i.range, duration: duration)
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int {
            t.fileSizeKB = size / 1024
            t.bitrate = duration > 0 ? Int(Double(size) * 8 / duration / 1000) : 0
        }
        return Output(track: t, fromDeck: source.fromDeck)
    }

    private static func finish(_ i: Input, _ r: Result<Output, Error>, seconds: Double, mix: MixModel, store: LibraryStore) {
        let f0 = CACurrentMediaTime()
        defer { mainSeconds = CACurrentMediaTime() - f0 }
        running = false
        switch r {
        case let .success(out):
            let t = out.track
            store.addCut(t, source: i.track)
            lastResult = (seconds, t, out.fromDeck)
            var msg = String(format: String(localized: "Geschnitten: %@ · %@"), t.fileName, Theme.time(t.duration))
            if i.load {
                if mix.load(t, deck: i.deck, force: false) {
                    msg += " · " + String(localized: "in Deck \(deckLetters[i.deck]) geladen")
                } else {
                    msg += " · " + String(localized: "Deck \(deckLetters[i.deck]) spielt, nicht geladen")
                }
            }
            StatusCenter.post(.ok, msg, detail: t.path, key: "cut")
            if Session.isSelfTest || MixController.debug {
                print(String(format: "[cut] %@ -> %@: %.2f s (%@)", i.mode.rawValue, t.path, seconds, out.fromDeck ? "deck-puffer" : "datei neu dekodiert"))
            }
        case let .failure(e as AudioCutWriter.CutError) where e == .cancelled:
            StatusCenter.post(.info, String(localized: "Schneiden abgebrochen"), key: "cut")
        case let .failure(e as AudioCutWriter.CutError) where e == .empty:
            StatusCenter.post(.warning, String(localized: "Ergebnis zu kurz (mindestens 1 s)"), key: "cut")
        case let .failure(e):
            StatusCenter.post(.error, String(localized: "Schneiden fehlgeschlagen: \(e.localizedDescription)"), detail: i.track.path, key: "cut")
        }
    }
}

extension MixModel {
    /// Bereich schneiden: neue Datei (Apple Lossless, `<Name> [cut].m4a`) neben dem Original, im Hintergrund; das
    /// Original bleibt unberührt. `load` nil = Einstellung „Ergebnis ins Deck laden“
    func cutRange(_ d: Int, mode: TrackCut.Mode, load: Bool? = nil) {
        guard let store = library, let r = range(d), r.length > 0.01 else { return }
        let s = deck(d)
        guard let t = s.track, !s.loading, s.duration > 0, let audio = audio(d) else { return }
        guard TrackCut.duration(s.duration, mode: mode, range: r) >= TrackTrim.minLength else {
            StatusCenter.post(.warning, String(localized: "Ergebnis zu kurz (mindestens 1 s)"), key: "cut")
            return
        }
        // Selbsttest: nie neben Christians Dateien schreiben
        let dir: URL? = Session.isSelfTest ? CutJob.selfTestDirectory : nil
        CutJob.start(.init(deck: d, mode: mode, range: r, track: t, grid: s.grid, hotcues: Array(s.hotcues.values), audio: audio,
                           load: load ?? prefs.ui.cutLoadsResult, directory: dir), mix: self, store: store)
    }
}

extension CutJob {
    /// Selbsttest: MIX741_CUT_DIR, sonst ein eigener Ordner im temporären Verzeichnis
    static var selfTestDirectory: URL {
        let u = ProcessInfo.processInfo.environment["MIX741_CUT_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("minos741-cut-selftest")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
}
