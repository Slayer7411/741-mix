import Foundation

/// Ein Cue-Punkt wie in Traktor (CUE_V2). Positionen in Millisekunden.
public struct Cue: Hashable, Sendable {
    public enum Kind: Int, Sendable {
        case cue = 0, fadeIn = 1, fadeOut = 2, load = 3, grid = 4, loop = 5
    }
    public var name: String
    public var kind: Kind
    public var startMs: Double
    public var lengthMs: Double
    /// -1 = Memory-Cue, 0–7 = Hotcue 1–8
    public var hotcue: Int

    public init(name: String, kind: Kind, startMs: Double, lengthMs: Double, hotcue: Int) {
        self.name = name; self.kind = kind; self.startMs = startMs; self.lengthMs = lengthMs; self.hotcue = hotcue
    }
}

/// Ein Track der Collection. `key` entspricht dem Traktor-Primärschlüssel (VOLUME + DIR + FILE).
public struct Track: Identifiable, Hashable, Sendable {
    public var id: String { key }
    public var key: String
    public var path: String
    public var title: String = ""
    public var artist: String = ""
    public var album: String = ""
    public var label: String = ""
    public var genre: String = ""
    public var remixer: String = ""
    public var producer: String = ""
    public var comment: String = ""
    /// Kommentar 2 (NML-Attribut RATING) – Mix-Steckbrief.
    public var comment2: String = ""
    public var keyText: String = ""
    /// Traktor MUSICAL_KEY 0–23, -1 = unbekannt
    public var musicalKey: Int = -1
    public var bpm: Double = 0
    public var duration: Double = 0
    public var bitrate: Int = 0
    public var rating: Int = 0
    public var color: Int = 0
    public var playCount: Int = 0
    public var importDate: Date?
    public var releaseDate: Date?
    public var lastPlayed: Date?
    public var peakDb: Double?
    public var perceivedDb: Double?
    public var cues: [Cue] = []

    public init(key: String, path: String) {
        self.key = key
        self.path = path
    }

    /// Sortier-/Anzeigehilfen für Tabellen
    public var importSort: Date { importDate ?? .distantPast }
    public var importText: String {
        guard let d = importDate else { return "" }
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
    public var playsText: String { playCount > 0 ? String(playCount) : "" }

    public var fileName: String { (path as NSString).lastPathComponent }
    public var fileExists: Bool { FileManager.default.fileExists(atPath: path) }

    /// Erster Grid-Marker (Beat 1) in ms.
    public var gridAnchorMs: Double? { cues.first { $0.kind == .grid }?.startMs }
    public var hotcues: [Cue] { cues.filter { $0.hotcue >= 0 }.sorted { $0.hotcue < $1.hotcue } }

    /// Open-Key-Notation (1d…12m) aus MUSICAL_KEY; Traktor: 0–11 Dur (C…B), 12–23 Moll (Cm…Bm).
    public var openKey: String {
        guard musicalKey >= 0 else { return keyText }
        let major = musicalKey < 12
        let semitone = musicalKey % 12
        // Quintenzirkel-Position: C = 1d, Am = 1m (Moll über die parallele Dur-Tonart)
        let n = ((major ? semitone : semitone + 3) * 7) % 12 + 1
        return "\(n)\(major ? "d" : "m")"
    }
}
