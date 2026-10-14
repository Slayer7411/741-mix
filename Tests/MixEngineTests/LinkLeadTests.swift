import Foundation
import Testing
@testable import MixEngine

/// Nachführung gegen eine Fake-Link-Zeitachse (Beat als Funktion der Host-Zeit), 200 Hz wie der Steuertick
private struct LinkSim {
    let bps = 128.0 / 60
    let dt = 0.005
    /// Link-Zeitachse: beat(t) = anchor + bps · t
    var anchor = 0.0
    /// MINOS-Clock: beat(T) = clockStart + rate · bps · T + Trims
    var clockStart = 0.0, rate = 1.0, trimmed = 0.0
    var jitter = 0.003
    var policy = LinkLeadPolicy()
    var forces = 0, trims = 0, maxAbs = 0.0
    var rng: UInt64 = 0x9E37_79B9_7F4A_7C15

    mutating func random() -> Double {
        rng = rng &* 6364136223846793005 &+ 1442695040888963407
        return Double(rng >> 11) / Double(1 << 53)
    }

    mutating func run(ticks: Range<Int>, canTrim: Bool, at: Int? = nil, jump: Double = 0) {
        for k in ticks {
            if k == at { clockStart += jump }
            let T = Double(k) * dt
            let beat = clockStart + rate * bps * T + trimmed
            let stamp = T + (random() * 2 - 1) * jitter
            var diff = (beat - (anchor + bps * stamp)).truncatingRemainder(dividingBy: 4)
            if diff > 2 { diff -= 4 } else if diff < -2 { diff += 4 }
            if k > 0 { maxAbs = max(maxAbs, abs(diff)) }
            switch policy.step(diff: diff, canTrim: canTrim) {
            case .force: forces += 1; anchor = beat - bps * stamp
            case .trim(let d): trims += 1; trimmed -= d
            case .none: break
            }
        }
    }
}

struct LinkLeadTests {
    @Test(arguments: [false, true])
    func jitterDoesNotReset(canTrim: Bool) {
        var s = LinkSim()
        s.run(ticks: 0..<1000, canTrim: canTrim)
        #expect(s.forces == 0)
        #expect(s.trims == 0)
    }

    @Test(arguments: [false, true])
    func jumpResetsOnce(canTrim: Bool) {
        var s = LinkSim()
        s.run(ticks: 0..<1000, canTrim: canTrim, at: 400, jump: 1)
        #expect(s.forces == 1)
    }

    @Test func firstTickAlignsOnce() {
        var s = LinkSim()
        s.clockStart = 1.7
        s.run(ticks: 0..<1000, canTrim: false)
        #expect(s.forces == 1)
    }

    /// Clock läuft der Zeitachse davon (übertrieben: 0,2 %): freie Clock wird nachgezogen, Link bleibt unberührt
    @Test func driftTrimsClockNotLink() {
        var s = LinkSim()
        s.rate = 1.002
        s.run(ticks: 0..<1000, canTrim: true)
        #expect(s.forces == 0)
        #expect(s.trims > 0)
        #expect(s.maxAbs < LinkLeadPolicy.tolerance)
    }

    /// Clock am Master-Deck: Drift wird erst ab der Toleranz an Link gegeben
    @Test func driftOnDeckForcesAboveTolerance() {
        var s = LinkSim()
        s.rate = 1.002
        s.run(ticks: 0..<1000, canTrim: false)
        // 0,2 % · 2,13 Beats/s · 5 s ≈ 0,021 Beats: höchstens eine Neusetzung
        #expect(s.forces <= 1)
        #expect(s.trims == 0)
    }
}
