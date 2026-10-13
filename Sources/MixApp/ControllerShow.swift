import Foundation

/// Startsequenz des Controllers als reine Funktion: Zeit → LED-Bild (testbar ohne Gerät). Senden: ControllerUnit.
/// Ablauf: Sturm (rot/weiß/lila, 2 s) → Decks der Seite (7-Segment, 1,2 s) → kurz dunkel → weißer Blitz → bereit.
enum LEDShow {
    enum Phase: Int, Comparable {
        case storm, decks, blackout, flash, ready
        static func < (a: Phase, b: Phase) -> Bool { a.rawValue < b.rawValue }
    }

    /// Palette der App: Theme.state (rot), Theme.bone (weiß), Theme.secondary (lila)
    enum Color: CaseIterable { case red, white, purple }

    struct Light: Equatable {
        var color: Color
        /// 0 = aus, 1 = volle Helligkeit (Einstellung „Helligkeit an“)
        var level: Double
        static let off = Light(color: .red, level: 0)
    }

    struct Frame: Equatable {
        var phase: Phase
        /// links Pad 1–4, rechts Pad 1–4
        var pads: [Light]
        /// einfarbige LEDs in der Reihenfolge von `buttons`
        var buttons: [Double]
        /// 6 Stellen (links 3, rechts 3), Bit n = Segment n (0 = Punkt)
        var digits: [UInt8]
        /// Touchstrip von links nach rechts
        var strip: [Light]
    }

    static let stormEnd = 2.0, decksEnd = 3.2, blackoutEnd = 3.28, flashEnd = 3.43
    static var duration: Double { flashEnd }
    /// Raster der Zufallswerte (= Takt der LED-Ausgabe, 30 ms)
    static let step = 0.03

    // MARK: - Geräte-Layout (Ausgabe-Reports 0x80 / 0x81, docs/controllers.md)

    static let padBytes = [0x14, 0x17, 0x20, 0x23, 0x1A, 0x1D, 0x26, 0x29]
    /// Pads als Schlange über das 2×4-Raster: obere Reihe L1 L2 R1 R2, untere zurück R4 R3 L4 L3
    static let padSnake = [0, 1, 4, 5, 7, 6, 3, 2]
    enum Group { case fx, left, right, center }
    /// einfarbige LEDs (Byte in 0x80, Gruppe) in Lauflicht-Reihenfolge
    static let buttons: [(byte: Int, group: Group)] = [
        (0x01, .fx), (0x02, .fx), (0x03, .fx), (0x04, .fx), (0x05, .fx), (0x06, .fx), (0x07, .fx), (0x08, .fx),
        (0x10, .right), (0x0F, .right), (0x13, .right), (0x2E, .right), (0x2F, .right), (0x32, .right), (0x33, .right),
        (0x12, .center),
        (0x31, .left), (0x30, .left), (0x2D, .left), (0x2C, .left), (0x11, .left), (0x0A, .left), (0x09, .left),
    ]
    static let stripStart = 0x31, displayLength = 0x5B
    /// Strip-Positionen: je zwei Bytes (rot, blau) ab 0x31
    static let stripCount = (displayLength - stripStart) / 2

    /// 7-Bit-Farben der Palette
    static func rgb(_ c: Color) -> (r: UInt8, g: UInt8, b: UInt8) {
        switch c {
        case .red: (127, 19, 23)       // Theme.state 210/31/38
        case .white: (127, 124, 120)   // Theme.bone 230/225/218
        case .purple: (91, 42, 127)    // Theme.secondary 150/70/210
        }
    }

    /// Deck → Buchstabe auf der 7-Segment-Anzeige
    static func letter(_ deck: Int) -> Character { ["A", "b", "C", "d"][max(0, min(3, deck))] }

    static func mask(_ ch: Character) -> UInt8 {
        (ControllerUnit.segments[ch] ?? []).reduce(UInt8(0)) { $0 | UInt8(1 << $1) }
    }

