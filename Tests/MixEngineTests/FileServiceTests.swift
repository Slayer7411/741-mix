import Foundation
import Testing
import MixEngine
import MixMedia
import MixProtocol

/// gebauter Helfer (.build/<konfig>/minos-files); fehlt er, laufen diese Tests nicht
let helperURL: URL? = {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    for c in ["debug", "release"] {
        let u = root.appendingPathComponent(".build/\(c)/\(FileProtocol.helperName)")
        if FileManager.default.isExecutableFile(atPath: u.path) { return u }
    }
    return nil
}()

private func client(_ env: [String: String] = [:], limit: Int64 = 1 << 30, beat: Double = 3) -> (FileServiceClient, URL)? {
    guard let helperURL else { print("[files] minos-files nicht gebaut, Test übersprungen"); return nil }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("minos-files-test-\(UUID().uuidString)")
    var c = FileServiceClient.Config(helper: helperURL, cacheDir: dir, cacheLimit: limit)
    c.environment = env
    c.beatTimeout = beat
    return (FileServiceClient(c), dir)
}

private func error(_ f: () throws -> Any) -> FileServiceClient.ServiceError? {
    do { _ = try f(); return nil } catch let e as FileServiceClient.ServiceError { return e } catch { return .invalid("\(error)") }
}

/// über den Helfer = bit-gleich mit dem Dekodieren im Prozess; zweites Laden aus dem Cache
@Test func helperDecodeMatchesInProcess() throws {
    guard let (c, dir) = client() else { return }
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try writeWAV(rate: 44100, channels: 2, seconds: 20)
    defer { try? FileManager.default.removeItem(at: url) }
    let t0 = Date()
    let ref = try TrackAudio.decode(url: url, sampleRate: 48000)
    let tIn = Date().timeIntervalSince(t0)
    var stages: [DecodeStage] = []
    let t1 = Date()
    let a = try c.decode(path: url.path, sampleRate: 48000, hardTimeout: 10, progress: { s, _ in if stages.last != s { stages.append(s) } })
    let tCold = Date().timeIntervalSince(t1)
    #expect(a.mapping != nil && a.frames == ref.frames)
    #expect(memcmp(a.left, ref.left, ref.frames * 4) == 0 && memcmp(a.right, ref.right, ref.frames * 4) == 0)
    #expect(Array(a.peak) == Array(ref.peak) && Array(a.high) == Array(ref.high) && a.spectrum == ref.spectrum)
    #expect(stages.contains(.decoding))
    let t2 = Date()
    let b = try c.decode(path: url.path, sampleRate: 48000, hardTimeout: 10)
    let tHit = Date().timeIntervalSince(t2)
    #expect(memcmp(b.left, ref.left, ref.frames * 4) == 0)
    #expect(c.stats.cacheHits == 1 && c.stats.decodes == 1)
    // andere Rate = eigener Eintrag
    _ = try c.decode(path: url.path, sampleRate: 44100, hardTimeout: 10)
    #expect(c.stats.decodes == 2 && c.cacheUsage().files == 2)
    print(String(format: "[files] 20 s Stereo 44,1 -> 48 kHz: im Prozess %.0f ms, Helfer kalt %.0f ms, Cache-Treffer %.0f ms, Helfer-Start %.0f ms",
                 tIn * 1000, tCold * 1000, tHit * 1000, c.stats.lastSpawnMs))
}

@Test func helperMissingAndUnreadable() throws {
    guard let (c, dir) = client() else { return }
    defer { try? FileManager.default.removeItem(at: dir) }
    let t0 = Date()
    #expect(error { try c.decode(path: "/nonexistent/minos-\(UUID().uuidString).aiff", sampleRate: 48000, hardTimeout: 10) } == .missing)
    #expect(Date().timeIntervalSince(t0) < 3)
    let bad = FileManager.default.temporaryDirectory.appendingPathComponent("minos-bad-\(UUID().uuidString).mp3")
    try Data("kein audio".utf8).write(to: bad)
    defer { try? FileManager.default.removeItem(at: bad) }
    guard case let .failed(code, _)? = error({ try c.decode(path: bad.path, sampleRate: 48000, hardTimeout: 10) }) else {
        Issue.record("kein Fehler"); return
    }
    #expect(code == .read || code == .format)
    // Helfer bleibt nach einem Fehler benutzbar (kein neuer Start)
    #expect(c.stats.spawns == 1 && c.stats.kills == 0)
}

/// Öffnen hängt (Cloud-Anbieter antwortet nicht): Herzschlag läuft weiter, keine Daten -> nach der harten Grenze
/// abgeschossen; der nächste Auftrag bekommt einen neuen Helfer
@Test func hangingOpenIsKilledAfterNoProgress() throws {
    guard let (c, dir) = client(["MIX741_FAULT": "hang-open:*hang*"]) else { return }
    defer { try? FileManager.default.removeItem(at: dir) }
    let hang = FileManager.default.temporaryDirectory.appendingPathComponent("minos-hang-\(UUID().uuidString).wav")
    let ok = try writeWAV(rate: 48000, channels: 2, seconds: 1)
    defer { try? FileManager.default.removeItem(at: ok) }
    let t0 = Date()
    #expect(error { try c.decode(path: hang.path, sampleRate: 48000, hardTimeout: 1) } == .stalled(1))
    let took = Date().timeIntervalSince(t0)
    #expect(took > 0.9 && took < 3)
    #expect(c.stats.kills == 1)
    let t1 = Date()
    let a = try c.decode(path: ok.path, sampleRate: 48000, hardTimeout: 5)
    #expect(abs(a.duration - 1) < 0.01)
    print(String(format: "[files] hängendes Öffnen: abgeschossen nach %.2f s (Grenze 1 s), nächster Track %.0f ms inkl. Neustart (%.0f ms)",
                 took, Date().timeIntervalSince(t1) * 1000, c.stats.lastSpawnMs))
}

