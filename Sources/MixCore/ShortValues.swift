import Foundation

/// Kurze Anzeige-Werte im Browser (⌘, -> BROWSER „Werte kürzen“). Nur Anzeige: Sortierung und Suche nutzen die vollen Werte.
public enum ShortValues {
    /// Version am Titelende -> Kürzel (Groß/Klein egal). Längere Einträge zuerst (sie enthalten kürzere)
    public static let versions: [(name: String, short: String)] = [
        ("original extended mix", "EXT"), ("extended original mix", "EXT"),
        ("original mix", "OM"), ("original version", "OM"), ("original", "OM"),
        ("extended mix", "EXT"), ("extended version", "EXT"), ("extended edit", "EXT"), ("extended", "EXT"), ("club mix", "CLUB"),
        ("radio edit", "RADIO"), ("radio mix", "RADIO"), ("radio version", "RADIO"),
        ("dub mix", "DUB"), ("dub", "DUB"), ("instrumental mix", "INST"), ("instrumental", "INST"),
        ("vip mix", "VIP"), ("vip", "VIP"), ("remix", "RMX"), ("rmx", "RMX"), ("rework", "RWK"), ("re-work", "RWK"),
        ("bootleg", "BOOT"), ("edit", "EDIT"), ("mix", "MIX"),
    ]

    /// Titel ohne Version am Ende + Kürzel (mit Namen davor, z. B. „Foo RMX“). nil = keine bekannte Version
    public static func version(_ title: String) -> (base: String, short: String)? {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        // „Name (Version)“ / „Name [Version]“
        if let close = t.last, close == ")" || close == "]" {
            let open: Character = close == ")" ? "(" : "["
            guard let i = t.lastIndex(of: open) else { return nil }
            let inner = String(t[t.index(after: i)..<t.index(before: t.endIndex)]).trimmingCharacters(in: .whitespaces)
            let base = String(t[..<i]).trimmingCharacters(in: .whitespaces)
            guard !base.isEmpty, let s = short(inner) else { return nil }
            return (base, s)
        }
        // „Name - Version“
        for sep in [" - ", " – "] {
            guard let r = t.range(of: sep, options: .backwards) else { continue }
            let inner = String(t[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            let base = String(t[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            guard !base.isEmpty, let s = short(inner) else { continue }
            return (base, s)
        }
        return nil
    }

    /// Kürzel einer Version („Original Mix“ -> OM, „Foo Remix“ -> „Foo RMX“); nil = unbekannt
    public static func short(_ version: String) -> String? {
        let v = version.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let low = v.lowercased()
        for (name, s) in versions {
            if low == name { return s }
            // Name davor („Foo Remix“), nur bei Remix & Co., nicht „Foo Original“
            if low.hasSuffix(" " + name), !["OM", "MIX"].contains(s) {
                let who = String(v.dropLast(name.count)).trimmingCharacters(in: .whitespaces)
                return who.isEmpty ? s : who + " " + s
            }
        }
        return nil
    }

    /// in der Mitte kürzen auf höchstens `max` Zeichen: Anfang und Ende bleiben („Very Long … Title“)
    public static func middle(_ s: String, max n: Int) -> String {
        let c = Array(s)
        guard c.count > n else { return s }
        guard n > 1 else { return n == 1 ? "…" : "" }
        let keep = n - 1, head = (keep + 1) / 2, tail = keep - head
        let h = String(c[0..<head]).trimmingCharacters(in: .whitespaces)
        let t = String(c[(c.count - tail)...]).trimmingCharacters(in: .whitespaces)
        return h + "…" + t
    }

    /// BPM: ganzzahlig bis auf 0,05 ohne Nachkommastelle, sonst eine
    public static func bpm(_ v: Double) -> String {
        guard v > 0 else { return "" }
        let r = v.rounded()
        return abs(v - r) < 0.05 ? String(format: "%.0f", r) : String(format: "%.1f", v)
    }

    /// Datum: jünger als ein Jahr „14.10.“, älter „Okt 26“ (Monat in der Sprache von `locale`, ohne Punkt)
    public static func date(_ d: Date?, now: Date = Date(), locale: Locale = .current) -> String {
        guard let d else { return "" }
        var cal = Calendar(identifier: .gregorian)
        cal.locale = locale
        let c = cal.dateComponents([.year, .month, .day], from: d)
        let age = now.timeIntervalSince(d)
        if age < 330 * 86400, age > -86400 {
            return String(format: "%02d.%02d.", c.day ?? 0, c.month ?? 0)
        }
        let names = cal.shortStandaloneMonthSymbols
        let m = max(1, min(12, c.month ?? 1))
        let name = names.count == 12 ? names[m - 1].replacingOccurrences(of: ".", with: "") : String(m)
        return String(format: "%@ %02d", name.prefix(3).capitalized, (c.year ?? 0) % 100)
    }
}
