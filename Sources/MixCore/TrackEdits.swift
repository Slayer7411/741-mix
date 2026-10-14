import Foundation

/// Schnitt eines Tracks, nicht destruktiv: gespielt wird nur zwischen Start und Ende (Sekunden, nil = Anfang / Ende
/// der Datei). Die Datei bleibt unverändert.
public struct TrackTrim: Codable, Equatable, Hashable, Sendable {
    public var start: Double?
    public var end: Double?

    /// kürzester Schnitt (s)
    public static let minLength = 1.0

    public init(start: Double? = nil, end: Double? = nil) { self.start = start; self.end = end }

    public var isEmpty: Bool { start == nil && end == nil }

    /// für eine Datei der Länge `duration`: Start ≤ 0 und Ende ≥ Dauer fallen weg (kein Schnitt dort);
    /// nil, wenn weniger als `minLength` übrig bliebe
    public func normalized(duration: Double) -> TrackTrim? {
        let eps = 0.001
        var t = TrackTrim()
        if let s = start, s.isFinite, s > eps { t.start = s }
        if let e = end, e.isFinite, duration <= 0 || e < duration - eps { t.end = max(0, e) }
        let lo = t.start ?? 0, hi = t.end ?? duration
        guard duration <= 0 || lo < duration, hi - lo >= Self.minLength - 1e-9 else { return nil }
        return t
    }

    /// gespielter Bereich in einer Datei der Länge `duration`
    public func range(duration: Double) -> ClosedRange<Double> {
        let lo = max(0, start ?? 0)
        return lo...max(lo, min(duration, end ?? duration))
    }
}

/// Eigene Änderungen an Tracks (Beatgrid, Hotcues, Schnitt) – dauerhaft; Hotcues und Grid gehen mit „in die Collection-Datei
/// schreiben“ in die Datei und verlassen dann edits.json (`clearWritten`).
/// Beim Laden eines Tracks werden sie über die Collection-Werte (und die eigene Analyse) gelegt: ein von Hand gesetztes
/// Grid gewinnt immer, nur RESET am Deck nimmt es weg.
public struct TrackEdit: Codable, Equatable, Sendable {
    public var bpm: Double?
    public var gridAnchorMs: Double?
    public var hotcues: [Cue]?
    /// Schnitt in Sekunden (fehlt in älteren Dateien)
    public var trimStart: Double?
    public var trimEnd: Double?
    /// Active Loops: Hotcues (0–7), deren Loop beim Erreichen von selbst einrastet (fehlt in älteren Dateien)
    public var activeLoops: [Int]?
    /// Herkunft des Grids: nil = von Hand, `.daw` = aus Warp-Markern übernommen (fehlt in älteren Dateien)
    public var gridSource: GridSource?
    public var modified = Date()
    /// Stand des Collection-Eintrags (`Track.entryStamp`), als Hotcues/Grid zuletzt von leer auf gesetzt gingen –
    /// Konfliktprüfung beim Neu-Laden (nil = unbekannt, ältere Dateien)
    public var stamp: String?

    public init(bpm: Double? = nil, gridAnchorMs: Double? = nil, hotcues: [Cue]? = nil, trim: TrackTrim = TrackTrim()) {
        self.bpm = bpm; self.gridAnchorMs = gridAnchorMs; self.hotcues = hotcues
        trimStart = trim.start; trimEnd = trim.end
    }

    /// von Hand gesetztes Grid (BPM und/oder Anker)
    public var hasGrid: Bool { bpm != nil || gridAnchorMs != nil }
    public var trim: TrackTrim {
        get { TrackTrim(start: trimStart, end: trimEnd) }
        set { trimStart = newValue.start; trimEnd = newValue.end }
    }
    public var isEmpty: Bool { !hasGrid && hotcues == nil && trim.isEmpty && (activeLoops ?? []).isEmpty }
    /// Teile, die auch in der Collection-Datei stehen können (Hotcues, Grid)
    public var hasNMLPart: Bool { hotcues != nil || hasGrid }
    /// ohne Hotcues und Grid (bleibt in edits.json: Schnitt, Active Loops)
    public var withoutNMLPart: TrackEdit {
        var e = self
        e.hotcues = nil; e.bpm = nil; e.gridAnchorMs = nil; e.stamp = nil
        return e
    }

    /// gleiche Änderung (ohne Zeitstempel)
    public func same(as o: TrackEdit?) -> Bool {
        guard let o else { return isEmpty }
        return bpm == o.bpm && gridAnchorMs == o.gridAnchorMs && hotcues == o.hotcues && trimStart == o.trimStart && trimEnd == o.trimEnd
            && (activeLoops ?? []) == (o.activeLoops ?? []) && gridSource == o.gridSource
    }

    /// Track mit den Änderungen (Grid, Hotcues; den Schnitt übernimmt das Deck)
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

/// Eigene Änderungen aller Tracks (Track-Schlüssel -> Änderung) in `edits.json`. Schreiben gesammelt (0,5 s nach der
/// letzten Änderung) auf einer eigenen Queue, nie auf dem Haupt- oder Audio-Thread. `writes` false = nur lesen
/// (Selbsttest, Messung: Christians Datei bleibt unangetastet).
public final class TrackEditStore: @unchecked Sendable {
    private var edits: [String: TrackEdit] = [:]
    let url: URL?
    let writes: Bool
    private let lock = NSLock()
    private var savePending = false
    private let queue = DispatchQueue(label: "minos741.edits", qos: .utility)
    /// Sammelzeit vor dem Schreiben
    var saveDelay: Double = 0.5

    public init(url: URL?, writes: Bool = true) {
        self.url = url
        self.writes = writes
        if let url, let d = try? Data(contentsOf: url), let e = try? JSONDecoder().decode([String: TrackEdit].self, from: d) { edits = e }
    }

