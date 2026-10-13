import Foundation

/// Markierter Bereich eines Tracks in Sekunden (start < end): Grundlage für Schneiden, Schnitt IN/OUT und Loop
public struct TrackRange: Equatable, Hashable, Sendable {
    public var start: Double
    public var end: Double

    public init(_ a: Double, _ b: Double) { start = min(a, b); end = max(a, b) }

    public var length: Double { end - start }

    /// Zeit aufs Raster (nächster Beat), `free` oder ohne Grid unverändert; begrenzt auf die Datei
    public static func snap(_ t: Double, grid: BeatGrid?, free: Bool, duration: Double) -> Double {
        var v = t
        if !free, let g = grid, g.bpm > 0, g.bpm.isFinite { v = g.nearestBeat(to: t) }
        return duration > 0 ? min(max(0, v), duration) : max(0, v)
    }

    /// „Takt.Beat“ einer Zeit (auf dem Beat: dieser Beat, nicht der davor)
    public static func barBeat(_ t: Double, grid: BeatGrid) -> String {
        let p = grid.barBeat(at: t + grid.beat * 1e-4)
        return "\(p.bar).\(p.beat)"
    }

    /// Länge in Beats als Text: ganze Zahl oder zwei Stellen
    public func beatsText(grid: BeatGrid) -> String {
        let b = length / grid.beat
        return abs(b - b.rounded()) < 0.01 ? String(Int(b.rounded())) : String(format: "%.2f", b)
    }
}

/// Echter Schnitt: neue Datei ohne den Bereich (`remove`) oder nur mit ihm (`keep`). Hier nur die Rechnung für Grid,
/// Cues, Metadaten und Dateinamen – das Audio setzt MixMedia zusammen.
public enum TrackCut {
    public enum Mode: String, Sendable, CaseIterable { case remove, keep }

    static let eps = 1e-6

    /// Länge der neuen Datei
    public static func duration(_ d: Double, mode: Mode, range r: TrackRange) -> Double {
        let lo = max(0, r.start), hi = min(d, r.end)
        switch mode {
        case .remove: return max(0, d - max(0, hi - lo))
        case .keep: return max(0, hi - lo)
        }
    }

    /// Grid der neuen Datei: beim Entfernen bleibt ein Anker vor dem Bereich, sonst rückt er um die entfernte Länge
    /// nach vorn; beim Kürzen zählt er ab dem neuen Anfang. Liegt er davor, um ganze Takte dahinter (Taktlage bleibt)
    public static func grid(_ g: BeatGrid, mode: Mode, range r: TrackRange) -> BeatGrid {
        var a: Double
        switch mode {
        case .remove:
            if g.anchor < r.start - eps { return g }
            a = g.anchor - r.length
        case .keep:
            a = g.anchor - r.start
        }
        let bar = g.beat * BeatGrid.beatsPerBar
        if a < -eps, bar > 0 { a += ((-a - eps) / bar).rounded(.up) * bar }
        return BeatGrid(anchor: max(0, a), bpm: g.bpm)
    }

    /// Zeit eines Cues (s, Loop mit Länge) in der neuen Datei; nil = liegt im entfernten Teil (Loops: ganz außerhalb)
    public static func map(_ t: Double, length: Double = 0, mode: Mode, range r: TrackRange) -> Double? {
        let end = t + max(0, length)
        switch mode {
        case .remove:
            if t < r.start - eps { return end <= r.start + eps ? t : nil }
            if t >= r.end - eps { return t - r.length }
            return nil
        case .keep:
            guard t >= r.start - eps, t < r.end - eps, end <= r.end + eps else { return nil }
            return max(0, t - r.start)
        }
    }

    /// Cues (Hotcues, Memory-Cues, Loops) übernehmen und verschieben, im entfernten Teil verwerfen; Grid-Marker
    /// fallen weg (das neue Grid setzt `track`)
    public static func cues(_ cues: [Cue], mode: Mode, range r: TrackRange) -> [Cue] {
        cues.compactMap { c in
            guard c.kind != .grid,
                  let t = map(c.startMs / 1000, length: c.kind == .loop ? c.lengthMs / 1000 : 0, mode: mode, range: r) else { return nil }
            var n = c
            n.startMs = t * 1000
            return n
        }
    }

