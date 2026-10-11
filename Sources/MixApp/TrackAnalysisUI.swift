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
    private var wanted: [String: (fields: TrackAnalysis.Fields, replace: Bool)] = [:]

    init(store: AnalysisStore) { self.store = store }

    func set(_ key: String, fields: TrackAnalysis.Fields, replace: Bool) { lock.lock(); wanted[key] = (fields, replace); lock.unlock() }
    private func take(_ key: String) -> (fields: TrackAnalysis.Fields, replace: Bool)? { lock.lock(); defer { lock.unlock() }; return wanted[key] }

    func isDone(_ job: OverviewJobs.Job) -> Bool { take(job.key) == nil }

    func run(_ job: OverviewJobs.Job, checkpoint: () throws -> Void) throws {
        guard let w = take(job.key) else { return }
        let t0 = Date()
        let r = try TrackAnalyzer.analyze(url: URL(fileURLWithPath: job.path), checkpoint: checkpoint)
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
    /// Neu analysieren: eigene Grid-Änderung des Tracks verwerfen
    @ObservationIgnored var clearGridEdit: (String) -> Void = { _ in }
    @ObservationIgnored private var changed: Set<String> = []
    @ObservationIgnored private var flushPending = false
    @ObservationIgnored private var batchFailed = 0
    @ObservationIgnored private var batchTotal = 0
    @ObservationIgnored private var cancelled = false

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
    }

    /// Rechtsklick -> Analysieren (fehlende Werte) / Neu analysieren (alles; gesperrte Tracks: nur fehlende)
    func enqueue(_ tracks: [Track], refresh: Bool) {
        var list: [OverviewJobs.Job] = []
        var seen: Set<String> = []
        for t in tracks where !t.path.isEmpty && t.fileExists && seen.insert(t.key).inserted {
            let full = refresh && !t.locked
            let fields: TrackAnalysis.Fields = full ? .all : TrackAnalysis.missing(in: t)
            guard !fields.isEmpty else { continue }
            handler.set(t.key, fields: fields, replace: full)
            if full { clearGridEdit(t.key) }
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

    func setDecks(playing: Bool, loading: Bool) { jobs.setDecks(playing: playing, loading: loading) }

    private func report(_ p: OverviewJobs.Progress) {
        let finished = progress.total > 0 && p.total == 0
        if progress != p { progress = p }
        guard finished else { return }
        let failed = p.failed - batchFailed
        let done = max(0, batchTotal - failed)
        var msg = cancelled ? String(localized: "Analyse abgebrochen") : String(localized: "Analysiert: \(done) Tracks")
        if failed > 0 { msg += " · " + String(localized: "\(failed) nicht lesbar") }
        StatusCenter.post(cancelled ? .info : failed > 0 ? .warning : .ok, msg, key: "analysis")
        batchTotal = 0
        if !cancelled, writeBack() { library?.scheduleWriteBack() }
    }

    /// neue Werte gesammelt in die Library (alle 0,3 s)
    private func changed(_ key: String) {
        changed.insert(key)
        guard !flushPending else { return }
        flushPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            MainActor.assumeIsolated {
                let a = Analyses.shared
                a.flushPending = false
                let keys = a.changed
                a.changed = []
                a.library?.applyAnalyses(keys)
            }
        }
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

/// Statuszeile: Stapel (n/m), Tempo, ✕
struct AnalysisStatus: View {
    var body: some View {
        let a = Analyses.shared, p = a.progress
        if p.total > 0 {
            HStack(spacing: 4.z) {
                Text("· " + String(localized: "Analyse \(p.done)/\(p.total)"))
                if let s = OverviewStatus.state(p.gate) { Text("· " + s).foregroundStyle(p.gate == .throttled ? Theme.muted : Theme.state) }
                Button("✕") { a.cancel() }.buttonStyle(.plain).help("Analyse abbrechen")
            }
        }
    }
}
