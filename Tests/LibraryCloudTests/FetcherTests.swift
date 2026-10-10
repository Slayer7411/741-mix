import Foundation
import Testing
@testable import LibraryCloud

private let t0 = Date(timeIntervalSinceReferenceDate: 2_000_000)
private func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

private func cfg(_ f: (inout FetchConfig) -> Void = { _ in }) -> FetchConfig {
    var c = FetchConfig()
    c.maxParallel = 2
    c.minTimeout = 60
    c.retryDelay = 5
    c.minFreeBytes = 0
    f(&c)
    return c
}

@Test func fetchInParallelAndVerify() {
    let fs = FakeCloudFS()
    let paths = (0..<5).map { "/lib/t\($0).mp3" }
    for p in paths { fs.add(p, .cloud, size: 100) }
    let f = CloudFetcher(fs: fs, config: cfg())
    f.enqueue(paths.map { FetchItem(path: $0, size: 100) }, batch: "b", label: "Auswahl", now: t0)
    #expect(f.tick(now: at(0)).isEmpty)
    #expect(fs.requestLog == ["/lib/t0.mp3", "/lib/t1.mp3"])
    #expect(f.activePaths == ["/lib/t0.mp3", "/lib/t1.mp3"])
    fs.complete("/lib/t0.mp3")
    let e = f.tick(now: at(1))
    #expect(e == [FetchEvent(path: "/lib/t0.mp3", batches: ["b"], outcome: .ready, attempts: 1)])
    #expect(fs.requestLog.count == 3)
    for p in paths { fs.complete(p) }
    var all: [FetchEvent] = e
    for s in 2..<6 { all += f.tick(now: at(Double(s))) }
    // t3/t4 waren schon fertig, bevor sie dran waren -> alreadyLocal
    #expect(all.count == 5 && all.allSatisfy(\.outcome.isSuccess))
    #expect(fs.requestLog.count == 3)
    let p = f.progress("b")!
    #expect(p.total == 5 && p.finished == 5 && p.failed == 0 && p.bytesDone == 500 && p.isDone)
    #expect(f.isIdle)
}

@Test func skipsLocalAndMissing() {
    let fs = FakeCloudFS()
    fs.add("/lib/local.mp3", .local)
    fs.add("/lib/cloud.mp3", .cloud)
    let f = CloudFetcher(fs: fs, config: cfg())
    f.enqueue([FetchItem(path: "/lib/local.mp3"), FetchItem(path: "/lib/gone.mp3"), FetchItem(path: "/lib/cloud.mp3")], batch: "b", now: t0)
    let e = f.tick(now: t0)
    #expect(e.map(\.outcome) == [.alreadyLocal, .missing])
    #expect(fs.requestLog == ["/lib/cloud.mp3"])
    #expect(f.progress("b")?.failed == 1)
}

@Test func pausedStartsOnlyDeckLoads() {
    let fs = FakeCloudFS()
    for p in ["/a", "/b", "/deck"] { fs.add(p, .cloud) }
    let f = CloudFetcher(fs: fs, config: cfg())
    f.enqueue([FetchItem(path: "/a"), FetchItem(path: "/b")], batch: "user", now: t0)
    _ = f.tick(now: t0, paused: true)
    #expect(fs.requestLog.isEmpty)
    f.enqueue([FetchItem(path: "/deck")], batch: "deck", priority: .deck, now: t0)
    _ = f.tick(now: at(1), paused: true)
    #expect(fs.requestLog == ["/deck"])
    _ = f.tick(now: at(2), paused: false)
    #expect(fs.requestLog == ["/deck", "/a"])
    fs.complete("/deck")
    _ = f.tick(now: at(3), paused: false)
    #expect(fs.requestLog == ["/deck", "/a", "/b"])
}

