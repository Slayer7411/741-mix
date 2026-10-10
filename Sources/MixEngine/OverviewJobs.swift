import Foundation
import MixCore

/// Warteschlangen + Arbeiter der Vorschau-Berechnung (eigene Threads). Reihenfolge: Rechtsklick-Stapel, sichtbare
/// Zeilen (zuletzt gezeigte zuerst), Hintergrund (neueste Tracks zuerst). Wann und wie schnell: `OverviewPolicy` –
/// geprüft vor jeder Datei und zwischen zwei Lese-Blöcken.
public final class OverviewJobs: @unchecked Sendable {
    public struct Job: Sendable {
        public let key: String
        public let path: String
        public let explicit: Bool
        public init(key: String, path: String, explicit: Bool) { self.key = key; self.path = path; self.explicit = explicit }
    }

    public struct Progress: Equatable, Sendable {
        /// Rechtsklick-Stapel
        public var done = 0, total = 0
        /// Hintergrund: Tracks mit Übersicht / Tracks mit Datei
        public var covered = 0, collection = 0
        /// Hintergrund: noch in der Warteschlange
        public var left = 0
        /// übersprungen: nur in der Cloud
        public var onlineOnly = 0
        /// nicht lesbar
        public var failed = 0
        public var gate = OverviewPolicy.Gate.full
        public init() {}
    }

    public var store: OverviewStore?
    public var onProgress: (@Sendable (Progress) -> Void)?
    /// Obergrenze der Arbeiter (Messungen)
    public var maxWorkers = 2
    /// QoS gedrosselt. utility: gemessen ohne Einfluss auf Audio- und Steuertakt, ~2,5× schneller als background
    /// (background läuft nur auf den Effizienzkernen und verhungert, wenn dort anderes rechnet)
    public var throttledQoS = QOS_CLASS_UTILITY

    private let lock = NSLock()
    private var mode = OverviewPolicy.Mode.always
    private var playing = false, loading = false
    private var loadEnded: Double?
    private var explicit: [Job] = []
    private var queued: Set<String> = []
    private var visible: [Job] = []
    private var visibleKeys: Set<String> = []
    private var idle: [Job] = []
    private var pending: Set<String> = []
    private var workers = 0
    private var started = false
    private var cancelGen = 0, idleGen = 0
    private var failed: Set<String> = []
    private var progress = Progress()

    public init() {}

    private static func now() -> Double { ProcessInfo.processInfo.systemUptime }

    public func start() {
        lock.lock(); started = true; lock.unlock()
        spawn()
    }

    /// aus: Hintergrund und sichtbare Zeilen leeren (nur der Rechtsklick-Stapel rechnet noch)
    public func setMode(_ m: OverviewPolicy.Mode) {
        lock.lock(); mode = m; lock.unlock()
        if m == .off { stopBackground() }
        spawn()
    }

    /// Deck-Zustand (Hauptthread bei jeder Änderung); Ende eines Ladens startet die Wartezeit
    public func setDecks(playing p: Bool, loading l: Bool) {
        lock.lock()
        if loading, !l { loadEnded = Self.now() }
        playing = p; loading = l
        lock.unlock()
        spawn()
    }

    /// Ende eines Ladens von außen melden (Tests)
    public func noteLoadEnded(at t: Double? = nil) { lock.lock(); loadEnded = t ?? Self.now(); lock.unlock() }

    public func enqueue(_ jobs: [Job]) {
        lock.lock()
        for j in jobs where !queued.contains(j.key) {
            explicit.append(Job(key: j.key, path: j.path, explicit: true))
            queued.insert(j.key)
            progress.total += 1
        }
        lock.unlock()
        report()
        spawn()
    }

    /// sichtbare Zeile ohne Übersicht: vor den Hintergrund ziehen (höchstens 400 gemerkt, älteste fallen raus)
    public func want(key: String, path: String) {
        lock.lock()
        guard mode != .off, !path.isEmpty, !visibleKeys.contains(key), !queued.contains(key), !failed.contains(key) else { lock.unlock(); return }
        visible.append(Job(key: key, path: path, explicit: false))
        visibleKeys.insert(key)
        if visible.count > 400 { visibleKeys.remove(visible.removeFirst().key) }
        lock.unlock()
        spawn()
    }

    /// Hintergrund-Liste (neueste zuerst) + Zähler für die Statuszeile
    public func setBackground(_ jobs: [Job], collection: Int, covered: Int, onlineOnly: Int) {
        lock.lock()
        idleGen += 1
        idle = jobs.reversed()   // von hinten abarbeiten
        pending = Set(jobs.map(\.key))
        progress.left = idle.count
        progress.collection = collection
        progress.covered = covered
        progress.onlineOnly = onlineOnly
        lock.unlock()
        report()
        spawn()
    }

    /// neue Übersicht im Speicher (auch vom Deck): Zähler nachführen
    public func stored(_ key: String) {
        lock.lock()
        let hit = pending.remove(key) != nil
        if hit { progress.covered += 1 }
        lock.unlock()
        if hit { report() }
    }

    /// Rechtsklick-Stapel abbrechen
    public func cancel() {
        lock.lock()
        cancelGen += 1
        explicit.removeAll(); queued.removeAll()
        progress.done = 0; progress.total = 0
        lock.unlock()
        report()
    }

    /// Hintergrund + sichtbare Zeilen anhalten (bis zur nächsten Liste)
    public func stopBackground() {
        lock.lock()
        idleGen += 1
        idle.removeAll(); visible.removeAll(); visibleKeys.removeAll(); pending.removeAll()
        progress.left = 0
        lock.unlock()
        report()
    }

