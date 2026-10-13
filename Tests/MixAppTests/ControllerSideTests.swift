import Foundation
import Testing
import MixCore
@testable import MixEngine
@testable import MixApp

// Feste Seite je Controller (Seriennummer, sonst USB-Position) und Startsequenz – ohne Gerät.

@Test func controllerSideKeyFallsBackToLocation() {
    #expect(ControllerSides.key(serial: " ABC123 ", location: 0x1420_0000) == "ABC123")
    #expect(ControllerSides.key(serial: "", location: 0x1420_0000) == "loc-14200000")
    #expect(ControllerSides.key(serial: nil, location: 0) == nil)
    #expect(!ControllerSides.isStable(ControllerSides.tempPrefix + "x") && ControllerSides.isStable("loc-14200000"))
}

@Test func controllerSideResolveInOrderSavedAndConflict() {
    // ohne Eintrag: der Reihe nach
    #expect(ControllerSides.resolve(saved: nil, taken: [])! == (.left, false))
    #expect(ControllerSides.resolve(saved: nil, taken: [.left])! == (.right, false))
    // gespeichert und frei: bleibt, auch als erstes Gerät
    #expect(ControllerSides.resolve(saved: .right, taken: [])! == (.right, false))
    // Konflikt: das zweite Gerät bekommt die andere Seite
    #expect(ControllerSides.resolve(saved: .left, taken: [.left])! == (.right, true))
    // dritter Controller: keine Seite
    #expect(ControllerSides.resolve(saved: .left, taken: [.left, .right]) == nil)
    // alte Deck-Zuordnung
    #expect(ControllerSide(decks: 0, 2) == .left && ControllerSide(decks: 1, 3) == .right && ControllerSide(decks: 0, 1) == nil)
    #expect(ControllerSides.saved("SN", in: ["SN": "right", "X": "oben"]) == .right && ControllerSides.saved("X", in: ["X": "oben"]) == nil)
}

@Test func controllerSideAssignSwapsTheOther() {
    let cur: [String: ControllerSide] = ["L": .left, "R": .right]
    #expect(ControllerSides.assign("R", to: .left, current: cur) == ["L": .right, "R": .left])
    #expect(ControllerSides.assign("L", to: .left, current: cur) == cur)
    #expect(ControllerSides.assign("L", to: .right, current: ["L": .left]) == ["L": .right])
}

@MainActor @Test func controllerManagerStoresSidesAndSwaps() {
    let core = MixController()
    let manager = ControllerManager(core: core, status: ControllerStatus())
    let a = "TEST-A-\(UUID().uuidString)", b = "TEST-B-\(UUID().uuidString)"
    defer { for k in [a, b] { for p in ["x1.", "x1pane.", "x1fx."] { UserDefaults.standard.removeObject(forKey: p + k) } } }
    // B steht gespeichert links, kommt aber als zweiter: A (neu) bekommt links, B weicht nach rechts aus
    var p = ControllerPrefs()
    p.sides = [b: "left"]
    manager.prefs = p
    let ia = manager.register(device: nil, serial: a, location: 1, name: "T")
    let ib = manager.register(device: nil, serial: b, location: 2, name: "T")
    #expect(ia?.side == .left && ia?.left == 0 && ia?.right == 2 && ia?.pane == 0 && ia?.fxUnit == 10)
    #expect(ib?.side == .right && ib?.left == 1 && ib?.right == 3 && ib?.pane == 1 && ib?.fxUnit == 11)
    #expect(manager.storedSide(a) == .left && manager.storedSide(b) == .right)
    // gleiches Gerät noch einmal: nichts doppelt
    #expect(manager.register(device: nil, serial: a, location: 1, name: "T") == nil)

    // Tausch per Seite: A nach rechts, B wechselt nach links, Decks hängen um
    manager.setSide(a, .right)
    core.controlQueue.sync {}
    let ua = manager.unit(a)!.info, ub = manager.unit(b)!.info
    #expect(ua.side == .right && ua.left == 1 && ua.right == 3)
    #expect(ub.side == .left && ub.left == 0 && ub.right == 2)
    #expect(manager.storedSide(a) == .right && manager.storedSide(b) == .left)
}

@MainActor @Test func controllerManagerKeepsOwnDecksOnItsSide() {
    let core = MixController()
    let manager = ControllerManager(core: core, status: ControllerStatus())
    let a = "TEST-C-\(UUID().uuidString)"
    defer { for p in ["x1.", "x1pane.", "x1fx."] { UserDefaults.standard.removeObject(forKey: p + a) } }
    // alte Zuordnung B/D ohne gespeicherte Seite -> rechts, Decks bleiben
    UserDefaults.standard.set([1, 3], forKey: "x1.\(a)")
    let i = manager.register(device: nil, serial: "", location: 0, name: "T")   // ohne Kennung: wird nicht gespeichert
    #expect(i?.side == .left && i.map { ControllerSides.isStable($0.id) } == false && manager.storedSide(i!.id) == nil)
    let j = manager.register(device: nil, serial: a, location: 3, name: "T")
    #expect(j?.side == .right && j?.left == 1 && j?.right == 3)
}

