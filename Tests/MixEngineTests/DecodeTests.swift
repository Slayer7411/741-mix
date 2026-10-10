import AVFoundation
import Foundation
import Testing
import MixEngine

/// Testdatei schreiben: Sinus 440 Hz, Pegel 0.5, `seconds` lang
func writeWAV(rate: Double, channels: UInt32, seconds: Double) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("minos-decode-\(UUID().uuidString).wav")
    let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
    let file = try AVAudioFile(forWriting: url, settings: fmt.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let n = AVAudioFrameCount(seconds * rate)
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n)!
    buf.frameLength = n
    for c in 0..<Int(channels) {
        for i in 0..<Int(n) { buf.floatChannelData![c][i] = Float(sin(2 * .pi * 440 * Double(i) / rate)) * 0.5 }
    }
    try file.write(from: buf)
    return url
}

private func check(_ t: TrackAudio, seconds: Double, rate: Double) {
    #expect(abs(Double(t.frames) - seconds * rate) < rate * 0.01)   // Länge ±10 ms
    #expect(t.sampleRate == rate)
    var pk: Float = 0, diff: Float = 0
    for i in stride(from: 0, to: t.frames, by: 7) { pk = max(pk, abs(t.left[i])); diff = max(diff, abs(t.left[i] - t.right[i])) }
    #expect(pk > 0.45 && pk < 0.55)   // Pegel bleibt
    #expect(diff < 0.01)              // beide Seiten gleich (Stereo-Sinus bzw. Mono dupliziert)
    #expect(t.peak.count == t.frames / Int(rate / TrackAudio.blocksPerSecond) + 1)
    #expect(t.peak.dropFirst(5).dropLast(5).allSatisfy { $0 > 0.4 })
}

/// gleiche Rate, Stereo: direkter Weg ohne Konverter
@Test func decodesStereoAtDeviceRate() throws {
    let url = try writeWAV(rate: 44100, channels: 2, seconds: 3.7)
    defer { try? FileManager.default.removeItem(at: url) }
    check(try TrackAudio.decode(url: url, sampleRate: 44100), seconds: 3.7, rate: 44100)
}

/// andere Rate + Mono: Konverter blockweise, Mono auf beide Seiten
@Test func decodesMonoWithRateConversion() throws {
    let url = try writeWAV(rate: 48000, channels: 1, seconds: 3.7)
    defer { try? FileManager.default.removeItem(at: url) }
    check(try TrackAudio.decode(url: url, sampleRate: 44100), seconds: 3.7, rate: 44100)
}

/// Stereo 96 kHz -> 44.1 kHz, länger als ein Block (65536 Frames)
@Test func decodesStereoWithRateConversion() throws {
    let url = try writeWAV(rate: 96000, channels: 2, seconds: 2.5)
    defer { try? FileManager.default.removeItem(at: url) }
    check(try TrackAudio.decode(url: url, sampleRate: 44100), seconds: 2.5, rate: 44100)
}
