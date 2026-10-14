import Darwin
import Foundation
import Testing
import MixCore
import MixDSP
import MixEngine

/// Vorschau-Arbeiter gegen Audio- und Steuertakt: Decks rendern im Echtzeit-Takt (Thread mit Time-Constraint-Policy wie
/// der Audio-Thread), ein 200-Hz-Takt wie der Steuertakt, dazu der Arbeiter auf echten Dateien in einem Temp-Cache.
/// Nur mit MIX741_BENCH=1 und MIX741_BENCH_TRACKS=<datei mit einem pfad je zeile> (Dateien werden nur gelesen).
private let benchTracks: [String] = {
    guard ProcessInfo.processInfo.environment["MIX741_BENCH"] == "1",
          let f = ProcessInfo.processInfo.environment["MIX741_BENCH_TRACKS"],
          let s = try? String(contentsOfFile: f, encoding: .utf8) else { return [] }
    return s.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
}()

private final class Decks: @unchecked Sendable {
    let e: OpaquePointer
    let fs = 44100.0
    var mem: [UnsafeMutablePointer<Float>] = []

    init(count: Int, fx: Bool) {
        e = mdsp_create(fs)
        let n = Int(70 * fs)
        for d in 0..<count {
            let l = UnsafeMutablePointer<Float>.allocate(capacity: n), r = UnsafeMutablePointer<Float>.allocate(capacity: n)
            var seed: UInt32 = 0x2545F491 &+ UInt32(d)
            for i in 0..<n {
                let t = Double(i) / fs
                seed = seed &* 1664525 &+ 1013904223
                let beat = t.truncatingRemainder(dividingBy: 0.4688)
                let v = Float(0.5 * sin(2 * .pi * 55 * beat) * exp(-beat * 18) + 0.15 * sin(2 * .pi * 220 * t))
                    + 0.05 * Float(Int32(bitPattern: seed)) / Float(Int32.max)
                l[i] = v; r[i] = v
            }
            mem += [l, r]
            mdsp_set_track(e, Int32(d), l, r, Int64(n), fs, 0)
            mdsp_set_param(e, Int32(d), MD_PLAYING, 1)
            mdsp_set_param(e, Int32(d), MD_KEYLOCK, 1)
            mdsp_set_param(e, Int32(d), MD_RATE, d % 2 == 0 ? 1.03 : 0.97)
            mdsp_set_param(e, Int32(d), MD_EQ_LOW, -6)
            if fx { mdsp_set_param(e, Int32(d), MDParam(rawValue: MD_FX1_ASSIGN.rawValue + UInt32(d)), 1) }
        }
        if fx { for u in 0..<2 { setRack(e, Int32(u), groupRack); mdsp_set_fx(e, Int32(u), u == 0 ? MDFX_REVERB_ON : MDFX_DELAY_ON, 1) } }
    }
    deinit { mdsp_destroy(e); mem.forEach { $0.deallocate() } }
}

private struct Stats {
    var render: [Double] = [], late: [Double] = [], control: [Double] = []
    var misses = 0
    static func pct(_ v: [Double], _ p: Double) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        return s[min(s.count - 1, Int(Double(s.count) * p))]
    }
    func line(_ label: String, deadline: Double) -> String {
        String(format: "%@: block p50 %.0f µs · p99 %.0f µs · p99.9 %.0f µs · max %.0f µs · wake late p99 %.0f µs max %.0f µs · misses %d (deadline %.0f µs) · control 200 Hz jitter p99 %.0f µs max %.0f µs",
               label, Self.pct(render, 0.5), Self.pct(render, 0.99), Self.pct(render, 0.999), render.max() ?? 0,
               Self.pct(late, 0.99), late.max() ?? 0, misses, deadline, Self.pct(control, 0.99), control.max() ?? 0)
    }
}

private func ticksPerNs() -> Double {
    var tb = mach_timebase_info_data_t()
    mach_timebase_info(&tb)
    return Double(tb.denom) / Double(tb.numer)
}