@Test func priorityOrderAndKeepIsLowest() {
    let fs = FakeCloudFS()
    for p in ["/k1", "/k2", "/u1", "/d1"] { fs.add(p, .cloud) }
    let f = CloudFetcher(fs: fs, config: cfg { $0.maxParallel = 1 })
    f.enqueue([FetchItem(path: "/k1"), FetchItem(path: "/k2")], batch: "keep", priority: .keep, now: t0)
    f.enqueue([FetchItem(path: "/u1")], batch: "user", now: t0)
    f.enqueue([FetchItem(path: "/d1")], batch: "deck", priority: .deck, now: t0)
    _ = f.tick(now: t0)
    // Deck zuerst (darf einen über die Grenze), dann Bereitmachen
    #expect(fs.requestLog == ["/d1"])
    fs.complete("/d1")
    _ = f.tick(now: at(1))
    #expect(fs.requestLog == ["/d1", "/u1"])
    fs.complete("/u1")
    _ = f.tick(now: at(2))
    // Lokal-halten: höchstens einer gleichzeitig
    #expect(fs.requestLog == ["/d1", "/u1", "/k1"])
    _ = f.tick(now: at(3))
    #expect(fs.requestLog.count == 3)
    fs.complete("/k1")
    _ = f.tick(now: at(4))
    #expect(fs.requestLog.last == "/k2")
}

@Test func keepWaitsForUserBatches() {
    let fs = FakeCloudFS()
    for p in ["/k", "/u1", "/u2", "/u3"] { fs.add(p, .cloud) }
    let f = CloudFetcher(fs: fs, config: cfg { $0.maxParallel = 2 })
    f.enqueue([FetchItem(path: "/k")], batch: "keep", priority: .keep, now: t0)
    f.enqueue(["/u1", "/u2", "/u3"].map { FetchItem(path: $0) }, batch: "user", now: t0)
    _ = f.tick(now: t0)
    fs.complete("/u1")
    _ = f.tick(now: at(1))
    #expect(fs.requestLog == ["/u1", "/u2", "/u3"])
}

@Test func timeoutRetryThenFail() {
    let fs = FakeCloudFS()
    fs.add("/slow", .cloud, size: 1000)
    let f = CloudFetcher(fs: fs, config: cfg { $0.maxAttempts = 2 })
    f.enqueue([FetchItem(path: "/slow")], batch: "b", now: t0)
    _ = f.tick(now: t0)
    #expect(f.tick(now: at(61)).isEmpty)          // Zeitgrenze -> neuer Versuch nach 5 s
    #expect(f.tick(now: at(62)).isEmpty)
    #expect(fs.requestLog.count == 1)
    _ = f.tick(now: at(67))
    #expect(fs.requestLog.count == 2)
    let e = f.tick(now: at(67 + 61))
    #expect(e == [FetchEvent(path: "/slow", batches: ["b"], outcome: .failed("Zeitüberschreitung"), attempts: 2)])
    #expect(f.isIdle)
}

@Test func timeoutScalesWithSize() {
    var c = FetchConfig()
    c.minTimeout = 60
    c.minRate = 256 * 1024
    #expect(c.timeout(size: 1_000_000) == 60)
    #expect(abs(c.timeout(size: 100 << 20) - 400) < 0.001)
}

@Test func failingRequestRetries() {
    let fs = FakeCloudFS()
    fs.add("/x", .cloud, failRequests: 1)
    fs.add("/y", .cloud, failRequests: 5)
    let f = CloudFetcher(fs: fs, config: cfg { $0.maxAttempts = 2 })
    f.enqueue([FetchItem(path: "/x"), FetchItem(path: "/y")], batch: "b", now: t0)
    _ = f.tick(now: t0)
    let e = f.tick(now: at(10))
    #expect(f.activePaths == ["/x"])
    #expect(e.map(\.outcome) == [.failed("anbieter nicht erreichbar")])
}

@Test func keepsFreeSpace() {
    let fs = FakeCloudFS()
    fs.add("/big", .cloud, size: 5 << 30)
    fs.add("/next", .cloud, size: 1)
    fs.free = 12 << 30
    let f = CloudFetcher(fs: fs, config: cfg { $0.minFreeBytes = 10 << 30 })
    f.enqueue([FetchItem(path: "/big"), FetchItem(path: "/next")], batch: "b", now: t0)
    let e = f.tick(now: t0)
    #expect(e.map(\.outcome) == [.noSpace])
    #expect(fs.requestLog.isEmpty)
    _ = f.tick(now: at(1))
    #expect(fs.requestLog == ["/next"])
}

