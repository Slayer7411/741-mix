import AVFoundation
import Foundation
import Testing
import MixCore
import MixEngine

/// Testdatei: erst Bass (60 Hz, Pegel 0.8), dann Höhen (8 kHz, Pegel 0.3)
private func writeTwoPart(rate: Double, seconds: Double) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("minos-ov-\(UUID().uuidString).wav")
    let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    let file = try AVAudioFile(forWriting: url, settings: fmt.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let n = AVAudioFrameCount(seconds * rate)
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n)!
    buf.frameLength = n
    for c in 0..<2 {
        for i in 0..<Int(n) {
            let t = Double(i) / rate
            buf.floatChannelData![c][i] = Float(i < Int(n) / 2 ? 0.8 * sin(2 * .pi * 60 * t) : 0.3 * sin(2 * .pi * 8000 * t))
        }
    }
    try file.write(from: buf)
    return url
}

/// Übersicht aus der Datei (blockweise): Länge, Pegel und Bänder je Hälfte
@Test func overviewFromFile() throws {
    let url = try writeTwoPart(rate: 44100, seconds: 6)
    defer { try? FileManager.default.removeItem(at: url) }
    let o = try OverviewAnalyzer.analyze(url: url)
    #expect(o.count == TrackOverview.points)
    #expect(abs(o.duration - 6) < 0.01)
    let n = o.count
    let first = (5..<(n / 2 - 5)), second = ((n / 2 + 5)..<(n - 5))
    #expect(first.allSatisfy { abs(o.peak($0) - 0.8) < 0.03 && o.low($0) > 0.8 && o.high($0) < 0.05 })
    #expect(second.allSatisfy { abs(o.peak($0) - 0.3) < 0.03 && o.high($0) > 0.85 && o.low($0) < 0.05 })
}

/// gleiche Übersicht wie aus dem Deck-Puffer (gleiche Rate) -> Browser und Deck zeigen dasselbe
@Test func overviewMatchesDeckAudio() throws {
    let url = try writeTwoPart(rate: 44100, seconds: 4)
    defer { try? FileManager.default.removeItem(at: url) }
    let a = TrackOverview(audio: try TrackAudio.decode(url: url, sampleRate: 44100))
    let b = try OverviewAnalyzer.analyze(url: url)
    #expect(a.count == b.count)
    #expect(abs(a.duration - b.duration) < 0.001)
    let diff = zip(a.bytes, b.bytes).map { abs(Int($0) - Int($1)) }.max() ?? 0
    #expect(diff <= 3)
}

/// Pause/Abbruch: checkpoint läuft je Lese-Block, ein Fehler bricht ab
@Test func overviewCheckpointCancels() throws {
    let url = try writeTwoPart(rate: 44100, seconds: 5)
    defer { try? FileManager.default.removeItem(at: url) }
    struct Stop: Error {}
    var calls = 0
    #expect(throws: Stop.self) {
        _ = try OverviewAnalyzer.analyze(url: url) { calls += 1; if calls == 3 { throw Stop() } }
    }
    #expect(calls == 3)
}

// MARK: - Warteschlange + Arbeiter

private final class Order: @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String] = []
    func add(_ k: String) { lock.lock(); keys.append(k); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return keys }
}

private func waitUntil(_ seconds: Double, _ done: () -> Bool) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end, !done() { Thread.sleep(forTimeInterval: 0.02) }
}

