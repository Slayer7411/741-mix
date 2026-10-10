import Foundation

/// Beat-Raster eines Tracks: Anker (Beat 1) in Sekunden + BPM. Grundlage für Sync, Quantize, Loops, Beatjump.
public struct BeatGrid: Hashable, Sendable {
    public var anchor: Double
    public var bpm: Double

    public init(anchor: Double, bpm: Double) {
        self.anchor = anchor
        self.bpm = bpm
    }

    public init?(track: Track) {
        guard track.bpm > 0 else { return nil }
        self.init(anchor: (track.gridAnchorMs ?? 0) / 1000, bpm: track.bpm)
    }

    /// Länge eines Beats in Sekunden
    public var beat: Double { 60 / bpm }

    /// Beat-Position (fortlaufend, 0 = Anker) zu einer Zeit
    public func beatPosition(at t: Double) -> Double { (t - anchor) / beat }

    /// Phase innerhalb des Beats, 0 ..< 1
    public func phase(at t: Double) -> Double {
        let p = beatPosition(at: t)
        return p - p.rounded(.down)
    }

    /// Zeit des Beats Nummer n
    public func time(ofBeat n: Double) -> Double { anchor + n * beat }

    /// Nächster Beat (für Quantize/Snap)
    public func nearestBeat(to t: Double) -> Double { time(ofBeat: beatPosition(at: t).rounded()) }

    /// Letzter Beat an oder vor t
    public func beatFloor(_ t: Double) -> Double { time(ofBeat: (beatPosition(at: t) + 1e-6).rounded(.down)) }

    /// Phasendifferenz in Beats (−0.5 … 0.5) zwischen eigener Position und einer Master-Phase
    public static func phaseError(own: Double, master: Double) -> Double {
        var d = own - master
        d -= d.rounded()
        return d
    }

    /// Beats in einem Takt (Traktor rechnet in 4/4)
    public static let beatsPerBar = 4.0

    /// Taktposition „Takt.Beat“ zur Anzeige (1-basiert)
    public func barBeat(at t: Double) -> (bar: Int, beat: Int) {
        let p = beatPosition(at: t).rounded(.down)
        let bar = Int((p / Self.beatsPerBar).rounded(.down))
        let beat = Int(p - Double(bar) * Self.beatsPerBar)
        return (bar + 1, beat + 1)
    }
}

/// Loop- und Sprunggrößen wie in Traktor (in Beats).
public enum BeatSizes {
    public static let loop: [Double] = [1.0 / 32, 1.0 / 16, 1.0 / 8, 1.0 / 4, 1.0 / 2, 1, 2, 4, 8, 16, 32]
    public static let jump: [Double] = [1.0 / 4, 1.0 / 2, 1, 2, 4, 8, 16, 32, 64]

    public static func label(_ beats: Double) -> String {
        beats >= 1 ? String(Int(beats)) : "1/\(Int((1 / beats).rounded()))"
    }
}
