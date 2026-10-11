import Foundation

/// Harmonie auf dem Open-Key-Rad (1d…12m wie `Track.openKey`). Codes wie MUSICAL_KEY: 0–11 Dur (C…B), 12–23 Moll (Cm…Bm).
/// Bezug im Browser = hörbarer Key des Master-Decks (ohne Master: Fokus-Deck), inkl. Key-Shift.
public enum Harmony {
    /// Stufe gegenüber dem Bezug
    public enum Step: Int, Sendable, CaseIterable {
        /// gleicher Key
        case same
        /// ±1 auf dem Rad, gleiches Tongeschlecht
        case adjacent
        /// Relativ Dur/Moll (gleiche Zahl)
        case relative
        /// Energie-Wechsel ±2, gleiches Tongeschlecht
        case energy
        /// alles andere
        case clash
    }

    /// Lage eines Tracks zum Bezug
    public struct Relation: Equatable, Sendable {
        public var step: Step
        /// Schritte auf dem Rad (-5…6), positiv = im Uhrzeigersinn (Quinte aufwärts)
        public var turn: Int
        public var modeChange: Bool

        /// Zeichen vor dem Key: ◆ gleich, ▲ / ▼ ±1, ◇ Relativ
        public var symbol: String {
            switch step {
            case .same: "◆"
            case .adjacent: turn > 0 ? "▲" : "▼"
            case .relative: "◇"
            case .energy, .clash: ""
            }
        }

        /// Abstand für die Sortierung: Stufe, dann Schritte auf dem Rad (+1 bei Wechsel Dur/Moll)
        public var distance: Int {
            let rank = [Step.same: 0, .adjacent: 1, .relative: 1, .energy: 2, .clash: 3][step]!
            return rank * 10 + abs(turn) + (modeChange ? 1 : 0)
        }
    }

    public static func isMinor(_ code: Int) -> Bool { code >= 12 }

    /// Zahl auf dem Rad (1–12)
    public static func wheel(_ code: Int) -> Int {
        let s = code % 12
        return ((isMinor(code) ? s + 3 : s) * 7) % 12 + 1
    }

    /// Code aus Zahl auf dem Rad und Tongeschlecht
    public static func code(wheel n: Int, minor: Bool) -> Int {
        let s = ((n - 1) * 7) % 12   // 7 · 7 ≡ 1 (mod 12)
        return minor ? 12 + (s + 9) % 12 : s
    }

    /// um ganze Halbtöne verschoben (Tongeschlecht bleibt)
    public static func shifted(_ code: Int, by semitones: Int) -> Int {
        let s = ((code % 12 + semitones) % 12 + 12) % 12
        return isMinor(code) ? 12 + s : s
    }

    public static func relation(_ code: Int, to ref: Int) -> Relation {
        var turn = (wheel(code) - wheel(ref) + 12) % 12
        if turn > 6 { turn -= 12 }
        let mode = isMinor(code) != isMinor(ref)
        let step: Step = switch (abs(turn), mode) {
        case (0, false): .same
        case (1, false): .adjacent
        case (0, true): .relative
        case (2, false): .energy
        default: .clash
        }
        return Relation(step: step, turn: turn, modeChange: mode)
    }

    private static let notes: [Character: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]

    /// Key aus Text: Open Key („8m“, „10d“), Camelot („8A“, „11B“) oder Ton („Am“, „F#“, „Ebm“, „C#min“); nil = unbekannt
    public static func code(text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard let first = t.first else { return nil }
        if first.isNumber {
            let digits = t.prefix { $0.isNumber }
            guard let n = Int(digits), (1...12).contains(n), t.count == digits.count + 1, let m = t.last else { return nil }
            switch m {
            case "d", "D": return code(wheel: n, minor: false)
            case "m", "M": return code(wheel: n, minor: true)
            // Camelot: 8B = C = 1d, A = Moll
            case "A", "a": return code(wheel: (n + 4) % 12 + 1, minor: true)
            case "B", "b": return code(wheel: (n + 4) % 12 + 1, minor: false)
            default: return nil
            }
        }
        guard let base = notes[Character(first.uppercased())] else { return nil }
        var rest = t.dropFirst(), s = base
        if let a = rest.first, "#♯".contains(a) { s += 1; rest = rest.dropFirst() } else if let a = rest.first, "b♭".contains(a) { s -= 1; rest = rest.dropFirst() }
        let r = rest.lowercased()
        guard ["", "m", "min", "minor", "maj", "major", "moll", "dur"].contains(r) else { return nil }
        let minor = r == "m" || r.hasPrefix("min") || r == "moll"
        return minor ? 12 + (s + 12) % 12 : (s + 12) % 12
    }
}

/// Bezug für Key-Farben, Matching und Harmonie-Sortierung: hörbarer Key (nil = Track ohne Key) und Tempo (0 = keins)
public struct HarmonyRef: Hashable, Sendable {
    public var key: Int?
    public var bpm: Double
    public init(key: Int?, bpm: Double) { self.key = key; self.bpm = bpm }
}

extension Track {
    /// Key als Code (0–23): MUSICAL_KEY, sonst aus dem Key-Text; nil = unbekannt
    public var harmonyCode: Int? { (0...23).contains(musicalKey) ? musicalKey : Harmony.code(text: keyText) }
}