/// Reihenfolge: Rechtsklick-Stapel, dann sichtbare Zeilen (zuletzt gezeigte zuerst), dann Hintergrund (Liste vorne zuerst);
/// nicht lesbare Datei wird gezählt und hält nichts auf; Zähler der Statuszeile
@Test func overviewJobsOrderAndCounters() throws {
    let urls = try (0..<6).map { _ in try writeTwoPart(rate: 44100, seconds: 1) }
    let bad = FileManager.default.temporaryDirectory.appendingPathComponent("minos-bad-\(UUID().uuidString).wav")
    try Data(repeating: 7, count: 4096).write(to: bad)
    defer { (urls + [bad]).forEach { try? FileManager.default.removeItem(at: $0) } }
    let store = OverviewStore(directory: nil)
    let order = Order()
    let jobs = OverviewJobs()
    jobs.maxWorkers = 1
    store.onChange = { order.add($0); jobs.stored($0) }
    jobs.store = store
    let job = { (i: Int, e: Bool) in OverviewJobs.Job(key: "k\(i)", path: urls[i].path, explicit: e) }
    jobs.setBackground([job(0, false), job(1, false), .init(key: "bad", path: bad.path, explicit: false)],
                       collection: 10, covered: 4, onlineOnly: 2)
    jobs.want(key: "k2", path: urls[2].path)
    jobs.want(key: "k3", path: urls[3].path)
    jobs.enqueue([job(4, true), job(5, true)])
    #expect(jobs.snapshot.total == 2 && jobs.snapshot.left == 3)
    jobs.start()
    waitUntil(20) { jobs.isIdle }
    #expect(order.all == ["k4", "k5", "k3", "k2", "k0", "k1"])
    let p = jobs.snapshot
    #expect(p.covered == 6)   // 4 + k0 + k1
    #expect(p.collection == 10 && p.onlineOnly == 2 && p.failed == 1 && p.left == 0)
    #expect(p.total == 0 && p.done == 0)   // Stapel fertig -> zurückgesetzt
}

/// lädt ein Deck: nichts rechnen (auch der Stapel nicht), danach die Wartezeit; dann gedrosselt, solange ein Deck spielt
@Test func overviewJobsPauseWhileLoading() throws {
    let url = try writeTwoPart(rate: 44100, seconds: 1)
    defer { try? FileManager.default.removeItem(at: url) }
    let store = OverviewStore(directory: nil)
    let jobs = OverviewJobs()
    jobs.store = store
    jobs.setDecks(playing: true, loading: true)
    jobs.enqueue([.init(key: "a", path: url.path, explicit: true)])
    jobs.start()
    Thread.sleep(forTimeInterval: 0.6)
    #expect(store.count == 0)
    #expect(jobs.snapshot.gate == .wait(.loading))
    jobs.setDecks(playing: true, loading: false)   // Ende des Ladens -> Wartezeit
    Thread.sleep(forTimeInterval: 0.6)
    #expect(store.count == 0 && jobs.snapshot.gate == .wait(.loading))
    jobs.noteLoadEnded(at: ProcessInfo.processInfo.systemUptime - OverviewPolicy.settle - 1)
    waitUntil(20) { store.count == 1 }
    #expect(store.count == 1)
    #expect(jobs.snapshot.gate == .throttled)
}

/// nur wenn kein Deck spielt: wartet beim Spielen; aus: Hintergrund und sichtbare Zeilen leer, Stapel rechnet
@Test func overviewJobsModes() throws {
    let urls = try (0..<2).map { _ in try writeTwoPart(rate: 44100, seconds: 1) }
    defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
    let store = OverviewStore(directory: nil)
    let jobs = OverviewJobs()
    jobs.store = store
    jobs.setMode(.idleOnly)
    jobs.setDecks(playing: true, loading: false)
    jobs.setBackground([.init(key: "a", path: urls[0].path, explicit: false)], collection: 1, covered: 0, onlineOnly: 0)
    jobs.start()
    Thread.sleep(forTimeInterval: 0.6)
    #expect(store.count == 0 && jobs.snapshot.gate == .wait(.playing))
    jobs.setDecks(playing: false, loading: false)
    waitUntil(20) { jobs.isIdle }
    #expect(store.count == 1)
    jobs.setMode(.off)
    jobs.want(key: "b", path: urls[1].path)
    #expect(jobs.isIdle)
    jobs.enqueue([.init(key: "b", path: urls[1].path, explicit: true)])
    waitUntil(20) { jobs.isIdle }
    #expect(store.count == 2)
}
