import Foundation
import Testing
import MixDSP

/// Kanalzug-EQ je Deck (Tief-Regal 100 Hz, Mitte 1 kHz, Höhen-Regal 10 kHz): 0 dB flach, Kill dämpft das Band,
/// Extremwerte bleiben endlich, Änderungen während des Spiels knacken nicht
private final class EQEngine {
    let e: OpaquePointer
    let fs = 44100.0
    private var tracks: [(UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>, Int)] = []

    init() { e = mdsp_create(fs) }
    deinit {
        mdsp_destroy(e)
        for t in tracks { t.0.deallocate(); t.1.deallocate() }
    }

    /// Sinus 0,5 auf Deck A, spielt ab sofort
    func sine(_ hz: Double, seconds: Double = 8) {
        let n = Int(seconds * fs)
        let l = UnsafeMutablePointer<Float>.allocate(capacity: n), r = UnsafeMutablePointer<Float>.allocate(capacity: n)
        for i in 0..<n { let v = Float(0.5 * sin(2 * .pi * hz * Double(i) / fs)); l[i] = v; r[i] = v }
        tracks.append((l, r, n))
        mdsp_set_track(e, 0, l, r, Int64(n), fs, 0)
        set(MD_PLAYING, 1)
    }

    func set(_ p: MDParam, _ v: Float) { mdsp_set_param(e, 0, p, v) }

    /// Block rendern: linker und rechter Kanal
    func render(_ n: Int = 512) -> ([Float], [Float]) {
        let bufs = (0..<2).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: n) }
        defer { bufs.forEach { $0.deallocate() } }
        var ptrs: [UnsafeMutablePointer<Float>?] = bufs.map { Optional($0) }
        ptrs.withUnsafeMutableBufferPointer { mdsp_render(e, $0.baseAddress, 2, Int32(n)) }
        return (Array(UnsafeBufferPointer(start: bufs[0], count: n)), Array(UnsafeBufferPointer(start: bufs[1], count: n)))
    }

    /// RMS des linken Kanals nach dem Einschwingen
    func rms(warm: Int = 20, blocks: Int = 40) -> Float {
        for _ in 0..<warm { _ = render() }
        var acc: Double = 0
        for _ in 0..<blocks { for v in render().0 { acc += Double(v) * Double(v) } }
        return Float((acc / Double(blocks * 512)).squareRoot())
    }
}

/// RMS eines Sinus mit Amplitude 0,5 (Pegel am Eingang des Kanals)
private let unityRMS = Float(0.5 / 2.0.squareRoot())

private func allFinite(_ x: [Float]) -> Bool { x.allSatisfy { $0.isFinite } }

/// größter Sprung zwischen zwei Abtastwerten
private func maxStep(_ x: [Float]) -> Float { zip(x, x.dropFirst()).map { abs($1 - $0) }.max() ?? 0 }

/// 0 dB ist flach: Tief, Mitte und Höhen kommen gleich laut an wie 1 kHz (die Kette selbst hat einen festen Pegel)
@Test func eqIsFlatAtZeroDb() {
    func level(_ hz: Double) -> Float {
        let c = EQEngine()
        c.sine(hz)
        c.set(MD_EQ_LOW, 0); c.set(MD_EQ_MID, 0); c.set(MD_EQ_HIGH, 0)
        return c.rms()
    }
    let ref = level(1000)
    for hz in [60.0, 10000] {
        let ratio = level(hz) / ref
        #expect(abs(ratio - 1) < 0.01, "\(hz) Hz gegen 1 kHz: Verhältnis \(ratio)")
    }
}

/// Kill (-40 dB) dämpft das gewählte Band um mehr als 25 dB (Mitte bei 1 kHz, Regale bei 40 Hz und 20 kHz)
@Test func eqKillAttenuatesItsBand() {
    let bands: [(MDParam, Double)] = [(MD_EQ_LOW, 40), (MD_EQ_MID, 1000), (MD_EQ_HIGH, 20000)]
    for (p, hz) in bands {
        let c = EQEngine()
        c.sine(hz)
        c.set(p, -40)
        let db = 20 * log10(c.rms() / unityRMS)
        #expect(db < -25, "Kill \(p) bei \(hz) Hz: \(db) dB")
    }
}

/// Extremwerte (±inf, NaN, weit außerhalb) ergeben keinen NaN am Ausgang, das Deck bleibt hörbar
@Test func eqStaysFiniteAtExtremes() {
    let c = EQEngine()
    c.sine(100)
    for v in [Float.infinity, -.infinity, .nan, -96, 60, 0] {
        c.set(MD_EQ_LOW, v); c.set(MD_EQ_MID, v); c.set(MD_EQ_HIGH, v)
        for _ in 0..<20 {
            let (l, r) = c.render()
            #expect(allFinite(l) && allFinite(r), "Wert \(v)")
        }
    }
    c.set(MD_EQ_LOW, 0); c.set(MD_EQ_MID, 0); c.set(MD_EQ_HIGH, 0)
    #expect(c.rms() > 0.1)
}

/// Änderung während des Spiels wird über ~15 ms gefahren: kein Sprung im Ausgang (Kill von 0 auf -40 dB)
@Test func eqChangeIsSmooth() {
    let c = EQEngine()
    c.sine(200)
    c.set(MD_EQ_LOW, 0); c.set(MD_EQ_MID, 0); c.set(MD_EQ_HIGH, 0)
    _ = c.rms()
    let base = maxStep(c.render(4096).0)
    c.set(MD_EQ_LOW, -40)
    let step = maxStep(c.render(4096).0)
    #expect(step < 2.5 * base, "Sprung \(step) gegen Grundlinie \(base)")
}
