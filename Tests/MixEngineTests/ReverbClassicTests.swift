import Foundation
import Testing
import MixDSP

/// Reverb (Allpass-Ring, Standardtyp) offline: Nachhall über die Größe, Klangneigung der Fahne, Stereo, Freeze,
/// NaN/Denormal, D/W 0 = trocken. Vergleichswerte des FDN stehen in der Ausgabe ([classic] … · fdn …).
private final class Rig {
    let e: OpaquePointer
    let fs: Double
    let l: UnsafeMutablePointer<Float>, r: UnsafeMutablePointer<Float>
    var bufs: [UnsafeMutablePointer<Float>?]

    init(seconds: Double, fs: Double = 44100, fdn: Bool = false, make: (Int) -> (Float, Float)) {
        self.fs = fs
        e = mdsp_create(fs)
        let n = Int(seconds * fs)
        l = .allocate(capacity: n); r = .allocate(capacity: n)
        for i in 0..<n { (l[i], r[i]) = make(i) }
        bufs = [.allocate(capacity: 512), .allocate(capacity: 512)]
        mdsp_set_track(e, 0, l, r, Int64(n), fs, 0)
        _ = capture(512.0 / fs)
        mdsp_set_param(e, 0, MD_FX1_ASSIGN, 1)
        setRack(e, 0, groupRack)
        fx(MDFX_REVERB_TYPE, fdn ? 1 : 0)
    }
    deinit { mdsp_destroy(e); l.deallocate(); r.deallocate(); bufs.forEach { $0?.deallocate() } }

    func fx(_ p: MDFXParam, _ v: Float) { mdsp_set_fx(e, 0, p, v) }
    func play(_ on: Bool) { mdsp_set_param(e, 0, MD_PLAYING, on ? 1 : 0) }
    /// Gruppenmodus: Hall-Anteil = amount × D/W, Eingang voll
    func group(size: Float, dw: Float = 1) {
        fx(MDFX_REVERB_AMOUNT, 1); fx(MDFX_DRYWET, dw); fx(MDFX_REVERB_SIZE, size)
        fx(MDFX_REVERB_HP, 0); fx(MDFX_REVERB_LP, 1); fx(MDFX_REVERB_DWSEND, 0)
    }
    func capture(_ seconds: Double) -> ([Float], [Float]) {
        var a: [Float] = [], b: [Float] = []
        for _ in 0..<Int(seconds * fs / 512) {
            bufs.withUnsafeMutableBufferPointer { mdsp_render(e, $0.baseAddress, 2, 512) }
            a += UnsafeBufferPointer(start: bufs[0], count: 512); b += UnsafeBufferPointer(start: bufs[1], count: 512)
        }
        return (a, b)
    }
}

private func white(_ s: UInt32) -> () -> Float {
    var seed = s
    return { seed = seed &* 1664525 &+ 1013904223; return (Float(seed >> 8) / Float(1 << 24) - 0.5) * 0.6 }
}
private func rms(_ x: ArraySlice<Float>) -> Double { var s = 0.0; for v in x { s += Double(v) * Double(v) }; return (s / Double(max(1, x.count))).squareRoot() }
private func db(_ x: Double) -> Double { 20 * log10(max(x, 1e-12)) }

/// Nachhallzeit: 10-ms-Fenster, Regression −5 … −35 dB
private func rt60(_ x: [Float], fs: Double) -> Double {
    let w = Int(0.01 * fs)
    var env: [Double] = [], i = 0
    while i + w <= x.count { env.append(db(rms(x[i..<i + w]))); i += w }
    guard let e0 = env.prefix(5).max() else { return 0 }
    var xs: [Double] = [], ys: [Double] = []
    for (k, v) in env.enumerated() {
        if v > e0 - 5 { continue }
        if v < e0 - 35 { break }
        xs.append(Double(k) * 0.01); ys.append(v)
    }
    guard xs.count > 5 else { return 0 }
    let mx = xs.reduce(0, +) / Double(xs.count), my = ys.reduce(0, +) / Double(ys.count)
    var num = 0.0, den = 0.0
    for k in xs.indices { num += (xs[k] - mx) * (ys[k] - my); den += (xs[k] - mx) * (xs[k] - mx) }
    return num < 0 ? -60 / (num / den) : .infinity
}

