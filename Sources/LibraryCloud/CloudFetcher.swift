import Foundation

/// Vorrang eines Downloads: Lokal-halten im Hintergrund < Bereitmachen < Deck lädt gerade
public enum FetchPriority: Int, Sendable, Comparable, CaseIterable {
    case keep = 0, user = 1, deck = 2
    public static func < (a: FetchPriority, b: FetchPriority) -> Bool { a.rawValue < b.rawValue }
}

public struct FetchConfig: Sendable, Equatable {
    /// gleichzeitig angeforderte Downloads (Bereitmachen); Lokal-halten nutzt höchstens einen
    public var maxParallel = 2
    /// Zeitgrenze je Datei: mindestens so viele Sekunden …
    public var minTimeout: TimeInterval = 60
    /// … sonst Größe ÷ diese Mindestrate (Bytes/s)
    public var minRate: Double = 256 * 1024
    /// Versuche je Datei (Anforderung + Warten)
    public var maxAttempts = 3
    /// Pause vor dem nächsten Versuch (wächst je Versuch)
    public var retryDelay: TimeInterval = 5
    /// so viel muss auf dem Volume frei bleiben
    public var minFreeBytes: Int64 = 10 << 30

    public init() {}

    public func timeout(size: Int64) -> TimeInterval { max(minTimeout, Double(size) / max(1, minRate)) }
}

/// Grenze eines Stapels (Bereitmachen): Bytes und/oder Zeit
public struct FetchBudget: Sendable, Equatable {
    public var maxBytes: Int64?
    public var maxSeconds: TimeInterval?
    public init(maxBytes: Int64? = nil, maxSeconds: TimeInterval? = nil) {
        self.maxBytes = maxBytes
        self.maxSeconds = maxSeconds
    }
}

public struct FetchItem: Sendable, Hashable {
    public var path: String
    /// Größe in Bytes (0 = unbekannt, wird beim Start geprüft)
    public var size: Int64
    public init(path: String, size: Int64 = 0) {
        self.path = path
        self.size = size
    }
}

public enum FetchOutcome: Sendable, Equatable {
    /// heruntergeladen und als lokal bestätigt
    case ready
    /// war schon lokal
    case alreadyLocal
    case missing
    case failed(String)
    /// zu wenig freier Platz
    case noSpace
    /// Stapel-Grenze (Bytes/Zeit) erreicht
    case overBudget
    case cancelled

    public var isSuccess: Bool { self == .ready || self == .alreadyLocal }
}

public struct FetchEvent: Sendable, Equatable {
    public var path: String
    public var batches: [String]
    public var outcome: FetchOutcome
    public var attempts: Int
}

/// Fortschritt eines Stapels
public struct FetchProgress: Sendable, Equatable {
    public var label = ""
    public var priority = FetchPriority.user
    public var total = 0
    /// abgeschlossen (erfolgreich oder nicht)
    public var finished = 0
    public var failed = 0
    public var bytesTotal: Int64 = 0
    public var bytesDone: Int64 = 0
    public var created = Date()

    public init() {}
    public var isDone: Bool { finished >= total }
    public var fraction: Double { total > 0 ? Double(finished) / Double(total) : 1 }
}

/// Download-Planer. Nicht threadsicher (daher @unchecked Sendable): ein Besitzer ruft alles auf derselben seriellen Queue auf.
/// `tick` (z. B. alle 0,5 s) prüft laufende Downloads, wiederholt nach Zeitgrenze und startet neue –
/// angehalten (`paused`, ein Deck lädt) startet nur Deck-Vorrang.
public final class CloudFetcher: @unchecked Sendable {
    public let fs: CloudFileSystem
    public var config: FetchConfig

    private struct Job {
        var item: FetchItem
        var priority: FetchPriority
        var batches: [String]
        var seq: Int
        var attempts = 0
        var notBefore = Date.distantPast
        var started: Date?
    }

    private struct Batch {
        var progress: FetchProgress
        var budget: FetchBudget
        var startedBytes: Int64 = 0
        var firstStart: Date?
    }

    private var queue: [Job] = []
    private var active: [String: Job] = [:]
    private var batches: [String: Batch] = [:]
    private var seq = 0

    public init(fs: CloudFileSystem = SystemCloudFileSystem(), config: FetchConfig = FetchConfig()) {
        self.fs = fs
        self.config = config
    }

    // MARK: Abfragen

