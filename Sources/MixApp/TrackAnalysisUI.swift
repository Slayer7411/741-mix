import Foundation
import Observation
import SwiftUI
import MixCore
import MixEngine

/// Arbeit je Datei der Analyse-Warteschlange: analysieren, gewünschte Felder ablegen
/// (Analysieren = fehlende Werte dazu, Neu analysieren = alles ersetzen)
final class AnalysisJobHandler: OverviewJobHandler, @unchecked Sendable {
    let store: AnalysisStore
    private let lock = NSLock()
    private var wanted: [String: Wanted] = [:]
    struct Wanted { var fields: TrackAnalysis.Fields; var replace: Bool; var octave: ClosedRange<Double> }

    /// Key-Profile lernen: Job-Schlüssel -> Tonart der Collection; gesammelte Chroma (Track-Schlüssel, Chroma, Tonart)
    private var learning: [String: Int] = [:]
    private var samples: [(key: String, chroma: [Double], code: Int)] = []
    private var profiles: TrackAnalyzer.KeyProfiles?

    init(store: AnalysisStore) { self.store = store }

    static func learnKey(_ track: String) -> String { "learn:" + track }

    func set(_ key: String, _ w: Wanted) { lock.lock(); wanted[key] = w; lock.unlock() }
    func setLearn(_ jobKey: String, code: Int) { lock.lock(); learning[jobKey] = code; lock.unlock() }
    func setProfiles(_ p: TrackAnalyzer.KeyProfiles?) { lock.lock(); profiles = p; lock.unlock() }
    /// gesammelte Chroma abholen (Lernen beendet oder abgebrochen)
    func takeSamples() -> [(key: String, chroma: [Double], code: Int)] {
        lock.lock(); defer { lock.unlock() }
        let s = samples
        samples = []; learning = [:]
        return s
    }
    private func take(_ key: String) -> Wanted? { lock.lock(); defer { lock.unlock() }; return wanted[key] }
    private func learnCode(_ key: String) -> Int? { lock.lock(); defer { lock.unlock() }; return learning[key] }

    func isDone(_ job: OverviewJobs.Job) -> Bool { take(job.key) == nil && learnCode(job.key) == nil }

    func run(_ job: OverviewJobs.Job, checkpoint: () throws -> Void) throws {
        if let code = learnCode(job.key) {
            // nur lokale Dateien: nichts herunterladen
            defer { lock.lock(); learning[job.key] = nil; lock.unlock() }
            guard OverviewPolicy.fileState(path: job.path) == .local,
                  let c = try TrackAnalyzer.chroma(url: URL(fileURLWithPath: job.path), checkpoint: checkpoint) else { return }
            lock.lock(); samples.append((String(job.key.dropFirst(6)), c, code)); lock.unlock()
            return
        }
        guard let w = take(job.key) else { return }
        lock.lock(); let p = profiles; lock.unlock()
        let t0 = Date()
        let r = try TrackAnalyzer.analyze(url: URL(fileURLWithPath: job.path), octave: w.octave, profiles: p, checkpoint: checkpoint)
        if MixController.debug {
            print(String(format: "[analyze] %.1f s · bpm %.3f (%.2f) · anchor %.3f (phrase %.2f) · key %@ (%.2f) · loud %+.2f dB · %@",
                         Date().timeIntervalSince(t0), r.bpm, r.tempoConfidence, r.anchor, r.phraseConfidence,
                         r.musicalKey >= 0 ? Track.openKey(code: r.musicalKey) : "-", r.keyClarity, r.perceivedDb, job.path))
            fflush(stdout)
        }
        store.put(r.analysis.restricted(to: w.fields), for: job.key, replace: w.replace)
        lock.lock(); wanted[job.key] = nil; lock.unlock()
    }
}

/// Eigene Analysen: Speicher (`analysis.json`), Stapel per Rechtsklick (gleiche Warteschlange und Regeln wie die
/// Vorschauen: gedrosselt, solange ein Deck spielt, Pause beim Laden, abbrechbar), Übernahme in die Library.
@MainActor @Observable
final class Analyses {
    static let shared = Analyses()

