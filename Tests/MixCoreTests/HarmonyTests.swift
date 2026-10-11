import Foundation
import Testing
@testable import MixCore

private func track(_ key: String, code: Int = -1, text: String = "", bpm: Double = 128) -> Track {
    var t = Track(key: key, path: "/m/\(key).mp3")
    t.musicalKey = code
    t.keyText = text
    t.bpm = bpm
    return t
}

@Test func harmonyWheelMatchesOpenKey() {
    for c in 0..<24 {
        let n = Harmony.wheel(c)
        #expect(Track.openKey(code: c) == "\(n)\(Harmony.isMinor(c) ? "m" : "d")")
        #expect(Harmony.code(wheel: n, minor: Harmony.isMinor(c)) == c)
        #expect(Harmony.code(text: Track.openKey(code: c)) == c)
        for s in -13...13 {
            var t = Track(key: "k", path: "/k")
            t.musicalKey = c
            #expect(Track.openKey(code: Harmony.shifted(c, by: s)) == t.openKey(shiftedBy: s))
        }
    }
}

@Test func harmonyParsesKeyText() {
    #expect(Harmony.code(text: "8B") == 0)     // C
    #expect(Harmony.code(text: "8A") == 21)    // Am
    #expect(Harmony.code(text: "1m") == 21)
    #expect(Harmony.code(text: "Am") == 21)
    #expect(Harmony.code(text: "F#") == 6)
    #expect(Harmony.code(text: "Ebm") == 15)
    #expect(Harmony.code(text: "C#min") == 13)
    #expect(Harmony.code(text: "Bb") == 10)
    #expect(Harmony.code(text: "") == nil)
    #expect(Harmony.code(text: "13m") == nil)
    #expect(Harmony.code(text: "Hm") == nil)
    #expect(track("t", text: "6m").harmonyCode == Harmony.code(wheel: 6, minor: true))
    #expect(track("t", code: 3, text: "6m").harmonyCode == 3)
}

@Test func harmonyRelations() {
    let ref = Harmony.code(wheel: 8, minor: true)   // 8m
    func rel(_ n: Int, _ minor: Bool) -> Harmony.Relation { Harmony.relation(Harmony.code(wheel: n, minor: minor), to: ref) }
    #expect(rel(8, true).step == .same && rel(8, true).symbol == "◆")
    #expect(rel(9, true).step == .adjacent && rel(9, true).symbol == "▲")
    #expect(rel(7, true).step == .adjacent && rel(7, true).symbol == "▼")
    #expect(rel(8, false).step == .relative && rel(8, false).symbol == "◇")
    #expect(rel(10, true).step == .energy && rel(6, true).step == .energy)
    #expect(rel(9, false).step == .clash && rel(2, true).step == .clash)
    // über die 12: 12m -> 1m = +1
    let r = Harmony.relation(Harmony.code(wheel: 1, minor: true), to: Harmony.code(wheel: 12, minor: true))
    #expect(r.step == .adjacent && r.turn == 1)
    #expect(rel(8, true).distance < rel(9, true).distance && rel(9, true).distance < rel(10, true).distance
            && rel(10, true).distance < rel(2, true).distance)
}

@Test func matchRuleFiltersKeyAndTempo() {
    var rule = MatchRule()
    let ref = HarmonyRef(key: Harmony.code(wheel: 8, minor: true), bpm: 128)
    let same = track("a", code: Harmony.code(wheel: 8, minor: true), bpm: 125)
    let adj = track("b", code: Harmony.code(wheel: 9, minor: true), bpm: 132)
    let rel = track("c", code: Harmony.code(wheel: 8, minor: false), bpm: 128)
    let energy = track("d", code: Harmony.code(wheel: 10, minor: true), bpm: 128)
    let far = track("e", code: Harmony.code(wheel: 8, minor: true), bpm: 140)
    let half = track("f", code: Harmony.code(wheel: 8, minor: true), bpm: 64.5)
    let none = track("g", bpm: 128)
    #expect(rule.matches(same, ref) && rule.matches(adj, ref) && rule.matches(rel, ref))
    #expect(!rule.matches(energy, ref) && !rule.matches(far, ref) && !rule.matches(half, ref) && !rule.matches(none, ref))
    rule.energy = true
    rule.halfDouble = true
    rule.relative = false
    #expect(rule.matches(energy, ref) && rule.matches(half, ref) && !rule.matches(rel, ref))
    rule.bpmWindow = 10
    #expect(rule.matches(far, ref))
    // Bezug ohne Key: nur Tempo, ohne Tempo: nur Key
    #expect(rule.matches(none, HarmonyRef(key: nil, bpm: 128)))
    #expect(rule.matches(far, HarmonyRef(key: ref.key, bpm: 0)))
    #expect(abs(MatchRule().tempoOffset(125, to: 128)! - 2.4) < 1e-9)
}

@Test func harmonySortOrdersByDistanceThenTempo() {
    let rule = MatchRule()
    let ref = HarmonyRef(key: Harmony.code(wheel: 8, minor: true), bpm: 128)
    let tracks = [
        track("clash", code: Harmony.code(wheel: 2, minor: true), bpm: 128),
        track("same-far", code: Harmony.code(wheel: 8, minor: true), bpm: 120),
        track("adj", code: Harmony.code(wheel: 9, minor: true), bpm: 128),
        track("nokey", bpm: 128),
        track("same-near", code: Harmony.code(wheel: 8, minor: true), bpm: 127.5),
        track("energy", code: Harmony.code(wheel: 6, minor: true), bpm: 128),
    ]
    let up = TrackSort.sorted(tracks, using: [KeyPathComparator(\Track.harmonySort)]) { rule.rank($0, ref) }
    #expect(up.map(\.key) == ["same-near", "same-far", "adj", "energy", "clash", "nokey"])
    let down = TrackSort.sorted(tracks, using: [KeyPathComparator(\Track.harmonySort, order: .reverse)]) { rule.rank($0, ref) }
    #expect(down.map(\.key) == up.map(\.key).reversed())
    // ohne Bezug: Reihenfolge der Quelle
    #expect(TrackSort.sorted(tracks, using: [KeyPathComparator(\Track.harmonySort)]).map(\.key) == tracks.map(\.key))
}