    /// Titel der neuen Datei: „ [cut]“ angehängt, ein schon geschnittener bleibt so
    public static func title(_ t: String) -> String {
        t.hasSuffix(" [cut]") ? t : (t.isEmpty ? "[cut]" : t + " [cut]")
    }

    /// Dateiname „<Name> [cut].m4a“, belegt -> „ [cut 2]“ usw.; ein Name, der schon auf [cut] / [cut n] endet,
    /// bekommt keine zweite Klammer
    public static func fileName(_ original: String, taken: (String) -> Bool) -> String {
        var base = (original as NSString).deletingPathExtension
        if let r = base.range(of: #" \[cut( \d+)?\]$"#, options: .regularExpression) { base.removeSubrange(r) }
        for n in 1...9999 {
            let name = base + (n == 1 ? " [cut]" : " [cut \(n)]") + ".m4a"
            if !taken(name) { return name }
        }
        return base + " [cut \(UUID().uuidString.prefix(8))].m4a"
    }

    /// Track der neuen Datei: Metadaten des Originals (Titel mit [cut]), Grid und Cues verschoben, neue Länge.
    /// `grid` und `hotcues` vom Deck (eigene Änderungen gelten), Memory-Cues aus dem Track
    public static func track(from t: Track, key: String, path: String, grid: BeatGrid?, hotcues: [Cue], mode: Mode,
                             range r: TrackRange, duration: Double, now: Date = Date()) -> Track {
        var n = t
        n.key = key
        n.path = path
        n.title = title(t.title)
        n.duration = duration
        n.importDate = now
        n.playCount = 0
        n.lastPlayed = nil
        n.loose = false
        n.fileMissing = false
        n.ownAnalysis = false
        let memory = t.cues.filter { $0.hotcue < 0 && $0.kind != .grid }
        var cues = Self.cues(memory + hotcues, mode: mode, range: r)
        if let g = grid, g.bpm > 0 {
            let ng = Self.grid(g, mode: mode, range: r)
            n.bpm = ng.bpm
            cues.insert(Cue(name: "Grid", kind: .grid, startMs: ng.anchor * 1000, lengthMs: 0, hotcue: -1), at: 0)
            // Grid-Marker auf einem Hotcue-Platz (oft Hotcue 1): bleibt dort, auf dem neuen Anker
            for var c in hotcues where c.kind == .grid {
                c.startMs = ng.anchor * 1000
                cues.append(c)
            }
        }
        n.cues = cues
        n.buildSearchText()
        return n
    }
}

/// Eintrag in `cuts.json`: geschnittene Datei (nicht in der Collection) mit ihren Metadaten
public struct CutEntry: Codable, Equatable, Sendable {
    public var key: String
    public var path: String
    /// Track, aus dem geschnitten wurde (Schlüssel, Pfad – Cover ohne eigene Tags)
    public var source: String
    public var sourcePath: String?
    public var created: Date
    /// Felder wie im Bearbeiten-Fenster (kanonischer Text)
    public var fields: [String: String]
    public var musicalKey: Int
    /// Tempo ungerundet (das Feld BPM hat nur drei Stellen)
    public var bpm: Double
    public var cues: [Cue]
    public var duration: Double
    public var color: Int
    public var fileSizeKB: Int
    public var bitrate: Int
    public var peakDb: Double?
    public var perceivedDb: Double?

    public init(track t: Track, source: String, sourcePath: String? = nil, created: Date = Date()) {
        key = t.key; path = t.path; self.source = source; self.sourcePath = sourcePath; self.created = created
        fields = Dictionary(uniqueKeysWithValues: TrackField.allCases.map { ($0.rawValue, $0.value(of: t)) })
        musicalKey = t.musicalKey; bpm = t.bpm; cues = t.cues; duration = t.duration; color = t.color
        fileSizeKB = t.fileSizeKB; bitrate = t.bitrate; peakDb = t.peakDb; perceivedDb = t.perceivedDb
    }

    public var track: Track {
        var t = Track(key: key, path: path)
        for (k, v) in fields { if let f = TrackField(rawValue: k) { f.set(v, on: &t) } }
        t.musicalKey = musicalKey; t.bpm = bpm; t.cues = cues; t.duration = duration; t.color = color
        t.fileSizeKB = fileSizeKB; t.bitrate = bitrate; t.peakDb = peakDb; t.perceivedDb = perceivedDb
        t.importDate = created
        t.buildSearchText()
        return t
    }
}
