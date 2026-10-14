import Foundation
import MixCore

/// Band-Hüllkurven für den Stil „3-Band (Mischung)“: Mono → drei Zustandsvariablen-Filter (Chamberlin, Q 0,5),
/// Standard 150 / 670 / 3000 Hz (`Params`), davon Tiefpass / Bandpass / Hochpass, gleichgerichtet, Hüllkurve mit Anstieg
/// und Abfall je Band. Je Block: Effektivwert des Mono-Signals, gewichtete Hüllkurven im Mittel und am lautesten Sample.
public enum BlendAnalyzer {
    public typealias Params = BlendParams
    /// Dämpfung der Filter (1/Q)
    static let damping: Float = 2
    /// Bandpass-Ausgang anheben (Spitze bei Dämpfung 2 = 0,5): ×1,4 ≈ −3 dB in der Mitte, Mitten bleiben neben Bass sichtbar
    static let midScale: Float = 1.4

    public static func analyze(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int, sampleRate: Double,
                               blocks: Int, params: Params = .standard) -> WaveBlend {
        analyze(left: left, right: right, frames: frames, sampleRate: sampleRate, blocks: blocks, params: params, cancelled: nil)!
    }

    /// wie oben, `cancelled` alle 512 Blöcke gefragt: true -> nil
    public static func analyze(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int, sampleRate: Double,
                               blocks: Int, params: Params, cancelled: (() -> Bool)?) -> WaveBlend? {
        let block = TrackAudio.blockFrames(sampleRate: sampleRate)
        var out = [UInt8](repeating: 0, count: blocks * WaveBlend.stride)
        guard frames > 0, blocks > 0 else { return WaveBlend(data: out) }
        let f = [params.low, params.midHz, params.high].map { Float(2 * sin(Double.pi * max(1, min($0, sampleRate / 6)) / sampleRate)) }
        let a = params.attackMs, r = params.releaseMs
        let coef = { (ms: Double) in Float(exp(-1 / (sampleRate * (max(0.01, ms) / 1000)))) }
        let att = [a.low, a.mid, a.high].map(coef), rel = [r.low, r.mid, r.high].map(coef)
        let (f0, f1, f2) = (f[0], f[1], f[2]), q = damping
        let (w0, w1, w2) = (params.weights.low, params.weights.mid, params.weights.high)
        var lp0: Float = 0, bp0: Float = 0, lp1: Float = 0, bp1: Float = 0, lp2: Float = 0, bp2: Float = 0
        var e0: Float = 0, e1: Float = 0, e2: Float = 0
        @inline(__always) func follow(_ e: inout Float, _ x: Float, _ a: Float, _ r: Float) {
            let k = x > e ? a : r
            e = x + k * (e - x)
        }
        var i = 0, stopped = false
        out.withUnsafeMutableBufferPointer { o in
            for b in 0..<blocks {
                if let cancelled, b & 511 == 0, cancelled() { stopped = true; break }
                let end = min(frames, i + block)
                guard end > i else { break }
                var sq: Float = 0, s0: Float = 0, s1: Float = 0, s2: Float = 0
                var top: Float = -1, t0: Float = 0, t1: Float = 0, t2: Float = 0
                let n = end - i
                while i < end {
                    let x = (left[i] + right[i]) * 0.5
                    // Tief: Tiefpass
                    lp0 += f0 * bp0
                    bp0 += f0 * (x - lp0 - q * bp0)
                    // Mitte: Bandpass
                    lp1 += f1 * bp1
                    bp1 += f1 * (x - lp1 - q * bp1)
                    // Hoch: Hochpass
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
        return stopped ? nil : WaveBlend(data: out)
    }
}