/// Energie je Band (Hann, ein FFT-Fenster ab Anfang, Länge Zweierpotenz)
private func bands(_ x: [Float], fs: Double, _ ranges: [(Double, Double)]) -> [Double] {
    var n = 1; while n * 2 <= x.count { n *= 2 }
    var re = (0..<n).map { Double(x[$0]) * (0.5 - 0.5 * cos(2 * .pi * Double($0) / Double(n))) }, im = [Double](repeating: 0, count: n)
    var j = 0
    for i in 1..<n {
        var bit = n >> 1
        while j & bit != 0 { j ^= bit; bit >>= 1 }
        j |= bit
        if i < j { re.swapAt(i, j); im.swapAt(i, j) }
    }
    var len = 2
    while len <= n {
        let ang = -2 * Double.pi / Double(len)
        for i in stride(from: 0, to: n, by: len) {
            for k in 0..<len / 2 {
                let c = cos(ang * Double(k)), s = sin(ang * Double(k)), a = i + k, b = i + k + len / 2
                let tr = re[b] * c - im[b] * s, ti = re[b] * s + im[b] * c
                re[b] = re[a] - tr; im[b] = im[a] - ti; re[a] += tr; im[a] += ti
            }
        }
        len <<= 1
    }
    let bin = fs / Double(n)
    return ranges.map { lo, hi in (Int(lo / bin)...min(n / 2 - 1, Int(hi / bin))).reduce(0.0) { $0 + re[$1] * re[$1] + im[$1] * im[$1] } }
}

private func corr(_ a: [Float], _ b: [Float]) -> Double {
    var ab = 0.0, aa = 0.0, bb = 0.0
    for i in 0..<min(a.count, b.count) { ab += Double(a[i]) * Double(b[i]); aa += Double(a[i]) * Double(a[i]); bb += Double(b[i]) * Double(b[i]) }
    return ab / max(1e-30, (aa * bb).squareRoot())
}

/// weißes Rauschen (mono) 1 s in den Hall, Deck stoppen, Fahne aufnehmen
private func tail(size: Float, fdn: Bool, fs: Double = 44100, seconds: Double = 8) -> ([Float], [Float]) {
    let w = white(4242)
    let r = Rig(seconds: 2, fs: fs, fdn: fdn) { _ in let v = w(); return (v, v) }
    r.group(size: size); r.fx(MDFX_REVERB_ON, 1)
    r.play(true); _ = r.capture(1)
    r.play(false)
    return r.capture(seconds)
}

@Test func reverbClassicRT60RisesWithSize() {
    var last = 0.0
    for size: Float in [0.2, 0.5, 0.9] {
        let (a, b) = tail(size: size, fdn: false, seconds: 12)
        let t = rt60(zip(a, b).map { ($0 + $1) / 2 }, fs: 44100)
        let (fa, fb) = tail(size: size, fdn: true, seconds: size > 0.8 ? 30 : 12)
        let tf = rt60(zip(fa, fb).map { ($0 + $1) / 2 }, fs: 44100)
        print(String(format: "[classic] size %.1f · RT60 %.2f s · fdn %.2f s", size, t, tf))
        #expect(t > last * 1.3 && t.isFinite)
        last = t
    }
    #expect(last > 3 && last < 12)
}

/// nicht blechern: 300 ms nach dem Stopp viel weniger Energie über 4 kHz als 200 Hz … 2 kHz (Eingang: weiß, dort +10 dB)
@Test func reverbClassicTailIsDark() {
    for size: Float in [0.3, 0.6, 0.9] {
        func tilt(_ fdn: Bool) -> Double {
            let (a, b) = tail(size: size, fdn: fdn, seconds: 1.2)
            let s = Array(zip(a, b).map { ($0 + $1) / 2 }[Int(0.3 * 44100)...])
            let e = bands(s, fs: 44100, [(200, 2000), (4000, 20000)])
            return 10 * log10(e[1] / e[0])
        }
        let t = tilt(false), tf = tilt(true)
        print(String(format: "[classic] size %.1f · tail >4 kHz re 200 Hz–2 kHz %.1f dB · fdn %.1f dB", size, t, tf))
        #expect(t < -6)
    }
}

@Test func reverbClassicStereoDecorrelated() {
    for size: Float in [0.2, 0.6, 0.9] {
        let (a, b) = tail(size: size, fdn: false, seconds: 1.5)
        let c = corr(Array(a[Int(0.1 * 44100)...]), Array(b[Int(0.1 * 44100)...]))
        let (fa, fb) = tail(size: size, fdn: true, seconds: 1.5)
        let cf = corr(Array(fa[Int(0.1 * 44100)...]), Array(fb[Int(0.1 * 44100)...]))
        print(String(format: "[classic] size %.1f · corr L/R %.3f · fdn %.3f", size, c, cf))
        #expect(abs(c) < 0.3)
    }
}