/// Echtzeit-Priorität wie ein CoreAudio-IO-Thread
private func makeRealtime(periodNs: Double) {
    let k = ticksPerNs()
    var pol = thread_time_constraint_policy_data_t(period: UInt32(periodNs * k), computation: UInt32(periodNs * 0.5 * k),
                                                   constraint: UInt32(periodNs * k), preemptible: 1)
    let count = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size)
    _ = withUnsafeMutablePointer(to: &pol) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            thread_policy_set(pthread_mach_thread_np(pthread_self()), thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), $0, count)
        }
    }
}

/// `seconds` lang im Takt rendern + Steuertakt messen
private func measure(_ decks: Decks, block: Int, seconds: Double) -> Stats {
    let periodNs = Double(block) / decks.fs * 1e9
    let k = ticksPerNs()
    var stats = Stats()
    let done = DispatchSemaphore(value: 0)
    // Steuertakt: 200 Hz auf einer userInteractive-Queue (wie MixController.tick)
    let q = DispatchQueue(label: "bench.control", qos: .userInteractive)
    let timer = DispatchSource.makeTimerSource(flags: .strict, queue: q)
    var controlLate: [Double] = []
    var last: UInt64 = 0
    timer.schedule(deadline: .now() + .milliseconds(5), repeating: .milliseconds(5), leeway: .milliseconds(1))
    timer.setEventHandler {
        // Abstand zweier Takte gegen 5 ms
        let now = DispatchTime.now().uptimeNanoseconds
        if last > 0 { controlLate.append(abs(Double(Int64(now) - Int64(last)) / 1000 - 5000)) }
        last = now
    }
    timer.resume()
    let t = Thread {
        makeRealtime(periodNs: periodNs)
        var bufs: [UnsafeMutablePointer<Float>?] = (0..<2).map { _ in .allocate(capacity: block) }
        defer { bufs.forEach { $0?.deallocate() } }
        for _ in 0..<50 { bufs.withUnsafeMutableBufferPointer { mdsp_render(decks.e, $0.baseAddress, 2, Int32(block)) } }
        let n = Int(seconds * 1e9 / periodNs)
        stats.render.reserveCapacity(n); stats.late.reserveCapacity(n)
        var next = mach_absolute_time() + UInt64(periodNs * k)
        for _ in 0..<n {
            mach_wait_until(next)
            let a = mach_absolute_time()
            bufs.withUnsafeMutableBufferPointer { mdsp_render(decks.e, $0.baseAddress, 2, Int32(block)) }
            let b = mach_absolute_time()
            let late = Double(a &- next) / k / 1000, dt = Double(b - a) / k / 1000
            stats.render.append(dt); stats.late.append(late)
            if late + dt > periodNs / 1000 { stats.misses += 1 }
            next += UInt64(periodNs * k)
            if b > next { next = b + UInt64(periodNs * k) }   // verpasst: neu einrasten
        }
        done.signal()
    }
    t.qualityOfService = .userInteractive
    t.start()
    done.wait()
    timer.cancel()
    q.sync {}
    stats.control = Array(controlLate.dropFirst(5))
    return stats
}

private func tempStore() -> (OverviewStore, URL) {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("minos-ovbench-\(UUID().uuidString)")
    return (OverviewStore(directory: d), d)
}

/// Arbeiter auf `paths` starten; `playing` = gedrosselt (immer-Modus), sonst volle Geschwindigkeit (Stapel, 2 Arbeiter)
private func startJobs(_ paths: ArraySlice<String>, playing: Bool, explicit: Bool, qos: qos_class_t = QOS_CLASS_BACKGROUND) -> (OverviewJobs, OverviewStore, URL) {
    let (store, dir) = tempStore()
    let jobs = OverviewJobs()
    jobs.throttledQoS = qos
    jobs.store = store
    jobs.setDecks(playing: playing, loading: false)
    let list = paths.enumerated().map { OverviewJobs.Job(key: "b\($0.offset)", path: $0.element, explicit: explicit) }
    if explicit { jobs.enqueue(list) } else { jobs.setBackground(list, collection: list.count, covered: 0, onlineOnly: 0) }
    jobs.start()
    return (jobs, store, dir)
}