    public var all: [String: TrackEdit] { lock.lock(); defer { lock.unlock() }; return edits }
    public func edit(for key: String) -> TrackEdit? { lock.lock(); defer { lock.unlock() }; return edits[key] }

    /// setzen (nil oder leer = entfernen); geschrieben wird gesammelt im Hintergrund
    public func set(_ e: TrackEdit?, for key: String) {
        lock.lock()
        edits[key] = e.flatMap { $0.isEmpty ? nil : $0 }
        let schedule = !savePending && writes && url != nil
        if schedule { savePending = true }
        lock.unlock()
        guard schedule else { return }
        queue.asyncAfter(deadline: .now() + saveDelay) { [self] in writePending() }
    }

    /// mehrere Einträge auf einmal ändern (`f` unter der Sperre; nil = entfernen), Schreiben gesammelt
    private func modify(_ f: (inout [String: TrackEdit]) -> Void) {
        lock.lock()
        f(&edits)
        for (k, e) in edits where e.isEmpty { edits[k] = nil }
        let schedule = !savePending && writes && url != nil
        if schedule { savePending = true }
        lock.unlock()
        guard schedule else { return }
        queue.asyncAfter(deadline: .now() + saveDelay) { [self] in writePending() }
    }

    /// nach dem Schreiben in die Collection-Datei: Hotcues und Grid, die so in der Datei stehen, verlassen edits.json
    /// (Schnitt und Active Loops bleiben). `keepGrid`: Grid bleibt trotzdem (eigene Analyse mit Grid – das von Hand
    /// gesetzte Grid muss weiter darüber liegen)
    public func clearWritten(_ written: [String: TrackEdit], keepGrid: Set<String> = []) {
        modify { edits in
            for (k, w) in written {
                guard var e = edits[k] else { continue }
                if let h = w.hotcues, e.hotcues == h { e.hotcues = nil }
                if w.hasGrid, !keepGrid.contains(k), e.bpm == w.bpm, e.gridAnchorMs == w.gridAnchorMs { e.bpm = nil; e.gridAnchorMs = nil }
                if !e.hasNMLPart { e.stamp = nil }
                edits[k] = e
            }
        }
    }

    /// Konflikt beim Neu-Laden: Einträge mit Hotcues/Grid, deren Collection-Eintrag sich seit der eigenen Änderung
    /// geändert hat (`current`: Schlüssel -> `Track.entryStamp`). Die Datei gewinnt: Hotcues und Grid fallen hier weg,
    /// zurück kommen die vollständigen alten Einträge (für die Konflikt-Sicherung)
    public func takeConflicts(current: [String: String]) -> [String: TrackEdit] {
        var out: [String: TrackEdit] = [:]
        lock.lock()
        let found = edits.filter { k, e in
            guard e.hasNMLPart, let s = e.stamp, !s.isEmpty, let c = current[k], !c.isEmpty else { return false }
            return s != c
        }
        lock.unlock()
        guard !found.isEmpty else { return [:] }
        modify { edits in
            for (k, e) in found { out[k] = e; edits[k] = e.withoutNMLPart }
        }
        return out
    }

    /// Datei umbenannt (anderer Track-Schlüssel): Änderung wandert mit
    public func rename(from old: String, to new: String) {
        guard old != new else { return }
        modify { edits in
            guard let e = edits.removeValue(forKey: old) else { return }
            edits[new] = e
        }
    }

    /// auf `queue`: letzten Stand schreiben, falls noch offen
    private func writePending() {
        lock.lock()
        guard savePending, let url else { lock.unlock(); return }
        savePending = false
        let snapshot = edits
        lock.unlock()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(snapshot) { try? d.write(to: url, options: .atomic) }
    }

    /// offene Änderungen sofort schreiben und warten (Beenden, Tests)
    public func flush() { queue.sync { writePending() } }
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
    /// Stand des Collection-Eintrags (`Track.entryStamp`) bei der ersten noch offenen Änderung (nil = unbekannt)
    public var stamp: String?

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

    /// Felder setzen; Werte gleich dem Collection-Wert (`base`) fallen heraus, leere Einträge verschwinden.
    /// `stamps`: Stand des Collection-Eintrags, gilt ab der ersten offenen Änderung (Konfliktprüfung)
    public func merge(_ changes: [String: [TrackField: String]], base: [String: Track], stamps: [String: String] = [:]) {
        lock.lock()
        for (key, fields) in changes {
            var e = edits[key] ?? MetadataEdit()
            if e.fields.isEmpty || e.stamp == nil, let s = stamps[key], !s.isEmpty { e.stamp = s }
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

    /// Konflikt beim Neu-Laden: Einträge, deren Collection-Eintrag sich seit der eigenen Änderung geändert hat
    /// (`current`: Schlüssel -> `Track.entryStamp`). Die Datei gewinnt: die Einträge verlassen den Speicher und kommen
    /// zurück (für die Konflikt-Sicherung)
    public func takeConflicts(current: [String: String]) -> [String: MetadataEdit] {
        lock.lock()
        let found = edits.filter { k, e in
            guard let s = e.stamp, !s.isEmpty, let c = current[k], !c.isEmpty else { return false }
            return s != c
        }
        for k in found.keys { edits[k] = nil }
        lock.unlock()
        if !found.isEmpty { save() }
        return found
    }

    /// Datei umbenannt (anderer Track-Schlüssel): Änderung wandert mit
    public func rename(from old: String, to new: String) {
        guard old != new else { return }
        lock.lock()
        let e = edits.removeValue(forKey: old)
        if let e { edits[new] = e }
        lock.unlock()
        if e != nil { save() }
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
