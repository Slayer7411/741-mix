import AVFoundation
import Foundation
import Testing
import MixEngine
import MixProtocol

// eigener Test-Prozess: zählt offene fds, ohne dass parallele Tests mitzählen

private let helperURL: URL? = {
    if let p = ProcessInfo.processInfo.environment["MIX741_FILES_HELPER"] { return URL(fileURLWithPath: p) }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    for c in ["debug", "release"] {
        let u = root.appendingPathComponent(".build/\(c)/\(FileProtocol.helperName)")
        if FileManager.default.isExecutableFile(atPath: u.path) { return u }
    }
    return nil
}()

private func writeWAV(seconds: Double) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("minos-leak-\(UUID().uuidString).wav")
    let fmt = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    let file = try AVAudioFile(forWriting: url, settings: fmt.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let n = AVAudioFrameCount(seconds * 48000)
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n)!
    buf.frameLength = n
    for c in 0..<2 { for i in 0..<Int(n) { buf.floatChannelData![c][i] = Float(sin(Double(i) * 0.05)) * 0.5 } }
    try file.write(from: buf)
    return url
}

private func openFDs() -> Int { (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 0 }

/// viele Aufträge mit Abschießen und Treffern: keine fds bleiben offen (Kanäle, übergebene Dateien), kein Helfer läuft weiter
@Test func noDescriptorLeakAcrossKills() throws {
    guard let helperURL else { print("[files] minos-files nicht gebaut, Test übersprungen"); return }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("minos-leak-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    var cfg = FileServiceClient.Config(helper: helperURL, cacheDir: dir)
    cfg.environment = ["MIX741_FAULT": "hang-open:*minos-hang*"]
    let c = FileServiceClient(cfg)
    let url = try writeWAV(seconds: 0.5)
    defer { try? FileManager.default.removeItem(at: url) }
    _ = try c.decode(path: url.path, sampleRate: 48000, hardTimeout: 5)
    Thread.sleep(forTimeInterval: 0.3)
    let before = openFDs()
    for i in 0..<20 {
        let t0 = Date()
        _ = try? c.decode(path: "/tmp/minos-hang-\(i).flac", sampleRate: 48000, hardTimeout: 30,
                          cancelled: { Date().timeIntervalSince(t0) > 0.05 })
        _ = try c.decode(path: url.path, sampleRate: 48000, hardTimeout: 5)
    }
    Thread.sleep(forTimeInterval: 1)
    let after = openFDs()
    print("[files] fds vor / nach 20 abgeschossenen Helfern: \(before) / \(after), Starts \(c.stats.spawns)")
    #expect(c.stats.kills == 20 && c.stats.cacheHits == 20 && c.stats.zombies == 0)
    #expect(after - before <= 2, "fds \(before) -> \(after)")
}
