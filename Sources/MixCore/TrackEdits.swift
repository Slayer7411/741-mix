import Foundation

/// Eigene Änderungen an Tracks (Beatgrid, Hotcues) – dauerhaft, ohne die Collection anzufassen.
/// Beim Laden eines Tracks werden sie über die Collection-Werte gelegt.
public struct TrackEdit: Codable, Equatable, Sendable {
    public var bpm: Double?
    public var gridAnchorMs: Double?
    public var hotcues: [Cue]?
    public var modified = Date()

    public init(bpm: Double? = nil, gridAnchorMs: Double? = nil, hotcues: [Cue]? = nil) {
        self.bpm = bpm; self.gridAnchorMs = gridAnchorMs; self.hotcues = hotcues
    }

    /// Track mit den Änderungen
    public func apply(to t: Track) -> Track {
        var t = t
        if let b = bpm { t.bpm = b }
        if let a = gridAnchorMs {
            // Anker nur um ganze Beats umnummeriert (Phrasen-Anker): Start-Cue bleibt am alten Anker
            if let old = t.gridAnchorMs, t.bpm > 0, !t.cues.contains(where: { $0.kind == .load }) {
                let beats = (a - old) / (60_000 / t.bpm)
                if abs(beats) >= 0.5, abs(beats - beats.rounded()) * 60_000 / t.bpm < 5 {
                    t.cues.append(Cue(name: "Load", kind: .load, startMs: old, lengthMs: 0, hotcue: -1))
                }
            }
            if let i = t.cues.firstIndex(where: { $0.kind == .grid }) { t.cues[i].startMs = a }
            else { t.cues.append(Cue(name: "Grid", kind: .grid, startMs: a, lengthMs: 0, hotcue: -1)) }
        }
        if let h = hotcues {
            t.cues.removeAll { $0.hotcue >= 0 && $0.kind != .grid }
            t.cues.append(contentsOf: h)
        }
        return t
    }
}

public final class TrackEditStore: @unchecked Sendable {
    public private(set) var edits: [String: TrackEdit] = [:]
    let url: URL
    private let lock = NSLock()

    public init(url: URL) {
        self.url = url
        if let d = try? Data(contentsOf: url), let e = try? JSONDecoder().decode([String: TrackEdit].self, from: d) { edits = e }
    }

    public func edit(for key: String) -> TrackEdit? { lock.lock(); defer { lock.unlock() }; return edits[key] }

    public func set(_ e: TrackEdit?, for key: String) {
        lock.lock()
        edits[key] = e
        let snapshot = edits
        lock.unlock()
        if let d = try? JSONEncoder().encode(snapshot) { try? d.write(to: url, options: .atomic) }
    }
}

// MARK: - Metadaten bearbeiten (Browser: Inline, Bearbeiten-Fenster)

/// Bearbeitbare Metadaten eines Tracks – die Felder, die auch das Bearbeiten-Fenster der Collection-Software kennt.
/// Werte laufen als kanonischer Text: Datum „JJJJ-MM-TT“, Bewertung „0“–„5“, Track-Nummer „“ oder Zahl, BPM „%.3f“.
public enum TrackField: String, CaseIterable, Codable, Sendable, Identifiable {
    case title, artist, album, mix, remixer, producer, label, catalogNo, genre, comment, comment2, keyText,
         trackNumber, releaseDate, bpm, rating

    public var id: String { rawValue }

    /// Spaltenname im Browser (gleich der Tabellen-Überschrift)
    public var label: String {
        switch self {
        case .title: "Title"
        case .artist: "Artist"
        case .album: "Release"
        case .mix: "Mix"
        case .remixer: "Remixer"
        case .producer: "Producer"
        case .label: "Label"
        case .catalogNo: "Catalog No"
        case .genre: "Genre"
        case .comment: "Comment"
        case .comment2: "Comment 2"
        case .keyText: "Key Text"
        case .trackNumber: "Track #"
        case .releaseDate: "Release Date"
        case .bpm: "BPM"
        case .rating: "Rating"
        }
    }

    /// reine Textfelder (alles außer Zahl, Datum, BPM, Bewertung)
    public var isText: Bool { ![.trackNumber, .releaseDate, .bpm, .rating].contains(self) }

    /// darf bei diesem Track bearbeitet werden (BPM nicht bei gesperrten Tracks)
    public func isEditable(_ t: Track) -> Bool { self != .bpm || !t.locked }

    /// aktueller Wert als kanonischer Text
    public func value(of t: Track) -> String {
        switch self {
        case .title: t.title
        case .artist: t.artist
        case .album: t.album
        case .mix: t.mix
        case .remixer: t.remixer
        case .producer: t.producer
        case .label: t.label
        case .catalogNo: t.catalogNo
        case .genre: t.genre
        case .comment: t.comment
        case .comment2: t.comment2
        case .keyText: t.keyText
        case .trackNumber: t.trackNumber > 0 ? String(t.trackNumber) : ""
        case .releaseDate: Track.dateText(t.releaseDate)
        case .bpm: t.bpm > 0 ? String(format: "%.3f", t.bpm) : ""
        case .rating: String(max(0, min(5, t.rating)))
        }
    }

