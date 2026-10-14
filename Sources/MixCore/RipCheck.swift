import Foundation

/// Rip-Prüfung: Anfang und Ende eines Tracks auf Material, das nicht zum Track gehört (Stille, Rest des vorigen bzw.
/// Anfang des nächsten Tracks), dazu Grid-Verdacht am Anfang. Erkennung in MixEngine (`RipCheck.check`), Ablage in
/// `ripcheck.json` (`RipCheckStore`).
public enum RipCheck {
    public enum Kind: String, Codable, Sendable { case silence, foreign, grid }
    public enum Edge: String, Codable, Sendable { case start, end }
    /// Merkmale, die den Befund tragen
    public enum Cue: String, Codable, Sendable { case silence, key, spectrum, tempo, loop, anchor, phase, drift }

    public struct Finding: Codable, Equatable, Sendable, Identifiable {
        public var kind: Kind
        public var edge: Edge
        /// vorgeschlagener Schnitt (s): Start = Schnitt IN, Ende = Schnitt OUT; Grid: Stelle des Verdachts
        public var time: Double
        /// 0…1
        public var confidence: Double
        public var cues: [Cue]
        /// Tonart davor / danach (MUSICAL_KEY 0–23), fremdes Stück in Takten (eigenes Tempo), Grid-Versatz (ms),
        /// lokales Tempo (BPM)
        public var keyForeign: Int?
        public var keyTrack: Int?
        public var bars: Int?
        public var offsetMs: Double?
        public var localBPM: Double?

        public init(kind: Kind, edge: Edge, time: Double, confidence: Double, cues: [Cue]) {
            self.kind = kind; self.edge = edge; self.time = time; self.confidence = confidence; self.cues = cues
        }

        /// Schlüssel für „verwerfen“ (je Art und Seite)
        public var id: String { kind.rawValue + "." + edge.rawValue }
        /// Befund mit Schnittvorschlag
        public var cuts: Bool { kind != .grid }
    }

    public struct Result: Codable, Equatable, Sendable {
        public var findings: [Finding]
        public var duration: Double
        public init(findings: [Finding] = [], duration: Double = 0) { self.findings = findings; self.duration = duration }

        public var start: Finding? { findings.first { $0.edge == .start && $0.cuts } }
        public var end: Finding? { findings.first { $0.edge == .end && $0.cuts } }
        public var grid: Finding? { findings.first { $0.kind == .grid } }
    }

    /// Stand eines Tracks: Ergebnis, verworfene und erledigte Befunde
    public struct Entry: Codable, Equatable, Sendable {
        public var result: Result
        public var dismissed: [String] = []
        /// erledigt über den markierten Bereich (REMOVE, KEEP, neue Datei, Schnitt aus Bereich)
        public var done: [String] = []
        public var checked = Date()
        public var version = RipCheck.version
        public init(result: Result) { self.result = result }

        enum CodingKeys: String, CodingKey { case result, dismissed, done, checked, version }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            result = try c.decode(Result.self, forKey: .result)
            dismissed = try c.decodeIfPresent([String].self, forKey: .dismissed) ?? []
            done = try c.decodeIfPresent([String].self, forKey: .done) ?? []
            checked = try c.decodeIfPresent(Date.self, forKey: .checked) ?? Date()
            version = try c.decodeIfPresent(Int.self, forKey: .version) ?? RipCheck.version
        }

