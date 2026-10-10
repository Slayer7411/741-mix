import Foundation

/// Farben und Höhen der Spektrum-Vorschau aus einer Übersicht: rot = Bass, grün = Mitten (Synths), blau = Höhen
/// (Drums/Hats), je Spalte additiv gemischt. Bänder gegen einen typischen Track gewichtet (Track-Tönung bleibt),
/// Sättigung angehoben; Höhe aus Spitze + Bass (laute Master: per Track normiert, Breaks deutlich niedriger).
public enum OverviewPaint {
    public struct RGB: Equatable, Sendable {
        public var r, g, b: Float
        public init(_ r: Float, _ g: Float, _ b: Float) { self.r = r; self.g = g; self.b = b }
    }

    public struct Column: Equatable, Sendable {
        /// Höhe 0–1 (1 = halbe Bildhöhe nach oben und unten)
        public var amp: Float
        public var color: RGB
    }

    /// Bandanteile eines typischen Tracks (Median über 1.913 Tracks einer Techno-/House-Collection: 0,62 / 0,28 / 0,09),
    /// Höhen leicht angehoben -> Synth-Flächen grün statt türkis
    public static let reference: (low: Float, mid: Float, high: Float) = (0.62, 0.28, 0.11)
    /// Gewicht der Track-Mittelwerte in der Referenz (Rest: typischer Track) -> Tönung bleibt, Verlauf trotzdem sichtbar
    static let trackShare: Float = 0.3
    /// Exponent auf die Gewichte (Kontrast zwischen den Bändern)
    static let contrast: Float = 2
    /// Anteil des Minimums, der abgezogen wird (Sättigung)
    static let saturation: Float = 0.65

    /// Energie je Punkt 0–1: Spitze per Track normiert und gespreizt, mal Bass-Anteil (Kick da = voll)
    public static func energy(_ o: TrackOverview) -> [Float] {
        guard o.count > 0 else { return [] }
        var top: Float = 0.001
        for i in 0..<o.count { top = max(top, o.peak(i)) }
        return (0..<o.count).map { i in pow(o.peak(i) / top, 2.5) * (0.35 + 0.65 * o.low(i).squareRoot()) }
    }

    /// `width` Spalten über die ganze Dauer; Farben mit der Palette (Bass, Mitten, Höhen)
    public static func columns(_ o: TrackOverview, width: Int, low: RGB, mid: RGB, high: RGB) -> [Column] {
        let n = o.count
        guard n > 0, width > 0 else { return [] }
        let e = energy(o)
        // Track-Mittel (nach Spitze gewichtet)
        var sw: Float = 0, tl: Float = 0, tm: Float = 0, th: Float = 0
        for i in 0..<n { let w = o.peak(i); sw += w; tl += w * o.low(i); tm += w * o.mid(i); th += w * o.high(i) }
        sw = max(sw, 1e-6)
        let k = trackShare
        let rl = (1 - k) * reference.low + k * tl / sw, rm = (1 - k) * reference.mid + k * tm / sw
        let rh = (1 - k) * reference.high + k * th / sw
        var top: Float = 0.001
        for i in 0..<n { top = max(top, o.peak(i)) }
        return (0..<width).map { x in
            let i = min(n - 1, x * n / width)
            // Bänder über 3 Punkte geglättet (kein Farbflackern)
            var l: Float = 0, m: Float = 0, h: Float = 0, c: Float = 0
            for j in max(0, i - 1)...min(n - 1, i + 1) { l += o.low(j); m += o.mid(j); h += o.high(j); c += 1 }
            let wl = pow(l / c / max(rl, 1e-3), contrast), wm = pow(m / c / max(rm, 1e-3), contrast)
            let wh = pow(h / c / max(rh, 1e-3), contrast)
            var rgb = RGB(low.r * wl + mid.r * wm + high.r * wh, low.g * wl + mid.g * wm + high.g * wh,
                          low.b * wl + mid.b * wm + high.b * wh)
            let mx = max(rgb.r, rgb.g, rgb.b, 1e-4)
            rgb = RGB(rgb.r / mx, rgb.g / mx, rgb.b / mx)
            let mn = min(rgb.r, rgb.g, rgb.b) * saturation
            rgb = RGB((rgb.r - mn) / (1 - mn), (rgb.g - mn) / (1 - mn), (rgb.b - mn) / (1 - mn))
            // Helligkeit aus der Spitze
            let bright = 0.55 + 0.45 * (o.peak(i) / top).squareRoot()
            return Column(amp: pow(e[i], 0.8), color: RGB(rgb.r * bright, rgb.g * bright, rgb.b * bright))
        }
    }

    /// große Energiesprünge (Drops): Position 0–1, höchstens `limit`, mindestens 1/16 der Länge auseinander
    public static func drops(_ o: TrackOverview, threshold: Float = 0.25, limit: Int = 4) -> [Double] {
        let e = energy(o), n = e.count, win = 6
        guard n > 2 * win else { return [] }
        var jump = [Float](repeating: 0, count: n)
        for j in win...(n - win) {
            var before: Float = 0, after: Float = 0
            for k in 0..<win { before += e[j - 1 - k]; after += e[j + k] }
            jump[j] = (after - before) / Float(win)
        }
        var out: [Int] = []
        for j in jump.indices.sorted(by: { jump[$0] > jump[$1] }) {
            guard jump[j] >= threshold, out.count < limit else { break }
            if out.allSatisfy({ abs($0 - j) > n / 16 }) { out.append(j) }
        }
        return out.sorted().map { Double($0) / Double(n) }
    }
}
