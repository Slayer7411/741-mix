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