        /// offene Befunde: nicht verworfen oder erledigt, Schnitt-Befunde ohne Schnitt auf ihrer Seite, Grid ohne eigenes Grid
        public func open(trim: TrackTrim?, gridEdited: Bool) -> [Finding] {
            result.findings.filter { f in
                guard !dismissed.contains(f.id), !done.contains(f.id) else { return false }
                switch (f.kind, f.edge) {
                case (.grid, _): return !gridEdited
                case (_, .start): return trim?.start == nil
                case (_, .end): return trim?.end == nil
                }
            }
        }
    }

    /// 1: erste Fassung
    public static let version = 1

    /// Bereich eines Schnitt-Befunds in Deck-Zeit: Anfang 0 … time, Ende time … Dauer. `edl` = Schnittliste, die das Deck
    /// spielt: Bereich in Ausgabe-Zeit, vorn bzw. hinten so weit, wie die Ausgabe Quelle vor bzw. hinter `time` spielt.
    /// nil = Grid-Befund, unter 10 ms oder nichts mehr davon in der Ausgabe
    public static func range(_ f: Finding, duration: Double, edl: EditList? = nil) -> TrackRange? {
        guard f.cuts, duration > 0 else { return nil }
        let t = min(max(0, f.time), duration)
        let r: TrackRange
        if let e = edl {
            var x = 0.0
            if f.edge == .start {
                for g in e.segments {
                    guard g.start < t - EditList.eps else { break }
                    x += min(g.end, t) - g.start
                    if g.end >= t - EditList.eps { break }
                }
                r = TrackRange(0, x)
            } else {
                for g in e.segments.reversed() {
                    guard g.end > t + EditList.eps else { break }
                    x += g.end - max(g.start, t)
                    if g.start <= t + EditList.eps { break }
                }
                r = TrackRange(e.duration - x, e.duration)
            }
        } else {
            r = f.edge == .start ? TrackRange(0, t) : TrackRange(t, duration)
        }
        return r.length > EditList.minSegment ? r : nil
    }


    /// Kurztext der Spalte: „▸ 7,3 s“ (Anfang), „◂ 3:02“ (Ende), „GRID“
    public static func columnText(_ open: [Finding]) -> String {
        var parts: [String] = []
        if let s = open.first(where: { $0.edge == .start && $0.cuts }) { parts.append("▸ " + shortTime(s.time)) }
        if let e = open.first(where: { $0.edge == .end && $0.cuts }) { parts.append("◂ " + shortTime(e.time)) }
        if open.contains(where: { $0.kind == .grid }) { parts.append("GRID") }
        return parts.joined(separator: " ")
    }

    /// unter einer Minute „7,3 s“, sonst „3:02“
    public static func shortTime(_ t: Double) -> String {
        let t = max(0, t)
        if t < 60 { return String(format: "%.1f s", t).replacingOccurrences(of: ".", with: ",") }
        let s = Int(t.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Rip-Prüfungen aller Tracks (Track-Schlüssel -> Stand) in `ripcheck.json`; `url` nil = nur im Speicher (Selbsttest)
public final class RipCheckStore: @unchecked Sendable {
    private var entries: [String: RipCheck.Entry] = [:]
    let url: URL?
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "minos741.ripcheck", qos: .utility)
    /// nach jeder Änderung mit dem Track-Schlüssel – beliebiger Thread
    public var onChange: (@Sendable (String) -> Void)?

    public init(url: URL?) {
        self.url = url
        if let url, let d = try? Data(contentsOf: url), let e = try? JSONDecoder().decode([String: RipCheck.Entry].self, from: d) { entries = e }
    }

    public var all: [String: RipCheck.Entry] { lock.lock(); defer { lock.unlock() }; return entries }
    public func entry(for key: String) -> RipCheck.Entry? { lock.lock(); defer { lock.unlock() }; return entries[key] }

    /// neues Ergebnis; verworfene und erledigte Befunde bleiben es, solange es sie noch gibt
    public func put(_ r: RipCheck.Result, for key: String) {
        lock.lock()
        var e = RipCheck.Entry(result: r)
        let ids = Set(r.findings.map(\.id))
        e.dismissed = (entries[key]?.dismissed ?? []).filter { ids.contains($0) }
        e.done = (entries[key]?.done ?? []).filter { ids.contains($0) }
        entries[key] = e
        lock.unlock()
        save()
        onChange?(key)
    }

    public func dismiss(_ ids: [String], for key: String) { mark(ids, key) { $0.dismissed } set: { $0.dismissed = $1 } }

    /// erledigt (über den markierten Bereich)
    public func markDone(_ ids: [String], for key: String) { mark(ids, key) { $0.done } set: { $0.done = $1 } }

    private func mark(_ ids: [String], _ key: String, get: (RipCheck.Entry) -> [String], set: (inout RipCheck.Entry, [String]) -> Void) {
        lock.lock()
        guard var e = entries[key] else { lock.unlock(); return }
        var l = get(e)
        for i in ids where !l.contains(i) { l.append(i) }
        set(&e, l)
        entries[key] = e
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

    public func rename(from old: String, to new: String) {
        guard old != new else { return }
        lock.lock()
        let e = entries.removeValue(forKey: old)
        if let e { entries[new] = e }
        lock.unlock()
        if e != nil { save(); onChange?(old); onChange?(new) }
    }

    private func save() {
        guard let url else { return }
        let snapshot = all
        queue.async {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let d = try? JSONEncoder().encode(snapshot) { try? d.write(to: url, options: .atomic) }
        }
    }

    public func flush() { queue.sync {} }
}
