import Foundation
import Testing
import MixCore
@testable import MixMedia

private let rate = 44100.0

/// Mono-Signal analysieren, Hüllkurven (Tief, Mitte, Hoch) im Mittel über die Blöcke in der Mitte
private func envelopes(_ x: [Float]) -> (low: Float, mid: Float, high: Float, rms: Float) {
    let blocks = x.count / TrackAudio.blockFrames(sampleRate: rate) + 1
    let b = x.withUnsafeBufferPointer {
        BlendAnalyzer.analyze(left: $0.baseAddress!, right: $0.baseAddress!, frames: x.count, sampleRate: rate, blocks: blocks)
    }
    #expect(b.count == blocks)
    let r = (blocks / 4)..<(blocks * 3 / 4), amp = WaveBlend.amplitude
    var l: Float = 0, m: Float = 0, h: Float = 0, q: Float = 0
    for i in r {
        let o = i * WaveBlend.stride
        l += amp[Int(b.data[o + 1])]; m += amp[Int(b.data[o + 2])]; h += amp[Int(b.data[o + 3])]; q += amp[Int(b.data[o])]
    }
    let n = Float(r.count)
    return (l / n, m / n, h / n, q / n)
}

private func sine(_ f: Double, amp: Float = 0.5) -> [Float] {
    (0..<Int(1.5 * rate)).map { amp * Float(sin(2 * .pi * f * Double($0) / rate)) }
}

@Test func sineLandsInItsBlendBand() {
    let lo = envelopes(sine(60)), mi = envelopes(sine(670)), hi = envelopes(sine(8000))
    #expect(lo.low > 4 * lo.mid && lo.low > 10 * lo.high)
    #expect(mi.mid > 2 * mi.low && mi.mid > 2 * mi.high)
    #expect(hi.high > 10 * hi.low && hi.high > 4 * hi.mid)
    // Effektivwert des Sinus 0,5 = 0,354 (0,5-dB-Raster)
    #expect(abs(lo.rms - 0.354) < 0.03)
}

@Test func silenceIsZero() {
    let e = envelopes([Float](repeating: 0, count: 20000))
    #expect(e.low == 0 && e.mid == 0 && e.high == 0 && e.rms == 0)
}

/// Laufzeit auf echten Dateien (nur mit MIX741_BLEND_BENCH=<pfad>[:<pfad>…]): Hüllkurven allein
@Test func benchBlendRealFiles() throws {
    guard let list = ProcessInfo.processInfo.environment["MIX741_BLEND_BENCH"] else { return }
    for path in list.split(separator: ":").map(String.init) {
        let a = try TrackAudio.decode(url: URL(fileURLWithPath: path), sampleRate: 44100)
        let t0 = Date()
        _ = BlendAnalyzer.analyze(left: a.left, right: a.right, frames: a.frames, sampleRate: a.sampleRate, blocks: a.peak.count)
        print(String(format: "[bench] %.0f s audio: Hüllkurven %.3f s – %@", a.duration, Date().timeIntervalSince(t0), (path as NSString).lastPathComponent))
    }
}

