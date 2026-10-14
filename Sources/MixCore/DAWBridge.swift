import Foundation

/// Live-Brücke zur DAW: ein Remote Script in der DAW schickt JSON per UDP an 127.0.0.1 (Port 7411, einstellbar).
/// Protokoll v1, ein Objekt je Paket (höchstens ~8 KB):
/// * `song` (alle 100 ms): `tempo`, `playing`, `beat` (Song-Position in Beats), `sig` (Zähler), `clips` (IDs aller
///   gemeldeten Clips, andere fallen weg), `pos` (ID -> [spielt 0/1, Position im Clip])
/// * `clip` (bei Änderung, dazu reihum alle 2 s): `id`, `track`, `trackName`, `name`, `file`, `warping`, `markers`
///   ([[beat, sec], …]), `truncated`, `loop` ([start, end] in Beats), `looping`, `start`, `end`, `playing`, `selected`,
///   `where` (session / arrangement)
/// * `bye`: Script beendet
/// Position im Clip: Beats des Clips (gewarpt), Sekunden der Datei (nicht gewarpt).
public enum DAWBridge {
    public static let defaultPort: UInt16 = 7411
    public static let version = 1

    public struct Song: Equatable, Sendable {
        public var tempo = 120.0
        public var playing = false
        public var beat = 0.0
        public var beatsPerBar = 4.0
        public var clipIDs: [String] = []
        /// ID -> (spielt, Position)
        public var positions: [String: Position] = [:]
        public var seq = 0
        public init() {}
    }

    public struct Position: Equatable, Sendable {
        public var playing: Bool
        public var value: Double
    }

    public struct Clip: Equatable, Sendable, Identifiable {
        public var id: String
        public var track: Int
        public var trackName: String
        public var name: String
        public var file: String
        public var warping: Bool
        public var markers: [WarpMarker]
        public var truncated: Bool
        public var loop: ClosedRange<Double>?
        public var looping: Bool
        public var start: Double
        public var end: Double
        public var playing: Bool
        public var selected: Bool
        public var arrangement: Bool

        public init(id: String, track: Int = 0, trackName: String = "", name: String = "", file: String = "", warping: Bool = true,
                    markers: [WarpMarker] = [], truncated: Bool = false, loop: ClosedRange<Double>? = nil, looping: Bool = false,
                    start: Double = 0, end: Double = 0, playing: Bool = false, selected: Bool = false, arrangement: Bool = false) {
            self.id = id; self.track = track; self.trackName = trackName; self.name = name; self.file = file; self.warping = warping
            self.markers = markers; self.truncated = truncated; self.loop = loop; self.looping = looping; self.start = start
            self.end = end; self.playing = playing; self.selected = selected; self.arrangement = arrangement
        }

        /// Warp-Abbildung (nil: nicht gewarpt oder zu wenige Marker)
        public var map: WarpMap? { warping ? WarpMap(markers) : nil }
        /// Grid wie bei der Clip-Analyse-Datei
        public func grid(beatsPerBar: Double = BeatGrid.beatsPerBar, duration: Double = 0) -> WarpGrid? {
            warping ? WarpGrid(markers: markers, beatsPerBar: beatsPerBar, duration: duration) : nil
        }
    }

    public enum Message: Equatable, Sendable {
        case song(Song)
        case clip(Clip)
        case bye
    }

    public enum ParseError: Error, Equatable {
        case notJSON, wrongVersion(Int), unknownType(String), missing(String)
    }

    /// ein Paket lesen
    public static func parse(_ data: Data) throws -> Message {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw ParseError.notJSON }
        let v = (o["v"] as? NSNumber)?.intValue ?? 0
        guard v == version else { throw ParseError.wrongVersion(v) }
        let type = o["t"] as? String ?? ""
        switch type {
        case "song":
            var s = Song()
            s.tempo = num(o["tempo"]) ?? 120
            s.playing = bool(o["playing"])
            s.beat = num(o["beat"]) ?? 0
            if let b = num(o["sig"]), b >= 1, b <= 32 { s.beatsPerBar = b }
            s.seq = (o["seq"] as? NSNumber)?.intValue ?? 0
            s.clipIDs = (o["clips"] as? [Any])?.compactMap { $0 as? String } ?? []
            if let p = o["pos"] as? [String: Any] {
                for (k, v) in p {
                    guard let a = v as? [Any], a.count >= 2, let x = num(a[1]) else { continue }
                    s.positions[k] = Position(playing: bool(a[0]), value: x)
                }
            }
            return .song(s)
        case "clip":
            guard let id = o["id"] as? String, !id.isEmpty else { throw ParseError.missing("id") }
            var c = Clip(id: id)
            c.track = (o["track"] as? NSNumber)?.intValue ?? 0
            c.trackName = o["trackName"] as? String ?? ""
            c.name = o["name"] as? String ?? ""
            c.file = o["file"] as? String ?? ""
            c.warping = o["warping"] == nil ? true : bool(o["warping"])
            c.markers = (o["markers"] as? [Any])?.compactMap { m -> WarpMarker? in
                guard let a = m as? [Any], a.count >= 2, let b = num(a[0]), let s = num(a[1]) else { return nil }
                return WarpMarker(sec: s, beat: b)
            } ?? []
            c.truncated = bool(o["truncated"])
            if let l = o["loop"] as? [Any], l.count >= 2, let a = num(l[0]), let b = num(l[1]), b > a { c.loop = a...b }
            c.looping = bool(o["looping"])
            c.start = num(o["start"]) ?? 0
            c.end = num(o["end"]) ?? 0
            c.playing = bool(o["playing"])
            c.selected = bool(o["selected"])
            c.arrangement = (o["where"] as? String) == "arrangement"
            return .clip(c)
        case "bye": return .bye
        default: throw ParseError.unknownType(type)
        }
    }

    static func num(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        return d.isFinite ? d : nil
    }
    static func bool(_ v: Any?) -> Bool {
        guard let n = v as? NSNumber else { return false }
        return n.boolValue
    }
}

