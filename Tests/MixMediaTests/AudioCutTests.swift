import AVFoundation
import Foundation
import Testing
@testable import MixMedia

/// Schneiden: Stücke zusammensetzen (Längen, Crossfade, Ränder), Apple-Lossless-Datei schreiben und zurücklesen
struct AudioCutTests {
    /// Rampe 0, 1, 2, … – jeder Frame eindeutig
    private func ramp(_ n: Int, offset: Float = 0) -> [Float] { (0..<n).map { Float($0) + offset } }

    private func render(_ s: AudioSplice, _ src: [Float], block: Int = 1 << 20) -> [Float] {
        var out = [Float](repeating: .nan, count: s.frames)
        src.withUnsafeBufferPointer { sp in
            out.withUnsafeMutableBufferPointer { op in
                var at = 0
                while at < s.frames {
                    let n = min(block, s.frames - at)
                    s.render(sp.baseAddress!, into: op.baseAddress! + at, from: at, count: n)
                    at += n
                }
            }
        }
        return out
    }

    @Test func removeLengthAndSeam() {
        let src = ramp(10_000)
        let s = AudioSplice.removing(3_000..<5_000, frames: 10_000, fade: 88)
        #expect(s.frames == 8_000)
        let out = render(s, src)
        // weit weg von der Naht: unverändert
        #expect(out[0] == 0 && out[2_955] == 2_955 && out[3_044] == 5_044 && out[7_999] == 9_999)
        // Naht bei 3000: 44 Frames davor / danach gemischt, Gewicht linear
        for j in 2_956..<3_044 {
            let w = (Float(j - 2_956) + 0.5) / 88
            let expected = Float(j) * (1 - w) + Float(j + 2_000) * w
            #expect(abs(out[j] - expected) < 0.01)
        }
        #expect(abs(out[2_999] - (2_999 + 2_000 * (43.5 / 88))) < 0.01)
        // Anfang und Ende der Datei bleiben (keine Blende)
        #expect(out.allSatisfy { !$0.isNaN })
    }

    @Test func blockwiseSameAsWhole() {
        let src = ramp(50_000)
        let s = AudioSplice.removing(10_007..<23_011, frames: 50_000, fade: 96)
        #expect(render(s, src, block: 777) == render(s, src))
    }

    @Test func keepFadesEdges() {
        let src = [Float](repeating: 1, count: 10_000)
        let s = AudioSplice.keeping(2_000..<6_000, frames: 10_000, fade: 100)
        #expect(s.frames == 4_000)
        let out = render(s, src)
        #expect(abs(out[0] - 0.005) < 1e-6 && abs(out[99] - 0.995) < 1e-6 && out[100] == 1)
        #expect(out[3_899] == 1 && abs(out[3_999] - 0.005) < 1e-6)
        // vom Dateianfang: keine Einblende
        let head = render(AudioSplice.keeping(0..<6_000, frames: 10_000, fade: 100), src)
        #expect(head[0] == 1 && abs(head[5_999] - 0.005) < 1e-6)
    }

    @Test func edgesAndEmpty() {
        let src = ramp(1_000)
        // bis zum Ende entfernt: nur das erste Stück, mit Ausblende
        let tail = AudioSplice.removing(600..<1_000, frames: 1_000, fade: 10)
        #expect(tail.pieces == [0..<600] && tail.frames == 600)
        // vom Anfang entfernt: kein Crossfade, Einblende
        let head = AudioSplice.removing(0..<400, frames: 1_000, fade: 10)
        #expect(head.pieces == [400..<1_000] && render(head, src)[599] == 999)
        // Naht nah am Dateirand: Crossfade gekürzt, kein Lesen außerhalb
        let near = AudioSplice.removing(2..<998, frames: 1_000, fade: 10)
        #expect(near.frames == 4)
        #expect(render(near, src).count == 4)
        #expect(AudioSplice.removing(0..<1_000, frames: 1_000, fade: 10).frames == 0)
        #expect(AudioSplice.fadeFrames(sampleRate: 44_100) == 88 && AudioSplice.fadeFrames(sampleRate: 48_000) == 96)
    }

