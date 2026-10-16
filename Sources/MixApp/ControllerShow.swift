import Foundation

/// Startsequenz des Controllers als reine Funktion: Zeit → LED-Bild (testbar ohne Gerät). Senden: ControllerUnit.
/// Ablauf: Glut (0–1,2 s) → Lauflicht in zwei Runden (–3,5 s) → Wirrwarr (–5 s) → Einpendeln (–8,4 s): das Flackern
/// wird seltener und ruhiger, LEDs fallen je Gruppe (Pads, Tasten, Ziffern, Strip) einzeln in den normalen Zustand;
/// die Ziffern zeigen bis dahin die Decks der Seite → ein Atempuls (–8,9 s) → bereit.
enum LEDShow {
    enum Phase: Int, Comparable {
        case storm, settle, breath, ready
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
        /// links Pad 1–4, rechts Pad 1–4; nil = LED schon im normalen Zustand
        var pads: [Light?]
        /// einfarbige LEDs in der Reihenfolge von `buttons`; nil = normal
        var buttons: [Double?]
        /// 6 Stellen (links 3, rechts 3), Bit n = Segment n (0 = Punkt); nil = normal
        var digits: [UInt8?]
        /// Touchstrip von links nach rechts; nil = normal
        var strip: [Light?]
        /// Atempuls 0…1 (nur Schlussphase): dimmt den normalen Zustand kurz ab
        var breath: Double = 0
    }

    static let stormEnd = 5.0, settleEnd = 8.4, duration = 8.9
    /// Sturm: Glut, Lauflicht Runde 1 und 2, Wirrwarr bis stormEnd
    static let emberEnd = 1.2, chaseTurn = 2.35, chaseEnd = 3.5
    /// Flackerdichte im Wirrwarr (Anteil der LEDs, die im Takt leuchten), danach quadratisch auf 0 bei settleEnd
    static let chaosDensity = 0.55
    /// Seitenwechsel: Ziffern noch mit den Decks, Rest schon im Einpendeln
    static let sideAt = 7.0
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

    // MARK: - Zeitplan

    /// Gruppen des Einpendelns, in dieser Reihenfolge
    enum Part: Int { case pads, buttons, digits, strip }

    /// Fenster, in dem die LEDs einer Gruppe einzeln in den normalen Zustand fallen
    static func window(_ p: Part) -> (from: Double, to: Double) {
        switch p {
        case .pads: return (stormEnd, 6.2)
        case .buttons: return (6.0, 7.2)
        case .digits: return (7.0, 8.0)
        case .strip: return (7.2, settleEnd)
        }
    }

    static func phase(at t: Double) -> Phase {
        t < stormEnd ? .storm : t < settleEnd ? .settle : t < duration ? .breath : .ready
    }

    /// Flackerdichte: im Wirrwarr konstant, im Einpendeln quadratisch auf 0 (ab settleEnd kein Flackern mehr)
    static func density(at t: Double) -> Double {
        guard t >= chaseEnd, t < settleEnd else { return 0 }
        guard t >= stormEnd else { return chaosDensity }
        let u = (t - stormEnd) / (settleEnd - stormEnd)
        return chaosDensity * (1 - u) * (1 - u)
    }

    /// Zeitpunkt, zu dem eine LED in den normalen Zustand fällt (zufällig im Fenster ihrer Gruppe, fest je Seed)
    static func settleAt(_ p: Part, _ i: Int, seed: UInt32) -> Double {
        let w = window(p)
        return w.from + noise(seed, 0, key(p, i, 0)) * (w.to - w.from)
    }

    /// Zufallsreihe je LED und Zweck (getrennt je Gruppe)
    private static func key(_ p: Part, _ i: Int, _ role: Int) -> Int { (p.rawValue * 64 + i) * 16 + role }

    /// Helligkeit des normalen Zustands im Atempuls (dimmt kurz ab, 0 = unverändert)
    static func breathPeak(_ peak: UInt8, _ breath: Double) -> UInt8 {
        UInt8((Double(peak) * (1 - 0.25 * max(0, min(1, breath)))).rounded())
    }

    // MARK: - Generator

