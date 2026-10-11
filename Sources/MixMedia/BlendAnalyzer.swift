import Foundation
import MixCore

/// Band-Hüllkurven für den Stil „3-Band (Mischung)“: Mono → drei Zustandsvariablen-Filter (Chamberlin, Q 0,5) bei
/// 150 / 670 / 3000 Hz, davon Tiefpass / Bandpass / Hochpass, gleichgerichtet, Hüllkurve mit Anstieg und Abfall je
/// Band. Je Block: Effektivwert des Mono-Signals, gewichtete Hüllkurven im Mittel und am lautesten Sample.
public enum BlendAnalyzer {
    /// Mittenfrequenzen Tief / Mitte / Hoch (Mitte = geometrisches Mittel)
    public static let frequencies: [Double] = [150, 670, 3000]
    /// Anstieg / Abfall der Hüllkurven (s)
    public static let attack: [Double] = [0.010, 0.005, 0.0025]
    public static let release: [Double] = [0.100, 0.035, 0.025]
    /// Gewichte vor der Farbmischung
    public static let weights: [Float] = [0.6, 1.0, 1.2]
    /// Dämpfung der Filter (1/Q)
    static let damping: Float = 2
    /// Bandpass-Ausgang anheben (Spitze bei Dämpfung 2 = 0,5): ×1,4 ≈ −3 dB in der Mitte, Mitten bleiben neben Bass sichtbar
    static let midScale: Float = 1.4

    public static func analyze(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int, sampleRate: Double,
                               blocks: Int) -> WaveBlend {
        let block = TrackAudio.blockFrames(sampleRate: sampleRate)
        var out = [UInt8](repeating: 0, count: blocks * WaveBlend.stride)
        guard frames > 0, blocks > 0 else { return WaveBlend(data: out) }
        let f = frequencies.map { Float(2 * sin(Double.pi * min($0, sampleRate / 6) / sampleRate)) }
        let att = attack.map { Float(exp(-1 / (sampleRate * $0))) }, rel = release.map { Float(exp(-1 / (sampleRate * $0))) }
        let (f0, f1, f2) = (f[0], f[1], f[2]), q = damping
        let (w0, w1, w2) = (weights[0], weights[1], weights[2] )
        var lp0: Float = 0, bp0: Float = 0, lp1: Float = 0, bp1: Float = 0, lp2: Float = 0, bp2: Float = 0
        var e0: Float = 0, e1: Float = 0, e2: Float = 0
        @inline(__always) func follow(_ e: inout Float, _ x: Float, _ a: Float, _ r: Float) {
            let k = x > e ? a : r
            e = x + k * (e - x)
        }
        var i = 0
        out.withUnsafeMutableBufferPointer { o in
            for b in 0..<blocks {
                let end = min(frames, i + block)
                guard end > i else { break }
                var sq: Float = 0, s0: Float = 0, s1: Float = 0, s2: Float = 0
                var top: Float = -1, t0: Float = 0, t1: Float = 0, t2: Float = 0
                let n = end - i
                while i < end {
                    let x = (left[i] + right[i]) * 0.5
                    // Tief: Tiefpass 150 Hz
                    lp0 += f0 * bp0
                    bp0 += f0 * (x - lp0 - q * bp0)
                    // Mitte: Bandpass 670 Hz
                    lp1 += f1 * bp1
                    bp1 += f1 * (x - lp1 - q * bp1)
                    // Hoch: Hochpass 3 kHz
                    lp2 += f2 * bp2
                    let hp = x - lp2 - q * bp2
                    bp2 += f2 * hp
                    follow(&e0, abs(lp0), att[0], rel[0])
                    follow(&e1, abs(bp1 * midScale), att[1], rel[1])
                    follow(&e2, abs(hp), att[2], rel[2])
                    sq += x * x; s0 += e0; s1 += e1; s2 += e2
                    if abs(x) > top { top = abs(x); t0 = e0; t1 = e1; t2 = e2 }
                    i += 1
                }
                let c = 1 / Float(n), at = b * WaveBlend.stride
                o[at + WaveBlend.rmsSlot] = WaveBlend.byte(amplitude: (sq * c).squareRoot())
                o[at + WaveBlend.meanSlot] = WaveBlend.byte(amplitude: w0 * s0 * c)
                o[at + WaveBlend.meanSlot + 1] = WaveBlend.byte(amplitude: w1 * s1 * c)
                o[at + WaveBlend.meanSlot + 2] = WaveBlend.byte(amplitude: w2 * s2 * c)
                o[at + WaveBlend.peakSlot] = WaveBlend.byte(amplitude: w0 * t0)
                o[at + WaveBlend.peakSlot + 1] = WaveBlend.byte(amplitude: w1 * t1)
                o[at + WaveBlend.peakSlot + 2] = WaveBlend.byte(amplitude: w2 * t2)
            }
        }
        return WaveBlend(data: out)
    }
}