@Test func byteAndTimeBudget() {
    let fs = FakeCloudFS()
    for p in ["/1", "/2", "/3", "/4"] { fs.add(p, .cloud, size: 100 << 20) }
    let f = CloudFetcher(fs: fs, config: cfg { $0.maxParallel = 4 })
    f.enqueue(["/1", "/2", "/3"].map { FetchItem(path: $0) }, batch: "b", budget: FetchBudget(maxBytes: 250 << 20), now: t0)
    let e = f.tick(now: t0)
    #expect(fs.requestLog == ["/1", "/2"])
    #expect(e.map(\.outcome) == [.overBudget])

    let g = CloudFetcher(fs: fs, config: cfg { $0.maxParallel = 1 })
    g.enqueue(["/4", "/3"].map { FetchItem(path: $0) }, batch: "t", budget: FetchBudget(maxSeconds: 30), now: t0)
    _ = g.tick(now: t0)
    let late = g.tick(now: at(31))
    #expect(late.map(\.path) == ["/3"] && late.first?.outcome == .overBudget)
}

@Test func cancelBatchKeepsSharedPaths() {
    let fs = FakeCloudFS()
    for p in ["/a", "/b", "/c"] { fs.add(p, .cloud) }
    let f = CloudFetcher(fs: fs, config: cfg { $0.maxParallel = 1 })
    f.enqueue(["/a", "/b"].map { FetchItem(path: $0) }, batch: "x", now: t0)
    f.enqueue(["/b", "/c"].map { FetchItem(path: $0) }, batch: "y", now: t0)
    _ = f.tick(now: t0)
    #expect(fs.requestLog == ["/a"])
    let ev = f.cancel(batch: "x")
    #expect(ev.map(\.path) == ["/a"])            // /b bleibt für y
    #expect(f.progress("x") == nil)
    _ = f.tick(now: at(1))
    #expect(fs.requestLog == ["/a", "/b"])
    #expect(f.queuedPaths == ["/c"])
}

@Test func sharedPathCountsForBothBatches() {
    let fs = FakeCloudFS()
    fs.add("/s", .cloud, size: 10)
    let f = CloudFetcher(fs: fs, config: cfg())
    f.enqueue([FetchItem(path: "/s", size: 10)], batch: "x", priority: .keep, now: t0)
    f.enqueue([FetchItem(path: "/s", size: 10)], batch: "y", now: t0)
    _ = f.tick(now: t0)
    fs.complete("/s")
    let e = f.tick(now: at(1))
    #expect(e.count == 1 && Set(e[0].batches) == ["x", "y"])
    #expect(f.progress("x")?.isDone == true && f.progress("y")?.isDone == true)
    #expect(fs.requestLog == ["/s"])
    #expect(f.overall().total == 1)                // nur Bereitmachen
    #expect(f.overall(minPriority: .keep).total == 2)
}

/// echter Download, nur mit CLOUD_LIVE_FILES=pfad1:pfad2 (Dateien in einem Cloud-Ordner)
@Test func liveDownload() throws {
    guard let list = ProcessInfo.processInfo.environment["CLOUD_LIVE_FILES"] else { return }
    let paths = list.split(separator: ":").map(String.init)
    let fs = SystemCloudFileSystem()
    let before = paths.map { fs.probe($0).state }
    let f = CloudFetcher(fs: fs, config: { var c = FetchConfig(); c.minFreeBytes = 1 << 30; return c }())
    f.enqueue(paths.map { FetchItem(path: $0) }, batch: "live", now: Date())
    let start = Date()
    var events: [FetchEvent] = []
    while !f.isIdle, Date().timeIntervalSince(start) < 120 {
        events += f.tick(now: Date())
        Thread.sleep(forTimeInterval: 0.25)
    }
    let secs = Date().timeIntervalSince(start)
    print("[live] vorher \(before) · \(String(format: "%.2f", secs)) s · " + events.map { "\(($0.path as NSString).lastPathComponent)=\($0.outcome)" }.joined(separator: " "))
    #expect(paths.allSatisfy { fs.probe($0).state == .local })
}
