import Foundation
import Testing
@testable import LibraryCloud

@Test func scanKeepsOrderAndCounts() {
    let fs = FakeCloudFS()
    var paths: [String] = []
    for i in 0..<2000 {
        let p = "/lib/t\(i).mp3"
        paths.append(p)
        fs.add(p, i % 10 == 0 ? .cloud : .local, size: Int64(i))
    }
    paths.append("/lib/gone.mp3")
    let r = CloudScanner(fs: fs, workers: 4).scan(paths)
    #expect(r.probes.count == 2001)
    #expect(r.count(.cloud) == 200)
    #expect(r.count(.local) == 1800)
    #expect(r.count(.missing) == 1)
    #expect(r.probes[10].state == .cloud && r.probes[11].state == .local && r.probes[11].size == 11)
    #expect(r.timedOut == 0 && !r.aborted)
}

@Test func scanTimesOutHangingProbes() {
    let fs = FakeCloudFS()
    var paths: [String] = []
    for i in 0..<200 {
        let p = "/lib/t\(i).mp3"
        paths.append(p)
        fs.add(p, .local, hang: [5, 50, 150].contains(i) ? 3 : 0)
    }
    let t0 = Date()
    let r = CloudScanner(fs: fs, workers: 2, timeout: 0.2, maxHung: 8).scan(paths)
    #expect(Date().timeIntervalSince(t0) < 1.5)
    #expect(r.timedOut == 3 && !r.aborted)
    #expect(r.probes[5].state == .unknown && r.probes[50].state == .unknown && r.probes[150].state == .unknown)
    #expect(r.count(.local) == 197)
}

@Test func scanAbortsWhenProviderHangs() {
    let fs = FakeCloudFS()
    let paths = (0..<100).map { "/lib/t\($0).mp3" }
    for p in paths { fs.add(p, .local, hang: 5) }
    let t0 = Date()
    let r = CloudScanner(fs: fs, workers: 2, timeout: 0.1, maxHung: 3).scan(paths)
    #expect(Date().timeIntervalSince(t0) < 1.5)
    #expect(r.aborted)
    #expect(r.count(.unknown) == 100)
}

@Test func scanCancels() {
    let fs = FakeCloudFS()
    let paths = (0..<50).map { "/lib/t\($0).mp3" }
    for p in paths { fs.add(p, .local, hang: 0.05) }
    let stop = Date().addingTimeInterval(0.2)
    let r = CloudScanner(fs: fs, workers: 1, timeout: 2).scan(paths, cancelled: { Date() > stop })
    #expect(r.aborted)
    #expect(r.count(.local) < 50)
    #expect(r.probes.count == 50)
}

@Test func emptyScan() {
    #expect(CloudScanner(fs: FakeCloudFS()).scan([]).probes.isEmpty)
}

/// echtes Dateisystem: lokale Datei, fehlende Datei, Ordner; nichts geladen
@Test func systemProbeLocalAndMissing() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cloudtest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let f = dir.appendingPathComponent("a.wav")
    try Data(count: 1234).write(to: f)
    let fs = SystemCloudFileSystem()
    #expect(fs.probe(f.path) == FileProbe(.local, size: 1234))
    #expect(fs.probe(dir.appendingPathComponent("b.wav").path).state == .missing)
    #expect(fs.probe(dir.path).state == .missing)
    #expect((fs.freeBytes(near: f.path) ?? 0) > 0)
    // Thread-Richtlinie danach unverändert
    #expect(getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD) == 0)
}

/// echte Library prüfen (nur lesen), nur mit CLOUD_LIVE_SCAN=<datei mit einem pfad je zeile>
@Test func liveScan() throws {
    guard let file = ProcessInfo.processInfo.environment["CLOUD_LIVE_SCAN"] else { return }
    let paths = try String(contentsOfFile: file, encoding: .utf8).split(separator: "\n").map(String.init)
    for run in 1...3 {
        let r = CloudScanner().scan(paths)
        print(String(format: "[live] lauf %d: %d pfade in %.3f s · lokal %d · nur online %d · fehlen %d · unbekannt %d · zeitgrenze %d",
                     run, paths.count, r.seconds, r.count(.local), r.count(.cloud), r.count(.missing), r.count(.unknown), r.timedOut))
    }
    let folder = CloudPaths.libraryFolder(paths)
    print("[live] library-ordner \(folder ?? "-") · beobachtet \(CloudPaths.watchRoots(paths))")
    if let folder {
        let t0 = Date()
        let s = CloudPin.status(of: folder)
        print(String(format: "[live] anheften %@ · alles lokal %@ · immer behalten %@ · %.0f ms", "\(s.pin)",
                     "\(s.recursivelyDownloaded.map(String.init) ?? "-")", "\(s.keepDownloaded.map(String.init) ?? "-")", Date().timeIntervalSince(t0) * 1000))
    }
}
