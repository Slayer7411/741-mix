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
    /// alle Dateien des letzten Durchgangs (SPLIT: zwei), Hinweis (Gain begrenzt, Tempo), angewendeter Gain (dB)
    static var lastTracks: [Track] = []
    static var lastNote: String?
    static var lastGain: Double?
    /// Hauptthread-Zeit des Abschlusses (eintragen, melden, ggf. laden)
    private(set) static var mainSeconds = 0.0

    /// Bereich entfernen / behalten, Schnittliste (EDIT-Modus), Tool-Loop (n Beats, nahtlos)
    enum Kind: Sendable {
        case cut(TrackCut.Mode, TrackRange)
        case edit(EditList)
        case toolLoop(beats: Int, range: TrackRange, bpm: Double, separators: String)
        /// Vorbereiten RENDER: Schnittliste + Gain in einem Durchgang
        case prepare(EditList, amp: AmpRequest, allowClipping: Bool)
        /// Vorbereiten SPLIT: zwei Dateien, geteilt an der Ausgabe-Zeit der Schnittliste
        case split(EditList, at: Double)
        /// Vorbereiten JOIN: zweite Datei (mit eigenen Änderungen) ans Ende der Schnittliste, am Grid
        case join(EditList, second: Track, matchTempo: Bool)
    }

    struct Input: Sendable {
        var deck: Int
        var kind: Kind
        var track: Track
        var grid: BeatGrid?
        var hotcues: [Cue]
        var audio: TrackAudio?
        /// Quelle ist `audio` selbst (Deck spielt eine Schnittliste), nicht die Datei
        var direct = false
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

    struct Output: Sendable {
        var tracks: [Track]
        var fromDeck: Bool
        var note: String?
        var gain: Double?
        var track: Track { tracks[0] }
    }

    /// Hintergrund: Datei schreiben, Track der neuen Datei bauen
    nonisolated private static func run(_ i: Input, report: (Double) -> Bool) throws -> Output {
        let src = URL(fileURLWithPath: i.track.path)
        let source: AudioCutWriter.Source
        if i.direct, let a = i.audio {
            source = .audio(a, bitDepth: AudioCutWriter.bitDepth(url: src))
        } else {
            source = try AudioCutWriter.source(url: src, deck: i.audio) { report(0.4 * $0) }
        }
        let rate = source.sampleRate
        let fade = AudioSplice.fadeFrames(sampleRate: rate)
        let dir = i.directory ?? src.deletingLastPathComponent()
        let fm = FileManager.default
        let taken: (String) -> Bool = { fm.fileExists(atPath: dir.appendingPathComponent($0).path) }
        let splice: AudioSplice, name: String
        switch i.kind {
        case .prepare, .split, .join:
            return try PrepareRender.run(i, source: source, report: report)
        case let .cut(mode, r):
            let a = Int((r.start * rate).rounded()), b = Int((r.end * rate).rounded())
            splice = mode == .remove ? AudioSplice.removing(a..<max(a, b), frames: source.frames, fade: fade)
                                     : AudioSplice.keeping(a..<max(a, b), frames: source.frames, fade: fade)
            guard Double(splice.frames) >= rate * TrackTrim.minLength else { throw AudioCutWriter.CutError.empty }
            name = TrackCut.fileName(src.lastPathComponent, taken: taken)
        case let .edit(edl):
            let f = edl.frames(rate: rate, sourceFrames: source.frames)
            splice = AudioSplice(pieces: f.pieces, sourceFrames: source.frames, fade: fade, muted: f.muted)
            guard Double(splice.frames) >= rate * TrackTrim.minLength else { throw AudioCutWriter.CutError.empty }
            name = TrackCut.fileName(src.lastPathComponent, taken: taken)
        case let .toolLoop(beats, r, bpm, _):
            let a = Int((r.start * rate).rounded()), n = ToolLoop.frames(beats: beats, bpm: bpm, rate: rate)
            guard n > 0, a >= 0, a + n <= source.frames else { throw AudioCutWriter.CutError.empty }
            splice = AudioSplice.toolLoop(a..<(a + n), frames: source.frames, fade: fade)
            name = ToolLoop.fileName(src.lastPathComponent, beats: beats, taken: taken)
        }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        let base = source.fromDeck ? 0 : 0.4
        try AudioCutWriter.write(splice, source: source, to: url) { report(base + (1 - base) * $0) }
        let duration = Double(splice.frames) / rate
        let vol = MusicFolder.volumeInfo(url.path)
        let key = MusicFolder.nmlKey(url.path, volume: vol.name, mount: vol.mount)
        var t: Track
        switch i.kind {
        case let .cut(mode, r):
            t = TrackCut.track(from: i.track, key: key, path: url.path, grid: i.grid, hotcues: i.hotcues, mode: mode, range: r, duration: duration)
        case let .edit(edl):
            t = TrackCut.track(from: i.track, key: key, path: url.path, grid: i.grid, hotcues: i.hotcues, edl: edl, duration: duration)
        case let .toolLoop(beats, _, bpm, seps):
            t = ToolLoop.track(from: i.track, key: key, path: url.path, beats: beats, bpm: bpm, duration: duration, separators: seps)
        case .prepare, .split, .join:
            throw AudioCutWriter.CutError.format
        }
        fileInfo(&t)
        return Output(tracks: [t], fromDeck: source.fromDeck)
    }

    /// Größe und Bitrate der neuen Datei
    nonisolated static func fileInfo(_ t: inout Track) {
        if let size = (try? FileManager.default.attributesOfItem(atPath: t.path))?[.size] as? Int {
            t.fileSizeKB = size / 1024
            t.bitrate = t.duration > 0 ? Int(Double(size) * 8 / t.duration / 1000) : 0
        }
    }

    private static func finish(_ i: Input, _ r: Result<Output, Error>, seconds: Double, mix: MixModel, store: LibraryStore) {
        let f0 = CACurrentMediaTime()
        defer { mainSeconds = CACurrentMediaTime() - f0 }
        running = false
        switch r {
        case let .success(out):
            let t = out.track
            for x in out.tracks { store.addCut(x, source: i.track) }
            lastResult = (seconds, t, out.fromDeck)
            lastTracks = out.tracks
            lastNote = out.note
            lastGain = out.gain
            var msg = String(format: String(localized: "Geschnitten: %@ · %@"), t.fileName, Theme.time(t.duration))
            switch i.kind {
            case let .toolLoop(beats, _, _, _): msg = String(format: String(localized: "Tool-Loop: %@ · %lld Beats"), t.fileName, beats)
            case .prepare: msg = String(format: String(localized: "Gerendert: %@ · %@"), t.fileName, Theme.time(t.duration))
            case .split: msg = String(format: String(localized: "Geteilt: %@"), out.tracks.map(\.fileName).joined(separator: " · "))
            case .join: msg = String(format: String(localized: "Zusammengefügt: %@ · %@"), t.fileName, Theme.time(t.duration))
            default: break
            }
            if let n = out.note { msg += " · " + n }
            if i.load, i.kind.loadsResult {
                if mix.load(t, deck: i.deck, force: false) {
                    msg += " · " + String(localized: "in Deck \(deckLetters[i.deck]) geladen")
                } else {
                    msg += " · " + String(localized: "Deck \(deckLetters[i.deck]) spielt, nicht geladen")
                }
            }
            StatusCenter.post(.ok, msg, detail: t.path, key: "cut")
            if Session.isSelfTest || MixController.debug {
                print(String(format: "[cut] %@ -> %@: %.2f s (%@)", i.kind.name, t.path, seconds, out.fromDeck ? "deck-puffer" : "datei neu dekodiert"))
            }
        case let .failure(e as AudioCutWriter.CutError) where e == .cancelled:
            StatusCenter.post(.info, String(localized: "Schneiden abgebrochen"), key: "cut")
        case let .failure(e as AudioCutWriter.CutError) where e == .empty:
            StatusCenter.post(.warning, String(localized: "Ergebnis zu kurz (mindestens 1 s)"), key: "cut")
        case let .failure(e as PrepareRender.Failure):
            StatusCenter.post(.warning, e.text, key: "cut")
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
        CutJob.start(.init(deck: d, kind: .cut(mode, r), track: t, grid: s.grid, hotcues: Array(s.hotcues.values), audio: audio,
                           load: load ?? prefs.ui.cutLoadsResult, directory: dir), mix: self, store: store)
    }
}

extension CutJob.Kind {
    var name: String {
        switch self {
        case let .cut(m, _): m.rawValue
        case .edit: "edit"
        case let .toolLoop(b, _, _, _): "tool-loop \(b)"
        case .prepare: "prepare"
        case .split: "split"
        case .join: "join"
        }
    }

    /// Ergebnis darf ins Deck (SPLIT: zwei Dateien, keine)
    var loadsResult: Bool { if case .split = self { false } else { true } }
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