/// Analyse bis Version mit festen Werten (150 / 670 / 3000 Hz), zum Vergleich mit `Params.standard`
private func legacyBlend(_ x: [Float], rate: Double, blocks: Int) -> [UInt8] {
    let block = TrackAudio.blockFrames(sampleRate: rate)
    var out = [UInt8](repeating: 0, count: blocks * WaveBlend.stride)
    let f = [150.0, 670, 3000].map { Float(2 * sin(Double.pi * min($0, rate / 6) / rate)) }
    let att = [0.010, 0.005, 0.0025].map { Float(exp(-1 / (rate * $0))) }, rel = [0.100, 0.035, 0.025].map { Float(exp(-1 / (rate * $0))) }
    let w: [Float] = [0.6, 1.0, 1.2], q: Float = 2
    var lp0: Float = 0, bp0: Float = 0, lp1: Float = 0, bp1: Float = 0, lp2: Float = 0, bp2: Float = 0, e0: Float = 0, e1: Float = 0, e2: Float = 0
    func follow(_ e: inout Float, _ v: Float, _ a: Float, _ r: Float) { let k = v > e ? a : r; e = v + k * (e - v) }
    var i = 0
    for b in 0..<blocks {
        let end = min(x.count, i + block)
        guard end > i else { break }
        var sq: Float = 0, s0: Float = 0, s1: Float = 0, s2: Float = 0, top: Float = -1, t0: Float = 0, t1: Float = 0, t2: Float = 0
        let n = end - i
        while i < end {
            let v = (x[i] + x[i]) * 0.5
            lp0 += f[0] * bp0; bp0 += f[0] * (v - lp0 - q * bp0)
            lp1 += f[1] * bp1; bp1 += f[1] * (v - lp1 - q * bp1)
            lp2 += f[2] * bp2; let hp = v - lp2 - q * bp2; bp2 += f[2] * hp
            follow(&e0, abs(lp0), att[0], rel[0]); follow(&e1, abs(bp1 * 1.4), att[1], rel[1]); follow(&e2, abs(hp), att[2], rel[2])
            sq += v * v; s0 += e0; s1 += e1; s2 += e2
            if abs(v) > top { top = abs(v); t0 = e0; t1 = e1; t2 = e2 }
            i += 1
        }
        let c = 1 / Float(n), at = b * WaveBlend.stride
        out[at] = WaveBlend.byte(amplitude: (sq * c).squareRoot())
        out[at + 1] = WaveBlend.byte(amplitude: w[0] * s0 * c); out[at + 2] = WaveBlend.byte(amplitude: w[1] * s1 * c)
        out[at + 3] = WaveBlend.byte(amplitude: w[2] * s2 * c)
        out[at + 4] = WaveBlend.byte(amplitude: w[0] * t0); out[at + 5] = WaveBlend.byte(amplitude: w[1] * t1); out[at + 6] = WaveBlend.byte(amplitude: w[2] * t2)
    }
    return out
}

private func noise(_ n: Int) -> [Float] {
    var s: UInt32 = 741
    return (0..<n).map { k in
        s = s &* 1_664_525 &+ 1_013_904_223
        return 0.4 * (Float(s >> 8) / Float(1 << 24) - 0.5) + 0.3 * Float(sin(Double(k) * 0.01))
    }
}

@Test func standardParamsMatchLegacyAnalysis() {
    for r in [44100.0, 48000] {
        let x = noise(Int(r * 2))
        let blocks = x.count / TrackAudio.blockFrames(sampleRate: r) + 1
        let b = x.withUnsafeBufferPointer { BlendAnalyzer.analyze(left: $0.baseAddress!, right: $0.baseAddress!, frames: x.count, sampleRate: r, blocks: blocks) }
        #expect(b.data == legacyBlend(x, rate: r, blocks: blocks))
    }
}

@Test func otherCrossoversGiveOtherEnvelopes() {
    let x = sine(250)
    let blocks = x.count / TrackAudio.blockFrames(sampleRate: rate) + 1
    func run(_ p: BlendAnalyzer.Params) -> WaveBlend {
        x.withUnsafeBufferPointer { BlendAnalyzer.analyze(left: $0.baseAddress!, right: $0.baseAddress!, frames: x.count, sampleRate: rate, blocks: blocks, params: p) }
    }
    let std = run(.standard), wide = run(BlendAnalyzer.Params(low: 400, mid: nil, high: 6000))
    #expect(std.data != wide.data)
    // 250 Hz: über dem Standard-Tiefpass (150), unter dem verschobenen (400) -> Tief-Hüllkurve größer
    let mid = blocks / 2 * WaveBlend.stride + WaveBlend.meanSlot
    #expect(wide.data[mid] > std.data[mid] + 6)
    // Abbrechen: nil
    let stopped = x.withUnsafeBufferPointer {
        BlendAnalyzer.analyze(left: $0.baseAddress!, right: $0.baseAddress!, frames: x.count, sampleRate: rate, blocks: blocks, params: .standard, cancelled: { true })
    }
    #expect(stopped == nil)
}
