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
    #expect(LEDShow.duration >= 8.5 && LEDShow.duration <= 9.2)
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
    #expect(seen == [.storm, .decks, .blackout, .flash, .fade, .ready])
    #expect(LEDShow.frame(at: LEDShow.duration, decks: (0, 2), seed: 7) == nil)
    // Sturm 5 s, Decks 1,2 s, Blitz gut 1 s, Ausdimmen 1,5 s
    #expect(LEDShow.stormEnd == 5 && abs(LEDShow.decksEnd - LEDShow.stormEnd - 1.2) < 0.01)
    #expect(abs(LEDShow.flashEnd - LEDShow.blackoutEnd - 1.1) < 0.06)
    #expect(abs(LEDShow.fadeEnd - LEDShow.flashEnd - 1.5) < 0.01)
}

@Test func ledShowTimeline() {
    func f(_ t: Double) -> LEDShow.Frame? { LEDShow.frame(at: t, decks: (0, 2), seed: 3) }
    // Sturm: Glut, Lauflicht (zwei Runden), Stroboskop bis zuletzt
    #expect(LEDShow.phase(at: 1.0) == .storm && f(1.0)!.pads.allSatisfy { $0.color == .red })
    #expect(f(2.0)!.pads.contains { $0 == .init(color: .purple, level: 1) })
    #expect(f(3.0)!.pads.contains { $0 == .init(color: .purple, level: 1) })
    var strobe = 0
    for k in 0..<4 {
        let s = f(4.8 + Double(k) * LEDShow.step)!
        #expect(s.phase == .storm && s.mix == 0)
        if s.pads.contains(where: { $0.color == .white && $0.level > 0 }) || s.digits.contains(where: { $0 != 0 }) { strobe += 1 }
    }
    #expect(strobe >= 1 && strobe <= 3)   // jeder zweite Takt dunkel
    #expect(f(4.9)!.phase == .storm)
    // Deck-Teil
    let d = f(5.6)!
    #expect(d.phase == .decks && d.digits[1] == LEDShow.mask("A"))
    // Blitz weiß, hält
    for t in [6.3, 7.2] {
        let w = f(t)!
        #expect(w.phase == .flash && w.mix == 0)
        #expect(w.pads.allSatisfy { $0 == .init(color: .white, level: 1) } && w.buttons.allSatisfy { $0 == 1 })
    }
    // Ausdimmen: gemischt, weich (Kosinus), am Ende normal
    let m = f(7.4)!
    #expect(m.phase == .fade && m.mix > 0 && m.mix < 0.1)
    #expect(abs(LEDShow.mix(at: (LEDShow.flashEnd + LEDShow.fadeEnd) / 2) - 0.5) < 1e-9)
    var prev = 0.0
    for k in 0...50 {
        let w = LEDShow.mix(at: LEDShow.flashEnd + Double(k) / 50 * (LEDShow.fadeEnd - LEDShow.flashEnd))
        #expect(w >= prev)
        prev = w
    }
    #expect(prev == 1)
    #expect(f(8.9) == nil)
}

@Test func ledShowFadeBlendsIntoNormal() {
    let peak: UInt8 = 100
    var normal = [UInt8](repeating: 0, count: 0x34)
    normal[0] = 0x80
    normal[0x31] = 100; normal[0x01] = 20; normal[0x14] = 80   // Play an, FX gedimmt, Pad rot
    func led(_ t: Double) -> [UInt8] {
        let f = LEDShow.frame(at: t, decks: (0, 2), seed: 3)!
        var (r, _) = LEDShow.reports(f, peak: peak)
        LEDShow.blend(&r, toward: normal, f.mix)
        return r
    }
    let white = led(7.2)
    #expect(white[0x31] == 100 && white[0x01] == 100)
    let mid = led((LEDShow.flashEnd + LEDShow.fadeEnd) / 2)
    #expect(mid[0] == 0x80 && mid[0x01] == 60 && mid[0x15] < white[0x15] && mid[0x15] > 0)
    let late = led(LEDShow.fadeEnd - 0.001)
    #expect(zip(late, normal).allSatisfy { abs(Int($0) - Int($1)) <= 1 })
    // Anteil 0 lässt das Bild unverändert
    var same = white
    LEDShow.blend(&same, toward: normal, 0)
    #expect(same == white)
}

@Test func ledShowIsPureAndShowsDeckLetters() {
    let a = LEDShow.frame(at: 1.0, decks: (0, 2), seed: 42), b = LEDShow.frame(at: 1.0, decks: (0, 2), seed: 42)
    #expect(a == b)
    let left = LEDShow.frame(at: 5.5, decks: (0, 2), seed: 1)!
    #expect(left.phase == .decks)
    #expect(left.digits[1] == LEDShow.mask("A") && left.digits[4] == LEDShow.mask("C"))
    let right = LEDShow.frame(at: 5.5, decks: (1, 3), seed: 1)!
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