    /// Stapel, sichtbare Zeilen und Hintergrund leer, kein Arbeiter läuft
    public var isIdle: Bool {
        lock.lock(); defer { lock.unlock() }
        return workers == 0 && explicit.isEmpty && visible.isEmpty && idle.isEmpty
    }

    public var snapshot: Progress { lock.lock(); defer { lock.unlock() }; return progress }

    // MARK: Arbeiter

    private func decksLocked() -> OverviewPolicy.Decks {
        .init(playing: playing, loading: loading, sinceLoad: loadEnded.map { Self.now() - $0 } ?? .infinity)
    }

    private func gateLocked(explicit e: Bool) -> OverviewPolicy.Gate { OverviewPolicy.gate(mode, explicit: e, decks: decksLocked()) }

    private func wantedLocked() -> Int {
        if !explicit.isEmpty { return min(maxWorkers, OverviewPolicy.workers(gate: gateLocked(explicit: true), explicitQueued: true)) }
        // sichtbare Zeilen und Hintergrund: ein Arbeiter
        return visible.isEmpty && idle.isEmpty ? 0 : min(maxWorkers, 1)
    }

    private func spawn() {
        lock.lock()
        guard started else { lock.unlock(); return }
        var n = 0
        while workers < wantedLocked() { workers += 1; n += 1 }
        lock.unlock()
        for _ in 0..<n {
            let t = Thread { [self] in work() }
            t.qualityOfService = .utility
            t.name = "minos741.overview"
            t.start()
        }
    }

    private func report() {
        lock.lock(); let p = progress; lock.unlock()
        onProgress?(p)
    }

    private func setGate(_ g: OverviewPolicy.Gate) {
        lock.lock()
        let changed = progress.gate != g
        progress.gate = g
        lock.unlock()
        if changed { report() }
    }

    private struct Cancelled: Error {}

    private func generation(_ job: Job) -> Int { job.explicit ? cancelGen : idleGen }

    /// wartet, solange die Regel es verlangt; abgebrochen -> werfen. Rückgabe: Tempo (voll / gedrosselt)
    private func pass(_ job: Job, gen: Int) throws -> OverviewPolicy.Gate {
        while true {
            lock.lock()
            let g = gateLocked(explicit: job.explicit), cur = generation(job)
            lock.unlock()
            if cur != gen || g == .wait(.off) { throw Cancelled() }
            setGate(g)
            if case .wait = g { Thread.sleep(forTimeInterval: 0.25); continue }
            return g
        }
    }

    /// QoS des Arbeiters: gedrosselt -> `throttledQoS`, sonst utility
    private func applyQoS(_ g: OverviewPolicy.Gate) {
        let q = g == .throttled ? throttledQoS : QOS_CLASS_UTILITY
        // je Thread merken
        let key = "minos741.overview.qos"
        guard Thread.current.threadDictionary[key] as? UInt32 != q.rawValue else { return }
        Thread.current.threadDictionary[key] = q.rawValue
        pthread_set_qos_class_self_np(q, 0)
    }

    private func work() {
        while true {
            lock.lock()
            if workers > wantedLocked() || (explicit.isEmpty && visible.isEmpty && idle.isEmpty) {
                workers -= 1
                if explicit.isEmpty, progress.done >= progress.total { progress.done = 0; progress.total = 0 }
                lock.unlock()
                report()
                return
            }
            let job: Job
            if !explicit.isEmpty { job = explicit.removeFirst() }
            else if !visible.isEmpty { job = visible.removeLast(); visibleKeys.remove(job.key) }
            else { job = idle.removeLast(); progress.left = idle.count }
            let gen = generation(job)
            let skip = failed.contains(job.key)
            lock.unlock()
            var g = OverviewPolicy.Gate.full
            if !skip { g = process(job, gen: gen) }
            lock.lock()
            if job.explicit, gen == cancelGen { progress.done += 1; queued.remove(job.key) }
            lock.unlock()
            report()
            // gedrosselt: Pause zwischen zwei Dateien
            if g == .throttled { Thread.sleep(forTimeInterval: OverviewPolicy.gap) }
        }
    }

    /// eine Datei; Rückgabe: zuletzt geltendes Tempo
    private func process(_ job: Job, gen: Int) -> OverviewPolicy.Gate {
        guard let store else { return .full }
        var g = OverviewPolicy.Gate.full
        do {
            g = try pass(job, gen: gen)
            if store.isValid(job.key, path: job.path) { stored(job.key); return .full }
            switch OverviewPolicy.admit(explicit: job.explicit, file: OverviewPolicy.fileState(path: job.path)) {
            case .skipOnline: return .full
            case .skipMissing: throw CocoaError(.fileNoSuchFile)
            case .read: break
            }
            guard let stamp = OverviewStore.Stamp.of(path: job.path) else { return .full }
            applyQoS(g)
            var t0 = Self.now(), owed = 0.0
            let ov = try OverviewAnalyzer.analyze(url: URL(fileURLWithPath: job.path)) {
                // zwischen zwei Lese-Blöcken: Regel prüfen; gedrosselt Rechenzeit sammeln und ab 0,2 s gleich lang
                // schlafen (kurze Schlafzeiten dehnt das System bei QoS background stark)
                owed += Self.now() - t0
                g = try pass(job, gen: gen)
                applyQoS(g)
                if g != .throttled { owed = 0 } else if owed >= OverviewPolicy.slice {
                    Thread.sleep(forTimeInterval: OverviewPolicy.pause(after: owed, gate: g))
                    owed = 0
                }
                t0 = Self.now()
            }
            store.put(job.key, path: job.path, overview: ov, stamp: stamp)
            stored(job.key)
        } catch is Cancelled {
        } catch {
            lock.lock()
            if failed.insert(job.key).inserted { progress.failed += 1 }
            pending.remove(job.key)
            lock.unlock()
        }
        return g
    }
}
