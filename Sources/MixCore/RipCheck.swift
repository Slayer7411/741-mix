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

    /// Stand eines Tracks: Ergebnis + verworfene Befunde
    public struct Entry: Codable, Equatable, Sendable {
        public var result: Result
        public var dismissed: [String] = []
        public var checked = Date()
        public var version = RipCheck.version
        public init(result: Result) { self.result = result }

        /// offene Befunde: nicht verworfen, Schnitt-Befunde ohne Schnitt auf ihrer Seite, Grid ohne eigenes Grid
        public func open(trim: TrackTrim?, gridEdited: Bool) -> [Finding] {
            result.findings.filter { f in
                guard !dismissed.contains(f.id) else { return false }
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

    /// neues Ergebnis; verworfene Befunde bleiben verworfen, solange es sie noch gibt
    public func put(_ r: RipCheck.Result, for key: String) {
        lock.lock()
        var e = RipCheck.Entry(result: r)
        let ids = Set(r.findings.map(\.id))
        e.dismissed = (entries[key]?.dismissed ?? []).filter { ids.contains($0) }
        entries[key] = e
        lock.unlock()
        save()
        onChange?(key)
    }

    public func dismiss(_ ids: [String], for key: String) {
        lock.lock()
        guard var e = entries[key] else { lock.unlock(); return }
        for i in ids where !e.dismissed.contains(i) { e.dismissed.append(i) }
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