    static func phase(at t: Double) -> Phase {
        t < stormEnd ? .storm : t < decksEnd ? .decks : t < blackoutEnd ? .blackout : t < flashEnd ? .flash : .ready
    }

    // MARK: - Generator

    /// LED-Bild zur Zeit t (s seit Start); nil = fertig, normaler LED-Zustand
    static func frame(at t: Double, decks: (left: Int, right: Int), seed: UInt32) -> Frame? {
        let t = max(0, t)
        let n = Int(t / step)
        func rnd(_ i: Int, _ salt: Int = 0) -> Double { noise(seed, n, i &* 31 &+ salt) }
        var f = Frame(phase: phase(at: t), pads: Array(repeating: .off, count: 8),
                      buttons: Array(repeating: 0, count: buttons.count), digits: Array(repeating: 0, count: 6),
                      strip: Array(repeating: .off, count: stripCount))
        switch f.phase {
        case .ready:
            return nil
        case .blackout:
            break
        case .flash:
            f.pads = Array(repeating: Light(color: .white, level: 1), count: 8)
            f.buttons = Array(repeating: 1, count: buttons.count)
            f.digits = Array(repeating: 0xFF, count: 6)
            f.strip = Array(repeating: Light(color: .white, level: 1), count: stripCount)
        case .decks:
            let fade = min(1, (t - stormEnd) / 0.15)
            for i in 0..<8 { f.pads[i] = Light(color: i < 4 ? .purple : .red, level: fade) }
            for (i, b) in buttons.enumerated() where b.group == .left || b.group == .right { f.buttons[i] = 0.8 * fade }
            let dash = mask("-")
            f.digits = [dash, mask(letter(decks.left)), dash, dash, mask(letter(decks.right)), dash]
            let mid = stripCount / 2
            for i in 0..<stripCount where i != mid { f.strip[i] = Light(color: i < mid ? .purple : .red, level: fade) }
        case .storm:
            if t < 0.5 {
                // Glut: dunkelrotes Flackern, einzelne Funken
                let e = t / 0.5
                for i in 0..<8 { f.pads[i] = Light(color: .red, level: 0.06 + 0.4 * rnd(i) * (0.5 + 0.5 * e)) }
                for i in 0..<stripCount { let r = rnd(i, 1); f.strip[i] = Light(color: .red, level: r < 0.25 ? 0.2 + 2 * r : 0.03) }
                for i in buttons.indices { f.buttons[i] = rnd(i, 2) < 0.15 ? 0.5 : 0.04 }
                for i in 0..<6 { let r = rnd(i, 3); f.digits[i] = r < 0.3 ? UInt8(1 << (1 + Int(r * 23) % 7)) : 0 }
            } else if t < 1.3 {
                // Lauflicht: lila Kopf, roter Schweif, weiße Funken
                let u = t - 0.5
                let head = u / 0.045
                for (pos, pad) in padSnake.enumerated() {
                    let d = (head - Double(pos)).truncatingRemainder(dividingBy: 8)
                    let dist = d < 0 ? d + 8 : d
                    f.pads[pad] = dist < 1 ? Light(color: .purple, level: 1)
                        : rnd(pad, 4) < 0.06 ? Light(color: .white, level: 1)
                        : Light(color: .red, level: max(0.06, 0.8 - (dist - 1) * 0.25))
                }
                // Strip: zwei Köpfe, gespiegelt hin und her
                let period = 0.4, last = Double(stripCount - 1)
                let ph = (u / period).truncatingRemainder(dividingBy: 1)
                let p = (ph < 0.5 ? ph * 2 : 2 - ph * 2) * last
                for i in 0..<stripCount {
                    let dist = min(abs(Double(i) - p), abs(Double(i) - (last - p)))
                    f.strip[i] = dist < 0.8 ? Light(color: .purple, level: 1) : Light(color: .red, level: max(0.03, 0.6 - dist * 0.15))
                }
                let bh = (u / 0.03).truncatingRemainder(dividingBy: Double(buttons.count))
                for i in buttons.indices {
                    let d = bh - Double(i)
                    let dist = d < 0 ? d + Double(buttons.count) : d
                    f.buttons[i] = max(0.05, 1 - dist * 0.3)
                }
                // 7-Segment: äußerer Ring läuft um (a b c d e f)
                let ring = [4, 3, 2, 7, 6, 5]
                for i in 0..<6 { f.digits[i] = UInt8(1 << ring[(Int(u / 0.05) + i) % ring.count]) }
            } else {
                // Stroboskop: wird dichter und weißer, zuletzt jeder zweite Takt dunkel
                let s = (t - 1.3) / (stormEnd - 1.3)
                let dark = s > 0.6 && n % 2 == 0
                func pick(_ i: Int, _ salt: Int) -> Light {
                    guard !dark, rnd(i, salt) < 0.25 + 0.5 * s else { return .off }
                    let c = rnd(i, salt + 1)
                    let color: Color = c < 0.2 + 0.4 * s ? .white : c < 0.6 + 0.2 * s ? .purple : .red
                    return Light(color: color, level: 0.6 + 0.4 * rnd(i, salt + 2))
                }
                for i in 0..<8 { f.pads[i] = pick(i, 5) }
                for i in 0..<stripCount { f.strip[i] = pick(i, 8) }
                for i in buttons.indices { f.buttons[i] = !dark && rnd(i, 11) < 0.3 + 0.5 * s ? 1 : 0 }
                for i in 0..<6 { f.digits[i] = dark ? 0 : UInt8(rnd(i, 12) * 255) & 0xFE }
            }
        }
        return f
    }

