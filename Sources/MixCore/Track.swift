import Foundation

/// Ein Cue-Punkt (NML CUE_V2). Positionen in Millisekunden.
public struct Cue: Hashable, Sendable, Codable {
    public enum Kind: Int, Sendable, Codable {
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

/// Ein Track der Collection. `key` entspricht dem NML-Primärschlüssel (VOLUME + DIR + FILE).
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
    /// NML INFO MIX (z. B. „Original Mix“)
    public var mix: String = ""
    public var catalogNo: String = ""
    public var trackNumber: Int = 0
    public var fileSizeKB: Int = 0
    public var comment: String = ""
    /// Kommentar 2 (NML-Attribut RATING) – Mix-Steckbrief.
    public var comment2: String = ""
    public var keyText: String = ""
    /// NML MUSICAL_KEY 0–23, -1 = unbekannt
    public var musicalKey: Int = -1
    public var bpm: Double = 0
    public var duration: Double = 0
    public var bitrate: Int = 0
    public var rating: Int = 0
    public var color: Int = 0
    public var playCount: Int = 0
    /// NML ENTRY LOCK="1": BPM, Grid und Key in der Collection gesperrt
    public var locked = false
    public var importDate: Date?
    public var releaseDate: Date?
    public var lastPlayed: Date?
    public var peakDb: Double?
    public var perceivedDb: Double?
    public var cues: [Cue] = []
    /// Suchtext für den Browser: alle Textfelder klein, ohne Akzente, als UTF-8 – einmal beim Laden gebaut
    public var searchText: [UInt8] = []

    public init(key: String, path: String) {
        self.key = key
        self.path = path
    }

    public static func fold(_ s: String) -> [UInt8] {
        Array(s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).utf8)
    }

    public mutating func buildSearchText() {
        searchText = Self.fold([artist, title, comment, comment2, label, genre, album, openKey].joined(separator: " "))
    }

    /// alle Wörter (mit `fold` vorbereitet) kommen im Suchtext vor
    public func matches(words: [[UInt8]]) -> Bool {
        words.allSatisfy { w in
            w.isEmpty || searchText.withUnsafeBufferPointer { h in
                w.withUnsafeBufferPointer { n in h.count >= n.count && memmem(h.baseAddress, h.count, n.baseAddress, n.count) != nil }
            }
        }
    }

    /// Sortier-/Anzeigehilfen für Tabellen
    public var importSort: Date { importDate ?? .distantPast }
    public var importText: String {
        guard let d = importDate else { return "" }
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
    public var playsText: String { playCount > 0 ? String(playCount) : "" }
    /// analysiert = Tempo und Lautheit vorhanden (in der Collection vorhanden)
    public var analyzed: Bool { bpm > 0 && perceivedDb != nil }
    public var analyzedSort: Int { analyzed ? 1 : 0 }
    public var gainSort: Double { perceivedDb ?? -99 }
    public var lastPlayedSort: Date { lastPlayed ?? .distantPast }
    public var releaseSort: Date { releaseDate ?? .distantPast }
    public static func dateText(_ d: Date?) -> String {
        guard let d else { return "" }
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public var fileName: String { (path as NSString).lastPathComponent }
    /// einmal beim Laden im Hintergrund geprüft (nil = noch nicht geprüft → als vorhanden behandeln);
    /// nie live prüfen – auf Google Drive dauert jeder Zugriff, bei 14k Tracks hängt sonst die Oberfläche
    public var fileMissing: Bool?
    public var fileExists: Bool { !(fileMissing ?? false) }
    /// Datei aus MUSIC FOLDERS, nicht in der Collection (kein Grid, keine Metadaten)
    public var loose = false

    /// Erster Grid-Marker (Beat 1) in ms.
    public var gridAnchorMs: Double? { cues.first { $0.kind == .grid }?.startMs }
    public var hotcues: [Cue] { cues.filter { $0.hotcue >= 0 }.sorted { $0.hotcue < $1.hotcue } }

    /// Open-Key-Notation (1d…12m) aus MUSICAL_KEY: 0–11 Dur (C…B), 12–23 Moll (Cm…Bm).
    public var openKey: String {
        guard musicalKey >= 0 else { return keyText }
        let major = musicalKey < 12
        let semitone = musicalKey % 12
        // Quintenzirkel-Position: C = 1d, Am = 1m (Moll über die parallele Dur-Tonart)
        let n = ((major ? semitone : semitone + 3) * 7) % 12 + 1
        return "\(n)\(major ? "d" : "m")"
    }

    /// Open Key nach einer Verschiebung um ganze Halbtöne (Dur/Moll bleibt), z. B. 8m + 1 = 3m
    public func openKey(shiftedBy semitones: Int) -> String {
        guard musicalKey >= 0 else { return openKey }
        let major = musicalKey < 12
        let semitone = (((musicalKey % 12) + semitones) % 12 + 12) % 12
        let n = ((major ? semitone : semitone + 3) * 7) % 12 + 1
        return "\(n)\(major ? "d" : "m")"
    }
}
