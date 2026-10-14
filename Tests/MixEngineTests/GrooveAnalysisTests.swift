import Foundation
import Testing
import MixCore
import MixEngine

/// Groove-Erkennung über die echte Spektralanalyse: gerenderter 4/4-Loop (Kick auf jedem Beat, Offbeat-Bass mit
/// Sidechain, geschlossene Hats auf den Offbeats, offene auf dem letzten Offbeat des Takts, Clap auf 2 und 4)
private let rate = 44100.0

private struct Noise {
    var state: UInt64 = 0x741
    mutating func next() -> Float {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Float(Int64(bitPattern: state) >> 11) / Float(1 << 52)
    }
}

private func render(bpm: Double, bars: Int, anchor: Double, bass: Bool = true, clap: Bool = true, hats: Bool = true) -> [Float] {
    let beat = 60 / bpm, n = Int((anchor + Double(bars * 4) * beat + 1) * rate)
    var x = [Float](repeating: 0, count: n)
    var g = Noise()
    // Hochpass-Rauschen (Hats) und Bandpass-Rauschen (Clap) vorab
    var hp = [Float](repeating: 0, count: n), bp = [Float](repeating: 0, count: n)
    var l1: Float = 0, l2: Float = 0, b1: Float = 0
    let aH = Float(1 - exp(-2 * Double.pi * 7000 / rate)), aB = Float(1 - exp(-2 * Double.pi * 2500 / rate)), aB2 = Float(1 - exp(-2 * Double.pi * 800 / rate))
    for i in 0..<n {
        let w = g.next()
        l1 += aH * (w - l1); hp[i] = w - l1
        l2 += aB * (w - l2); b1 += aB2 * (l2 - b1); bp[i] = l2 - b1
    }
    for b in 0..<(bars * 4) {
        let t0 = anchor + Double(b) * beat
        let s0 = Int(t0 * rate)
        // Kick: Sinus-Sweep 150 -> 50 Hz
        var ph = 0.0
        for i in 0..<Int(0.3 * rate) where s0 + i < n {
            let t = Double(i) / rate
            ph += 2 * .pi * (50 + 100 * exp(-t * 30)) / rate
            x[s0 + i] += Float(sin(ph) * exp(-t * 9)) * 0.8
        }
        // Offbeat-Bass: 55 Hz Sägezahn (tief gefiltert), Sidechain = Pause um die Kick
        if bass {
            // Sägezahn durch zwei Tiefpässe (400 Hz), weich ein- und ausgeblendet
            let o = Int((t0 + beat / 2) * rate), len = Int(beat / 2 * 0.9 * rate)
            let lp = Float(1 - exp(-2 * Double.pi * 400 / rate))
            var y1: Float = 0, y2: Float = 0
            for i in 0..<len where o + i < n {
                let t = Double(i) / rate
                let saw = Float(2 * (55 * t - floor(55 * t + 0.5)))
                y1 += lp * (saw - y1); y2 += lp * (y1 - y2)
                let env = Float(min(1, t / 0.01, Double(len - i) / rate / 0.01))
                x[o + i] += y2 * env * 0.5
            }
        }
        if clap, b % 2 == 1 {
            for i in 0..<Int(0.12 * rate) where s0 + i < n { x[s0 + i] += bp[s0 + i] * Float(exp(-Double(i) / rate * 30)) * 1.2 }
        }
        if hats {
            let o = Int((t0 + beat / 2) * rate), open = b % 4 == 3
            let dec = open ? 5.0 : 60.0
            for i in 0..<Int((open ? 0.3 : 0.08) * rate) where o + i < n { x[o + i] += hp[o + i] * Float(exp(-Double(i) / rate * dec)) * 0.5 }
        }
    }
    return x
}

private func pattern(_ x: [Float], bpm: Double, anchor: Double, start: Double) -> GroovePattern {
    let block = TrackAudio.blockFrames(sampleRate: rate)
    let a = SpectrumAnalyzer(sampleRate: rate, block: block)
    x.withUnsafeBufferPointer { a.feed(left: $0.baseAddress!, right: $0.baseAddress!, count: x.count) }
    let s = a.finish()
    return GrooveAnalyzer.extract(s, blocksPerSecond: rate / Double(block), grid: BeatGrid(anchor: anchor, bpm: bpm), startBeat: start, beats: 8)
}

@Test func grooveFromRenderedTechno() {
    for bpm in [124.0, 132.0, 140.0] {
        let x = render(bpm: bpm, bars: 8, anchor: 0.37)
        let p = pattern(x, bpm: bpm, anchor: 0.37, start: 8)
        #expect(p.steps(.kick) == [0, 4, 8, 12, 16, 20, 24, 28], "\(bpm): Kick \(p.steps(.kick))")
        #expect(p.steps(.snare) == [4, 12, 20, 28], "\(bpm): Snare \(p.steps(.snare))")
        #expect(p.steps(.closedHat) == [2, 6, 10, 18, 22, 26], "\(bpm): Hats \(p.steps(.closedHat))")
        #expect(p.steps(.openHat) == [14, 30], "\(bpm): offen \(p.steps(.openHat))")
    }
}

@Test func grooveFromRenderedKickOnly() {
    let x = render(bpm: 128, bars: 8, anchor: 0.1, bass: false, clap: false, hats: false)
    let p = pattern(x, bpm: 128, anchor: 0.1, start: 4)
    #expect(p.steps(.kick) == [0, 4, 8, 12, 16, 20, 24, 28])
    #expect(p.steps(.snare).isEmpty && p.hatSteps.isEmpty, "Snare \(p.steps(.snare)) Hats \(p.hatSteps.sorted())")
}