    @ObservationIgnored let store = AnalysisStore(url: Session.isSelfTest ? nil : HistoryStore.baseDir.appendingPathComponent("analysis.json"))
    @ObservationIgnored let jobs = OverviewJobs()
    @ObservationIgnored private let handler: AnalysisJobHandler
    /// Stand für die Statuszeile
    private(set) var progress = OverviewJobs.Progress()
    @ObservationIgnored weak var library: LibraryStore?
    /// Einstellung: Ergebnisse auch in die Collection-Datei schreiben
    @ObservationIgnored var writeBack: () -> Bool = { false }
    /// Einstellung: Untergrenze der BPM-Oktave
    @ObservationIgnored var bpmLow: () -> Double = { TrackAnalyzer.defaultOctave.lowerBound }
    @ObservationIgnored private var changed: Set<String> = []
    @ObservationIgnored private var flushPending = false
    @ObservationIgnored private var decksPlaying = false
    @ObservationIgnored private var batchFailed = 0
    @ObservationIgnored private var batchTotal = 0
    @ObservationIgnored private var cancelled = false
    /// gelernte Key-Profile (`key-profiles.json`), nil = Krumhansl / Temperley
    private(set) var profiles: TrackAnalyzer.KeyProfiles?
    /// Lernen läuft: Zahl der Jobs
    private(set) var learnTotal = 0
    @ObservationIgnored let profilesURL: URL? = Session.isSelfTest ? nil : HistoryStore.baseDir.appendingPathComponent("key-profiles.json")
    /// höchstens so viele Tracks je Lernlauf, gleichmäßig über die Liste verteilt
    static let learnLimit = 300

    private init() {
        handler = AnalysisJobHandler(store: store)
        jobs.handler = handler
        jobs.setMode(.off)   // nur der Rechtsklick-Stapel
        store.onChange = { key in
            DispatchQueue.main.async { MainActor.assumeIsolated { Analyses.shared.changed(key) } }
        }
        jobs.onProgress = { p in
            DispatchQueue.main.async { MainActor.assumeIsolated { Analyses.shared.report(p) } }
        }
        jobs.start()
        if let u = profilesURL, let p = TrackAnalyzer.KeyProfiles.load(url: u) { profiles = p; handler.setProfiles(p) }
    }

    /// Rechtsklick Collection / ⌘, -> Key-Profile lernen: lokale Tracks mit Tonart aus der Collection (keine eigene
    /// Analyse), gleiche Warteschlange wie die Analyse, Ergebnis nach `key-profiles.json`
    func learnProfiles(from tracks: [Track]) {
        guard learnTotal == 0 else { return }
        let own = store.all
        let candidates = tracks.filter { $0.musicalKey >= 0 && $0.musicalKey < 24 && !$0.path.isEmpty && $0.fileExists && own[$0.key]?.musicalKey == nil }
        guard candidates.count >= TrackAnalyzer.minLearnTracks else {
            StatusCenter.post(.warning, String(localized: "Zu wenige Tracks mit Tonart aus der Collection: \(candidates.count)"), key: "analysis")
            return
        }
        let step = max(1, candidates.count / Self.learnLimit)
        let picked = stride(from: 0, to: candidates.count, by: step).prefix(Self.learnLimit).map { candidates[$0] }
        _ = handler.takeSamples()
        var list: [OverviewJobs.Job] = []
        for t in picked {
            let k = AnalysisJobHandler.learnKey(t.key)
            handler.setLearn(k, code: t.musicalKey)
            list.append(.init(key: k, path: t.path, explicit: true, refresh: true))
        }
        if batchTotal == 0 { batchFailed = progress.failed; cancelled = false; jobs.forgetFailures() }
        learnTotal = list.count
        jobs.enqueue(list)
    }

    /// Lernen beendet: Profile rechnen, speichern, ab jetzt in der Analyse
    private func finishLearning() {
        let samples = handler.takeSamples().sorted { $0.key < $1.key }
        learnTotal = 0
        guard !cancelled else { StatusCenter.post(.info, String(localized: "Key-Profile: Lernen abgebrochen"), key: "analysis"); return }
        guard let p = TrackAnalyzer.learnProfiles(samples.map { ($0.chroma, $0.code) }) else {
            StatusCenter.post(.warning, String(localized: "Zu wenige lokale Tracks mit Tonart: \(samples.count)"), key: "analysis")
            return
        }
        if let u = profilesURL {
            do { try p.save(url: u) } catch {
                StatusCenter.post(.warning, String(localized: "Key-Profile nicht gespeichert"), key: "analysis")
                return
            }
        }
        profiles = p
        handler.setProfiles(p)
        StatusCenter.post(.ok, Self.profilesText(p), key: "analysis")
    }

    static func profilesText(_ p: TrackAnalyzer.KeyProfiles) -> String {
        String(localized: "Profile gelernt: \(p.tracks) Tracks · exakt \(Int((p.exact * 100).rounded())) %, vorher \(Int((p.before * 100).rounded())) %")
    }

    /// Profile verwerfen: Datei weg, wieder Krumhansl / Temperley
    func discardProfiles() {
        if let u = profilesURL { try? FileManager.default.removeItem(at: u) }
        profiles = nil
        handler.setProfiles(nil)
        StatusCenter.post(.info, String(localized: "Key-Profile verworfen"), key: "analysis")
    }

