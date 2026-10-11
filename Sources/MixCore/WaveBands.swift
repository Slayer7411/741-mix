import Foundation

/// 3-Band-Wellenform aus dem feinen Spektrum: je Block eigene Höhe für Bass (< 250 Hz), Mitten (250 Hz – 4 kHz) und
/// Höhen (> 4 kHz) statt Farbanteilen. Effektivwert je Band gewichtet, gegen das stärkste Band gestaucht; das stärkste
/// Band reicht bis zur Spitze des Blocks (echter Pegel), die anderen liegen darin.
public enum WaveBands {
    /// Gewicht auf den Effektivwert (Bass = 1). Gemasterte Club-Tracks: Mitten ~10 dB, Höhen ~16 dB unter dem Bass
    /// (Perzentil 95, `SpectrumColors.nominal`); stärker angehoben deckten Hats und Shaker den Bass ganz zu
    public static let midGain: Float = 1.6
    public static let highGain: Float = 1.2
    /// Exponent auf das Verhältnis zum stärksten Band (< 1: leise Bänder etwas breiter, Bass bleibt vorn)
    public static let curve: Float = 0.9

    /// Höhen relativ zur Blockspitze (0…1), stärkstes Band = 1
    public struct Heights: Equatable, Sendable {
        public var low, mid, high: Float
        public init(low: Float, mid: Float, high: Float) { self.low = low; self.mid = mid; self.high = high }
        public static let zero = Heights(low: 0, mid: 0, high: 0)
    }

    /// Byte (0,5-dB-Schritte) → mittleres Quadrat
    static let power: [Float] = (0..<256).map { $0 == 0 ? 0 : powf(10, (Float($0) - 255) / 20) }

    /// mittlere Quadrate Bass / Mitten / Höhen eines Blocks (Summe der feinen Bänder)
    @inline(__always) public static func energy(_ s: WaveSpectrum, _ i: Int) -> (low: Float, mid: Float, high: Float) {
        let o = i * WaveSpectrum.stride
        return s.data.withUnsafeBufferPointer { d in
            (power[Int(d[o])] + power[Int(d[o + 1])], power[Int(d[o + 2])] + power[Int(d[o + 3])],
             power[Int(d[o + 4])] + power[Int(d[o + 5])])
        }
    }

    /// Höhen aus den mittleren Quadraten; `highBoost` multipliziert das Höhen-Gewicht (Einstellung Höhen-Betonung)
    public static func heights(low: Float, mid: Float, high: Float, highBoost: Float = 1) -> Heights {
        let a = low.squareRoot(), b = midGain * mid.squareRoot(), c = highGain * highBoost * high.squareRoot()
        let m = max(a, b, c)
        guard m > 1e-7 else { return .zero }
        return Heights(low: powf(a / m, curve), mid: powf(b / m, curve), high: powf(c / m, curve))
    }

    /// alle Blöcke; Höhen-Betonung 0…2 → Höhen-Gewicht ×0,5…×2
    public static func heights(_ s: WaveSpectrum, highBoost: Double = 1) -> [Heights] {
        let k = Float(pow(2, highBoost - 1))
        return (0..<s.count).map { i in
            let e = energy(s, i)
            return heights(low: e.low, mid: e.mid, high: e.high, highBoost: k)
        }
    }
}