// MARK: - Startsequenz

@Test func ledShowPhasesInOrderAndEndsReady() {
    #expect(LEDShow.duration >= 3 && LEDShow.duration <= 4)
    var last = LEDShow.Phase.storm
    var seen: [LEDShow.Phase] = []
    var t = 0.0
    while t < LEDShow.duration + 0.5 {
        let ph = LEDShow.phase(at: t)
        #expect(ph >= last)
        if seen.last != ph { seen.append(ph) }
        last = ph
        let f = LEDShow.frame(at: t, decks: (0, 2), seed: 7)
        #expect((f == nil) == (ph == .ready))
        if let f { #expect(f.phase == ph) }
        t += LEDShow.step
    }
    #expect(seen == [.storm, .decks, .blackout, .flash, .ready])
    #expect(LEDShow.frame(at: LEDShow.duration, decks: (0, 2), seed: 7) == nil)
    // Sturm etwa 2 s, Decks etwa 1 s, Blitz etwa 150 ms
    #expect(abs(LEDShow.stormEnd - 2) < 0.3 && abs(LEDShow.decksEnd - LEDShow.stormEnd - 1) < 0.3)
    #expect(abs(LEDShow.flashEnd - LEDShow.blackoutEnd - 0.15) < 0.03)
}

@Test func ledShowIsPureAndShowsDeckLetters() {
    let a = LEDShow.frame(at: 1.0, decks: (0, 2), seed: 42), b = LEDShow.frame(at: 1.0, decks: (0, 2), seed: 42)
    #expect(a == b)
    let left = LEDShow.frame(at: 2.5, decks: (0, 2), seed: 1)!
    #expect(left.phase == .decks)
    #expect(left.digits[1] == LEDShow.mask("A") && left.digits[4] == LEDShow.mask("C"))
    let right = LEDShow.frame(at: 2.5, decks: (1, 3), seed: 1)!
    #expect(right.digits[1] == LEDShow.mask("b") && right.digits[4] == LEDShow.mask("d"))
    let flash = LEDShow.frame(at: LEDShow.blackoutEnd + 0.05, decks: (0, 2), seed: 1)!
    #expect(flash.pads.allSatisfy { $0 == .init(color: .white, level: 1) } && flash.buttons.allSatisfy { $0 == 1 })
    let (led, disp) = LEDShow.reports(flash, peak: 127)
    #expect(led.count == 0x34 && led[0] == 0x80 && disp.count == 0x5B && disp[0] == 0x81)
    #expect(LEDShow.buttons.allSatisfy { led[$0.byte] == 127 })
    #expect(disp[LEDShow.stripStart...].allSatisfy { $0 == 127 })
}

@Test func ledShowPadColorsOnlyFromPalette() {
    let palette = LEDShow.Color.allCases.map(LEDShow.rgb)
    var lit = 0, colors = Set<Int>()
    for seed: UInt32 in [1, 99, 12345] {
        var t = 0.0
        while let f = LEDShow.frame(at: t, decks: (1, 3), seed: seed) {
            let (led, _) = LEDShow.reports(f, peak: 110)
            for base in LEDShow.padBytes {
                let c = (Int(led[base]), Int(led[base + 1]), Int(led[base + 2]))
                if c == (0, 0, 0) { continue }
                lit += 1
                // jede leuchtende Pad-Farbe = Palettenfarbe × Helligkeit
                let match = palette.firstIndex { p in
                    let k = Double(c.0) / Double(p.r)
                    return abs(Double(p.g) * k - Double(c.1)) <= 1.5 && abs(Double(p.b) * k - Double(c.2)) <= 1.5
                }
                #expect(match != nil, "Pad-Farbe \(c) nicht aus der Palette")
                if let match { colors.insert(match) }
            }
            for l in f.strip + f.pads { #expect(l.level >= 0 && l.level <= 1) }
            for l in f.buttons { #expect(l >= 0 && l <= 1) }
            t += LEDShow.step
        }
    }
    #expect(lit > 100 && colors.count == 3)   // rot, weiß und lila kommen alle vor
}

@Test func ledShowSegmentLetters() {
    // A b C d auf der 7-Segment-Anzeige (1 = g, 2 = c, 3 = b, 4 = a, 5 = f, 6 = e, 7 = d)
    #expect(LEDShow.mask("A") == 0b0111_1110 && LEDShow.mask("C") == 0b1111_0000)
    #expect(LEDShow.letter(0) == "A" && LEDShow.letter(1) == "b" && LEDShow.letter(2) == "C" && LEDShow.letter(3) == "d")
}