    /// Eingabe prüfen und in die kanonische Form bringen; nil = ungültig
    public func normalize(_ input: String) -> String? {
        if isText { return input.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\t", with: " ") }
        let s = input.trimmingCharacters(in: .whitespaces)
        switch self {
        case .trackNumber:
            if s.isEmpty { return "" }
            guard let n = Int(s), n >= 0, n < 10000 else { return nil }
            return n == 0 ? "" : String(n)
        case .rating:
            guard let n = Int(s.isEmpty ? "0" : s), (0...5).contains(n) else { return nil }
            return String(n)
        case .bpm:
            guard let v = Double(s.replacingOccurrences(of: ",", with: ".")), v >= 20, v <= 999 else { return nil }
            return String(format: "%.3f", v)
        case .releaseDate:
            if s.isEmpty { return "" }
            let p = s.split(whereSeparator: { "-/.".contains($0) }).map(String.init)
            guard (1...3).contains(p.count), p.allSatisfy({ Int($0) != nil }) else { return nil }
            let y = Int(p[0])!, m = p.count > 1 ? Int(p[1])! : 1, d = p.count > 2 ? Int(p[2])! : 1
            guard (1000...9999).contains(y), (1...12).contains(m), (1...31).contains(d) else { return nil }
            return String(format: "%04d-%02d-%02d", y, m, d)
        default: return s
        }
    }

    /// kanonischen Wert in den Track übernehmen (Suchtext baut der Aufrufer neu)
    public func set(_ v: String, on t: inout Track) {
        switch self {
        case .title: t.title = v
        case .artist: t.artist = v
        case .album: t.album = v
        case .mix: t.mix = v
        case .remixer: t.remixer = v
        case .producer: t.producer = v
        case .label: t.label = v
        case .catalogNo: t.catalogNo = v
        case .genre: t.genre = v
        case .comment: t.comment = v
        case .comment2: t.comment2 = v
        case .keyText: t.keyText = v
        case .trackNumber: t.trackNumber = Int(v) ?? 0
        case .releaseDate: t.releaseDate = Self.date(v)
        case .bpm: if let b = Double(v), b > 0 { t.bpm = b }
        case .rating: t.rating = max(0, min(5, Int(v) ?? 0))
        }
    }

    /// „JJJJ-MM-TT“ -> Datum (gregorianisch, wie der NML-Parser)
    static func date(_ s: String) -> Date? {
        let p = s.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return DateComponents(calendar: Calendar(identifier: .gregorian), year: p[0], month: p[1], day: p[2]).date
    }
}

/// Eigene Metadaten-Änderungen eines Tracks: Feld -> kanonischer Wert. Liegen über der Collection,
/// bis sie (optional) in die Collection-Datei geschrieben sind.
public struct MetadataEdit: Codable, Equatable, Sendable {
    public var fields: [String: String] = [:]
    public var modified = Date()

    public init(fields: [TrackField: String] = [:]) {
        self.fields = Dictionary(uniqueKeysWithValues: fields.map { ($0.key.rawValue, $0.value) })
    }

    public var values: [TrackField: String] {
        Dictionary(uniqueKeysWithValues: fields.compactMap { k, v in TrackField(rawValue: k).map { ($0, v) } })
    }

    /// Track mit den Änderungen, Suchtext neu
    public func apply(to t: Track) -> Track {
        var t = t
        for (f, v) in values where f.isEditable(t) { f.set(v, on: &t) }
        t.buildSearchText()
        return t
    }
}

/// Metadaten-Änderungen aller Tracks (Track-Schlüssel -> Felder), als JSON gespeichert. `url` nil = nur im Speicher (Selbsttest).
public final class MetadataStore: @unchecked Sendable {
    private var edits: [String: MetadataEdit] = [:]
    let url: URL?
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "minos741.metadata", qos: .utility)

    public init(url: URL?) {
        self.url = url
        if let url, let d = try? Data(contentsOf: url), let e = try? JSONDecoder().decode([String: MetadataEdit].self, from: d) { edits = e }
    }

    public var all: [String: MetadataEdit] { lock.lock(); defer { lock.unlock() }; return edits }
    public func edit(for key: String) -> MetadataEdit? { lock.lock(); defer { lock.unlock() }; return edits[key] }

    /// Felder setzen; Werte gleich dem Collection-Wert (`base`) fallen heraus, leere Einträge verschwinden
    public func merge(_ changes: [String: [TrackField: String]], base: [String: Track]) {
        lock.lock()
        for (key, fields) in changes {
            var e = edits[key] ?? MetadataEdit()
            for (f, v) in fields {
                if let b = base[key], f.value(of: b) == v { e.fields[f.rawValue] = nil } else { e.fields[f.rawValue] = v }
            }
            e.modified = Date()
            edits[key] = e.fields.isEmpty ? nil : e
        }
        lock.unlock()
        save()
    }

    /// nach dem Schreiben in die Collection: Felder entfernen, deren Wert inzwischen so in der Datei steht
    public func clear(written: [String: [TrackField: String]]) {
        lock.lock()
        for (key, fields) in written {
            guard var e = edits[key] else { continue }
            for (f, v) in fields where e.fields[f.rawValue] == v { e.fields[f.rawValue] = nil }
            edits[key] = e.fields.isEmpty ? nil : e
        }
        lock.unlock()
        save()
    }

    public func remove(_ keys: [String]) {
        lock.lock()
        for k in keys { edits[k] = nil }
        lock.unlock()
        save()
    }

    /// im Hintergrund schreiben (Reihenfolge bleibt über die serielle Queue erhalten)
    private func save() {
        guard let url else { return }
        let snapshot = all
        queue.async {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let d = try? JSONEncoder().encode(snapshot) { try? d.write(to: url, options: .atomic) }
        }
    }

    /// wartet, bis alle Schreibvorgänge durch sind (Tests, Beenden)
    public func flush() { queue.sync {} }
}
