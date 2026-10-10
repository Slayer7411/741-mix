import Foundation

/// Farben des feinen Spektrums (Deck-Wellenform, später Browser-Vorschau): je Block aus 6 Bandpegeln und der Höhen-Dauer.
/// Jedes Band wird gegen die eigene Verteilung des Tracks normiert – Unterschiede innerhalb eines Tracks (Hats geschlossen
/// → offen, Drums setzen ein, Breakdown) treten hervor. Das lauteste Band (relativ zu seinem Bezug) bestimmt die Farbe.
public struct SpectrumColors: Sendable {
    public struct RGB: Equatable, Sendable {
        public var r, g, b: Float
        public init(r: Float, g: Float, b: Float) { self.r = r; self.g = g; self.b = b }
    }

    public static let sub = RGB(r: 1.00, g: 0.50, b: 0.04)      // orange
    public static let bass = RGB(r: 0.96, g: 0.12, b: 0.10)     // rot
    public static let lowMid = RGB(r: 0.10, g: 0.80, b: 0.26)   // grün
    public static let highMid = RGB(r: 0.62, g: 0.96, b: 0.16)  // gelbgrün
    public static let closed = RGB(r: 0.18, g: 0.44, b: 1.00)   // blau: kurze Höhen (geschlossene Hats)
    public static let open = RGB(r: 0.62, g: 0.93, b: 1.00)     // hellblau: gehaltene Höhen (offene Hats, Ride)

    /// typische Bandpegel (Perzentil 95, dBFS) gemasterter Club-Tracks; der Bezug eines Tracks bleibt 10 dB darunter
    /// bis 6 dB darüber – ein Track ohne Sub färbt nicht wegen ein paar leiser Sub-Reste orange
    public static let nominal: [Float] = [-8, -7, -16, -20, -22, -27]
    /// dB Vorsprung, mit dem ein Band 10× so stark in die Farbe eingeht
    public static let contrast: Float = 3.5

    /// Bezugspegel je Band (dB)
    public let ref: [Float]
    /// dB Anhebung für Höhen und Luft (Einstellung Höhen-Betonung, 0…2 → 0…10 dB)
    public let boost: Float

    public init(_ s: WaveSpectrum, highBoost: Double = 1) {
        let p = s.reference(percentile: 0.95)
        ref = (0..<6).map { min(Self.nominal[$0] + 6, max(Self.nominal[$0] - 10, p[$0])) }
        boost = Float(highBoost) * 5
    }

    /// fester Bezug (dB je Band), z. B. `nominal`
    public init(ref: [Float], highBoost: Double = 1) {
        self.ref = ref
        boost = Float(highBoost) * 5
    }

    /// offen-Anteil 0…1 aus der Höhen-Dauer (0,35 = typisch geschlossen, 0,8 = gehalten)
    public static func openness(_ sustain: Float) -> Float { max(0, min(1, (sustain - 0.35) / 0.45)) }

    static func lerp(_ a: RGB, _ b: RGB, _ t: Float) -> RGB {
        RGB(r: a.r + (b.r - a.r) * t, g: a.g + (b.g - a.g) * t, b: a.b + (b.b - a.b) * t)
    }

    public struct Result: Sendable {
        /// Farbe des Körpers (volle Höhe = Spitzenpegel)
        public var body: RGB
        /// Höhe der Höhen-Ebene relativ zum Körper (0…0,85)
        public var high: Float
        /// Farbe der Höhen-Ebene (blau … hellblau)
        public var highColor: RGB
        /// stärkstes Band (relativ zum Bezug)
        public var dominant: WaveSpectrum.Band
    }

    /// Farbe aus 6 Bandpegeln (dB) und der Höhen-Dauer (0…1)
    public func color(_ L: [Float], sustain: Float) -> Result {
        let o = Self.openness(sustain)
        let hiC = Self.lerp(Self.closed, Self.open, o)
        let airC = Self.lerp(Self.closed, Self.open, 0.35 + 0.65 * o)
        let cols = [Self.sub, Self.bass, Self.lowMid, Self.highMid, hiC, airC]
        var d = [Float](repeating: 0, count: 6)
        for b in 0..<6 { d[b] = L[b] - ref[b] + (b >= 4 ? boost : 0) }
        var top: Float = -.infinity, dom = 0
        for b in 0..<6 where d[b] > top { top = d[b]; dom = b }
        var r: Float = 0, g: Float = 0, bl: Float = 0, sum: Float = 0
        for b in 0..<6 where d[b] > -40 {
            let w = powf(10, (d[b] - top) / Self.contrast)
            r += cols[b].r * w; g += cols[b].g * w; bl += cols[b].b * w; sum += w
        }
        // auf volle Sättigung ziehen, leise Stellen etwas dunkler
        let level = max(0, min(1, 1 + top / 30))
        let m = max(r, g, bl, 0.0001)
        let k = 0.7 + 0.3 * level
        let body = sum > 0 ? RGB(r: r / m * k, g: g / m * k, b: bl / m * k) : RGB(r: 0.3, g: 0.3, b: 0.3)
        let high = powf(max(0, min(1, 1 + max(d[4], d[5]) / 24)), 1.6) * 0.85
        return Result(body: body, high: high, highColor: hiC, dominant: WaveSpectrum.Band(rawValue: dom)!)
    }

    /// Farbe eines Blocks
    public func color(_ s: WaveSpectrum, _ i: Int) -> Result {
        color((0..<6).map { WaveSpectrum.decibel(s.data[i * WaveSpectrum.stride + $0]) }, sustain: s.sustain(i))
    }
}
