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

/// Filter „passt zum Master“: welche Stufen zählen (gleich immer), BPM-Fenster in Prozent, halbes/doppeltes Tempo
public struct MatchRule: Hashable, Sendable, Codable {
    public var adjacent = true
    public var relative = true
    public var energy = false
    public var bpmWindow = 4.0
    public var halfDouble = false
    /// Gruppen aus Kommentar 2 (TagProfile): ähnlich = Gruppen in `similar` mit gleichem ersten Wort; ergänzend =
    /// `keep` gleich, `change` anders, keine gemeinsame Rolle. Master ohne Gruppen: egal; Track ohne: nein
    public enum Groove: String, Codable, Sendable, CaseIterable { case off, similar, complement }
    public var groove = Groove.off
    public var similar = "K B"
    public var keep = "K"
    public var change = "H"
    public init() {}

    private static func groups(_ s: String) -> [String] { s.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init) }

    public func matchesTags(_ t: TagProfile, _ ref: TagProfile) -> Bool {
        guard groove != .off, !ref.isEmpty else { return true }
        guard !t.isEmpty else { return false }
        func same(_ g: String) -> Bool { ref.primary[g] == nil || t.primary[g] == ref.primary[g] }
        switch groove {
        case .off: return true
        case .similar: return Self.groups(similar).allSatisfy(same)
        case .complement:
            return Self.groups(keep).allSatisfy(same)
                && Self.groups(change).allSatisfy { g in ref.primary[g] == nil || (t.primary[g] != nil && t.primary[g] != ref.primary[g]) }
                && t.roles.isDisjoint(with: ref.roles)
        }
    }

    public func accepts(_ s: Harmony.Step) -> Bool {
        switch s {
        case .same: true
        case .adjacent: adjacent
        case .relative: relative
        case .energy: energy
        case .clash: false
        }
    }

    /// Tempo-Abweichung in Prozent (Pitch, den der Track bis zum Bezug braucht), mit halbem/doppeltem Tempo die kleinste;
    /// nil ohne Tempo
    public func tempoOffset(_ bpm: Double, to ref: Double) -> Double? {
        guard bpm > 0, ref > 0 else { return nil }
        let factors: [Double] = halfDouble ? [1, 2, 0.5] : [1]
        return factors.map { (ref / (bpm * $0) - 1) * 100 }.min { abs($0) < abs($1) }
    }

    /// passt: Key (ohne Key des Bezugs: egal; Track ohne Key: nein) und Tempo (ohne Bezugs-Tempo: egal)
    public func matches(_ t: Track, _ ref: HarmonyRef) -> Bool {
        if let rk = ref.key {
            guard let k = t.harmonyCode, accepts(Harmony.relation(k, to: rk).step) else { return false }
        }
        guard ref.bpm > 0 else { return true }
        guard let off = tempoOffset(t.bpm, to: ref.bpm) else { return false }
        return abs(off) <= bpmWindow + 1e-9
    }

    /// Sortierwert „Harmonie“: Abstand zum Bezug, dann Tempo-Abweichung (kleiner = passender)
    public func rank(_ t: Track, _ ref: HarmonyRef?) -> Double {
        guard let ref else { return 0 }
        var r = 0.0
        if let rk = ref.key { r = Double(t.harmonyCode.map { Harmony.relation($0, to: rk).distance } ?? 99) * 1000 }
        return r + min(999, tempoOffset(t.bpm, to: ref.bpm).map(abs) ?? 999)
    }
}

extension Track {
    /// Key als Code (0–23): MUSICAL_KEY, sonst aus dem Key-Text; nil = unbekannt
    public var harmonyCode: Int? { (0...23).contains(musicalKey) ? musicalKey : Harmony.code(text: keyText) }
    /// Platzhalter der Sortierspalte „Harmonie“ – der Wert hängt am Bezug (TrackSort `rank`)
    public var harmonySort: Int { 0 }
}
