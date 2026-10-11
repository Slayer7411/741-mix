import Testing
@testable import MixCore

// MUSICAL_KEY: 0–11 Dur (C…B), 12–23 Moll; Open Key C = 1d, Am = 1m

@Test func keySyncNumbersMatchOpenKey() {
    for code in 0..<24 {
        var t = Track(key: "k", path: "/k")
        t.musicalKey = code
        for s in -6...6 { #expect("\(KeySync.number(code: code, shift: s))\(code < 12 ? "d" : "m")" == t.openKey(shiftedBy: s)) }
    }
}

@Test func keySyncTakesSmallestCompatibleShift() {
    #expect(KeySync.shift(code: 21, masterCode: 21, masterShift: 0) == 0)    // gleicher Key
    #expect(KeySync.shift(code: 21, masterCode: 21, masterShift: 2) == 2)    // Master +2: nur +2 (−3, −5 passen auch, größer)
    #expect(KeySync.shift(code: 21, masterCode: 16, masterShift: 0) == 0)    // 1m ↔ 2m: Nachbar, passt schon
    #expect(KeySync.shift(code: 21, masterCode: 0, masterShift: 0) == 0)     // 1m ↔ 1d: Parallele
    #expect(KeySync.shift(code: 21, masterCode: 9, masterShift: 0) == -3)    // 1m -> 4d: nur über die Parallele 4m
    // ±6 ist derselbe Key: die Richtung näher am aktuellen Key-Shift
    let six = (0..<24).first { KeySync.shift(code: 0, masterCode: $0, masterShift: 0) == 6 || KeySync.shift(code: 0, masterCode: $0, masterShift: 0) == -6 }
    if let m = six {
        #expect(KeySync.shift(code: 0, masterCode: m, masterShift: 0, current: 5) == 6)
        #expect(KeySync.shift(code: 0, masterCode: m, masterShift: 0, current: -5) == -6)
    }
    for d in 0..<24 { for m in 0..<24 { for ms in -6...6 { #expect(abs(KeySync.shift(code: d, masterCode: m, masterShift: ms)) <= 6) } } }
}
