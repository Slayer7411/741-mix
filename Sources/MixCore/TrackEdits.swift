import Foundation

/// Eigene Änderungen an Tracks (Beatgrid, Hotcues) – dauerhaft, ohne die Traktor-Collection anzufassen.
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
