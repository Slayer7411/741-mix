import Foundation

/// Ganzzahl-Wandlung beim Schreiben: Float (±1 = Vollaussteuerung) auf 16 oder 24 Bit, optional mit TPDF-Dither.
/// Der Zufall ist ein fester Generator (SplitMix64): gleiche Eingabe, gleiche Datei.
public struct AudioDither: Sendable {
    private var state: UInt64

    public init(seed: UInt64 = 0x4D49_4E4F_3734_3121) { state = seed }

    /// gleichverteilt in [0, 1)
    public mutating func uniform() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    /// TPDF in LSB: Summe zweier gleichverteilter Werte aus [-0.5, 0.5), also dreieckig in (-1, 1)
    public mutating func tpdf() -> Double { (uniform() - 0.5) + (uniform() - 0.5) }

    /// Ganzzahl-Werte im Bereich der Bit-Tiefe (16: −32768 … 32767, 24: −8388608 … 8388607). `dither` nur bei 16 Bit
    /// sinnvoll; ohne Dither wird auf den nächsten Wert gerundet
    public static func quantize(_ x: UnsafePointer<Float>, count n: Int, bits: Int, dither: Bool, rng: inout AudioDither,
                                into out: UnsafeMutablePointer<Int32>) {
        let scale = bits == 16 ? 32768.0 : 8388608.0
        let hi = scale - 1, lo = -scale
        for i in 0..<n {
            var v = Double(x[i]) * scale
            if dither { v += rng.tpdf() }
            out[i] = Int32(min(hi, max(lo, v.rounded())))
        }
    }
}