    /// deterministischer Zufall 0..<1 (SplitMix64)
    static func noise(_ seed: UInt32, _ step: Int, _ i: Int) -> Double {
        var x = (UInt64(seed) &* 0x9E37_79B9_7F4A_7C15) ^ (UInt64(truncatingIfNeeded: step) &* 0xBF58_476D_1CE4_E5B9)
            ^ (UInt64(truncatingIfNeeded: i) &* 0x94D0_49BB_1331_11EB)
        x ^= x >> 31
        x = x &* 0xD6E8_FEB8_6659_FD93
        x ^= x >> 32
        return Double(x >> 11) / Double(UInt64(1) << 53)
    }

    // MARK: - Bild → Reports

    /// Ausgabe-Reports 0x80 (Tasten, Pads) und 0x81 (7-Segment, Strip); peak = Helligkeit „an“ (0…127)
    static func reports(_ f: Frame, peak: UInt8) -> (led: [UInt8], display: [UInt8]) {
        let top = Int(min(127, peak))
        func v(_ l: Double) -> Int { Int((max(0, min(1, l)) * Double(top)).rounded()) }
        var led = [UInt8](repeating: 0, count: 0x34)
        led[0] = 0x80
        for (i, p) in f.pads.enumerated() where i < padBytes.count {
            let c = rgb(p.color), l = v(p.level), b = padBytes[i]
            led[b] = UInt8(Int(c.r) * l / 127); led[b + 1] = UInt8(Int(c.g) * l / 127); led[b + 2] = UInt8(Int(c.b) * l / 127)
        }
        for (i, l) in f.buttons.enumerated() where i < buttons.count { led[buttons[i].byte] = UInt8(v(l)) }
        var disp = [UInt8](repeating: 0, count: displayLength)
        disp[0] = 0x81
        for (d, m) in f.digits.enumerated() where d < 6 {
            let base = 0x01 + (d / 3) * 0x18 + (d % 3) * 8
            for bit in 0..<8 where m & UInt8(1 << bit) != 0 { disp[base + bit] = UInt8(top) }
        }
        for (i, s) in f.strip.enumerated() where i < stripCount {
            let l = v(s.level)
            let (red, blue): (Int, Int) = switch s.color {
            case .red: (l, 0)
            case .purple: (l, l * 4 / 5)
            case .white: (l, l)
            }
            disp[stripStart + i * 2] = UInt8(red)
            disp[stripStart + i * 2 + 1] = UInt8(blue)
        }
        return (led, disp)
    }
}