/// Zustand der DAW, wie die Pakete ihn melden. Reine Werte; `apply` gibt zurück, ob sich die Clip-Liste (nicht nur
/// Positionen) geändert hat.
public struct DAWSession: Equatable, Sendable {
    public var song = DAWBridge.Song()
    public var clips: [String: DAWBridge.Clip] = [:]
    /// Systemzeit (s) des letzten Pakets / der letzten Positionen
    public var lastPacket = 0.0
    public var positionsAt = 0.0
    public var connected = false

    public init() {}

    /// nach Spur und Name sortiert (für Liste und Anzeige)
    public var orderedClips: [DAWBridge.Clip] {
        clips.values.sorted { ($0.track, $0.arrangement ? 1 : 0, $0.name, $0.id) < ($1.track, $1.arrangement ? 1 : 0, $1.name, $1.id) }
    }
    public var trackCount: Int { Set(clips.values.map(\.track)).count }

    @discardableResult
    public mutating func apply(_ m: DAWBridge.Message, now: Double) -> Bool {
        lastPacket = now
        switch m {
        case let .song(s):
            let was = connected
            connected = true
            song = s
            positionsAt = now
            let keep = Set(s.clipIDs)
            let before = clips.count
            clips = clips.filter { keep.contains($0.key) }
            for (id, p) in s.positions where clips[id] != nil { clips[id]?.playing = p.playing }
            return clips.count != before || !was
        case let .clip(c):
            connected = true
            var c = c
            if let p = song.positions[c.id] { c.playing = p.playing }
            let changed = clips[c.id].map { !Self.sameShape($0, c) } ?? true
            clips[c.id] = c
            return changed
        case .bye:
            let changed = connected || !clips.isEmpty
            self = DAWSession()
            lastPacket = now
            return changed
        }
    }

    /// alles außer Spiel-Zustand gleich (Spielen ändert die Liste nicht)
    static func sameShape(_ a: DAWBridge.Clip, _ b: DAWBridge.Clip) -> Bool {
        var x = a, y = b
        x.playing = false; y.playing = false
        return x == y
    }

    /// Verbindung gilt als weg, wenn so lange nichts kommt (s)
    public static let timeout = 2.0
    public func alive(now: Double) -> Bool { connected && now - lastPacket < Self.timeout }

    /// Position eines Clips jetzt: letzte gemeldete Position + vergangene Zeit im Song-Tempo (gewarpt: Beats, sonst
    /// Sekunden), höchstens `maxExtrapolation` s weitergerechnet. nil = nicht gemeldet
    public func position(of id: String, now: Double, maxExtrapolation: Double = 0.5) -> Double? {
        guard let p = song.positions[id] else { return nil }
        guard p.playing, song.playing else { return p.value }
        let dt = max(0, min(maxExtrapolation, now - positionsAt))
        let warped = clips[id]?.warping ?? true
        return p.value + (warped ? dt * song.tempo / 60 : dt)
    }
}

/// Stückweise lineare Abbildung Beat ↔ Sekunde aus Warp-Markern (außerhalb mit dem Tempo des ersten / letzten Abschnitts).
public struct WarpMap: Equatable, Sendable {
    public let markers: [WarpMarker]

    public init?(_ raw: [WarpMarker]) {
        let m = WarpGrid.clean(raw)
        guard m.count >= 2 else { return nil }
        markers = m
    }

    public func sec(atBeat b: Double) -> Double {
        let (i, j) = segment(b, \.beat)
        let p = markers[i], q = markers[j]
        return p.sec + (b - p.beat) * (q.sec - p.sec) / (q.beat - p.beat)
    }

    public func beat(atSec s: Double) -> Double {
        let (i, j) = segment(s, \.sec)
        let p = markers[i], q = markers[j]
        return p.beat + (s - p.sec) * (q.beat - p.beat) / (q.sec - p.sec)
    }

    /// Abschnitt (Index-Paar) für einen Wert; davor der erste, danach der letzte
    private func segment(_ v: Double, _ k: KeyPath<WarpMarker, Double>) -> (Int, Int) {
        var lo = 0, hi = markers.count - 1
        if v <= markers[1][keyPath: k] { return (0, 1) }
        if v >= markers[hi - 1][keyPath: k] { return (hi - 1, hi) }
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if markers[mid][keyPath: k] <= v { lo = mid } else { hi = mid }
        }
        return (lo, hi)
    }

    /// Zeiten (s) aller ganzen Beats in einem Sekundenbereich, mit Takt-Eins-Kennung (Beat ≡ 0 mod Takt)
    public func beats(in range: ClosedRange<Double>, beatsPerBar: Double = BeatGrid.beatsPerBar, limit: Int = 4096) -> [(sec: Double, bar: Bool)] {
        let b0 = beat(atSec: range.lowerBound).rounded(.up), b1 = beat(atSec: range.upperBound).rounded(.down)
        guard b1 >= b0, b1 - b0 < Double(limit) else { return [] }
        var out: [(Double, Bool)] = []
        var b = b0
        while b <= b1 {
            let r = b.truncatingRemainder(dividingBy: beatsPerBar)
            out.append((sec(atBeat: b), abs(r) < 1e-9))
            b += 1
        }
        return out
    }
}