    /// LED-Bild zur Zeit t (s seit Start); nil = fertig, normaler LED-Zustand
    static func frame(at t: Double, decks: (left: Int, right: Int), seed: UInt32) -> Frame? {
        let t = max(0, t)
        let ph = phase(at: t)
        guard ph != .ready else { return nil }
        let n = Int(t / step)
        func rnd(_ i: Int, _ salt: Int = 0) -> Double { noise(seed, n, i &* 31 &+ salt) }
        var f = Frame(phase: ph, pads: Array(repeating: Light.off, count: 8),
                      buttons: Array(repeating: 0, count: buttons.count), digits: Array(repeating: 0, count: 6),
                      strip: Array(repeating: Light.off, count: stripCount))
        if t < chaseEnd {
            if t < emberEnd {
                // Glut: dunkelrotes Flackern, Funken werden dichter
                let e = t / emberEnd
                for i in 0..<8 { f.pads[i] = Light(color: .red, level: 0.06 + 0.4 * rnd(i) * (0.4 + 0.6 * e)) }
                for i in 0..<stripCount {
                    let r = rnd(i, 1)
                    f.strip[i] = Light(color: .red, level: r < 0.1 + 0.2 * e ? 0.2 + 2 * r : 0.03)
                }
                for i in buttons.indices { f.buttons[i] = rnd(i, 2) < 0.05 + 0.15 * e ? 0.5 : 0.04 }
                for i in 0..<6 { let r = rnd(i, 3); f.digits[i] = r < 0.1 + 0.25 * e ? UInt8(1 << (1 + Int(r * 23) % 7)) : 0 }
            } else {
                // Lauflicht in zwei Runden: lila Kopf, roter Schweif, weiße Funken; Runde 2 rückwärts, schneller, mehr Funken
                let second = t >= chaseTurn
                let u = second ? t - chaseTurn : t - emberEnd
                let dir = second ? -1.0 : 1.0, speed = second ? 0.032 : 0.045, sparks = second ? 0.12 : 0.05
                let head = u / speed
                for (pos, pad) in padSnake.enumerated() {
                    let d = (head - dir * Double(pos)).truncatingRemainder(dividingBy: 8)
                    let dist = d < 0 ? d + 8 : d
                    f.pads[pad] = dist < 1 ? Light(color: .purple, level: 1)
                        : rnd(pad, 4) < sparks ? Light(color: .white, level: 1)
                        : Light(color: .red, level: max(0.06, 0.8 - (dist - 1) * 0.25))
                }
                // Strip: zwei Köpfe, gespiegelt hin und her
                let period = second ? 0.3 : 0.4, last = Double(stripCount - 1)
                let ph = (u / period).truncatingRemainder(dividingBy: 1)
                let p = (ph < 0.5 ? ph * 2 : 2 - ph * 2) * last
                for i in 0..<stripCount {
                    let dist = min(abs(Double(i) - p), abs(Double(i) - (last - p)))
                    f.strip[i] = dist < 0.8 ? Light(color: .purple, level: 1)
                        : second && rnd(i, 13) < sparks ? Light(color: .white, level: 0.8)
                        : Light(color: .red, level: max(0.03, 0.6 - dist * 0.15))
                }
                let count = Double(buttons.count)
                let bh = (u / (second ? 0.022 : 0.03)).truncatingRemainder(dividingBy: count)
                for i in buttons.indices {
                    let d = bh - dir * Double(i)
                    let m = d.truncatingRemainder(dividingBy: count)
                    let dist = m < 0 ? m + count : m
                    f.buttons[i] = max(0.05, 1 - dist * 0.3)
                }
                // 7-Segment: äußerer Ring läuft um (a b c d e f), Runde 2 andersherum
                let ring = second ? [5, 6, 7, 2, 3, 4] : [4, 3, 2, 7, 6, 5]
                for i in 0..<6 { f.digits[i] = UInt8(1 << ring[(Int(u / 0.05) + i) % ring.count]) }
            }
        } else {
            // Wirrwarr, dann Einpendeln: jede LED fällt zu eigenem Zeitpunkt in den normalen Zustand (nil),
            // davor flackert sie mit der Dichte d; ruhiger = seltener neu gewürfelt, gleichmäßigere Helligkeit
            let d = density(at: t), h = d / chaosDensity
            let b = n / (1 + Int(5 * (1 - h)))          // Haltezeit je Bild: 1 Takt im Wirrwarr, bis 6 Takte ruhig
            func rb(_ p: Part, _ i: Int, _ role: Int) -> Double { noise(seed, b, key(p, i, role)) }
            func level(_ p: Part, _ i: Int) -> Double { 0.85 - (0.1 + 0.5 * h) * rb(p, i, 3) }
            func light(_ p: Part, _ i: Int) -> Light {
                guard rb(p, i, 1) < d else { return .off }
                let c = rb(p, i, 2), white = 0.3 * h
                let color: Color = c < white ? .white : c < white + 0.3 ? .purple : .red
                return Light(color: color, level: level(p, i))
            }
            for i in 0..<8 {
                f.pads[i] = t < settleAt(.pads, i, seed: seed) ? light(.pads, i) : nil
            }
            for i in buttons.indices {
                let lit: Double? = rb(.buttons, i, 1) < d ? level(.buttons, i) : 0
                f.buttons[i] = t < settleAt(.buttons, i, seed: seed) ? lit : nil
            }
            // 7-Segment: Wirrwarr zufällig, danach die Decks der Seite, bis die Ziffer einpendelt
            let dash = mask("-")
            let letters: [UInt8] = [dash, mask(letter(decks.left)), dash, dash, mask(letter(decks.right)), dash]
            for i in 0..<6 {
                guard t < settleAt(.digits, i, seed: seed) else { f.digits[i] = nil; continue }
                if t < stormEnd {
                    var m: UInt8 = 0
                    for bit in 1...7 where rb(.digits, i, 4 + bit) < d { m |= UInt8(1 << bit) }
                    f.digits[i] = m
                } else {
                    f.digits[i] = letters[i]
                }
            }
            for i in 0..<stripCount {
                f.strip[i] = t < settleAt(.strip, i, seed: seed) ? light(.strip, i) : nil
            }
        }
        if ph == .breath { f.breath = sin(Double.pi * (t - settleEnd) / (duration - settleEnd)) }
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

    /// Ausgabe-Reports 0x80 (Tasten, Pads) und 0x81 (7-Segment, Strip); peak = Helligkeit „an“ (0…127).
    /// LEDs im normalen Zustand (nil) übernehmen ihre Bytes aus `normal`, alle anderen zeigen das Bild.
    static func reports(_ f: Frame, peak: UInt8, normal: (led: [UInt8], display: [UInt8])) -> (led: [UInt8], display: [UInt8]) {
        let top = Int(min(127, peak))
        func v(_ l: Double) -> Int { Int((max(0, min(1, l)) * Double(top)).rounded()) }
        var led = [UInt8](repeating: 0, count: 0x34)
        led[0] = 0x80
        for (i, p) in f.pads.enumerated() where i < padBytes.count {
            let b = padBytes[i]
            guard let p else { led[b..<b + 3] = normal.led[b..<b + 3]; continue }
            let c = rgb(p.color), l = v(p.level)
            led[b] = UInt8(Int(c.r) * l / 127); led[b + 1] = UInt8(Int(c.g) * l / 127); led[b + 2] = UInt8(Int(c.b) * l / 127)
        }
        for (i, l) in f.buttons.enumerated() where i < buttons.count {
            let byte = buttons[i].byte
            led[byte] = l.map { UInt8(v($0)) } ?? normal.led[byte]
        }
        var disp = [UInt8](repeating: 0, count: displayLength)
        disp[0] = 0x81
        for (d, m) in f.digits.enumerated() where d < 6 {
            let base = 0x01 + (d / 3) * 0x18 + (d % 3) * 8
            for bit in 0..<8 {
                disp[base + bit] = m.map { $0 & UInt8(1 << bit) != 0 ? UInt8(top) : 0 } ?? normal.display[base + bit]
            }
        }
        for (i, s) in f.strip.enumerated() where i < stripCount {
            let at = stripStart + i * 2
            guard let s else { disp[at] = normal.display[at]; disp[at + 1] = normal.display[at + 1]; continue }
            let l = v(s.level)
            let (red, blue): (Int, Int) = switch s.color {
            case .red: (l, 0)
            case .purple: (l, l * 4 / 5)
            case .white: (l, l)
            }
            disp[at] = UInt8(red)
            disp[at + 1] = UInt8(blue)
        }
        return (led, disp)
    }
}
