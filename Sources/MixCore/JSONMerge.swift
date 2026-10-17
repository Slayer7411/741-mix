import Foundation

/// Zusammenführen von JSON-Objekten (Fernzugriff, prefs-set): Objekte gehen rekursiv ineinander, sonst ersetzt der Auftrag
public enum JSONMerge {
    public static func merged(_ base: [String: Any], _ patch: [String: Any]) -> [String: Any] {
        var r = base
        for (k, v) in patch {
            if let b = base[k] as? [String: Any], let o = v as? [String: Any] {
                r[k] = merged(b, o)
            } else {
                r[k] = v
            }
        }
        return r
    }

    /// Pfade im Auftrag, die es im Muster nicht gibt (Tippfehler). Leere Objekte im Muster sind freie Zuordnungen:
    /// dort ist jeder Schlüssel recht
    public static func unknownPaths(_ patch: [String: Any], reference: [String: Any], prefix: String = "") -> [String] {
        var out: [String] = []
        for (k, v) in patch.sorted(by: { $0.key < $1.key }) {
            let path = prefix.isEmpty ? k : prefix + "." + k
            guard let ref = reference[k] else {
                if !reference.isEmpty { out.append(path) }
                continue
            }
            if let o = v as? [String: Any], let r = ref as? [String: Any], !r.isEmpty {
                out += unknownPaths(o, reference: r, prefix: path)
            }
        }
        return out
    }
}
