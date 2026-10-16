import Foundation
import Testing
import MixDSP

/// Null-Test: Deck neutral (Tempo 1, kein Keylock, EQ 0 dB, kein Filter, Lautstärke 1) -> Ausgang = Quelle?
/// Misst Versatz (Frames), Pegel (dB) und Restfehler nach Abzug. Main-Volume 1 (das Main ist ein Regler, kein fester Abzug).
@Test func deckOutputEqualsSource() {
    let fs = 44100.0, frames = 44100 * 6
    let L = UnsafeMutablePointer<Float>.allocate(capacity: frames), R = UnsafeMutablePointer<Float>.allocate(capacity: frames)
    defer { L.deallocate(); R.deallocate() }
    var seed: UInt64 = 7
    func rnd() -> Float { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Float(Int64(bitPattern: seed >> 11) % 1_000_000) / 1_000_000 }
    for i in 0..<frames { L[i] = (rnd() - 0.5) * 0.5; R[i] = (rnd() - 0.5) * 0.5 }
    let e = mdsp_create(fs)!
    defer { mdsp_destroy(e) }
    mdsp_set_master(e, 1)   // Main 1 (Voreinstellung 0,85 = −1,4 dB)
    mdsp_set_param(e, 0, MD_VOLUME, 1)
    mdsp_set_param(e, 0, MD_RATE, 1)
    mdsp_set_param(e, 0, MD_OUT_CHANNEL, 0)
    mdsp_set_track(e, 0, L, R, Int64(frames), fs, 1.0)
    mdsp_set_param(e, 0, MD_PLAYING, 1)
    let n = 512, blocks = 300
    var outL: [Float] = [], outR: [Float] = []
    let ptrs = (0..<4).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: n) }
    defer { ptrs.forEach { $0.deallocate() } }
    for _ in 0..<blocks {
        var chans: [UnsafeMutablePointer<Float>?] = ptrs
        chans.withUnsafeMutableBufferPointer { mdsp_render(e, $0.baseAddress, 4, Int32(n)) }
        outL += UnsafeBufferPointer(start: ptrs[0], count: n); outR += UnsafeBufferPointer(start: ptrs[1], count: n)
    }
    // Versatz suchen: Ausgang ab Block 20 gegen Quelle ab 1 s + Versatz
    let probe = 20 * n, len = 44100
    var best = (off: 0, err: Float.infinity, gain: Float(0))
    for off in -4096...4096 {
        let s0 = Int(fs) + probe + off
        guard s0 >= 0, s0 + len < frames else { continue }
        var dot: Float = 0, ee: Float = 0
        for i in stride(from: 0, to: len, by: 7) { dot += outL[probe + i] * L[s0 + i]; ee += L[s0 + i] * L[s0 + i] }
        let g = dot / max(ee, 1e-12)
        var err: Float = 0
        for i in stride(from: 0, to: len, by: 7) { let d = outL[probe + i] - g * L[s0 + i]; err += d * d }
        if err < best.err { best = (off, err, g) }
    }
    let s0 = Int(fs) + probe + best.off
    var maxRaw: Float = 0, maxRes: Float = 0, rms: Float = 0
    for i in 0..<len {
        maxRaw = max(maxRaw, abs(outL[probe + i] - L[s0 + i]), abs(outR[probe + i] - R[s0 + i]))
        maxRes = max(maxRes, abs(outL[probe + i] - best.gain * L[s0 + i]))
        rms += L[s0 + i] * L[s0 + i]
    }
    for w in [20, 60, 120, 240] {   // Fehler je Abschnitt (Blöcke ab Start): klingt er ab?
        let p0 = w * n, q0 = Int(fs) + p0 + best.off
        var m: Float = 0, mr: Float = 0
        for i in 0..<(4 * n) where q0 + i < frames && p0 + i < outL.count { m = max(m, abs(outL[p0 + i] - L[q0 + i])); mr = max(mr, abs(outR[p0 + i] - R[q0 + i])) }
        print(String(format: "[null] ab block %d: L %.2e R %.2e", w, m, mr))
    }
    print(String(format: "[null] versatz %d frames · pegel %.4f (%.3f dB) · max |aus-quelle| %.2e · nach pegel %.2e · quelle rms %.3f",
                 best.off, best.gain, 20 * log10(Double(best.gain)), maxRaw, maxRes, sqrt(rms / Float(len))))
    #expect(best.off == 0)
    #expect(abs(best.gain - 1) < 1e-4)
    #expect(maxRaw == 0)   // bit-genau: Tempo 1 liest die Samples unverändert
}
