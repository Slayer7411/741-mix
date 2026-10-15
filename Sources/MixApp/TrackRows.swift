import Foundation
import MixCore

/// Browser-Zeilen: einzeilig (eine Spalte je Feld) oder zweizeilig (Textfelder in der Sammelspalte „Track“)
enum BrowserRows: String, CaseIterable, Codable, Identifiable {
    case single = "Einzeilig", double = "Zweizeilig (Text)"
    var id: String { rawValue }
}

/// Detailleiste unter der Liste: automatisch (an bei zweizeiligen Zeilen), immer, nie – je Bereich umschaltbar
enum DetailBarMode: String, CaseIterable, Codable, Identifiable {
    case auto = "Automatisch (bei zweizeilig)", on = "An", off = "Aus"
    var id: String { rawValue }
}

/// Teil der Sammelspalte; `lineBreak` trennt Zeile 1 und 2
enum TrackPart: String, CaseIterable, Codable, Identifiable {
    case title, artist, comment, tags, label, album, remixer, lineBreak = "br"
    var id: String { rawValue }

    var name: String {
        switch self {
        case .title: String(localized: "Titel")
        case .artist: "Artist"
        case .comment: String(localized: "Kommentar")
        case .tags: String(localized: "Tags (Kommentar 2)")
        case .label: "Label"
        case .album: "Album"
        case .remixer: "Remixer"
        case .lineBreak: String(localized: "— Zeile 2 —")
        }
    }

    /// bearbeitbares Feld (Inline, Tab)
    var field: TrackField? {
        switch self {
        case .title: .title
        case .artist: .artist
        case .comment: .comment
        case .tags: .comment2
        case .label: .label
        case .album: .album
        case .remixer: .remixer
        case .lineBreak: nil
        }
    }

    /// Spalte, die die Sammelspalte im zweizeiligen Modus ersetzt
    var column: String? {
        switch self {
        case .title: "title"
        case .artist: "artist"
        case .comment: "comment"
        case .tags: "comment2"
        case .label: "label"
        case .album: "release"
        case .remixer: "remixer"
        case .lineBreak: nil
        }
    }

    /// Sortierung der Sammelspalte (Kopf-Menü)
    static let sortable: [TrackPart] = [.title, .artist, .comment, .label]

    var sort: KeyPathComparator<Track>? {
        switch self {
        case .title: KeyPathComparator(\Track.title)
        case .artist: KeyPathComparator(\Track.artist)
        case .comment: KeyPathComparator(\Track.comment)
        case .label: KeyPathComparator(\Track.label)
        case .tags: KeyPathComparator(\Track.comment2)
        case .album: KeyPathComparator(\Track.album)
        case .remixer: KeyPathComparator(\Track.remixer)
        case .lineBreak: nil
        }
    }
}

/// Anordnung der Sammelspalte (⌘, -> BROWSER): Teile in Reihenfolge, genau ein Zeilenwechsel
enum TrackParts {
    static let standard: [TrackPart] = [.title, .artist, .lineBreak, .comment, .tags, .label]
    /// Vorlage „Kommentar zuerst“: Zeile 1 Kommentar · Titel, Zeile 2 Artist · Tags
    static let commentFirst: [TrackPart] = [.comment, .title, .lineBreak, .artist, .tags]
    static let presets: [(String, [TrackPart])] = [(String(localized: "Standard"), standard), (String(localized: "Kommentar zuerst"), commentFirst)]

    /// gespeicherte Liste -> gültige: unbekannte und doppelte raus, genau ein Zeilenwechsel, mindestens ein Teil
    static func normalized(_ raw: [String]) -> [TrackPart] {
        var out: [TrackPart] = [], seen = Set<TrackPart>()
        for r in raw { if let p = TrackPart(rawValue: r), seen.insert(p).inserted { out.append(p) } }
        if !out.contains(.lineBreak) { out.append(.lineBreak) }
        guard out.contains(where: { $0 != .lineBreak }) else { return standard }
        return out
    }

    /// Zeile 1 und Zeile 2
    static func lines(_ parts: [TrackPart]) -> (first: [TrackPart], second: [TrackPart]) {
        guard let i = parts.firstIndex(of: .lineBreak) else { return (parts, []) }
        return (Array(parts[..<i]), parts[(i + 1)...].filter { $0 != .lineBreak })
    }

    /// Felder in Lesereihenfolge (Tab in der Inline-Bearbeitung)
    static func fields(_ parts: [TrackPart]) -> [TrackField] { parts.compactMap(\.field) }

    /// Teil eine Stelle nach oben (-1) / unten (+1)
    static func moved(_ parts: [TrackPart], _ p: TrackPart, by d: Int) -> [TrackPart] {
        guard let i = parts.firstIndex(of: p) else { return parts }
        let j = i + d
        guard j >= 0, j < parts.count else { return parts }
        var out = parts
        out.swapAt(i, j)
        return out
    }
}
