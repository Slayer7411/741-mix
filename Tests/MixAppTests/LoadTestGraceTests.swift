import Foundation
import Testing
@testable import MixApp

/// Lasttest: Overloads nach Handtests (Gerät ab/an, Ruhezustand, Ratenwechsel) zählen nicht
@Test func overloadGraceExcludesHandTests() {
    var g = OverloadGrace()
    g.overloads(1, at: 10)                      // ohne Ereignis: zählt (nach 1 s eingeordnet)
    #expect(g.settle(now: 10.5) == (0, 0))
    #expect(g.settle(now: 11.1) == (1, 0))
    g.event(at: 20)                             // Gerät wieder verbunden
    g.overloads(1, at: 20.05)
    g.overloads(2, at: 24.9)                    // noch in der Schonfrist (5 s)
    g.overloads(1, at: 25.2)                    // danach: zählt
    g.settle(now: 30)
    #expect(g.counted == 2 && g.excluded == 3)
}

@Test func overloadGraceCoversEventSeenOnePollLate() {
    var g = OverloadGrace()
    g.overloads(1, at: 40.0)                    // Overload kommt eine Abfrage vor dem Zähler des Wiederverbindens
    g.event(at: 40.05)
    g.settle(now: 45)
    #expect(g.counted == 0 && g.excluded == 1)
    g.overloads(1, at: 50)
    g.settle(now: 50.2, final: true)            // Stufenende: alles einordnen
    #expect(g.counted == 1)
}

@Test func overloadGraceThreeHandTestsDoNotAbort() {
    // wie im Lasttest: USB ziehen, Gerät aus/an, Schlaf -> je 1 Overload beim Wiederverbinden
    var g = OverloadGrace()
    for t in [100.0, 200, 300] { g.event(at: t); g.overloads(1, at: t + 0.3) }
    g.settle(now: 400)
    #expect(g.counted == 0 && g.excluded == 3, "Abbruchregel (3 Overloads) darf nicht greifen")
}

@Test func phaseStatsMaxAndStd() {
    var p = PhaseStats()
    for e in [0.001, -0.003, 0.002, 0.0] { p.add(e) }
    #expect(p.count == 4)
    #expect(abs(p.maxAbs - 0.003) < 1e-12)
    #expect(abs(p.mean - 0.0) < 1e-12)
    #expect(abs(p.std - (0.000014 / 3).squareRoot()) < 1e-9)
}
