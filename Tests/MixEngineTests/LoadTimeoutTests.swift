import Foundation
import Testing
import MixDSP
import MixCore
import MixEngine

/// gesammelte Meldungen des Kerns, mit Zeitstempel: so lässt sich der Abbruch des Wächters messen, ohne dass das
/// Abfragen aus dem Test (unter Last selbst Sekunden verzögert) die Messung verfälscht
private final class Notices: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [(EngineNotice, Date)] = []
    func add(_ n: EngineNotice) { lock.withLock { list.append((n, Date())) } }
    var all: [EngineNotice] { lock.withLock { list.map(\.0) } }
    func time(of f: (EngineNotice) -> Bool) -> Date? { lock.withLock { list.first { f($0.0) }?.1 } }
}

private func controller(timeout: Double) -> (MixController, Notices) {
    let c = MixController()
    var p = EnginePrefs()
    p.loadTimeout = timeout
    c.setPrefs(p)
    let n = Notices()
    c.onNotice = { n.add($0) }
    return (c, n)
}

private func waitLoaded(_ c: MixController, _ d: Int, max seconds: Double) async throws -> Double {
    let t0 = Date()
    while c.snapshot().decks[d].loading, Date().timeIntervalSince(t0) < seconds { try await Task.sleep(for: .milliseconds(10)) }
    return Date().timeIntervalSince(t0)
}

@Test func loadTimeoutDefaultIsFourSeconds() {
    #expect(EnginePrefs().loadTimeout == 4)
}

@Test func missingFileFailsImmediately() async throws {
    let (c, n) = controller(timeout: 4)
    var t = Track(key: "gone", path: "/nonexistent/minos-\(UUID().uuidString).aiff")
    t.artist = "Somebody"; t.title = "Gone"
    // geprüft im Hintergrund (nie auf dem aufrufenden Hauptthread): Meldung nach Millisekunden (Zeitstempel der
    // Meldung, das Abfragen aus dem Test kommt unter Last Sekunden zu spät)
    let t0 = Date()
    c.load(t, deck: 0)
    _ = try await waitLoaded(c, 0, max: 5)
    let failed = n.time(of: { $0.key == "load.0" }).map { $0.timeIntervalSince(t0) } ?? .nan
    #expect(failed < 1)
    let s = c.snapshot().decks[0]
    #expect(!s.loading)
    #expect(s.track == nil)
    #expect(s.error?.contains("Datei fehlt") == true)
    try await Task.sleep(for: .milliseconds(20))
    let e = n.all.first { $0.key == "load.0" }
    #expect(e?.level == .error)
    #expect(e?.text == "Datei fehlt: Somebody – Gone")
    #expect(e?.detail == t.path)
}

/// Dekoder hängt (Cloud-Datei, die nie kommt): nach der Zeitgrenze abgebrochen, Deck leer, das spät fertige
/// Ergebnis wird verworfen, das andere Deck bleibt unberührt
@Test func hungDecoderTimesOutAndIsDiscarded() async throws {
    let (c, n) = controller(timeout: 1)
    let rate = c.engine.sampleRate
    let hung = try writeWAV(rate: rate, channels: 2, seconds: 1)
    let other = try writeWAV(rate: rate, channels: 2, seconds: 2)
    defer { try? FileManager.default.removeItem(at: hung); try? FileManager.default.removeItem(at: other) }
    let real = c.decoder
    c.decoder = { url, r, progress in
        if url == hung { Thread.sleep(forTimeInterval: 2) }   // hängt länger als die Zeitgrenze, liefert dann doch
        return try real(url, r, progress)
    }
    c.load(Track(key: "other", path: other.path), deck: 1)
    _ = try await waitLoaded(c, 1, max: 5)
    #expect(c.snapshot().decks[1].track?.key == "other")
    var t = Track(key: "hung", path: hung.path); t.artist = "A"; t.title = "Hung"
    let t0 = Date()
    c.load(t, deck: 0)
    let seen = try await waitLoaded(c, 0, max: 5)
    let isError = { (e: EngineNotice) in e.key == "load.0" && e.level == .error }
    let cancelled = n.time(of: isError).map { $0.timeIntervalSince(t0) } ?? .nan
    print(String(format: "[load] hängender Dekoder: Abbruch nach %.2f s, im Test gesehen nach %.2f s (Grenze 1 s, Dekoder liefert nach 2 s)", cancelled, seen))
    // Abbruch nach der Grenze (+ 0,25 s Wächter-Takt), sicher bevor der Dekoder nach 2 s doch liefert
    #expect(cancelled > 0.9 && cancelled < 1.9)
    var s = c.snapshot().decks[0]
    #expect(s.track == nil)
    #expect(s.error != nil)
    #expect(c.trackAudio(0) == nil)
    let e = n.all.first(where: isError)
    #expect(e?.text.hasPrefix("Track nicht ladbar (1 s): A – Hung") == true)
    // Dekoder wird nach 2 s doch fertig: darf das Deck nicht mehr belegen
    try await Task.sleep(for: .milliseconds(1600))
    s = c.snapshot().decks[0]
    #expect(s.track == nil)
    #expect(c.trackAudio(0) == nil)
    #expect(c.snapshot().decks[1].track?.key == "other")
    #expect(abs((c.trackAudio(1)?.duration ?? 0) - 2) < 0.05)
}

