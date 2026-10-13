import Foundation

/// Seite eines Controllers: links = Decks A/C, Browser links, FX1 (+FX3); rechts = B/D, Browser rechts, FX2 (+FX4)
enum ControllerSide: String, CaseIterable, Codable, Identifiable {
    case left, right
    var id: String { rawValue }
    var other: ControllerSide { self == .left ? .right : .left }
    var decks: (left: Int, right: Int) { self == .left ? (0, 2) : (1, 3) }
    var pane: Int { self == .left ? 0 : 1 }
    var fxUnit: Int { self == .left ? 10 : 11 }

    /// Seite aus einer alten Deck-Zuordnung (A/C bzw. B/D), sonst nil
    init?(decks l: Int, _ r: Int) {
        switch (l, r) {
        case (0, 2): self = .left
        case (1, 3): self = .right
        default: return nil
        }
    }
}

/// Feste Seite je Gerät: Schlüssel = Seriennummer, sonst USB-Position. Reine Funktionen (Tests ohne Gerät)
enum ControllerSides {
    static let tempPrefix = "tmp-"

    /// stabiler Schlüssel: Seriennummer, sonst USB-Position; nil = keine eindeutige Kennung
    static func key(serial: String?, location: Int?) -> String? {
        if let s = serial?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { return s }
        if let l = location, l != 0 { return String(format: "loc-%08x", l) }
        return nil
    }

    /// Schlüssel ohne Kennung (gilt nur bis zum Trennen, wird nie gespeichert)
    static func isStable(_ key: String) -> Bool { !key.hasPrefix(tempPrefix) }

    /// Seite für ein neu erkanntes Gerät: gespeicherte Seite, sonst die erste freie (der Reihe nach).
    /// Belegt ein anderes verbundenes Gerät die gespeicherte Seite, bekommt dieses die andere (moved).
    /// nil = beide Seiten belegt (dritter Controller)
    static func resolve(saved: ControllerSide?, taken: Set<ControllerSide>) -> (side: ControllerSide, moved: Bool)? {
        let free = ControllerSide.allCases.filter { !taken.contains($0) }
        guard let first = free.first else { return nil }
        guard let saved else { return (first, false) }
        return free.contains(saved) ? (saved, false) : (first, true)
    }

    /// Gerät `key` auf `side` stellen; ein anderes Gerät auf dieser Seite wechselt auf die andere (Tausch)
    static func assign(_ key: String, to side: ControllerSide, current: [String: ControllerSide]) -> [String: ControllerSide] {
        var r = current
        r[key] = side
        for (k, s) in current where k != key && s == side { r[k] = side.other }
        return r
    }

    /// gespeicherte Seite aus den Einstellungen
    static func saved(_ key: String, in sides: [String: String]) -> ControllerSide? {
        sides[key].flatMap(ControllerSide.init(rawValue:))
    }
}
