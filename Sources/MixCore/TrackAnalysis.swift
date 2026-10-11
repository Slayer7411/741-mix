import Foundation

/// Ergebnis der eigenen Analyse eines Tracks (Tempo + Grid-Anker, Tonart, Lautheit). Nur gesetzte Felder liegen über
/// den Collection-Werten. `Analysieren` füllt fehlende Werte, `Neu analysieren` alle (gesperrte Tracks: nur fehlende).
public struct TrackAnalysis: Codable, Equatable, Sendable {
    /// was gerechnet / übernommen wird. Tempo und Grid gehören zusammen (der Anker passt nur zum eigenen Tempo)
    public struct Fields: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let tempo = Fields(rawValue: 1)
        public static let key = Fields(rawValue: 2)
        public static let loudness = Fields(rawValue: 4)
        public static let all: Fields = [.tempo, .key, .loudness]
    }

    public var bpm: Double?
    public var gridAnchorMs: Double?
    /// 0–11 Dur (C…B), 12–23 Moll (Cm…Bm), wie MUSICAL_KEY in der Collection
    public var musicalKey: Int?
    /// Lautheit relativ zur Referenz der Collection (positiv = lauter); Auto-Gain = −perceivedDb
    public var perceivedDb: Double?
    /// Abstand der Spitze zu 0 dBFS wie PEAK_DB der Collection (positiv = darunter)
    public var peakDb: Double?
    public var analyzed = Date()
    /// Version des Verfahrens
    public var version = TrackAnalysis.currentVersion
    /// schon in die Collection-Datei geschrieben
    public var written = false

    /// 2: PEAK_DB als Abstand zu 0 dBFS (1: Spitze in dBFS, Vorzeichen umgekehrt)
    public static let currentVersion = 2

    public init(bpm: Double? = nil, gridAnchorMs: Double? = nil, musicalKey: Int? = nil, perceivedDb: Double? = nil, peakDb: Double? = nil) {
        self.bpm = bpm; self.gridAnchorMs = gridAnchorMs; self.musicalKey = musicalKey; self.perceivedDb = perceivedDb; self.peakDb = peakDb
    }

    public var isEmpty: Bool { bpm == nil && gridAnchorMs == nil && musicalKey == nil && perceivedDb == nil && peakDb == nil }

    public var fields: Fields {
        var f: Fields = []
        if bpm != nil || gridAnchorMs != nil { f.insert(.tempo) }
        if musicalKey != nil { f.insert(.key) }
        if perceivedDb != nil { f.insert(.loudness) }
        return f
    }

    /// was dem Track fehlt (Collection-Werte): Tempo ohne BPM oder ohne Grid, keine Tonart, keine Lautheit
    public static func missing(in t: Track) -> Fields {
        var f: Fields = []
        if !(t.bpm.isFinite && t.bpm > 0) || t.gridAnchorMs == nil { f.insert(.tempo) }
        if t.musicalKey < 0 { f.insert(.key) }
        if t.perceivedDb == nil { f.insert(.loudness) }
        return f
    }

    /// nur die genannten Felder
    public func restricted(to f: Fields) -> TrackAnalysis {
        var a = self
        if !f.contains(.tempo) { a.bpm = nil; a.gridAnchorMs = nil }
        if !f.contains(.key) { a.musicalKey = nil }
        if !f.contains(.loudness) { a.perceivedDb = nil; a.peakDb = nil }
        return a
    }

    /// gesetzte Felder von `other` übernehmen (Analysieren: fehlende Werte zu einem alten Eintrag)
    public func merged(with other: TrackAnalysis) -> TrackAnalysis {
        var a = self
        if other.bpm != nil || other.gridAnchorMs != nil { a.bpm = other.bpm; a.gridAnchorMs = other.gridAnchorMs }
        if let k = other.musicalKey { a.musicalKey = k }
        if other.perceivedDb != nil { a.perceivedDb = other.perceivedDb; a.peakDb = other.peakDb }
        a.analyzed = other.analyzed
        a.version = other.version
        a.written = false
        return a
    }

    /// Track mit den analysierten Werten (Suchtext neu, Tonart-Text wie die Collection)
    public func apply(to t: Track) -> Track {
        guard !isEmpty else { return t }
        var t = t
        if let b = bpm, b > 0, b.isFinite { t.bpm = b }
        if let a = gridAnchorMs, a.isFinite {
            if let i = t.cues.firstIndex(where: { $0.kind == .grid }) { t.cues[i].startMs = a }
            else { t.cues.append(Cue(name: "AutoGrid", kind: .grid, startMs: a, lengthMs: 0, hotcue: -1)) }
        }
        if let k = musicalKey, (0...23).contains(k) {
            t.musicalKey = k
            t.keyText = Track.openKey(code: k)
        }
        if let p = perceivedDb, p.isFinite { t.perceivedDb = p }
        if let p = peakDb, p.isFinite { t.peakDb = p }
        t.ownAnalysis = true
        t.buildSearchText()
        return t
    }
}

/// Eigene Analysen aller Tracks (Track-Schlüssel -> Werte), als JSON gespeichert. `url` nil = nur im Speicher (Selbsttest).
public final class AnalysisStore: @unchecked Sendable {
    private var entries: [String: TrackAnalysis] = [:]
    let url: URL?
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "minos741.analysis", qos: .utility)
    /// nach jeder Änderung mit dem Track-Schlüssel – beliebiger Thread
    public var onChange: (@Sendable (String) -> Void)?

    public init(url: URL?) {
        self.url = url
        if let url, let d = try? Data(contentsOf: url), let e = try? JSONDecoder().decode([String: TrackAnalysis].self, from: d) {
            entries = e.mapValues(Self.migrated)
        }
    }

    /// alte Einträge: Vorzeichen der Spitze umdrehen
    static func migrated(_ a: TrackAnalysis) -> TrackAnalysis {
        guard a.version < 2 else { return a }
        var a = a
        a.peakDb = a.peakDb.map { -$0 }
        a.version = 2
        return a
    }

    public var all: [String: TrackAnalysis] { lock.lock(); defer { lock.unlock() }; return entries }
    public var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }
    public func entry(for key: String) -> TrackAnalysis? { lock.lock(); defer { lock.unlock() }; return entries[key] }

    /// Ergebnis ablegen: `replace` ersetzt den Eintrag ganz (Neu analysieren), sonst kommen die Felder dazu
    public func put(_ a: TrackAnalysis, for key: String, replace: Bool) {
        lock.lock()
        let merged = replace ? a : (entries[key]?.merged(with: a) ?? a)
        entries[key] = merged.isEmpty ? nil : merged
        lock.unlock()
        save()
        onChange?(key)
    }

    public func remove(_ keys: [String]) {
        lock.lock()
        for k in keys { entries[k] = nil }
        lock.unlock()
        save()
        for k in keys { onChange?(k) }
    }

    /// nach dem Schreiben in die Collection-Datei
    public func markWritten(_ keys: some Sequence<String>) {
        lock.lock()
        for k in keys { entries[k]?.written = true }
        lock.unlock()
        save()
    }

    /// noch nicht in der Collection-Datei
    public var unwritten: [String: TrackAnalysis] { all.filter { !$0.value.written } }

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
