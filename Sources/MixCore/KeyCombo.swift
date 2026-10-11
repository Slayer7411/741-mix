import Foundation

/// Tastenkombination: Taste + Modifier, gespeichert als Text („cmd+opt+p“, „cmd+space“, „ctrl+cmd+1“).
/// Taste = ein Zeichen (klein) oder ein Name aus `KeyCombo.names` (Pfeile, F-Tasten, Leertaste …).
public struct KeyCombo: Hashable, Sendable, Codable, CustomStringConvertible {
    public struct Mods: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let control = Mods(rawValue: 1)
        public static let option = Mods(rawValue: 2)
        public static let shift = Mods(rawValue: 4)
        public static let command = Mods(rawValue: 8)
    }

    public var key: String
    public var mods: Mods

    public init(_ key: String, _ mods: Mods = [.command]) {
        self.key = key.count == 1 ? key.lowercased() : key
        self.mods = mods
    }

    /// benannte Tasten -> Anzeige
    public static let names: [String: String] = [
        "space": "SPACE", "left": "←", "right": "→", "up": "↑", "down": "↓",
        "return": "↩", "tab": "⇥", "escape": "⎋", "delete": "⌫", "forwarddelete": "⌦",
        "home": "↖", "end": "↘", "pageup": "⇞", "pagedown": "⇟",
    ].merging((1...12).map { ("f\($0)", "F\($0)") }, uniquingKeysWith: { a, _ in a })

    /// Reihenfolge wie in macOS-Menüs: ⌃⌥⇧⌘
    private static let order: [(Mods, String, String)] = [
        (.control, "ctrl", "⌃"), (.option, "opt", "⌥"), (.shift, "shift", "⇧"), (.command, "cmd", "⌘"),
    ]

    /// Text zum Speichern
    public var id: String { Self.order.filter { mods.contains($0.0) }.map { $0.1 + "+" }.joined() + key }

    public init?(id: String) {
        var rest = Substring(id), mods: Mods = []
        while let m = Self.order.first(where: { rest.hasPrefix($0.1 + "+") && rest.count > $0.1.count + 1 }) {
            mods.insert(m.0)
            rest = rest.dropFirst(m.1.count + 1)
        }
        let key = String(rest)
        guard key.count == 1 || Self.names[key] != nil else { return nil }
        self.init(key, mods)
    }

    /// Anzeige mit Symbolen: „⌥⌘P“, „⌘SPACE“, „⌃⌘1“
    public var symbols: String {
        Self.order.filter { mods.contains($0.0) }.map(\.2).joined() + (Self.names[key] ?? key.uppercased())
    }

    public var description: String { symbols }

    /// ohne ⌘, ⌥, ⌃ (nur Taste oder Shift + Taste) – stört beim Tippen, wird nur außerhalb von Textfeldern ausgelöst
    public var isPlain: Bool { mods.isDisjoint(with: [.command, .option, .control]) }

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let c = KeyCombo(id: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Tastenkombination \(s)"))
        }
        self = c
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(id)
    }

    /// Kombinationen, die mehreren Aktionen zugeordnet sind (Aktion-ID -> Kombination)
    public static func conflicts(_ assigned: [String: KeyCombo]) -> [KeyCombo: [String]] {
        Dictionary(grouping: assigned, by: \.value).mapValues { $0.map(\.key).sorted() }.filter { $0.value.count > 1 }
    }
}

/// Gruppe in den Einstellungen
public enum ShortcutGroup: String, CaseIterable, Sendable {
    case decks, browser, view, general
}

/// Alle Aktionen mit Tastenkürzel. Die IDs werden gespeichert (`prefs.v1` -> `shortcuts`) und dürfen sich nicht ändern.
public enum ShortcutID: String, CaseIterable, Sendable {
    case focusDeckA = "deck.focus.a", focusDeckB = "deck.focus.b", focusDeckC = "deck.focus.c", focusDeckD = "deck.focus.d"
    case play = "deck.play", cue = "deck.cue", cup = "deck.cup", sync = "deck.sync", master = "deck.master", keylock = "deck.keylock"
    case loop = "deck.loop", reloop = "deck.reloop", beatjumpBack = "deck.beatjump.back", beatjumpForward = "deck.beatjump.forward"
    case hotcue1 = "deck.hotcue.1", hotcue2 = "deck.hotcue.2", hotcue3 = "deck.hotcue.3", hotcue4 = "deck.hotcue.4"
    case hotcue5 = "deck.hotcue.5", hotcue6 = "deck.hotcue.6", hotcue7 = "deck.hotcue.7", hotcue8 = "deck.hotcue.8"
    case resetPlayed = "browser.resetplayed", loadSelected = "browser.load", previewSelected = "browser.preview"
    case reloadCollection = "browser.reload"
    case favorite1 = "browser.favorite.1", favorite2 = "browser.favorite.2", favorite3 = "browser.favorite.3"
    case favorite4 = "browser.favorite.4", favorite5 = "browser.favorite.5", favorite6 = "browser.favorite.6"
    case toggleMixer = "view.mixer", toggleFourDecks = "view.fourdecks", bigBrowser = "view.bigbrowser", bigBrowserKey = "view.bigbrowser.key"
    case compactDecks = "view.compactdecks"
    case zoomIn = "view.zoom.in", zoomOut = "view.zoom.out", zoomReset = "view.zoom.reset"
    case openCollection = "app.open", settings = "app.settings", closeWindow = "app.close", reconnectAudio = "app.reconnect"

