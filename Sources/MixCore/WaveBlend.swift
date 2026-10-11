import Foundation

/// Daten des Stils „3-Band (Mischung)“ je Wellenform-Block, 8 Bytes: Effektivwert des Mono-Signals, die gewichteten
/// Band-Hüllkurven Tief / Mitte / Hoch im Mittel über den Block und am lautesten Sample des Blocks.
/// Pegel in 0,5-dB-Schritten wie `WaveSpectrum` (255 = 0 dBFS, 0 = Stille). 10 min ≈ 1,4 MB.
public struct WaveBlend: Equatable, Sendable {
    public static let stride = 8
    public static let rmsSlot = 0, meanSlot = 1, peakSlot = 4

    public var data: [UInt8]
    public init(data: [UInt8]) { self.data = data }
    public static let empty = WaveBlend(data: [])

    public var count: Int { data.count / Self.stride }

    /// Amplitude → Byte (0,5 dB je Schritt, −127 dBFS … 0 dBFS)
    @inline(__always) public static func byte(amplitude a: Float) -> UInt8 {
        guard a > 4.5e-7 else { return 0 }
        return UInt8(max(1, min(255, (255 + 40 * log10f(a)).rounded())))
    }

    /// Byte → Amplitude (Tabelle)
    public static let amplitude: [Float] = (0..<256).map { $0 == 0 ? 0 : powf(10, (Float($0) - 255) / 40) }
}

/// Rasterung des Mischungs-Stils: je Pixelspalte und -zeile Deckung (Anteil der Samples, die die Zeile erreichen) und
/// Farbe aus den Band-Hüllkurven genau dieser Samples. Unten (bis zum Effektivwert) deckt jeder Block voll mit seiner
/// mittleren Farbe, darüber fällt die Deckung linear bis zur Spitze und die Farbe geht in die des lautesten Samples
/// über – Transienten und Höhen färben die Spitzen, der Körper bleibt beim Bass. Helligkeit = Deckung^(1/3,5).
public enum BlendPaint {
    public typealias RGB = (r: Float, g: Float, b: Float)

    /// Exponent der Helligkeit über der Deckung (weich nach oben auslaufend)
    public static let gamma: Float = 1 / 3.5
    /// Grundpegel im Nenner der Bandanteile: leise Stellen werden dunkler statt voll gesättigt
    public static let floor: Float = 0.01
    /// Exponent auf die Bandanteile der RGB-Palette (> 1: das stärkste Band setzt sich in der Farbe durch)
    public static let saturation: Float = 1.5

    /// Palette: `direct` = Bandanteile direkt als Rot / Grün / Blau, sonst drei Farben (Tief, Mitte, Hoch), Höhen
    /// quadratisch (nur starke Höhen färben)
    public struct Palette: Sendable {
        public var low: RGB, mid: RGB, high: RGB
        public var direct: Bool
        /// Anteil der Höhen in der Mischung (1 = voll)
        public var highShare: Float
        public init(low: RGB, mid: RGB, high: RGB, direct: Bool = false, highShare: Float = 1) {
            self.low = low; self.mid = mid; self.high = high; self.direct = direct; self.highShare = highShare
        }
        public static let rgb = Palette(low: (1, 0, 0), mid: (0, 1, 0), high: (0, 0, 1), direct: true)
    }

    /// Helligkeit (Deckung 0…1 → 0…1), 1024 Stufen
    static let lift: [Float] = (0...1024).map { powf(Float($0) / 1024, gamma) }
    @inline(__always) static func brightness(_ c: Float) -> Float { lift[Int(max(0, min(1, c)) * 1024)] }

    /// Farbe aus den summierten Hüllkurven (Tief, Mitte, Hoch) und der Deckungssumme der Zeile
    @inline(__always) public static func color(_ e: RGB, weight: Float, _ p: Palette) -> RGB {
        guard weight > 0 else { return (0, 0, 0) }
        let l = e.r / weight, m = e.g / weight, h = e.b / weight
        let s = 1 / (l + m + h + floor)
        let a1 = l * s, a2 = m * s, a3 = h * s * p.highShare
        // direkt: Anteile gespreizt und auf das stärkste Band gezogen (klare Farben, Mischungen gelb / cyan / weiß statt
        // trüb), Pegel nahe dem Grundpegel dunkler
        if p.direct {
            let b1 = powf(a1, saturation), b2 = powf(a2, saturation), b3 = powf(a3, saturation)
            let g = min(1, a1 + a2 + a3) / max(b1, b2, b3, 1e-6)
            return (min(1, b1 * g), min(1, b2 * g), min(1, b3 * g))
        }
        let k = 1 / (a1 + a2 + floor)
        let w1 = a1 * k, w2 = a2 * k, w3 = a3 * a3
        return (min(1, p.low.r * w1 + p.mid.r * w2 + p.high.r * w3),
                min(1, p.low.g * w1 + p.mid.g * w2 + p.high.g * w3),
                min(1, p.low.b * w1 + p.mid.b * w2 + p.high.b * w3))
    }

    /// eine Spalte aus den Blöcken `from..<to` rastern: `half` Zeilen von der Mitte nach außen, Zeile j bei Amplitude
    /// (j + 0,5) / half (volle Höhe = 0 dBFS). Schreibt RGBA (vormultipliziert) je Zeile über `put(j, r, g, b, a)`.
    @inline(__always)
    public static func column(peak: UnsafeBufferPointer<Float>, blend: UnsafeBufferPointer<UInt8>, from: Int, to: Int,
                              half: Int, palette p: Palette, put: (Int, UInt8, UInt8, UInt8, UInt8) -> Void) {
        let n = min(peak.count, blend.count / WaveBlend.stride)
        let lo = max(0, min(n - 1, from)), hi = max(lo + 1, min(n, to))
        guard n > 0, half > 0 else { return }
        let amp = WaveBlend.amplitude
        var top: Float = 0
        for k in lo..<hi { top = max(top, peak[k]) }
        let rows = min(half, Int((top * Float(half)).rounded(.up)))
        guard rows > 0 else { return }
        let count = Float(hi - lo), inv = 1 / Float(half)
        for j in 0..<rows {
            let y = (Float(j) + 0.5) * inv
            var c: Float = 0, er: Float = 0, eg: Float = 0, eb: Float = 0
            for k in lo..<hi {
                let pk = peak[k]
                guard y < pk else { continue }
                let o = k * WaveBlend.stride
                let r = min(amp[Int(blend[o])], pk * 0.98)
                var cov: Float = 1, s: Float = 0
                if y > r { cov = (pk - y) / (pk - r); s = 1 - cov }
                let m = o + WaveBlend.meanSlot, t = o + WaveBlend.peakSlot
                er += cov * (amp[Int(blend[m])] * (1 - s) + amp[Int(blend[t])] * s)
                eg += cov * (amp[Int(blend[m + 1])] * (1 - s) + amp[Int(blend[t + 1])] * s)
                eb += cov * (amp[Int(blend[m + 2])] * (1 - s) + amp[Int(blend[t + 2])] * s)
                c += cov
            }
            guard c > 0 else { continue }
            let L = brightness(c / count)
            let rgb = color((er, eg, eb), weight: c, p)
            put(j, UInt8(rgb.r * L * 255), UInt8(rgb.g * L * 255), UInt8(rgb.b * L * 255), UInt8(L * 255))
        }
    }
}
