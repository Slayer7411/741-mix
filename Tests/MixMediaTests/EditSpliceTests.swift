import AVFoundation
import Foundation
import Testing
import MixCore
@testable import MixMedia

/// Schnittliste hörbar: stumme Stücke, Duplikat, Tool-Loop-Naht, gerenderter Puffer, Loop-Datei
struct EditSpliceTests {
    private func ramp(_ n: Int) -> [Float] { (0..<n).map { Float($0) } }

    private func render(_ s: AudioSplice, _ src: [Float]) -> [Float] {
        var out = [Float](repeating: .nan, count: s.frames)
        src.withUnsafeBufferPointer { sp in
            out.withUnsafeMutableBufferPointer { op in
                var at = 0
                while at < s.frames {
                    let n = min(1000, s.frames - at)
                    s.render(sp.baseAddress!, into: op.baseAddress! + at, from: at, count: n)
                    at += n
                }
            }
        }
        return out
    }

    /// Schnittliste -> Frames -> Ausgabe: außerhalb der Nähte sample-genau die Quelle, stumm = 0
    @Test func editListSampleExact() {
        let rate = 1000.0, src = ramp(10_000)
        var e = EditList(duration: 10)
        e.duplicate(TrackRange(2, 3))   // 0-3, 2-3, 3-10
        e.mute(TrackRange(5, 6))        // Ausgabe 5-6 = Quelle 4-5
        let f = e.frames(rate: rate, sourceFrames: src.count)
        let s = AudioSplice(pieces: f.pieces, sourceFrames: src.count, fade: 2, muted: f.muted)
        #expect(s.frames == 11_000)
        let out = render(s, src)
        #expect(out.allSatisfy { !$0.isNaN })
        #expect(out[0] == 0 && out[2_500] == 2_500 && out[2_998] == 2_998)
        #expect(out[3_001] == 2_001 && out[3_500] == 2_500 && out[3_998] == 2_998)   // Kopie
        #expect(out[4_001] == 3_001 && out[4_998] == 3_998)
        #expect(out[5_001] == 0 && out[5_500] == 0 && out[5_998] == 0)               // stumm
        #expect(out[6_001] == 5_001 && out[10_999] == 9_999)
        // Naht in die Stille: ausgehendes Stück blendet aus
        #expect(out[4_999] < 4_000 && out[4_999] > 0)
    }

    /// Tool-Loop: Länge exakt, Ende läuft klickfrei in den Anfang (Sprung nicht größer als im Signal selbst)
    @Test func toolLoopSeamless() {
        let rate = 44_100.0, n = Int(rate * 6)
        let src = (0..<n).map { Float(sin(2 * Double.pi * 437.3 * Double($0) / rate)) * 0.8 }
        let beats = 8, bpm = 128.0
        let a = 44_100, len = ToolLoop.frames(beats: beats, bpm: bpm, rate: rate)
        #expect(len == 165_375)
        let fade = AudioSplice.fadeFrames(sampleRate: rate)
        let s = AudioSplice.toolLoop(a..<(a + len), frames: n, fade: fade)
        #expect(s.frames == len)
        let out = render(s, src)
        let maxStep = zip(src.dropFirst(), src).map { abs($0 - $1) }.max()!
        let seam = abs(out[0] - out[len - 1])
        #expect(seam <= maxStep * 1.01)
        // Inneres unverändert
        #expect(out[100] == src[a + 100] && out[len - fade - 1] == src[a + len - fade - 1])
        // Rampe: ohne Naht spränge das Ende um die ganze Loop-Länge zurück, mit Naht um einen Schritt
        let ramp = (0..<n).map { Float($0) / Float(n) }
        let r = render(s, ramp)
        #expect(abs(ramp[a] - ramp[a + len - 1]) > 0.9 * Float(len) / Float(n))
        #expect(abs(r[0] - r[len - 1]) <= 1.01 / Float(n))
        // Loop am Dateianfang: Naht aus dem Audio nach dem Ende
        let head = render(AudioSplice.toolLoop(0..<len, frames: n, fade: fade), src)
        #expect(abs(head[0] - head[len - 1]) <= maxStep * 1.01)
    }

    @Test func renderedTrackAudio() {
        let n = 48_000 * 3
        let t = HeapPCM(capacity: n)
        for i in 0..<n { t.left[i] = Float(i % 100) / 100; t.right[i] = -Float(i % 100) / 100 }
        t.setFrames(n)
        let a = t.finish(sampleRate: 48_000)
        let s = AudioSplice.removing(48_000..<96_000, frames: n, fade: 96)
        let r = TrackAudio.rendered(s, from: a)
        #expect(r.frames == 96_000 && r.sampleRate == 48_000)
        #expect(r.left[10] == a.left[10] && r.right[60_000] == a.right[108_000])
        #expect(abs(r.peak.count - a.peak.count * 2 / 3) <= 1)
        // Wellenform-Blöcke aus der Quelle übernommen (nicht neu gerechnet): Block 200 der Ausgabe = Block 360 der Quelle
        let block = TrackAudio.blockFrames(sampleRate: 48_000)
        #expect(r.peak[10] == a.peak[10] && r.peak[200] == a.peak[(200 * block + 48_000) / block])
        #expect(r.blend.data.count == r.peak.count * WaveBlend.stride || r.blend.data.isEmpty)
    }

    /// Loop-Datei schreiben und zurücklesen: Länge exakt beats · 60 / bpm · rate
    @Test func toolLoopFileLength() throws {
        let rate = 44_100.0, n = Int(rate * 6)
        let l = (0..<n).map { Float(sin(Double($0) * 0.05)) * 0.5 }
        let src = AudioCutWriter.Source.samples([l, l], sampleRate: rate, bitDepth: 16)
        let len = ToolLoop.frames(beats: 4, bpm: 123.4, rate: rate)
        let s = AudioSplice.toolLoop(10_000..<(10_000 + len), frames: n, fade: AudioSplice.fadeFrames(sampleRate: rate))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("minos-toolloop-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        try AudioCutWriter.write(s, source: src, to: url)
        let f = try AVAudioFile(forReading: url)
        #expect(Int(f.length) == len)
        #expect(f.processingFormat.sampleRate == rate)
    }
}