    @Test(arguments: [1, 2, 6])
    func writeAppleLossless(channels: Int) throws {
        let rate = 44_100.0, n = 44_100 * 3
        // einfache Teilausdrücke: der Typprüfer der CI brauchte für die verschachtelte Zeile zu lang
        var chans: [[Float]] = []
        for c in 0..<channels {
            let step = 0.01 * Double(c + 1)
            var ch = [Float](repeating: 0, count: n)
            for i in 0..<n { ch[i] = Float(sin(Double(i) * step)) * 0.5 }
            chans.append(ch)
        }
        let src = AudioCutWriter.Source.samples(chans, sampleRate: rate, bitDepth: 24)
        let splice = AudioSplice.removing(44_100..<88_200, frames: n, fade: AudioSplice.fadeFrames(sampleRate: rate))
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("x [cut].m4a")
        var steps = 0
        try AudioCutWriter.write(splice, source: src, to: url) { _ in steps += 1; return true }
        #expect(steps >= 1)
        let f = try AVAudioFile(forReading: url)
        #expect(f.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatAppleLossless)
        #expect(Int(f.processingFormat.channelCount) == channels)
        #expect(f.processingFormat.sampleRate == rate)
        #expect(Int(f.length) == n - 44_100)
        // zurückgelesen = zusammengesetzt (24 Bit)
        let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
        try f.read(into: buf)
        let last = channels - 1
        let expect = chans[last].withUnsafeBufferPointer { sp -> [Float] in
            var o = [Float](repeating: 0, count: splice.frames)
            o.withUnsafeMutableBufferPointer { splice.render(sp.baseAddress!, into: $0.baseAddress!, from: 0, count: splice.frames) }
            return o
        }
        var worst: Float = 0
        for i in 0..<splice.frames { worst = max(worst, abs(buf.floatChannelData![last][i] - expect[i])) }
        #expect(worst < 1e-5)
        // keine Teil-Datei übrig
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["x [cut].m4a"])
    }

    @Test func cancelLeavesNothing() throws {
        let n = 44_100 * 4
        let src = AudioCutWriter.Source.samples([[Float](repeating: 0.1, count: n), [Float](repeating: 0.1, count: n)], sampleRate: 44_100)
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("y [cut].m4a")
        #expect(throws: AudioCutWriter.CutError.cancelled) {
            try AudioCutWriter.write(.keeping(0..<n, frames: n, fade: 88), source: src, to: url) { _ in false }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test func sourceFromFileKeepsRate() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = try writeTestWAV(rate: 48_000, channels: 1, seconds: 2, in: dir)
        let s = try AudioCutWriter.source(url: wav, deck: nil)
        #expect(s.sampleRate == 48_000 && s.channels.count == 1 && s.frames == 96_000 && !s.fromDeck)
        // Deck-Puffer passt (Stereo, gleiche Rate, gleiche Länge) -> keine zweite Dekodierung
        let st = try writeTestWAV(rate: 44_100, channels: 2, seconds: 1, in: dir)
        let deck = try TrackAudio.decode(url: st, sampleRate: 44_100)
        let s2 = try AudioCutWriter.source(url: st, deck: deck)
        #expect(s2.fromDeck && s2.frames == deck.frames)
        // andere Rate im Deck -> Datei in ihrer Rate
        let deck48 = try TrackAudio.decode(url: st, sampleRate: 48_000)
        let s3 = try AudioCutWriter.source(url: st, deck: deck48)
        #expect(!s3.fromDeck && s3.sampleRate == 44_100 && s3.frames == 44_100)
    }

    /// Schreibdauer 6 Minuten Stereo 44,1 kHz (Messwert, kein Grenzwert)
    @Test func sixMinuteWriteTime() throws {
        let rate = 44_100.0, n = Int(rate * 360)
        // Sinus + Rauschen (xorshift, schneller als Float.random im Debug-Build)
        var x: UInt32 = 0x9E37_79B9
        let chans = (0..<2).map { c in
            (0..<n).map { i -> Float in
                x ^= x << 13; x ^= x >> 17; x ^= x << 5
                return Float(sin(Double(i) * 0.031 * Double(c + 1))) * 0.4 + (Float(x & 0xFFFF) / 65_536 - 0.5) * 0.2
            }
        }
        let src = AudioCutWriter.Source.samples(chans, sampleRate: rate, bitDepth: 16)
        let splice = AudioSplice.removing(Int(rate * 120)..<Int(rate * 150), frames: n, fade: AudioSplice.fadeFrames(sampleRate: rate))
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let t0 = Date()
        try AudioCutWriter.write(splice, source: src, to: dir.appendingPathComponent("six [cut].m4a"))
        let secs = Date().timeIntervalSince(t0)
        print(String(format: "[cut] 6 min stereo 44.1 kHz -> alac 16 bit: %.2f s", secs))
        #expect(secs < 30)
    }
}
