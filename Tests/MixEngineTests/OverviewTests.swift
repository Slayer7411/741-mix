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
