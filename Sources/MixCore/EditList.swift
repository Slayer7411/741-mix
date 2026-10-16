import Foundation

/// Stück der Schnittliste: Bereich der Quelle in Sekunden; stumm = Stille gleicher Länge
public struct EditSegment: Codable, Equatable, Hashable, Sendable {
    public var start: Double
    public var end: Double
    public var muted: Bool

    public init(_ start: Double, _ end: Double, muted: Bool = false) {
        self.start = start; self.end = end; self.muted = muted
    }

    public var length: Double { max(0, end - start) }
}

/// Schnittliste (EDL) eines Tracks, nicht destruktiv: Stücke der Quelle in Ausgabe-Reihenfolge. Alle Bearbeitungen
/// rechnen in Ausgabe-Zeit (was das Deck mit der Liste spielt). Eine Marke teilt ein Stück, ohne das Audio zu ändern
public struct EditList: Codable, Equatable, Sendable {
    /// Länge der Quelle (s)
    public var source: Double
    public var segments: [EditSegment]

    static let eps = 1e-6
    /// kürzestes Stück (s)
    public static let minSegment = 0.01

    public init(duration: Double) {
        source = max(0, duration)
        segments = source > 0 ? [EditSegment(0, source)] : []
    }

    public init(source: Double, segments: [EditSegment]) {
        self.source = max(0, source)
        self.segments = segments
    }

    /// Länge der Ausgabe
    public var duration: Double { segments.reduce(0) { $0 + $1.length } }

    /// Ausgabe-Anfang je Stück
    public var starts: [Double] {
        var s: [Double] = [], at = 0.0
        for g in segments { s.append(at); at += g.length }
        return s
    }

    /// Nähte zwischen den Stücken (Ausgabe-Zeit)
    public var joints: [Double] { Array(starts.dropFirst()) }

    /// Naht k (zwischen Stück k und k+1) schneidet: Quelle springt oder stumm wechselt. Sonst nur eine Marke
    public func isCut(joint k: Int) -> Bool {
        guard segments.indices.contains(k + 1) else { return false }
        let a = segments[k], b = segments[k + 1]
        return abs(a.end - b.start) > Self.eps || a.muted != b.muted
    }

    /// Stücke wie gehört: Nachbarn ohne Schnitt zusammengelegt (Marken zählen nicht)
    public var audible: [EditSegment] {
        var out: [EditSegment] = []
        for g in segments where g.length > Self.eps {
            if var last = out.last, abs(last.end - g.start) <= Self.eps, last.muted == g.muted {
                last.end = g.end
                out[out.count - 1] = last
            } else {
                out.append(g)
            }
        }
        return out
    }

    /// spielt die Quelle unverändert
    public var isPlain: Bool {
        let a = audible
        guard let f = a.first else { return source <= 0 }
        return a.count == 1 && !f.muted && f.start <= Self.eps && f.end >= source - Self.eps
    }

    /// gleiches Audio (Marken egal)
    public func sameAudio(as o: EditList) -> Bool { audible == o.audible }

    /// Stück an Ausgabe-Zeit t (Ende gehört zum letzten Stück)
    public func segment(at t: Double) -> Int? {
        guard !segments.isEmpty else { return nil }
        let s = starts
        for k in segments.indices.reversed() where t >= s[k] - Self.eps { return t <= s[k] + segments[k].length + Self.eps ? k : nil }
        return nil
    }

    /// Ausgabe-Zeit -> Quelle
    public func sourceTime(_ t: Double) -> Double? {
        guard let k = segment(at: t) else { return nil }
        let g = segments[k]
        return min(g.end, max(g.start, g.start + t - starts[k]))
    }

    /// Quelle -> Ausgabe-Zeit (erstes Vorkommen), nil = nicht in der Liste
    public func outputTime(_ s: Double) -> Double? {
        let st = starts
        for (k, g) in segments.enumerated() where s >= g.start - Self.eps && s < g.end - Self.eps { return st[k] + s - g.start }
        if let k = segments.indices.first(where: { abs(segments[$0].end - s) <= Self.eps }) { return st[k] + segments[k].length }
        return nil
    }

    /// Ausgabe-Bereich eines Stücks
    public func range(of k: Int) -> TrackRange? {
        guard segments.indices.contains(k) else { return nil }
        let s = starts[k]
        return TrackRange(s, s + segments[k].length)
    }

    // MARK: Bearbeiten (Ausgabe-Zeit)

