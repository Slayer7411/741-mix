import Foundation

/// Codename je Hauptversion: MINOS richtet die Seelen im Inferno, jede Hauptversion heißt nach einem Höllenkreis.
/// Kopie für Shell: `scripts/codename.sh` (CodenameTests prüft die Gleichheit).
public enum Codename {
    /// Index = Hauptversion. Ab 10 (und darüber) bleibt PARADISUS.
    public static let names = ["LIMBUS", "LUXURIA", "GULA", "AVARITIA", "IRA", "HAERESIS",
                               "VIOLENTIA", "FRAUS", "PRODITIO", "PURGATORIUM", "PARADISUS"]

    /// Name zur Hauptversion. Negative Werte zählen wie 0, zu große wie PARADISUS.
    public static func name(major: Int) -> String {
        names[min(max(major, 0), names.count - 1)]
    }

    /// Codename zu einer Version („0.8.2“, „v1“, „10.0“). nil bei ungültiger Version.
    /// Erlaubt: optionales „v“, 1 bis 3 Zahlen mit Punkt, nur Ziffern.
    public static func forVersion(_ version: String) -> String? {
        major(of: version).map { name(major: $0) }
    }

    /// Hauptversion aus einer Versionsangabe, nil bei ungültiger Eingabe
    public static func major(of version: String) -> Int? {
        var s = Substring(version)
        if s.first == "v" { s = s.dropFirst() }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }) else { return nil }
        return Int(parts[0])
    }
}