/// langsamer, aber stetiger Dekoder (große Datei, langsames Laufwerk): kein Abbruch, solange Daten kommen
@Test func slowButProgressingDecodeIsNotCancelled() async throws {
    let (c, _) = controller(timeout: 1)
    let rate = c.engine.sampleRate
    let url = try writeWAV(rate: rate, channels: 2, seconds: 8)
    defer { try? FileManager.default.removeItem(at: url) }
    c.decoder = { u, r, progress in
        try TrackAudio.decode(url: u, sampleRate: r) { frames in
            Thread.sleep(forTimeInterval: 0.4)   // je Block 0,4 s – insgesamt länger als die Zeitgrenze
            return progress(frames)
        }
    }
    c.load(Track(key: "slow", path: url.path), deck: 2)
    let took = try await waitLoaded(c, 2, max: 10)
    #expect(took > 1.2)
    #expect(c.snapshot().decks[2].track?.key == "slow")
    #expect(c.snapshot().decks[2].error == nil)
}

/// unlesbare Datei: sofort Fehler mit Grund, kein Warten auf die Zeitgrenze. Grenze bewusst weit (30 s): unter Last
/// (parallele Tests, Builds) dauert allein das Einplanen des Dekoders Sekunden; gezählt wird, dass der Fehler vom
/// Dekoder kommt (Text ohne Zeitangabe) und lange vor der Grenze
@Test func unreadableFileFailsWithReason() async throws {
    let (c, n) = controller(timeout: 30)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("minos-bad-\(UUID().uuidString).mp3")
    try Data("kein audio".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    c.load(Track(key: "bad", path: url.path), deck: 3)
    let t0 = Date()
    let seen = try await waitLoaded(c, 3, max: 25)
    let failed = n.time { $0.key == "load.3" && $0.level == .error }.map { $0.timeIntervalSince(t0) } ?? .nan
    print(String(format: "[load] unlesbare Datei: Fehler nach %.2f s, im Test gesehen nach %.2f s", failed, seen))
    #expect(failed < 20)   // gemessen unter Last 150 (16 Rechenschleifen + ganze Suite): 16 s bis der Dekoder überhaupt dran ist
    #expect(c.snapshot().decks[3].error != nil)
    try await Task.sleep(for: .milliseconds(20))
    #expect(n.all.contains { $0.key == "load.3" && $0.level == .error && $0.text.hasPrefix("Track nicht ladbar: ") })
}

/// Messung der DSP-Last im Render-Callback: mach_absolute_time + Eintragen kostet deutlich unter 1 µs je Block
@Test func loadInstrumentationCost() {
    mdsp_load_set_rate(48000)
    let n = 1_000_000
    let t0 = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<n {
        let a = mach_absolute_time()
        mdsp_load_record(a, mach_absolute_time(), 256)
    }
    let ns = Double(DispatchTime.now().uptimeNanoseconds - t0) / Double(n)
    let l = mdsp_load_take()
    print(String(format: "[bench] DSP-Last-Messung: %.1f ns je Block (%u Blöcke)", ns, l.blocks))
    #expect(ns < 1000)
    #expect(l.blocks == UInt32(n))
    #expect(l.average >= 0 && l.average < 0.01)
    mdsp_load_reset_overloads()
    mdsp_load_set_rate(0)
}