    /// Marke bei t: Stück teilen (Audio unverändert). false = liegt auf einer Naht oder außerhalb
    @discardableResult
    public mutating func split(at t: Double) -> Bool {
        let st = starts
        for (k, g) in segments.enumerated() {
            let a = st[k], b = a + g.length
            guard t > a + Self.minSegment - Self.eps, t < b - Self.minSegment + Self.eps else { continue }
            let s = g.start + (t - a)
            segments[k].end = s
            segments.insert(EditSegment(s, g.end, muted: g.muted), at: k + 1)
            return true
        }
        return false
    }

    /// Marke k (Naht zwischen k und k+1) entfernen: nur ohne Schnitt (sonst änderte sich das Audio)
    @discardableResult
    public mutating func removeMark(_ k: Int) -> Bool {
        guard segments.indices.contains(k + 1), !isCut(joint: k) else { return false }
        segments[k].end = segments[k + 1].end
        segments.remove(at: k + 1)
        return true
    }

    /// Naht k auf Ausgabe-Zeit t verschieben (rollen): das linke Stück endet später/früher, das rechte beginnt
    /// entsprechend, die Länge bleibt. Begrenzt auf die Quelle und `minSegment`
    @discardableResult
    public mutating func moveJoint(_ k: Int, to t: Double) -> Bool {
        guard segments.indices.contains(k + 1) else { return false }
        let at = starts[k + 1]
        var dt = t - at
        let a = segments[k], b = segments[k + 1]
        dt = max(dt, Self.minSegment - a.length, -b.start)
        dt = min(dt, b.length - Self.minSegment, source - a.end)
        guard abs(dt) > Self.eps else { return false }
        segments[k].end += dt
        segments[k + 1].start += dt
        return true
    }

    /// an a und b teilen; Stücke dazwischen
    mutating func isolate(_ r: TrackRange) -> Range<Int>? {
        let a = max(0, r.start), b = min(duration, r.end)
        guard b - a >= Self.minSegment - Self.eps else { return nil }
        split(at: a)
        split(at: b)
        let st = starts
        let lo = segments.indices.first { st[$0] >= a - Self.minSegment / 2 } ?? segments.count
        let hi = segments.indices.last { st[$0] + segments[$0].length <= b + Self.minSegment / 2 }.map { $0 + 1 } ?? lo
        return lo < hi ? lo..<hi : nil
    }

    /// Bereich entfernen; nil = nichts entfernt oder weniger als `keep` übrig
    @discardableResult
    public mutating func remove(_ r: TrackRange, keep minimum: Double = TrackTrim.minLength) -> Bool {
        var n = self
        guard let i = n.isolate(r) else { return false }
        n.segments.removeSubrange(i)
        guard n.duration >= minimum - Self.eps else { return false }
        self = n
        return true
    }

    /// nur den Bereich behalten
    @discardableResult
    public mutating func keep(_ r: TrackRange, minimum: Double = TrackTrim.minLength) -> Bool {
        var n = self
        guard let i = n.isolate(r) else { return false }
        n.segments = Array(n.segments[i])
        guard n.duration >= minimum - Self.eps else { return false }
        self = n
        return true
    }

    /// Bereich noch einmal hinter sich selbst; liefert den Bereich der Kopie
    @discardableResult
    public mutating func duplicate(_ r: TrackRange) -> TrackRange? {
        var n = self
        guard let i = n.isolate(r) else { return nil }
        let block = Array(n.segments[i])
        let start = n.starts[i.upperBound - 1] + n.segments[i.upperBound - 1].length
        n.segments.insert(contentsOf: block, at: i.upperBound)
        self = n
        return TrackRange(start, start + block.reduce(0) { $0 + $1.length })
    }

    /// Bereich stumm (gleiche Länge); ist schon alles darin stumm, wieder hörbar
    @discardableResult
    public mutating func mute(_ r: TrackRange) -> Bool {
        var n = self
        guard let i = n.isolate(r) else { return false }
        let on = !n.segments[i].allSatisfy(\.muted)
        for k in i { n.segments[k].muted = on }
        self = n
        return true
    }