@Test(.enabled(if: benchTracks.count >= 100))
func benchOverviewJobsAgainstAudio() {
    let block = Int(ProcessInfo.processInfo.environment["MIX741_BENCH_BLOCK"] ?? "") ?? 256
    let secs = Double(ProcessInfo.processInfo.environment["MIX741_BENCH_SECONDS"] ?? "") ?? 30
    let deadline = Double(block) / 44100 * 1e6
    print("[ovbench] 4 decks keylock + fx, \(block) frames @ 44.1 kHz, \(Int(secs)) s per phase")
    print("[ovbench] " + measure(Decks(count: 4, fx: true), block: block, seconds: secs).line("without job", deadline: deadline))
    var (jobs, store, dir) = startJobs(benchTracks[0..<50], playing: true, explicit: false)
    var t0 = Date()
    print("[ovbench] " + measure(Decks(count: 4, fx: true), block: block, seconds: secs).line("job throttled, qos background", deadline: deadline))
    print(String(format: "[ovbench]   throttled background: %d tracks in %.0f s", store.count, Date().timeIntervalSince(t0)))
    jobs.stopBackground(); waitIdle(jobs); try? FileManager.default.removeItem(at: dir)
    (jobs, store, dir) = startJobs(benchTracks[50..<100], playing: true, explicit: false, qos: QOS_CLASS_UTILITY)
    t0 = Date()
    print("[ovbench] " + measure(Decks(count: 4, fx: true), block: block, seconds: secs).line("job throttled, qos utility", deadline: deadline))
    print(String(format: "[ovbench]   throttled utility: %d tracks in %.0f s", store.count, Date().timeIntervalSince(t0)))
    jobs.stopBackground(); waitIdle(jobs); try? FileManager.default.removeItem(at: dir)
    (jobs, store, dir) = startJobs(benchTracks[100..<200], playing: false, explicit: true)
    t0 = Date()
    print("[ovbench] " + measure(Decks(count: 4, fx: true), block: block, seconds: secs).line("job full speed (2 workers, utility)", deadline: deadline))
    print(String(format: "[ovbench]   full speed: %d tracks in %.0f s", store.count, Date().timeIntervalSince(t0)))
    jobs.cancel(); waitIdle(jobs); try? FileManager.default.removeItem(at: dir)
}

private func waitIdle(_ jobs: OverviewJobs) {
    let end = Date().addingTimeInterval(60)
    while Date() < end, !jobs.isIdle { Thread.sleep(forTimeInterval: 0.05) }
}

/// 100 echte Tracks, gedrosselt, während 2 Decks im Takt rendern: Tracks je Minute
@Test(.enabled(if: benchTracks.count >= 300 && ProcessInfo.processInfo.environment["MIX741_BENCH_THROUGHPUT"] == "1"))
func benchOverviewThroughput() {
    var decks = Decks(count: 2, fx: false)
    let env = ProcessInfo.processInfo.environment
    let qos = env["MIX741_BENCH_QOS"] == "background" ? QOS_CLASS_BACKGROUND : QOS_CLASS_UTILITY
    let from = Int(env["MIX741_BENCH_FROM"] ?? "") ?? 200, count = Int(env["MIX741_BENCH_COUNT"] ?? "") ?? 100
    let (jobs, store, dir) = startJobs(benchTracks[from..<(from + count)], playing: true, explicit: false, qos: qos)
    let t0 = Date()
    var all = Stats()
    while !jobs.isIdle, Date().timeIntervalSince(t0) < 1500 {
        let s = measure(decks, block: 256, seconds: 10)
        decks = Decks(count: 2, fx: false)   // Tracks 70 s lang: neu laden
        all.render += s.render; all.late += s.late; all.control += s.control; all.misses += s.misses
    }
    let secs = Date().timeIntervalSince(t0)
    let p = jobs.snapshot
    print(String(format: "[ovbench] throttled (qos %@), 2 decks playing: %d / %d tracks (%d unreadable) in %.0f s -> %.1f tracks/min",
                 qos == QOS_CLASS_UTILITY ? "utility" : "background", store.count, count, p.failed, secs, Double(store.count) / secs * 60))
    print("[ovbench] " + all.line("2 decks keylock during that run", deadline: 256 / 44100 * 1e6))
    try? FileManager.default.removeItem(at: dir)
}
