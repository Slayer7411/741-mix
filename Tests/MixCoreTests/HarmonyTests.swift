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
