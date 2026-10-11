import Foundation

/// Key Sync auf dem Open-Key-Rad (Zahl 1–12, d = Dur, m = Moll; MUSICAL_KEY 0–11 Dur, 12–23 Moll)
public enum KeySync {
    /// Open-Key-Zahl eines MUSICAL_KEY nach `shift` Halbtönen
    public static func number(code: Int, shift: Int = 0) -> Int {
        let major = code < 12
        let semitone = (((code % 12) + shift) % 12 + 12) % 12
        return ((major ? semitone : semitone + 3) * 7) % 12 + 1
    }

    /// passt: gleiche Zahl (gleicher Key bzw. Parallele) oder Nachbar ±1 im selben Tongeschlecht
    public static func compatible(_ a: Int, _ aMajor: Bool, _ b: Int, _ bMajor: Bool) -> Bool {
        if a == b { return true }
        let diff = ((a - b) % 12 + 12) % 12
        return aMajor == bMajor && (diff == 1 || diff == 11)
    }

    /// Key-Shift (−6…6) für einen Track mit `code` zum hörbaren Master-Key (`masterCode` + `masterShift` Halbtöne):
    /// kleinster Betrag, bei dem der Key gleich oder kompatibel ist; bei gleichem Betrag gewinnt der gleiche Key,
    /// dann die Richtung näher an `current`
    public static func shift(code: Int, masterCode: Int, masterShift: Int, current: Int = 0) -> Int {
        let target = number(code: masterCode, shift: masterShift), tMajor = masterCode < 12, major = code < 12
        func rank(_ s: Int) -> (Int, Int, Int) {
            let n = number(code: code, shift: s)
            return (abs(s), n == target && major == tMajor ? 0 : 1, abs(s - current))
        }
        let ok = (-6...6).filter { compatible(number(code: code, shift: $0), major, target, tMajor) }
        return ok.min { rank($0) < rank($1) } ?? 0
    }
}
