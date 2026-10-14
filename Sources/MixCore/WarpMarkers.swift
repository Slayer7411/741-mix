import Foundation

/// Warp-Marker einer DAW: Zeit in der Datei (s) ↔ Beat im Clip (0 = Takt 1, Beat 1 des Clips).
public struct WarpMarker: Hashable, Codable, Sendable {
    public var sec: Double
    public var beat: Double

    public init(sec: Double, beat: Double) { self.sec = sec; self.beat = beat }
}

/// Herkunft des Grids eines Tracks (Browser-Tooltip, Deck-Hinweis).
public enum GridSource: String, Codable, Sendable {
    case collection, analysis, daw, manual

    /// manuell oder DAW (eigene Änderung) > Analyse > Collection; nil = kein Grid
    public static func of(_ t: Track, edit: TrackEdit?, analysis: TrackAnalysis?) -> GridSource? {
        if let e = edit, e.hasGrid { return e.gridSource ?? .manual }
        if let a = analysis, a.bpm != nil || a.gridAnchorMs != nil { return .analysis }
        return t.gridAnchorMs != nil && t.bpm > 0 ? .collection : nil
    }
}

/// Grid aus Warp-Markern. MINOS kennt ein konstantes Tempo (Anker + BPM): genommen wird der längste Abschnitt mit
/// gleichem Tempo (±0,5 %), darin die Ausgleichsgerade Zeit über Beat. Anker = Beat 0 des Clips (Takt-Eins), liegt er
/// vor der Datei: die erste Takt-Eins danach.
public struct WarpGrid: Equatable, Sendable {
    public var grid: BeatGrid
    /// bereinigte Marker (aufsteigend, Zeit und Beat streng steigend)
    public var markers: [WarpMarker]
    /// Tempo der Abschnitte zwischen den Markern
    public var tempoRange: ClosedRange<Double>
    /// alle Abschnitte im selben Tempo (±0,01 BPM)
    public var constant: Bool
    /// größte Abweichung des konstanten Grids von den Markern (ms)
    public var maxDeviationMs: Double

    /// Tempo-Gruppe: ein Abschnitt gehört dazu, solange er höchstens so weit vom Mittel der Gruppe abweicht
    public static let groupTolerance = 0.005
    public static let constantTolerance = 0.01

    /// Marker -> Grid; nil bei weniger als zwei brauchbaren Markern. `duration` (s, 0 = unbekannt) begrenzt den Anker
    public init?(markers raw: [WarpMarker], beatsPerBar: Double = BeatGrid.beatsPerBar, duration: Double = 0) {
        let m = Self.clean(raw)
        guard m.count >= 2, beatsPerBar > 0 else { return nil }
        var tempi: [Double] = [], secs: [Double] = []
        for i in 0..<(m.count - 1) {
            let ds = m[i + 1].sec - m[i].sec
            tempi.append((m[i + 1].beat - m[i].beat) / ds * 60)
            secs.append(ds)
        }
        // Abschnitte gleichen Tempos zusammenfassen, der längste (Sekunden) bestimmt das Grid
        var groups: [(from: Int, to: Int, secs: Double, beats: Double)] = []
        for i in tempi.indices {
            if var g = groups.last {
                let mean = g.beats / g.secs * 60
                if abs(tempi[i] - mean) <= mean * Self.groupTolerance {
                    g.to = i; g.secs += secs[i]; g.beats += m[i + 1].beat - m[i].beat
                    groups[groups.count - 1] = g
                    continue
                }
            }
            groups.append((i, i, secs[i], m[i + 1].beat - m[i].beat))
        }
        guard let best = groups.max(by: { $0.secs < $1.secs }) else { return nil }
        // Ausgleichsgerade sec = a + b · beat über die Marker der Gruppe (zwei Marker: genau)
        let pts = m[best.from...(best.to + 1)]
        let n = Double(pts.count)
        let mb = pts.reduce(0) { $0 + $1.beat } / n, ms = pts.reduce(0) { $0 + $1.sec } / n
        var sbb = 0.0, sbs = 0.0
        for p in pts { sbb += (p.beat - mb) * (p.beat - mb); sbs += (p.beat - mb) * (p.sec - ms) }
        guard sbb > 0 else { return nil }
        let b = sbs / sbb, a = ms - b * mb
        guard b > 0, b.isFinite, a.isFinite else { return nil }
        let bpm = 60 / b
        guard bpm > 20, bpm < 1000 else { return nil }
        // Takt-Eins: Beat 0 des Clips, sonst die erste Takt-Eins in der Datei
        var anchor = a
        if anchor < 0 || (duration > 0 && anchor >= duration) {
            let bar = b * beatsPerBar
            anchor = a + (-a / bar).rounded(.up) * bar
            if anchor < 0 { anchor += bar }
        }
        grid = BeatGrid(anchor: anchor, bpm: bpm)
        markers = m
        tempoRange = (tempi.min() ?? bpm)...(tempi.max() ?? bpm)
        constant = tempoRange.upperBound - tempoRange.lowerBound <= Self.constantTolerance
        maxDeviationMs = m.map { abs(a + b * $0.beat - $0.sec) * 1000 }.max() ?? 0
    }

    /// endliche Werte, nach Beat sortiert, Zeit und Beat streng steigend (doppelte und rückläufige fallen weg)
    public static func clean(_ raw: [WarpMarker]) -> [WarpMarker] {
        var out: [WarpMarker] = []
        for p in raw.filter({ $0.sec.isFinite && $0.beat.isFinite }).sorted(by: { $0.beat < $1.beat }) {
            if let l = out.last, p.sec <= l.sec + 1e-9 || p.beat <= l.beat + 1e-9 { continue }
            out.append(p)
        }
        return out
    }
}