    public var isIdle: Bool { queue.isEmpty && active.isEmpty }
    public var activePaths: Set<String> { Set(active.keys) }
    /// wartend + laufend (für die Übergabe beim Beenden)
    public var pendingPaths: [String] { active.keys.sorted() + queue.sorted { $0.seq < $1.seq }.map(\.item.path) }
    public var queuedPaths: [String] { queue.sorted { $0.seq < $1.seq }.map(\.item.path) }
    public func contains(_ path: String) -> Bool { active[path] != nil || queue.contains { $0.item.path == path } }
    public func progress(_ batch: String) -> FetchProgress? { batches[batch]?.progress }
    public var batchIDs: [String] { batches.keys.sorted() }

    /// alle Stapel ab diesem Vorrang zusammengezählt (Statusleiste)
    public func overall(minPriority: FetchPriority = .user) -> FetchProgress {
        var p = FetchProgress()
        for b in batches.values where b.progress.priority >= minPriority {
            p.total += b.progress.total
            p.finished += b.progress.finished
            p.failed += b.progress.failed
            p.bytesTotal += b.progress.bytesTotal
            p.bytesDone += b.progress.bytesDone
        }
        return p
    }

    // MARK: Aufträge

    /// Stapel einreihen. Pfade, die schon warten oder laden, zählen zusätzlich für diesen Stapel; ein höherer
    /// Vorrang wird übernommen.
    public func enqueue(_ items: [FetchItem], batch: String, label: String = "", priority: FetchPriority = .user,
                        budget: FetchBudget = FetchBudget(), now: Date = Date()) {
        var b = batches[batch] ?? Batch(progress: FetchProgress(), budget: budget)
        b.progress.label = label
        if batches[batch] == nil {
            b.progress.priority = priority
            b.progress.created = now
        } else {
            b.progress.priority = max(b.progress.priority, priority)
        }
        b.budget = budget
        var seen = Set<String>()
        for it in items where seen.insert(it.path).inserted {
            if var j = active[it.path] {
                guard !j.batches.contains(batch) else { continue }
                j.batches.append(batch)
                j.priority = max(j.priority, priority)
                active[it.path] = j
            } else if let i = queue.firstIndex(where: { $0.item.path == it.path }) {
                guard !queue[i].batches.contains(batch) else { continue }
                queue[i].batches.append(batch)
                queue[i].priority = max(queue[i].priority, priority)
                if it.size > 0 { queue[i].item.size = it.size }
            } else {
                seq += 1
                queue.append(Job(item: it, priority: priority, batches: [batch], seq: seq))
            }
            b.progress.total += 1
            b.progress.bytesTotal += it.size
        }
        batches[batch] = b
    }

    /// Stapel abbrechen: wartende Pfade fallen weg (sofern kein anderer Stapel sie braucht). Bereits angeforderte
    /// Downloads laufen beim Anbieter weiter – sie werden nur nicht mehr verfolgt.
    @discardableResult
    public func cancel(batch: String) -> [FetchEvent] {
        var events: [FetchEvent] = []
        for i in queue.indices.reversed() where queue[i].batches.contains(batch) {
            queue[i].batches.removeAll { $0 == batch }
            if queue[i].batches.isEmpty {
                events.append(FetchEvent(path: queue[i].item.path, batches: [batch], outcome: .cancelled, attempts: queue[i].attempts))
                queue.remove(at: i)
            }
        }
        for (p, var j) in active where j.batches.contains(batch) {
            j.batches.removeAll { $0 == batch }
            if j.batches.isEmpty {
                active[p] = nil
                events.append(FetchEvent(path: p, batches: [batch], outcome: .cancelled, attempts: j.attempts))
            } else {
                active[p] = j
            }
        }
        batches[batch] = nil
        return events
    }

    @discardableResult
    public func cancelAll(priority: FetchPriority? = nil) -> [FetchEvent] {
        let ids = batches.filter { priority == nil || $0.value.progress.priority == priority }.map(\.key)
        return ids.flatMap { cancel(batch: $0) }
    }

    /// fertige Stapel entfernen (nach der Meldung)
    public func forget(batch: String) {
        guard let b = batches[batch], b.progress.isDone else { return }
        batches[batch] = nil
    }

    // MARK: Takt