    public var group: ShortcutGroup {
        switch self {
        case .resetPlayed, .loadSelected, .previewSelected, .reloadCollection,
             .favorite1, .favorite2, .favorite3, .favorite4, .favorite5, .favorite6: .browser
        case .toggleMixer, .toggleFourDecks, .bigBrowser, .bigBrowserKey, .compactDecks, .zoomIn, .zoomOut, .zoomReset: .view
        case .openCollection, .settings, .closeWindow, .reconnectAudio: .general
        default: .decks
        }
    }

    /// Deck-Index (Fokus), Hotcue-Index (0–7) bzw. Favoriten-Platz (0–5)
    public var index: Int? {
        switch self {
        case .focusDeckA: 0
        case .focusDeckB: 1
        case .focusDeckC: 2
        case .focusDeckD: 3
        case .hotcue1: 0
        case .hotcue2: 1
        case .hotcue3: 2
        case .hotcue4: 3
        case .hotcue5: 4
        case .hotcue6: 5
        case .hotcue7: 6
        case .hotcue8: 7
        case .favorite1: 0
        case .favorite2: 1
        case .favorite3: 2
        case .favorite4: 3
        case .favorite5: 4
        case .favorite6: 5
        default: nil
        }
    }

    /// Standardbelegung (nil = frei)
    public var defaultCombo: KeyCombo? {
        switch self {
        case .focusDeckA: KeyCombo("1")
        case .focusDeckB: KeyCombo("2")
        case .focusDeckC: KeyCombo("3")
        case .focusDeckD: KeyCombo("4")
        case .play: KeyCombo("space")
        case .cue: KeyCombo("c", [.option, .command])
        case .cup: KeyCombo("v", [.option, .command])
        case .sync: KeyCombo("y")
        case .loop: KeyCombo("l")
        case .beatjumpBack: KeyCombo("left", [.option, .command])
        case .beatjumpForward: KeyCombo("right", [.option, .command])
        case .hotcue1, .hotcue2, .hotcue3, .hotcue4, .hotcue5, .hotcue6, .hotcue7, .hotcue8:
            KeyCombo("\((index ?? 0) + 1)", [.control, .command])
        case .favorite1, .favorite2, .favorite3, .favorite4, .favorite5, .favorite6:
            KeyCombo("\((index ?? 0) + 1)", [.control, .option])
        case .resetPlayed: KeyCombo("p", [.option, .command])
        case .toggleMixer: KeyCombo("m", [.option, .command])
        case .toggleFourDecks: KeyCombo("4", [.option, .command])
        case .bigBrowser: KeyCombo("b", [.option, .command])
        case .bigBrowserKey: KeyCombo("space", [])
        case .compactDecks: KeyCombo("k", [.option, .command])
        case .zoomIn: KeyCombo("+")
        case .zoomOut: KeyCombo("-")
        case .zoomReset: KeyCombo("0")
        case .openCollection: KeyCombo("o")
        case .settings: KeyCombo(",")
        case .closeWindow: KeyCombo("w")
        case .master, .keylock, .reloop, .loadSelected, .previewSelected, .reloadCollection, .reconnectAudio: nil
        }
    }
}

/// Belegung: eigene Werte (ID -> Kombination als Text, "" = frei) über der Standardbelegung
public struct ShortcutMap: Equatable, Sendable {
    public var overrides: [String: String]

    public init(overrides: [String: String] = [:]) { self.overrides = overrides }

    public func combo(_ a: ShortcutID) -> KeyCombo? {
        guard let s = overrides[a.rawValue] else { return a.defaultCombo }
        return s.isEmpty ? nil : KeyCombo(id: s) ?? a.defaultCombo
    }

    public func isDefault(_ a: ShortcutID) -> Bool { combo(a) == a.defaultCombo }

    /// setzen; gleich wie Standard -> eigener Wert entfällt
    public mutating func set(_ a: ShortcutID, _ c: KeyCombo?) {
        overrides[a.rawValue] = c == a.defaultCombo ? nil : (c?.id ?? "")
    }

    public var assigned: [ShortcutID: KeyCombo] {
        Dictionary(uniqueKeysWithValues: ShortcutID.allCases.compactMap { a in combo(a).map { (a, $0) } })
    }

    /// Aktion zu einer gedrückten Kombination (bei Konflikt die erste in Listenreihenfolge)
    public func action(for c: KeyCombo) -> ShortcutID? { ShortcutID.allCases.first { combo($0) == c } }

    /// Aktionen mit doppelt vergebener Kombination
    public var conflicts: [KeyCombo: [ShortcutID]] {
        KeyCombo.conflicts(Dictionary(uniqueKeysWithValues: assigned.map { ($0.key.rawValue, $0.value) }))
            .mapValues { ids in ids.compactMap(ShortcutID.init(rawValue:)) }
    }

    public func conflicting(_ a: ShortcutID) -> [ShortcutID] {
        guard let c = combo(a) else { return [] }
        return ShortcutID.allCases.filter { $0 != a && combo($0) == c }
    }
}
