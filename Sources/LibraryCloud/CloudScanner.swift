import Foundation

/// Ergebnis eines Prüflaufs
public struct ScanReport: Sendable {
    /// je Pfad in Eingabe-Reihenfolge
    public var probes: [FileProbe]
    /// Prüfungen über der Zeitgrenze (als `.unknown` eingetragen)
    public var timedOut = 0
    /// Lauf abgebrochen: zu viele hängende Prüfungen (Anbieter antwortet nicht) oder von außen
    public var aborted = false
    public var seconds = 0.0

    public func count(_ s: CloudState) -> Int { probes.reduce(0) { $0 + ($1.state == s ? 1 : 0) } }
}

/// Prüft viele Pfade parallel mit fester Arbeiterzahl. Jede Prüfung hat eine Zeitgrenze: hängt ein Aufruf im
/// Anbieter, wird der Pfad `.unknown`, der Arbeiter aufgegeben (er endet, sobald der Aufruf zurückkommt) und
/// ein neuer gestartet. Ab `maxHung` hängenden Aufrufen bricht der Lauf ab – der Rest bleibt `.unknown`.
public final class CloudScanner: @unchecked Sendable {
    public let fs: CloudFileSystem
    public var workers: Int
    public var timeout: TimeInterval
    public var maxHung: Int

    public init(fs: CloudFileSystem = SystemCloudFileSystem(), workers: Int = 4, timeout: TimeInterval = 2, maxHung: Int = 8) {
        self.fs = fs
        self.workers = max(1, workers)
        self.timeout = timeout
        self.maxHung = max(1, maxHung)
    }

    private final class Run: @unchecked Sendable {
        let cond = NSCondition()
        var next = 0
        var results: [FileProbe?]
        var done = 0
        /// Arbeiter -> (Index, Start in ns)
        var active: [Int: (index: Int, start: UInt64)] = [:]
        var abandoned = Set<Int>()
        var stop = false
        init(count: Int) { results = Array(repeating: nil, count: count) }
    }

    /// blockiert bis zum Ende (Hintergrund-Thread). `cancelled` wird alle ~50 ms gefragt,
    /// `progress(fertig, gesamt)` höchstens 10× pro Sekunde
    public func scan(_ paths: [String], cancelled: @Sendable () -> Bool = { false },
                     progress: (@Sendable (Int, Int) -> Void)? = nil) -> ScanReport {
        let start = Date()
        let n = paths.count
        guard n > 0 else { return ScanReport(probes: []) }
        let run = Run(count: n)
        var nextWorker = 0
        var hung = 0
        var timedOut = 0
        var aborted = false
        let limitNs = UInt64(max(0.001, timeout) * 1e9)
        let fs = fs

        func spawn() {
            let id = nextWorker
            nextWorker += 1
            let t = Thread {
                while true {
                    run.cond.lock()
                    if run.stop || run.abandoned.contains(id) || run.next >= n {
                        run.active[id] = nil
                        run.cond.unlock()
                        return
                    }
                    let i = run.next
                    run.next += 1
                    run.active[id] = (i, DispatchTime.now().uptimeNanoseconds)
                    run.cond.unlock()
                    let p = fs.probe(paths[i])
                    run.cond.lock()
                    if run.abandoned.contains(id) { run.cond.unlock(); return }   // zu spät, schon als unbekannt eingetragen
                    if run.results[i] == nil { run.results[i] = p; run.done += 1 }
                    run.active[id] = nil
                    run.cond.signal()
                    run.cond.unlock()
                }
            }
            t.qualityOfService = .utility
            t.name = "minos741.cloud.scan"
            t.start()
        }

        run.cond.lock()
        for _ in 0..<min(workers, n) { spawn() }
        var lastReport = Date.distantPast
        while run.done < n {
            run.cond.wait(until: Date().addingTimeInterval(0.05))
            let now = DispatchTime.now().uptimeNanoseconds
            for (id, cur) in run.active where now &- cur.start > limitNs {
                run.active[id] = nil
                run.abandoned.insert(id)
                if run.results[cur.index] == nil { run.results[cur.index] = FileProbe(.unknown); run.done += 1 }
                timedOut += 1
                hung += 1
                if hung < maxHung { spawn() }
            }
            let stopNow = hung >= maxHung || cancelled()
            if stopNow, !run.stop {
                // Rest als unbekannt; laufende Arbeiter werden aufgegeben
                run.stop = true
                aborted = true
                for (id, cur) in run.active {
                    run.abandoned.insert(id)
                    if run.results[cur.index] == nil { run.results[cur.index] = FileProbe(.unknown); run.done += 1 }
                }
                run.active.removeAll()
                for i in run.next..<n where run.results[i] == nil { run.results[i] = FileProbe(.unknown); run.done += 1 }
                run.next = n
            }
            if let progress, Date().timeIntervalSince(lastReport) > 0.1 {
                lastReport = Date()
                let d = run.done
                run.cond.unlock()
                progress(d, n)
                run.cond.lock()
            }
        }
        run.stop = true
        let probes = run.results.map { $0 ?? FileProbe(.unknown) }
        run.cond.unlock()
        progress?(n, n)
        return ScanReport(probes: probes, timedOut: timedOut, aborted: aborted, seconds: Date().timeIntervalSince(start))
    }
}
