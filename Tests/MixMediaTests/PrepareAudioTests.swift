import AVFoundation
import Foundation
import Testing
import MixCore
@testable import MixMedia

/// Vorbereiten im Audio: Gain Bit-genau in die Datei, Format wie die Quelle, Spitze, JOIN-Naht, Wandeln, SPLIT
struct PrepareAudioTests {
    /// 16-Bit-WAV mit bekannten Werten (k / 32768)
    private func wav16(_ chans: [[Int16]], rate: Double, in dir: URL, name: String = "src.wav") throws -> URL {
        let url = dir.appendingPathComponent(name)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: chans.count,
                                       AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let f = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let n = chans[0].count
        let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(n))!
        buf.frameLength = AVAudioFrameCount(n)
        for (c, ch) in chans.enumerated() { for i in 0..<n { buf.floatChannelData![c][i] = Float(ch[i]) / 32_768 } }
        try f.write(from: buf)
        return url
    }

    private func read(_ url: URL) throws -> (chans: [[Float]], format: AVAudioFormat) {
        let f = try AVAudioFile(forReading: url)
        let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
        try f.read(into: buf)
        let n = Int(buf.frameLength)
        return ((0..<Int(buf.format.channelCount)).map { c in Array(UnsafeBufferPointer(start: buf.floatChannelData![c], count: n)) }, f.fileFormat)
    }

    private func samples(_ n: Int, seed: UInt32) -> [Int16] {
        var x = seed
        return (0..<n).map { _ in x ^= x << 13; x ^= x >> 17; x ^= x << 5; return Int16(truncatingIfNeeded: Int(x % 16_000) - 8_000) }
    }

    /// Amplify: jedes Sample genau × Faktor (×2 = +6.02 dB lässt 16-Bit-Werte ganzzahlig), Format bleibt WAV 16 Bit,
    /// ALAC ebenso Bit-genau; Faktor 1 = die Quelle
    @Test(arguments: ["wav", "m4a"])
    func gainBitExact(ext: String) throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let n = 20_000
        let l = samples(n, seed: 0x1234_5678), r = samples(n, seed: 0x0BAD_F00D)
        let src = try wav16([l, r], rate: 44_100, in: dir)
        let fmt = AudioCutWriter.format(matching: src)
        #expect(fmt.container == .wav && fmt.bitDepth == 16 && !fmt.float && fmt.ext == "wav")
        let s = try AudioCutWriter.source(url: src, deck: nil)
        #expect(s.bitDepth == 16)
        let splice = AudioSplice.keeping(0..<s.frames, frames: s.frames, fade: 0)
        let render: AudioCutWriter.Render = { c, out, from, k in splice.render(s.channels[c], into: out, from: from, count: k) }
        let peak = AudioCutWriter.peak(frames: splice.frames, channels: 2, render: render)
        #expect(peak == Float(max(l.map { abs(Int($0)) }.max()!, r.map { abs(Int($0)) }.max()!)) / 32_768)
        let out = dir.appendingPathComponent("x [amp +6]." + ext)
        try AudioCutWriter.write(frames: splice.frames, channels: 2, sampleRate: 44_100, format: ext == "wav" ? fmt : .alac(16),
                                 to: out, gain: 2, render: render)
        let back = try read(out)
        #expect(back.format.streamDescription.pointee.mFormatID == (ext == "wav" ? kAudioFormatLinearPCM : kAudioFormatAppleLossless))
        #expect(back.chans[0].count == n)
        #expect(back.chans[0] == l.map { Float(Int($0) * 2) / 32_768 })
        #expect(back.chans[1] == r.map { Float(Int($0) * 2) / 32_768 })
        // Faktor 1: Bit-genau die Quelle
        let same = dir.appendingPathComponent("y." + ext)
        try AudioCutWriter.write(frames: splice.frames, channels: 2, sampleRate: 44_100, format: ext == "wav" ? fmt : .alac(16), to: same, render: render)
        #expect(try read(same).chans[0] == l.map { Float($0) / 32_768 })
    }

    /// +3 dB: Spitze × 1,4125; ohne Clipping-Erlaubnis bleibt die Spitze unter 1 (sicherer Faktor)
    @Test func gainPeakAndGuard() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let n = 8_000
        let ch = (0..<n).map { Float(sin(Double($0) * 0.05)) * 0.6 }
        let s = AudioCutWriter.Source.samples([ch], sampleRate: 48_000)
        let r: AudioCutWriter.Render = { _, out, from, k in out.update(from: s.channels[0] + from, count: k) }
        let p0 = AudioCutWriter.peak(frames: n, channels: 1, render: r)
        let f3 = Float(Amplify.factor(db: 3))
        let a = dir.appendingPathComponent("a.m4a")
        try AudioCutWriter.write(frames: n, channels: 1, sampleRate: 48_000, format: .alac(24), to: a, gain: f3, render: r)
        let pa = try read(a).chans[0].map(abs).max()!
        #expect(abs(pa / p0 - 1.4125) < 1e-3)
        // +6 dB wollte über 0 dBFS: begrenzt (0.6 · 2 = 1.2)
        let lim = Amplify.limit(6, peak: p0, allowClipping: false)
        #expect(lim.limited)
        let b = dir.appendingPathComponent("b.m4a")
        try AudioCutWriter.write(frames: n, channels: 1, sampleRate: 48_000, format: .alac(24), to: b,
                                 gain: Amplify.safeFactor(lim.db, peak: p0), render: r)
        let pb = try read(b).chans[0].map(abs).max()!
        #expect(pb <= 1 && pb > 0.999)
    }

    @Test func formatMatching() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let float = try writeTestWAV(rate: 44_100, channels: 2, seconds: 0.1, in: dir)
        let f = AudioCutWriter.format(matching: float)
        #expect(f.container == .wav && f.float && f.bitDepth == 32)
        #expect(AudioCutWriter.format(matching: dir.appendingPathComponent("missing.flac")) == .alac(24))
        // AIFF 24 Bit bleibt AIFF
        let aif = dir.appendingPathComponent("s.aiff")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1,
                                       AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: true]
        do {
            let w = try AVAudioFile(forWriting: aif, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let buf = AVAudioPCMBuffer(pcmFormat: w.processingFormat, frameCapacity: 100)!
            buf.frameLength = 100
            try w.write(from: buf)
        }
        let fa = AudioCutWriter.format(matching: aif)
        #expect(fa.container == .aiff && fa.bitDepth == 24 && fa.ext == "aiff")
        // geschrieben als AIFF 24 Bit
        let out = dir.appendingPathComponent("o.aiff")
        try AudioCutWriter.write(frames: 100, channels: 1, sampleRate: 44_100, format: fa, to: out, render: { _, o, _, k in o.update(repeating: 0.25, count: k) })
        let back = try read(out)
        #expect(back.chans[0].allSatisfy { $0 == 0.25 } && back.format.streamDescription.pointee.mBitsPerChannel == 24)
    }

    /// JOIN: Länge = Naht + Rest der zweiten; weg von der Naht unverändert; Naht ohne Sprung; Stille bis zum Takt
    @Test func joinLengthAndSeam() {
        let fade = 88
        // erste: +0.5 Gleichspannung, 10_000 Frames; Naht bei 10_000 (Ende genau auf dem Takt); zweite: −0.5 ab Frame 300
        let a = [Float](repeating: 0.5, count: 10_000)
        let b = [Float](repeating: -0.5, count: 6_000)
        let j = AudioJoin(aFrames: a.count, joint: 10_000, bStart: 300, bFrames: b.count, fade: fade)
        #expect(j.frames == 10_000 + 6_000 - 300)
        var out = [Float](repeating: .nan, count: j.frames)
        a.withUnsafeBufferPointer { ap in
            b.withUnsafeBufferPointer { bp in
                out.withUnsafeMutableBufferPointer { op in
                    var at = 0
                    while at < j.frames {
                        let k = min(777, j.frames - at)
                        j.render(a: { o, f, n in o.update(from: ap.baseAddress! + f, count: n) }, b: bp.baseAddress!, into: op.baseAddress! + at,
                                 from: at, count: k)
                        at += k
                    }
                }
            }
        }
        #expect(out.allSatisfy { !$0.isNaN })
        // die erste endet auf der Naht: Crossfade davor, die zweite liegt ab der Naht ganz vorn (Grid genau)
        #expect(out[0] == 0.5 && out[9_911] == 0.5 && out[10_000] == -0.5 && out[j.frames - 1] == -0.5)
        // ohne Crossfade wäre der Sprung 1.0: höchstens 1 / 88 je Frame
        let steps = zip(out.dropFirst(), out).map { abs($0 - $1) }
        let worst = steps.indices.max { steps[$0] < steps[$1] }!
        #expect(steps[worst] <= 1.0 / Float(fade) + 1e-6, "Sprung \(steps[worst]) bei \(worst): \(out[max(0, worst - 2)...min(out.count - 1, worst + 3)])")
        // erste hat Audio über die Naht: Crossfade mittig
        let c = AudioJoin(aFrames: 10_200, joint: 10_000, bStart: 300, bFrames: b.count, fade: fade)
        var o1 = [Float](repeating: .nan, count: c.frames)
        let a2 = [Float](repeating: 0.5, count: 10_200)
        a2.withUnsafeBufferPointer { ap in
            b.withUnsafeBufferPointer { bp in
                o1.withUnsafeMutableBufferPointer { op in
                    c.render(a: { o, f, n in o.update(from: ap.baseAddress! + f, count: n) }, b: bp.baseAddress!, into: op.baseAddress!,
                             from: 0, count: c.frames)
                }
            }
        }
        #expect(c.frames == j.frames && o1[9_955] == 0.5 && o1[10_044] == -0.5 && abs(o1[10_000]) < 0.01)
        // erste endet vor der Naht: Stille bis dahin, die zweite beginnt mit ihrem Dateianfang auf der Naht
        let k = AudioJoin(aFrames: 9_000, joint: 10_000, bStart: 0, bFrames: 2_000, fade: fade)
        var o2 = [Float](repeating: .nan, count: k.frames)
        a.withUnsafeBufferPointer { ap in
            b.withUnsafeBufferPointer { bp in
                o2.withUnsafeMutableBufferPointer { op in
                    k.render(a: { o, f, n in o.update(from: ap.baseAddress! + f, count: n) }, b: bp.baseAddress!, into: op.baseAddress!,
                             from: 0, count: k.frames)
                }
            }
        }
        #expect(k.frames == 12_000 && o2[8_999] == 0.5 && o2[9_000] == 0 && o2[9_999] == 0 && o2[10_000] == -0.5)
    }

    /// Wandeln: gleiche Rate + Kanäle = die Quelle; Mono -> Stereo; andere Rate / Tempo -> Länge passt
    @Test func convert() throws {
        let n = 48_000
        let ch = (0..<n).map { Float(sin(Double($0) * 0.01)) * 0.5 }
        let s = AudioCutWriter.Source.samples([ch], sampleRate: 48_000)
        #expect(try AudioCutWriter.converted(s, rate: 48_000, channels: 1) === s)
        let st = try AudioCutWriter.converted(s, rate: 48_000, channels: 2)
        #expect(st.channels.count == 2 && st.frames == n && st.channels[1][1234] == ch[1234])
        let r = try AudioCutWriter.converted(s, rate: 44_100, channels: 2)
        #expect(r.frames == 44_100 && r.sampleRate == 44_100)
        // Tempo +0.4 %: kürzer um den Faktor
        let fast = try AudioCutWriter.converted(s, rate: 48_000, channels: 1, speed: 1.004)
        #expect(fast.frames == Int((Double(n) / 1.004).rounded()))
        // Inhalt: Sinus bleibt Sinus (Mitte, weg von den Rändern), Frequenz × Tempo
        let i = 20_000
        #expect(abs(fast.channels[0][i] - Float(sin(Double(i) * 1.004 * 0.01)) * 0.5) < 0.01)
    }

    /// SPLIT über die Schnittliste: Teile zusammen = Original, Teil 2 beginnt sample-genau an der Marke
    @Test func splitPartsSampleExact() {
        let rate = 1_000.0, n = 10_000
        let src = (0..<n).map { Float($0) }
        let (p1, p2) = SplitPlan.parts(EditList(duration: 10), at: 4)!
        let f1 = p1.frames(rate: rate, sourceFrames: n), f2 = p2.frames(rate: rate, sourceFrames: n)
        let s1 = AudioSplice(pieces: f1.pieces, sourceFrames: n, fade: 2, muted: f1.muted)
        let s2 = AudioSplice(pieces: f2.pieces, sourceFrames: n, fade: 2, muted: f2.muted)
        #expect(s1.frames + s2.frames == n && s1.frames == 4_000)
        var o = [Float](repeating: 0, count: s2.frames)
        src.withUnsafeBufferPointer { sp in o.withUnsafeMutableBufferPointer { s2.render(sp.baseAddress!, into: $0.baseAddress!, from: 0, count: s2.frames) } }
        #expect(o[1] < 4_001 && o[2] == 4_002 && o[s2.frames - 1] == 9_999)   // 2-Frame-Einblende an der Marke
    }
}
