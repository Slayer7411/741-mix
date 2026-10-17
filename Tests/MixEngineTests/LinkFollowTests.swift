import Foundation
import Testing
@testable import MixEngine

/// Folgen gegen eine feste Link-Zeitachse: die Clock startet versetzt, Aktionen verschieben sie wie der Steuertick
private func runFollow(ticks: Int, clockOffset: Double, linkShift: (Int) -> Double = { _ in 0 }) -> (maxAbs: Double, actions: Int) {
    let bps = 128.0 / 60, dt = 0.005
    var offset = clockOffset
    var policy = LinkFollowPolicy()
    var rng: UInt64 = 0x9E37_79B9_7F4A_7C15
    var maxAbs = 0.0, actions = 0
    for k in 0..<ticks {
        rng = rng &* 6364136223846793005 &+ 1442695040888963407
        let jitter = (Double(rng >> 11) / Double(1 << 53) * 2 - 1) * 0.003
        let T = Double(k) * dt
        let beat = offset + bps * T
        let linkBeat = bps * (T + jitter) + linkShift(k)
        var diff = (beat - linkBeat).truncatingRemainder(dividingBy: 4)
        if diff > 2 { diff -= 4 } else if diff < -2 { diff += 4 }
        if k > ticks / 2 { maxAbs = max(maxAbs, abs(diff)) }
        switch policy.step(diff: diff) {
        case .none: break
        case .trim(let d), .jump(let d): actions += 1; offset -= d
        }
    }
    return (maxAbs, actions)
}

@Test func followJumpsToLinkAtStart() {
    var p = LinkFollowPolicy()
    #expect(p.step(diff: 0.5) == .jump(0.5))
    // danach Pause
    #expect(p.step(diff: 0.5) == .none)
}

@Test func followIgnoresJitter() {
    var p = LinkFollowPolicy()
    _ = p.step(diff: 0)
    var acted = false
    for k in 0..<2000 where p.step(diff: k % 2 == 0 ? 0.006 : -0.006) != .none { acted = true }
    #expect(!acted)
}

@Test func followTrimsSmallOffset() {
    var p = LinkFollowPolicy()
    _ = p.step(diff: 0)
    var first: LinkFollowPolicy.Action = .none
    for _ in 0..<100 where first == .none { first = p.step(diff: 0.01) }
    guard case .trim(let d) = first else { Issue.record("kein trim: \(first)"); return }
    #expect(d > 0.005 && d < 0.01)
}

@Test func followConvergesAndKeepsUpWithLinkShift() {
    // 120 s: Start 0,7 Beats daneben, nach 60 s springt die Link-Zeitachse um 0,5 Beats
    let r = runFollow(ticks: 24_000, clockOffset: 0.7) { $0 >= 12_000 ? 0.5 : 0 }
    #expect(r.maxAbs < 0.02)
    #expect(r.actions >= 2)
}
