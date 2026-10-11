import Foundation
import Testing
import MixCore
import MixEngine

/// Meldungen mit Zeitstempel (wie LoadTimeoutTests)
private final class Notices: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [(EngineNotice, Date)] = []
    func add(_ n: EngineNotice) { lock.withLock { list.append((n, Date())) } }
    var all: [EngineNotice] { lock.withLock { list.map(\.0) } }
    func time(of f: (EngineNotice) -> Bool) -> Date? { lock.withLock { list.first { f($0.0) }?.1 } }
}

private func serviceController(_ env: [String: String] = [:], soft: Double = 1, hard: Double = 5)
    -> (MixController, FileServiceClient, Notices, URL)? {
    guard let helperURL else { print("[files] minos-files nicht gebaut, Test übersprungen"); return nil }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("minos-load-test-\(UUID().uuidString)")
    var cfg = FileServiceClient.Config(helper: helperURL, cacheDir: dir)
    cfg.environment = env
    let fs = FileServiceClient(cfg)
    let c = MixController()
    var p = EnginePrefs()
    p.loadTimeout = soft
    p.loadAbortTimeout = hard
    c.setPrefs(p)
    c.fileService = fs
    let n = Notices()
    c.onNotice = { n.add($0) }
    return (c, fs, n, dir)
}

private func waitLoaded(_ c: MixController, _ d: Int, max seconds: Double) async throws -> Double {
    let t0 = Date()
    while c.snapshot().decks[d].loading, Date().timeIntervalSince(t0) < seconds { try await Task.sleep(for: .milliseconds(10)) }
    return Date().timeIntervalSince(t0)
}

/// Laden über den Helfer: Deck bekommt eine eingeblendete Datei, zweites Laden aus dem Cache
@Test func controllerLoadsThroughService() async throws {
    guard let (c, fs, _, dir) = serviceController() else { return }
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try writeWAV(rate: c.engine.sampleRate, channels: 2, seconds: 3)
    defer { try? FileManager.default.removeItem(at: url) }
    c.load(Track(key: "a", path: url.path), deck: 0)
    _ = try await waitLoaded(c, 0, max: 10)
    #expect(c.snapshot().decks[0].track?.key == "a")
    #expect(c.trackAudio(0)?.mapping != nil)
    #expect(abs((c.trackAudio(0)?.duration ?? 0) - 3) < 0.01)
    c.load(Track(key: "b", path: url.path), deck: 1)
    _ = try await waitLoaded(c, 1, max: 10)
    #expect(c.snapshot().decks[1].track?.key == "b" && fs.stats.cacheHits == 1)
}

@Test func serviceMissingFileFailsImmediately() async throws {
    guard let (c, _, n, dir) = serviceController() else { return }
    defer { try? FileManager.default.removeItem(at: dir) }
    var t = Track(key: "gone", path: "/nonexistent/minos-\(UUID().uuidString).aiff")
    t.artist = "Somebody"; t.title = "Gone"
    let t0 = Date()
    c.load(t, deck: 0)
    _ = try await waitLoaded(c, 0, max: 5)
    let failed = n.time(of: { $0.key == "load.0" && $0.level == .error }).map { $0.timeIntervalSince(t0) } ?? .nan
    #expect(failed < 2)
    #expect(c.snapshot().decks[0].error?.contains("Datei fehlt") == true)
    #expect(n.all.contains { $0.text == "Datei fehlt: Somebody – Gone" })
}

