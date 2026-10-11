import Foundation
import Testing
import MixCore
import MixEngine

private let rate = 44100.0

/// Band-Höhen (Mittel über die Blöcke in der Mitte) eines Signals
private func heights(_ x: [Float]) -> WaveBands.Heights {
    let a = SpectrumAnalyzer(sampleRate: rate, block: Int(rate / TrackAudio.blocksPerSecond))
    x.withUnsafeBufferPointer { a.feed(left: $0.baseAddress!, right: $0.baseAddress!, count: x.count) }
    let h = WaveBands.heights(a.finish())
    let r = (h.count / 5)..<(h.count * 4 / 5)
    let n = Float(r.count)
    return WaveBands.Heights(low: r.reduce(0) { $0 + h[$1].low } / n, mid: r.reduce(0) { $0 + h[$1].mid } / n,
                             high: r.reduce(0) { $0 + h[$1].high } / n)
}

private func sine(_ f: Double, amp: Float) -> [Float] {
    (0..<Int(2 * rate)).map { amp * Float(sin(2 * .pi * f * Double($0) / rate)) }
}

@Test func sineLandsInItsBand() {
    let lo = heights(sine(60, amp: 0.5)), mi = heights(sine(1000, amp: 0.5)), hi = heights(sine(8000, amp: 0.5))
    #expect(lo.low > 0.99 && lo.mid < 0.05 && lo.high < 0.05)
    #expect(mi.mid > 0.99 && mi.low < 0.05 && mi.high < 0.05)
    #expect(hi.high > 0.99 && hi.low < 0.05 && hi.mid < 0.1)
}

/// Kick-Grundton + Hat 20 dB leiser: Bass voll, Höhen sichtbar, aber deutlich darunter
@Test func quietHighsStayVisibleUnderBass() {
    let x = zip(sine(60, amp: 0.5), sine(8000, amp: 0.05)).map { $0 + $1 }
    let h = heights(x)
    let want = powf(WaveBands.highGain * 0.1, WaveBands.curve)
    #expect(h.low > 0.99)
    #expect(abs(h.high - want) < 0.03)
    #expect(h.high > 0.1 && h.high < 0.3)
}

@Test func highBoostScalesHighs() {
    let e = (low: Float(0.25), mid: Float(0), high: Float(0.0025))
    let n = WaveBands.heights(low: e.low, mid: e.mid, high: e.high).high
    let b = WaveBands.heights(low: e.low, mid: e.mid, high: e.high, highBoost: 2).high
    #expect(abs(b / n - powf(2, WaveBands.curve)) < 1e-4)
    #expect(WaveBands.heights(low: 0, mid: 0, high: 0) == .zero)
}