    /// Rechtsklick -> Analysieren (fehlende Werte) / Neu analysieren (alles; gesperrte Tracks: nur fehlende)
    func enqueue(_ tracks: [Track], refresh: Bool) {
        var list: [OverviewJobs.Job] = []
        var seen: Set<String> = []
        let lo = bpmLow()
        let octave = TrackAnalyzer.octaveRange(lo...(2 * lo))
        for t in tracks where !t.path.isEmpty && t.fileExists && seen.insert(t.key).inserted {
            let full = refresh && !t.locked
            let fields: TrackAnalysis.Fields = full ? .all : TrackAnalysis.missing(in: t)
            guard !fields.isEmpty else { continue }
            handler.set(t.key, .init(fields: fields, replace: full, octave: octave))
            list.append(.init(key: t.key, path: t.path, explicit: true, refresh: refresh))
        }
        guard !list.isEmpty else {
            StatusCenter.post(.info, String(localized: "Nichts zu analysieren: Tempo, Grid, Tonart und Lautheit sind vorhanden"), key: "analysis")
            return
        }
        if batchTotal == 0 { batchFailed = progress.failed; cancelled = false; jobs.forgetFailures() }
        batchTotal += list.count
        jobs.enqueue(list)
    }

    func cancel() {
        cancelled = true
        jobs.cancel()
    }

    func setDecks(playing: Bool, loading: Bool) {
        decksPlaying = playing
        jobs.setDecks(playing: playing, loading: loading)
        if !playing, flushPending { flush() }
    }

    private func report(_ p: OverviewJobs.Progress) {
        let finished = progress.total > 0 && p.total == 0
        if progress != p { progress = p }
        guard finished else { return }
        if learnTotal > 0 { finishLearning() }
        guard batchTotal > 0 else { batchTotal = 0; return }
        let failed = p.failed - batchFailed
        let done = max(0, batchTotal - failed)
        var msg = cancelled ? String(localized: "Analyse abgebrochen") : String(localized: "Analysiert: \(done) Tracks")
        if failed > 0 { msg += " · " + String(localized: "\(failed) nicht lesbar") }
        StatusCenter.post(cancelled ? .info : failed > 0 ? .warning : .ok, msg, key: "analysis")
        batchTotal = 0
        flush()
        if !cancelled, writeBack() { library?.scheduleWriteBack() }
    }

    /// neue Werte gesammelt in die Library: alle 0,3 s. Solange ein Deck spielt, erst am Ende des Stapels, wenn kein
    /// Deck mehr spielt oder nach 30 s – jede Übernahme baut die Browser-Listen neu (Collection mit 14k Tracks:
    /// ~0,25 s Hauptthread je Bereich, die Wellenformen stehen so lange)
    private func changed(_ key: String) {
        changed.insert(key)
        guard !flushPending else { return }
        flushPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + (decksPlaying ? 30 : 0.3)) {
            MainActor.assumeIsolated { Analyses.shared.flush() }
        }
    }

    /// gesammelte Werte jetzt übernehmen (Messung: MIX741_BENCH=browser)
    func flush() {
        flushPending = false
        guard !changed.isEmpty else { return }
        let keys = changed
        changed = []
        library?.applyAnalyses(keys)
    }
}

/// Rechtsklick auf Tracks oder eine Quelle: Analysieren (fehlende Werte) / Neu analysieren (alles)
struct AnalysisMenuButtons: View {
    let tracks: () -> [Track]
    var body: some View {
        Button("Analysieren") { Analyses.shared.enqueue(tracks(), refresh: false) }
        Button("Neu analysieren") { Analyses.shared.enqueue(tracks(), refresh: true) }
    }
}

/// Rechtsklick TRACK COLLECTION: Key-Profile lernen / verwerfen
struct KeyProfileMenuButtons: View {
    let tracks: () -> [Track]
    var body: some View {
        let a = Analyses.shared
        Button("Key-Profile lernen") { a.learnProfiles(from: tracks()) }.disabled(a.learnTotal > 0)
        if a.profiles != nil { Button("Key-Profile verwerfen") { a.discardProfiles() } }
    }
}

/// Statuszeile: Stapel (n/m), Tempo, ✕
struct AnalysisStatus: View {
    var body: some View {
        let a = Analyses.shared, p = a.progress
        if p.total > 0 {
            HStack(spacing: 4.z) {
                Text("· " + (a.learnTotal > 0 ? String(localized: "Key-Profile \(p.done)/\(p.total)") : String(localized: "Analyse \(p.done)/\(p.total)")))
                if let s = OverviewStatus.state(p.gate) { Text("· " + s).foregroundStyle(p.gate == .throttled ? Theme.muted : Theme.state) }
                Button("✕") { a.cancel() }.buttonStyle(.plain).help("Analyse abbrechen")
            }
        }
    }
}