    public func tick(now: Date = Date(), paused: Bool = false) -> [FetchEvent] {
        var events: [FetchEvent] = []

        // 1. laufende Downloads prüfen
        for (p, var j) in active {
            let probe = fs.probe(p)
            switch probe.state {
            case .local:
                if j.item.size == 0 { j.item.size = probe.size }
                events.append(finish(j, .ready))
                active[p] = nil
            case .missing:
                events.append(finish(j, .missing))
                active[p] = nil
            case .cloud, .unknown:
                guard let s = j.started, now.timeIntervalSince(s) > config.timeout(size: max(j.item.size, probe.size)) else { continue }
                active[p] = nil
                if j.attempts >= config.maxAttempts {
                    events.append(finish(j, .failed("Zeitüberschreitung")))
                } else {
                    j.started = nil
                    j.notBefore = now.addingTimeInterval(config.retryDelay * Double(j.attempts))
                    queue.append(j)
                }
            }
        }

        // 2. Grenzen der Stapel (Zeit)
        for (id, b) in batches {
            guard let max = b.budget.maxSeconds, let first = b.firstStart, now.timeIntervalSince(first) > max else { continue }
            events += drop(batch: id, outcome: .overBudget)
        }

        // 3. neue starten
        var noSpace = false
        while !noSpace, let i = nextIndex(now: now, paused: paused) {
            var j = queue.remove(at: i)
            let probe = fs.probe(j.item.path)
            if probe.size > 0 { j.item.size = probe.size }
            switch probe.state {
            case .local:
                events.append(finish(j, .alreadyLocal))
                continue
            case .missing:
                events.append(finish(j, .missing))
                continue
            case .cloud, .unknown:
                break
            }
            if let ev = overBudget(j) { events.append(ev); continue }
            if let free = fs.freeBytes(near: j.item.path), free - j.item.size < config.minFreeBytes {
                events.append(finish(j, .noSpace))
                noSpace = true
                continue
            }
            j.attempts += 1
            do {
                try fs.requestDownload(j.item.path)
                j.started = now
                for id in j.batches {
                    batches[id]?.startedBytes += j.item.size
                    if batches[id]?.firstStart == nil { batches[id]?.firstStart = now }
                }
                active[j.item.path] = j
            } catch {
                if j.attempts >= config.maxAttempts {
                    events.append(finish(j, .failed(error.localizedDescription)))
                } else {
                    j.notBefore = now.addingTimeInterval(config.retryDelay * Double(j.attempts))
                    queue.append(j)
                }
            }
        }
        return events
    }

    /// nächster startbarer Auftrag: höchster Vorrang, dann Reihenfolge. Lokal-halten nur, wenn sonst nichts
    /// wartet, und höchstens einer gleichzeitig. Angehalten: nur Deck-Vorrang.
    private func nextIndex(now: Date, paused: Bool) -> Int? {
        let running = active.count
        let keepRunning = active.values.filter { $0.priority == .keep }.count
        let higherWaiting = queue.contains { $0.priority > .keep }
        var best: Int?
        for (i, j) in queue.enumerated() where j.notBefore <= now {
            if paused && j.priority < .deck { continue }
            if j.priority == .deck { if running >= config.maxParallel + 1 { continue } }   // Deck darf einen mehr
            else if running >= config.maxParallel { continue }
            if j.priority == .keep && (higherWaiting || keepRunning >= 1) { continue }
            if let b = best {
                let o = queue[b]
                if j.priority > o.priority || (j.priority == o.priority && j.seq < o.seq) { best = i }
            } else {
                best = i
            }
        }
        return best
    }

    private func overBudget(_ j: Job) -> FetchEvent? {
        for id in j.batches {
            guard let b = batches[id], let max = b.budget.maxBytes else { continue }
            if b.startedBytes + j.item.size > max { return finish(j, .overBudget) }
        }
        return nil
    }

    private func drop(batch id: String, outcome: FetchOutcome) -> [FetchEvent] {
        var events: [FetchEvent] = []
        for i in queue.indices.reversed() where queue[i].batches.contains(id) {
            let j = queue.remove(at: i)
            events.append(finish(j, outcome))
        }
        return events
    }

    private func finish(_ j: Job, _ outcome: FetchOutcome) -> FetchEvent {
        for id in j.batches {
            guard var b = batches[id] else { continue }
            b.progress.finished += 1
            if !outcome.isSuccess { b.progress.failed += 1 }
            if outcome == .ready || outcome == .alreadyLocal { b.progress.bytesDone += j.item.size }
            batches[id] = b
        }
        return FetchEvent(path: j.item.path, batches: j.batches, outcome: outcome, attempts: j.attempts)
    }
}