/// Helfer steht ganz (kein Herzschlag) -> nach `beatTimeout` abgeschossen
@Test func frozenHelperIsKilled() throws {
    guard let (c, dir) = client(["MIX741_FAULT": "freeze-open:*freeze*"], beat: 1) else { return }
    defer { try? FileManager.default.removeItem(at: dir) }
    let t0 = Date()
    #expect(error { try c.decode(path: "/tmp/minos-freeze.wav", sampleRate: 48000, hardTimeout: 30) } == .unresponsive)
    #expect(Date().timeIntervalSince(t0) < 3)
    #expect(c.stats.kills == 1)
}

/// Absturz mitten im Dekodieren: ein Neuversuch mit neuem Helfer, stürzt der auch ab -> Fehler
@Test func crashingHelperIsRetriedOnce() throws {
    guard let (c, dir) = client(["MIX741_FAULT": "crash-after:100000"]) else { return }
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try writeWAV(rate: 48000, channels: 2, seconds: 5)
    defer { try? FileManager.default.removeItem(at: url) }
    guard case .crashed? = error({ try c.decode(path: url.path, sampleRate: 48000, hardTimeout: 5) }) else {
        Issue.record("kein Absturz gemeldet"); return
    }
    #expect(c.stats.crashes == 2 && c.stats.spawns >= 2)
    // nichts Halbes im Cache
    #expect(c.cacheUsage().files == 0)
}

/// anderer Track gewählt: hängender Auftrag wird abgeschossen, sofort
@Test func cancelKillsHangingJob() throws {
    guard let (c, dir) = client(["MIX741_FAULT": "hang-open:*hang*"]) else { return }
    defer { try? FileManager.default.removeItem(at: dir) }
    let t0 = Date()
    let e = error { try c.decode(path: "/tmp/minos-hang.wav", sampleRate: 48000, hardTimeout: 30, cancelled: { Date().timeIntervalSince(t0) > 0.3 }) }
    #expect(e == .cancelled)
    #expect(Date().timeIntervalSince(t0) < 1)
    #expect(c.stats.kills == 1)
}

/// Helfer startet nicht (stürzt vor dem Handshake ab): dreimal -> gesperrt, Aufrufer dekodiert im Prozess
@Test func crashLoopBlocksHelper() throws {
    guard let (c, dir) = client(["MIX741_FAULT": "crash-start"]) else { return }
    defer { try? FileManager.default.removeItem(at: dir) }
    for _ in 0..<3 {
        guard case .unavailable? = error({ try c.decode(path: "/tmp/x.wav", sampleRate: 48000, hardTimeout: 5) }) else {
            Issue.record("Start nicht als fehlgeschlagen erkannt"); return
        }
    }
    #expect(c.unavailable)
    #expect(c.stats.startFailures == 3)
    let t0 = Date()
    guard case .unavailable? = error({ try c.decode(path: "/tmp/x.wav", sampleRate: 48000, hardTimeout: 5) }) else { Issue.record("nicht gesperrt"); return }
    #expect(Date().timeIntervalSince(t0) < 0.1 && c.stats.startFailures == 3)
}

/// Cache-Grenze: älteste zuerst, eingeblendete bleiben, nur gelöscht (nie gekürzt), alte tmp-Reste weg
@Test func cacheTrimsOldestUnmapped() throws {
    guard let (c, dir) = client() else { return }
    defer { try? FileManager.default.removeItem(at: dir) }
    var files: [URL] = []
    defer { files.forEach { try? FileManager.default.removeItem(at: $0) } }
    for _ in 0..<4 { files.append(try writeWAV(rate: 48000, channels: 2, seconds: 2)) }
    // erster bleibt eingeblendet (liegt in einem Deck), obwohl er der älteste ist
    let held = try c.decode(path: files[0].path, sampleRate: 48000, hardTimeout: 5)
    for f in files.dropFirst() {
        _ = try c.decode(path: f.path, sampleRate: 48000, hardTimeout: 5)
        Thread.sleep(forTimeInterval: 0.02)   // unterscheidbare Zeitstempel
    }
    let usage = c.cacheUsage()
    #expect(usage.files == 4)
    let one = usage.bytes / 4
    let tmp = dir.appendingPathComponent("abc.mtrk.tmp-1-2")
    try Data(count: 10).write(to: tmp)
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: tmp.path)
    c.cacheLimit = one * 2 + one / 2
    c.trimCache()   // läuft nach dem Setzen der Grenze auch im Hintergrund – gezählt wird das Ergebnis
    #expect(c.cacheUsage().files == 2)
    #expect(!FileManager.default.fileExists(atPath: tmp.path))
    let names = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
    let heldName = held.mapping!.header.key.fileName
    #expect(names.contains(heldName))
    // gehaltener Track bleibt lesbar
    var s: Float = 0
    for i in stride(from: 0, to: held.frames, by: 64) { s += held.left[i] }
    #expect(s.isFinite)
    // Treffer frischt den Zeitstempel auf: danach nicht mehr der älteste
    let hit = try c.decode(path: files[3].path, sampleRate: 48000, hardTimeout: 5)
    #expect(hit.mapping != nil && c.stats.cacheHits == 1)
}