    /// Stücke im Bereich als Block am Nachbarstück vorbei verschieben (`by` -1 = nach links, +1 = nach rechts);
    /// liefert den neuen Bereich des Blocks
    @discardableResult
    public mutating func move(_ r: TrackRange, by dir: Int) -> TrackRange? {
        var n = self
        guard dir != 0, let i = n.isolate(r) else { return nil }
        let st = n.starts
        let a = st[i.lowerBound], b = st[i.upperBound - 1] + n.segments[i.upperBound - 1].length
        if dir < 0 {
            guard i.lowerBound > 0 else { return nil }
            let nb = n.segments.remove(at: i.lowerBound - 1)
            n.segments.insert(nb, at: i.upperBound - 1)
            self = n
            return TrackRange(a - nb.length, b - nb.length)
        }
        guard i.upperBound < n.segments.count else { return nil }
        let nb = n.segments.remove(at: i.upperBound)
        n.segments.insert(nb, at: i.lowerBound)
        self = n
        return TrackRange(a + nb.length, b + nb.length)
    }

    // MARK: Audio, Grid, Cues

    /// Stücke in Frames bei `rate` (Ränder gerundet, Längen sample-genau aufaddiert) und stumm je Stück; leere fallen weg
    public func frames(rate: Double, sourceFrames n: Int) -> (pieces: [Range<Int>], muted: [Bool]) {
        var p: [Range<Int>] = [], m: [Bool] = []
        for g in audible {
            let a = min(n, max(0, Int((g.start * rate).rounded()))), b = min(n, max(0, Int((g.end * rate).rounded())))
            guard b > a else { continue }
            p.append(a..<b)
            m.append(g.muted)
        }
        return (p, m)
    }

    /// Grid der Ausgabe: Taktlage ab dem ersten Stück wie in der Quelle (Anker auf ganze Takte nach vorn).
    /// Schnitte auf Beats halten das Raster dahinter; freie Schnitte verschieben es
    public func grid(_ g: BeatGrid) -> BeatGrid {
        guard let f = segments.first else { return g }
        return TrackCut.grid(g, mode: .keep, range: TrackRange(f.start, f.start + f.length))
    }

    /// Cues (Hotcues, Memory-Cues, Loops) aufs erste Vorkommen; Loops nur, wenn sie ganz in einem Stück liegen.
    /// Grid-Marker fallen weg (das Grid rechnet `grid`)
    public func cues(_ cues: [Cue]) -> [Cue] {
        let st = starts
        return cues.compactMap { c in
            guard c.kind != .grid else { return nil }
            let s = c.startMs / 1000, len = c.kind == .loop ? max(0, c.lengthMs / 1000) : 0
            guard let k = segments.indices.first(where: { segments[$0].start - Self.eps <= s && s < segments[$0].end - Self.eps
                && s + len <= segments[$0].end + Self.eps }) else { return nil }
            var n = c
            n.startMs = (st[k] + s - segments[k].start) * 1000
            return n
        }
    }

    /// passt zur Quelle (gespeicherte Liste, Datei inzwischen anders lang -> verwerfen)
    public func fits(duration d: Double) -> Bool { abs(d - source) < 0.05 && segments.allSatisfy { $0.start >= -Self.eps && $0.end <= d + 0.05 } }
}

/// Raster beim Markieren im EDIT-Modus (Beats; Takt = 4)
public enum EditSnap: Int, CaseIterable, Codable, Sendable {
    case beat = 1, bar = 4, bars2 = 8, bars4 = 16, bars8 = 32

    public var beats: Double { Double(rawValue) }

    public var label: String {
        switch self {
        case .beat: "1 BEAT"
        case .bar: "1 BAR"
        case .bars2: "2 BARS"
        case .bars4: "4 BARS"
        case .bars8: "8 BARS"
        }
    }

    public var next: EditSnap { Self.allCases[(Self.allCases.firstIndex(of: self)! + 1) % Self.allCases.count] }
    public var previous: EditSnap {
        let i = Self.allCases.firstIndex(of: self)!
        return Self.allCases[(i + Self.allCases.count - 1) % Self.allCases.count]
    }
}

extension TrackRange {
    /// Zeit aufs Raster `step` Beats ab dem Grid-Anker (nächster Rasterpunkt); `free` oder ohne Grid unverändert
    public static func snap(_ t: Double, grid: BeatGrid?, step: Double, free: Bool, duration: Double) -> Double {
        var v = t
        if !free, let g = grid, g.bpm > 0, g.bpm.isFinite, step > 0 {
            v = g.time(ofBeat: (g.beatPosition(at: t) / step).rounded() * step)
        }
        return duration > 0 ? min(max(0, v), duration) : max(0, v)
    }
}

/// Tool-Loop: genau n Beats als eigene, nahtlos loopbare Datei
public enum ToolLoop {
    public static let sizes = [2, 4, 8, 16]
    public static let tag = "tool-loop"