/// Cloud-Datei kommt nicht: nach der ersten Grenze nur ein Hinweis (Deck lädt weiter), nach der zweiten wird der
/// Helfer abgeschossen und das Laden abgebrochen; das andere Deck bleibt unberührt
@Test func serviceHangWarnsThenAborts() async throws {
    guard let (c, fs, n, dir) = serviceController(["MIX741_FAULT": "hang-open:*minos-hang*"], soft: 1, hard: 5) else { return }
    defer { try? FileManager.default.removeItem(at: dir) }
    var t = Track(key: "hang", path: "/tmp/minos-hang-\(UUID().uuidString).flac")
    t.artist = "A"; t.title = "Hung"
    // Helfer vorab starten (wie die App): der Start zählt nicht zur Grenze
    fs.warmUp()
    let w0 = Date()
    while fs.stats.spawns == 0, Date().timeIntervalSince(w0) < 10 { try await Task.sleep(for: .milliseconds(10)) }
    let lag = LagProbe()
    let t0 = Date()
    c.load(t, deck: 2)
    try await Task.sleep(for: .milliseconds(2500))
    let warned = n.time(of: { $0.key == "load.2" && $0.level == .warning }).map { $0.timeIntervalSince(t0) } ?? .nan
    #expect(warned > 0.9 && warned < 2.2 + lag.max)
    #expect(n.all.contains { $0.text.hasPrefix("Deck C lädt noch (1 s ohne Daten): A – Hung") })
    _ = try await waitLoaded(c, 2, max: 10)
    let failed = n.time(of: { $0.key == "load.2" && $0.level == .error }).map { $0.timeIntervalSince(t0) } ?? .nan
    print(String(format: "[load] Datei-Dienst, hängende Datei: Hinweis nach %.2f s, Abbruch nach %.2f s (Grenzen 1 / 5 s, Verzug %.2f s)", warned, failed, lag.max))
    #expect(failed > 4.9 && failed < 7 + lag.max)   // Zeitstempel der Meldungen: das Abfragen im Test kommt unter Last zu spät
    #expect(warned < failed)
    #expect(c.snapshot().decks[2].track == nil)
    #expect(n.all.contains { $0.text.hasPrefix("Track nicht ladbar (5 s): A – Hung · keine Audiodaten (Drive antwortet nicht)") })
    #expect(fs.stats.kills == 1)
}

/// anderer Track ins Deck, während der erste hängt: alter Helfer sofort abgeschossen, neuer Track lädt gleich
@Test func serviceNewLoadKillsHangingOne() async throws {
    guard let (c, fs, _, dir) = serviceController(["MIX741_FAULT": "hang-open:*minos-hang*"], soft: 1, hard: 30) else { return }
    defer { try? FileManager.default.removeItem(at: dir) }
    let ok = try writeWAV(rate: c.engine.sampleRate, channels: 2, seconds: 2)
    defer { try? FileManager.default.removeItem(at: ok) }
    c.load(Track(key: "hang", path: "/tmp/minos-hang-x.flac"), deck: 0)
    try await Task.sleep(for: .milliseconds(300))
    c.load(Track(key: "ok", path: ok.path), deck: 0)
    let took = try await waitLoaded(c, 0, max: 10)
    #expect(c.snapshot().decks[0].track?.key == "ok")
    #expect(took < 3)
    try await Task.sleep(for: .milliseconds(300))
    #expect(fs.stats.kills == 1)
    print(String(format: "[load] Datei-Dienst: hängender Track abgelöst, neuer Track nach %.0f ms", took * 1000))
}

/// Helfer startet nicht: Laden geht im Prozess weiter, mit Hinweis
@Test func serviceUnavailableFallsBackInProcess() async throws {
    guard let (c, _, n, dir) = serviceController(["MIX741_FAULT": "crash-start"]) else { return }
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try writeWAV(rate: c.engine.sampleRate, channels: 2, seconds: 1)
    defer { try? FileManager.default.removeItem(at: url) }
    c.load(Track(key: "a", path: url.path), deck: 3)
    _ = try await waitLoaded(c, 3, max: 10)
    #expect(c.snapshot().decks[3].track?.key == "a")
    #expect(c.trackAudio(3)?.mapping == nil)
    #expect(n.all.contains { $0.key == "files" && $0.level == .warning })
}