/// Freeze: Eingang zu, Fahne steht – kein Anwachsen, kaum Verlust (Höhen über 10 kHz gehen beim Lesen langsam verloren);
/// aus = klingt wieder ab. 44,1 / 96 / 192 kHz, Rauschen unter ~10 kHz
@Test func reverbClassicFreezeHolds() {
    for fs in [44100.0, 96000.0, 192000.0] {
        for size: Float in [0, 0.5, 1] {
            let w = white(7), a1 = Float(1 - exp(-2 * Double.pi * 10000 / fs))
            var lp: Float = 0
            let r = Rig(seconds: 3, fs: fs) { _ in lp += a1 * (w() - lp); return (lp, lp) }
            r.group(size: size); r.fx(MDFX_REVERB_ON, 1)
            r.play(true); _ = r.capture(1.5)
            r.fx(MDFX_REVERB_FREEZE, 1); _ = r.capture(0.3)
            r.play(false)
            let (a, _) = r.capture(1)
            _ = r.capture(8)
            let (b, _) = r.capture(1)
            r.fx(MDFX_REVERB_FREEZE, 0)
            _ = r.capture(size == 1 ? 25 : 10)
            let (c, _) = r.capture(1)
            let ra = rms(a[...]), rb = rms(b[...]), rc = rms(c[...])
            print(String(format: "[classic] freeze %.0f Hz size %.1f: rms %.4f -> 9 s %.4f (%+.2f dB) · released %.1f dB",
                         fs, size, ra, rb, db(rb / ra), db(rc / ra)))
            #expect(a.allSatisfy { $0.isFinite } && b.allSatisfy { $0.isFinite })
            #expect(ra > 1e-3 && rb <= ra * 1.06 && rb > ra * 0.84)   // 9 s: −1,5 … +0,5 dB (Größe 0: wenige Moden, Pegel schwankt ±0,3 dB)
            #expect(rc < ra * 0.05)
        }
    }
}

/// ausklingend bis Stille: endlich, keine Denormals am Ausgang, danach wird nicht mehr gerechnet (Ausgang exakt 0)
@Test func reverbClassicNoNaNNoDenormal() {
    for fs in [44100.0, 48000.0, 96000.0] {
        let w = white(99)
        let r = Rig(seconds: 2, fs: fs) { i in let v = w(); return (i % 4410 == 0 ? 1 : v, v) }
        r.group(size: 0.4); r.fx(MDFX_REVERB_ON, 1); r.fx(MDFX_REVERB_HP, 0.6); r.fx(MDFX_REVERB_LP, 0.2)
        r.play(true); _ = r.capture(1)
        r.fx(MDFX_REVERB_ON, 0); r.play(false)
        let (a, b) = r.capture(25)
        let bad = (a + b).filter { !$0.isFinite || ($0 != 0 && abs($0) < Float.leastNormalMagnitude) }.count
        print(String(format: "[classic] %.0f Hz: %d bad samples, last second rms %.2e", fs, bad, rms(a.suffix(Int(fs)))))
        #expect(bad == 0)
        #expect(a.suffix(Int(fs)).allSatisfy { $0 == 0 })
    }
}

/// D/W 0: Ausgang bitgleich trocken (Gruppe: Hall-Anteil 0; Single: nichts geht in den Hall)
@Test func reverbClassicDryWetZeroIsDry() {
    for single in [false, true] {
        func run(_ on: Bool) -> [Float] {
            let w = white(3)
            let r = Rig(seconds: 3) { _ in let v = w(); return (v, -v) }
            r.group(size: 0.7, dw: 0)
            if single { r.fx(MDFX_REVERB_DWSEND, 1); r.fx(MDFX_REVERB_HP, 0.4) }
            r.fx(MDFX_REVERB_ON, on ? 1 : 0)
            r.play(true)
            let (a, b) = r.capture(2)
            return a + b
        }
        let dry = run(false), wet = run(true)
        #expect(dry.count == wet.count && zip(dry, wet).allSatisfy { $0.bitPattern == $1.bitPattern })
    }
}

/// Typ wechseln, während der Hall läuft: der alte klingt aus, der neue übernimmt, kein Sprung
@Test func reverbTypeSwitchRingsOut() {
    let w = white(11)
    let r = Rig(seconds: 4) { _ in let v = w(); return (v, v) }
    r.group(size: 0.6); r.fx(MDFX_REVERB_ON, 1)
    r.play(true); _ = r.capture(1)
    r.fx(MDFX_REVERB_TYPE, 1)
    let (a, _) = r.capture(1)
    r.play(false)
    let (b, _) = r.capture(1)
    #expect(a.allSatisfy { $0.isFinite && abs($0) < 4 } && rms(b[...]) > 1e-3)
}

/// Rechenzeit je Block (MIX741_BENCH=1): 1 Deck, Hall an, 512 Frames, Allpass-Ring vs. FDN
@Test(.enabled(if: ProcessInfo.processInfo.environment["MIX741_BENCH"] == "1"))
func reverbClassicCPU() {
    for fdn in [false, true] {
        let w = white(5)
        let r = Rig(seconds: 70, fdn: fdn) { _ in let v = w(); return (v, v) }
        r.group(size: 0.6); r.fx(MDFX_REVERB_ON, 1)
        r.play(true)
        for _ in 0..<200 { r.bufs.withUnsafeMutableBufferPointer { mdsp_render(r.e, $0.baseAddress, 2, 512) } }
        let count = 4000, t0 = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<count { r.bufs.withUnsafeMutableBufferPointer { mdsp_render(r.e, $0.baseAddress, 2, 512) } }
        let us = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1000 / Double(count)
        print(String(format: "[classic] cpu 1 deck reverb %@ · 512 frames · %.1f µs/block", fdn ? "fdn    " : "classic", us))
    }
}