    /// Bereich: ab dem aktiven Loop, sonst ab der Position auf den nächsten Taktanfang (vor dem Anker: erster Takt);
    /// nil = passt nicht mehr in den Track
    public static func range(beats: Int, grid g: BeatGrid, position: Double, loopStart: Double?, duration: Double) -> TrackRange? {
        guard beats > 0, g.bpm > 0, g.bpm.isFinite else { return nil }
        let bar = BeatGrid.beatsPerBar
        var start: Double
        if let l = loopStart {
            start = l
        } else {
            var n = (g.beatPosition(at: position) / bar).rounded() * bar
            if g.time(ofBeat: n) < -EditList.eps { n += ((-g.time(ofBeat: n)) / (bar * g.beat)).rounded(.up) * bar }
            start = g.time(ofBeat: n)
        }
        start = max(0, start)
        let end = start + Double(beats) * g.beat
        guard end <= duration + 1e-3 else { return nil }
        return TrackRange(start, min(end, duration))
    }

    /// Länge in Frames: beats · 60 / bpm · rate
    public static func frames(beats: Int, bpm: Double, rate: Double) -> Int {
        Int((Double(beats) * 60 / bpm * rate).rounded())
    }

    public static func label(_ beats: Int) -> String { "[tool-loop \(beats)]" }

    public static func title(_ t: String, beats: Int) -> String {
        var base = t
        if let r = base.range(of: #" \[(cut|tool-loop \d+)\]$"#, options: .regularExpression) { base.removeSubrange(r) }
        return base.isEmpty ? label(beats) : base + " " + label(beats)
    }

    /// „<Name> [tool-loop 8].m4a“, belegt -> „[tool-loop 8 #2]“ usw.
    public static func fileName(_ original: String, beats: Int, ext: String = "m4a", taken: (String) -> Bool) -> String {
        var base = (original as NSString).deletingPathExtension
        if let r = base.range(of: #" \[(cut|tool-loop)( \d+)?( #\d+)?\]$"#, options: .regularExpression) { base.removeSubrange(r) }
        for n in 1...9999 {
            let name = base + (n == 1 ? " [tool-loop \(beats)]" : " [tool-loop \(beats) #\(n)]") + "." + ext
            if !taken(name) { return name }
        }
        return base + " [tool-loop \(beats) \(UUID().uuidString.prefix(8))]." + ext
    }

    /// „tool-loop 8 beats · 128 BPM · from <Titel>“
    public static func comment(beats: Int, bpm: Double, from title: String) -> String {
        let b = abs(bpm - bpm.rounded()) < 0.005 ? String(Int(bpm.rounded())) : String(format: "%.2f", bpm)
        return "tool-loop \(beats) beats · \(b) BPM · from \(title)"
    }

    /// Tags (Kommentar 2) mit `tool-loop`, vorhandene bleiben
    public static func tags(_ comment2: String, separators: String) -> String {
        let tags = Tags.split(comment2, separators: separators)
        guard !tags.contains(where: { Tags.key($0) == Tags.key(tag) }) else { return comment2 }
        let sep = separators.first.map(String.init) ?? " "
        let trimmed = comment2.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? tag : trimmed + (sep == " " ? " " : sep + " ") + tag
    }

    /// Track der Loop-Datei: Metadaten des Originals, Titel mit Label, Kommentar, Tag, BPM und Key vom Original,
    /// Grid-Anker bei 0, keine Cues außer dem Grid
    public static func track(from t: Track, key: String, path: String, beats: Int, bpm: Double, duration: Double,
                             separators: String, now: Date = Date()) -> Track {
        var n = t
        n.key = key
        n.path = path
        n.title = title(t.title, beats: beats)
        n.comment = comment(beats: beats, bpm: bpm, from: t.title.isEmpty ? t.fileName : t.title)
        n.comment2 = tags(t.comment2, separators: separators)
        n.duration = duration
        n.bpm = bpm
        n.importDate = now
        n.playCount = 0
        n.lastPlayed = nil
        n.loose = false
        n.fileMissing = false
        n.ownAnalysis = false
        n.cues = [Cue(name: "Grid", kind: .grid, startMs: 0, lengthMs: 0, hotcue: -1),
                  Cue(name: "Loop", kind: .loop, startMs: 0, lengthMs: duration * 1000, hotcue: 0)]
        n.buildSearchText()
        return n
    }

    /// Track ist ein Tool-Loop (Tag)
    public static func isToolLoop(_ t: Track, separators: String) -> Bool {
        Tags.split(t.comment2, separators: separators).contains { Tags.key($0) == Tags.key(tag) }
    }
}
