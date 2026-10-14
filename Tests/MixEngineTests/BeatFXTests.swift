import Foundation
import Testing
import MixDSP

/// Beat-FX offline (Gater, Roll, Flanger, Phaser): Raster der Clock, Wiederholung, wandernde Kerben, Ein/Aus ohne Knacken,
/// D/W 0 = trocken, NaN/Denormal bei 44,1/48/96 kHz
private final class Rig {
    let e: OpaquePointer
    let fs: Double
    let l: UnsafeMutablePointer<Float>, r: UnsafeMutablePointer<Float>
    var bufs: [UnsafeMutablePointer<Float>?]

    init(seconds: Double, fs: Double = 44100, bpm: Double = 125, make: (Int) -> (Float, Float)) {
        self.fs = fs
        e = mdsp_create(fs)
        let n = Int(seconds * fs)
        l = .allocate(capacity: n); r = .allocate(capacity: n)
        for i in 0..<n { (l[i], r[i]) = make(i) }
        bufs = [.allocate(capacity: 512), .allocate(capacity: 512)]
        mdsp_set_track(e, 0, l, r, Int64(n), fs, 0)
        _ = capture(512.0 / fs)
        mdsp_set_param(e, 0, MD_FX1_ASSIGN, 1)
        setRack(e, 0, beatRack)
        mdsp_clock_set_bpm(e, bpm)
        mdsp_clock_set_beat(e, 0)   // übernimmt der nächste Block: Sample 0 = Beat 0
    }
    deinit { mdsp_destroy(e); l.deallocate(); r.deallocate(); bufs.forEach { $0?.deallocate() } }

    func fx(_ p: MDFXParam, _ v: Float) { mdsp_set_fx(e, 0, p, v) }
    func play(_ on: Bool) { mdsp_set_param(e, 0, MD_PLAYING, on ? 1 : 0) }
    func capture(_ seconds: Double) -> ([Float], [Float]) {
        var a: [Float] = [], b: [Float] = []
        for _ in 0..<Int((seconds * fs / 512).rounded()) {
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

private enum Effect: CaseIterable { case gater, roll, flanger, phaser }

private extension Rig {
    func set(_ fx: Effect, on: Bool) {
        switch fx {
        case .gater: self.fx(MDFX_GATER_ON, on ? 1 : 0)
        case .roll: self.fx(MDFX_ROLL_ON, on ? 1 : 0)
        case .flanger: self.fx(MDFX_FLANGER_ON, on ? 1 : 0)
        case .phaser: self.fx(MDFX_PHASER_ON, on ? 1 : 0)
        }
    }
}

/// Gater 1/4 Beat, offen ½: Pegel geht im Raster auf und zu, ±1 ms (44,1 und 96 kHz)
@Test(arguments: [44100.0, 96000.0])
func gaterFollowsBeatDivider(fs: Double) {
    let r = Rig(seconds: 3, fs: fs, bpm: 120) { _ in (0.5, 0.5) }
    r.fx(MDFX_GATER_BEATS, 0.25); r.fx(MDFX_GATER_WIDTH, 0.5); r.fx(MDFX_GATER_SHAPE, 0); r.fx(MDFX_GATER_ON, 1)
    r.play(true)
    let (a, _) = r.capture(2)
    let spb = fs / 2   // 120 BPM
    let open = a[Int(0.3 * fs)..<Int(0.4 * fs)].max() ?? 0, half = open / 2
    #expect(open > 0.4 && a[Int(0.3 * fs)..<Int(0.4 * fs)].min()! < open * 0.01)
    var worst = 0.0, edges = 0
    for k in 4..<12 {   // ab Beat 1 (Lautstärke-Rampe des Decks vorbei)
        for (frac, rising) in [(0.0, true), (0.125, false)] {
            let want = (Double(k) * 0.25 + frac) * spb
            let lo = Int(want - 0.004 * fs), hi = Int(want + 0.004 * fs)
            guard let i = (lo..<hi).first(where: { rising ? a[$0] >= half && a[$0 - 1] < half : a[$0] <= half && a[$0 - 1] > half })
            else { Issue.record("keine Flanke bei Beat \(Double(k) * 0.25 + frac)"); continue }
            worst = max(worst, abs(Double(i) - want) / fs * 1000)
            edges += 1
        }
    }
    print(String(format: "[beatfx] gater %.0f kHz: %d Flanken, größte Abweichung vom Raster %.3f ms", fs / 1000, edges, worst))
    #expect(edges == 16 && worst <= 1)
}

/// Roll: Ausgang wiederholt genau die Länge (Autokorrelation, auch rückwärts); aus = Live-Signal dort, wo das Deck inzwischen ist
@Test func rollRepeatsExactLength() {
    for reverse in [false, true] {
        let w = white(3)
        let make: (Int) -> (Float, Float) = { _ in let v = w(); return (v, v) }
        let r = Rig(seconds: 4, make: make)
        let w2 = white(3)
        let dry = Rig(seconds: 4) { _ in let v = w2(); return (v, v) }
        r.fx(MDFX_ROLL_BEATS, 0.25); r.fx(MDFX_ROLL_REVERSE, reverse ? 1 : 0)
        r.play(true); dry.play(true)
        _ = r.capture(0.5); _ = dry.capture(0.5)
        r.fx(MDFX_ROLL_ON, 1)
        let (a, _) = r.capture(1.5)
        _ = dry.capture(1.5)
        let len = Int((0.25 * 60 / 125 * r.fs).rounded())   // 5292
        let seg = Array(a[Int(0.5 * r.fs)..<Int(0.5 * r.fs) + 3 * len])
        func corr(_ lag: Int) -> Double {
            var xy = 0.0, xx = 0.0, yy = 0.0
            for i in 0..<(seg.count - lag) { let x = Double(seg[i]), y = Double(seg[i + lag]); xy += x * y; xx += x * x; yy += y * y }
            return xy / max(1e-12, (xx * yy).squareRoot())
        }
        var best = 0, bestC = -1.0
        for lag in (len - 300)...(len + 300) { let c = corr(lag); if c > bestC { bestC = c; best = lag } }
        let half = corr(len / 2), off = corr(len + 301)
        print(String(format: "[beatfx] roll%@ 1/4 Beat: beste Wiederholung %d Frames (Soll %d), Korrelation %.4f, bei ½ Länge %.3f, Länge + 301 %.3f",
                     reverse ? " rückwärts" : "", best, len, bestC, half, off))
        #expect(best == len && bestC > 0.97 && abs(half) < 0.2 && abs(off) < 0.2)
        // aus: nach der Rampe bitgleich mit einem Deck ohne Roll (gleiche Position)
        r.fx(MDFX_ROLL_ON, 0)
        _ = r.capture(0.2); _ = dry.capture(0.2)
        let (x, _) = r.capture(0.2), (y, _) = dry.capture(0.2)
        #expect(x == y)
    }
}

/// nass (mit Effekt) und trocken, gleiches Rauschen, 120 BPM
private func wetDry(_ setup: (Rig) -> Void) -> ([Float], [Float]) {
    let w = white(9), w2 = white(9)
    let r = Rig(seconds: 4, bpm: 120) { _ in let v = w(); return (v, v) }
    let d = Rig(seconds: 4, bpm: 120) { _ in let v = w2(); return (v, v) }
    setup(r)
    r.play(true); d.play(true)
    return (r.capture(3).0, d.capture(3).0)
}

/// Flanger: Verzögerung (erste Kerbe 1/(2d)) aus der Kreuzkorrelation nass − ½ trocken gegen trocken. Raster: Periode 2 bzw. 4 Beats
@Test func flangerNotchesFollowRate() {
    func delayAt(_ wet: [Float], _ dry: [Float], _ t: Double) -> Double {
        let c = Int(t * 44100), n = 1024
        var best = 0, bv = -Double.infinity
        for lag in 8...420 {
            var s = 0.0
            for i in (c - n / 2)..<(c + n / 2) { s += Double(wet[i] - 0.5 * dry[i]) * Double(dry[i - lag]) }
            if s > bv { bv = s; best = lag }
        }
        return Double(best)
    }
    for period: Float in [2, 4] {
        let (wet, dry) = wetDry { r in
            r.fx(MDFX_FLANGER_BEATS, period); r.fx(MDFX_FLANGER_DEPTH, 1); r.fx(MDFX_FLANGER_FEEDBACK, 0); r.fx(MDFX_FLANGER_SPREAD, 0)
            r.fx(MDFX_FLANGER_ON, 1)
        }
        let notch = [1.0, 1.5, 2.0, 2.5].map { 44100 / (2 * delayAt(wet, dry, $0)) }
        print(String(format: "[beatfx] flanger Periode %.0f Beats: erste Kerbe bei 1,0 / 1,5 / 2,0 / 2,5 s = %.0f / %.0f / %.0f / %.0f Hz",
                     period, notch[0], notch[1], notch[2], notch[3]))
        if period == 2 {   // Periode 1 s: auf dem Teiler oben (0,3 ms), dazwischen unten (8 ms)
            #expect(abs(notch[0] / 1667 - 1) < 0.15 && abs(notch[2] / 1667 - 1) < 0.15)
            #expect(abs(notch[1] / 62.5 - 1) < 0.15 && abs(notch[3] / 62.5 - 1) < 0.15)
        } else {           // Periode 2 s: bei 1 s unten, bei 2 s oben, dazwischen in der Mitte
            #expect(abs(notch[0] / 62.5 - 1) < 0.15 && abs(notch[2] / 1667 - 1) < 0.15)
            #expect(notch[1] > 150 && notch[1] < 700 && notch[3] > 150 && notch[3] < 700)
        }
    }
}

/// Phaser (4 Stufen): tiefste Stelle von |nass ÷ trocken| zwischen 200 Hz und 8 kHz, Kerbe bei 0,414 × Eckfrequenz (130 Hz … 6,2 kHz)
@Test func phaserNotchesFollowRate() {
    func notchAt(_ wet: [Float], _ dry: [Float], _ t: Double) -> Double {
        let n = 4096, c = Int(t * 44100) - n / 2
        func spec(_ x: [Float]) -> [Double] {
            var re = (0..<n).map { Double(x[c + $0]) * (0.5 - 0.5 * cos(2 * .pi * Double($0) / Double(n))) }, im = [Double](repeating: 0, count: n)
            fft(&re, &im)
            return (0..<n / 2).map { re[$0] * re[$0] + im[$0] * im[$0] }
        }
        let sw = spec(wet), sd = spec(dry)
        let lo = Int(200.0 * Double(n) / 44100), hi = Int(8000.0 * Double(n) / 44100)
        var best = lo, bv = Double.infinity
        for k in lo...hi {
            var a = 0.0, b = 0.0
            for j in (k - 3)...(k + 3) { a += sw[j]; b += sd[j] }
            if a / b < bv { bv = a / b; best = k }
        }
        return Double(best) * 44100 / Double(n)
    }
    for period: Float in [2, 4] {
        let (wet, dry) = wetDry { r in
            r.fx(MDFX_PHASER_BEATS, period); r.fx(MDFX_PHASER_DEPTH, 1); r.fx(MDFX_PHASER_FEEDBACK, 0); r.fx(MDFX_PHASER_STAGES, 4)
            r.fx(MDFX_PHASER_ON, 1)
        }
        let notch = [1.0, 1.5, 2.0, 2.5].map { notchAt(wet, dry, $0) }
        print(String(format: "[beatfx] phaser Periode %.0f Beats: Kerbe bei 1,0 / 1,5 / 2,0 / 2,5 s = %.0f / %.0f / %.0f / %.0f Hz",
                     period, notch[0], notch[1], notch[2], notch[3]))
        if period == 2 {
            #expect(abs(notch[0] / 314 - 1) < 0.2 && abs(notch[2] / 314 - 1) < 0.2)
            #expect(abs(notch[1] / 2567 - 1) < 0.2 && abs(notch[3] / 2567 - 1) < 0.2)
        } else {
            #expect(abs(notch[0] / 2567 - 1) < 0.2 && abs(notch[2] / 314 - 1) < 0.2)
        }
    }
}

/// Ein/Aus mit Sinus 220 Hz: kein Sprung (zweite Differenz < −40 dBFS) in den 20 ms nach dem Schalten
@Test func beatFXToggleWithoutClick() {
    for fx in Effect.allCases {
        let r = Rig(seconds: 4, bpm: 120) { i in let v = Float(0.5 * sin(2 * Double.pi * 220 * Double(i) / 44100)); return (v, v) }
        r.fx(MDFX_ROLL_BEATS, 0.25); r.fx(MDFX_FLANGER_FEEDBACK, 0.8); r.fx(MDFX_PHASER_FEEDBACK, 0.8)
        r.play(true)
        _ = r.capture(0.5)
        func worst(_ a: [Float], _ n: Int) -> Float {
            var m: Float = 0
            for i in 2..<n { m = max(m, abs(a[i] - 2 * a[i - 1] + a[i - 2])) }
            return m
        }
        let w = Int(0.02 * 44100)
        r.set(fx, on: true)
        let (on, _) = r.capture(1.0)
        // aus bei Gater-Phase ~0,75 (Tor zu, nächste Flanke 30 ms später): Beat ≈ k + 0,1875
        let beat = mdsp_clock_beat(r.e), next = (beat * 4).rounded(.up) / 4 + 0.1875
        _ = r.capture((next - beat) / 2)
        r.set(fx, on: false)
        let (off, _) = r.capture(0.3)
        print(String(format: "[beatfx] %@ zweite Differenz nach ein %.4f · aus %.4f (Sinus allein 0.0004, Grenze 0.0100)", "\(fx)", worst(on, w), worst(off, w)))
        #expect(worst(on, w) < 0.01 && worst(off, w) < 0.01)
    }
}

/// D/W 0 (oder Anteil 0): Ausgang bitgleich mit einem Deck ohne Effekt
@Test func beatFXDryWetZeroIsBitExact() {
    let w = white(21), w2 = white(21)
    let r = Rig(seconds: 3) { _ in let v = w(); return (v, -v) }
    let d = Rig(seconds: 3) { _ in let v = w2(); return (v, -v) }
    r.fx(MDFX_DRYWET, 0)
    for fx in Effect.allCases { r.set(fx, on: true) }
    r.play(true); d.play(true)
    let a = r.capture(2), b = d.capture(2)
    #expect(a.0 == b.0 && a.1 == b.1)
}

/// extreme Einstellungen, danach Stille: kein NaN, keine Denormals (44,1 / 48 / 96 kHz)
@Test(arguments: [44100.0, 48000.0, 96000.0])
func beatFXNoNaNOrDenormal(fs: Double) {
    let w = white(5)
    let r = Rig(seconds: 4, fs: fs, bpm: 174) { i in
        let v = Double(i) < fs ? w() * 3 : 0
        return (v, v)
    }
    r.fx(MDFX_GATER_BEATS, 0.0625); r.fx(MDFX_GATER_SHAPE, 1); r.fx(MDFX_ROLL_BEATS, 1.0 / 32); r.fx(MDFX_ROLL_DECAY, 24)
    r.fx(MDFX_ROLL_REVERSE, 1)
    r.fx(MDFX_FLANGER_FEEDBACK, 1); r.fx(MDFX_FLANGER_DEPTH, 1); r.fx(MDFX_FLANGER_BEATS, 0.5)
    r.fx(MDFX_PHASER_FEEDBACK, 1); r.fx(MDFX_PHASER_DEPTH, 1); r.fx(MDFX_PHASER_STAGES, 8); r.fx(MDFX_PHASER_BEATS, 0)
    r.fx(MDFX_PHASER_HZ, 8)
    for fx in Effect.allCases { r.set(fx, on: true) }
    r.play(true)
    let (a, b) = r.capture(3)
    let bad = (a + b).filter { !$0.isFinite || ($0 != 0 && abs($0) < Float.leastNormalMagnitude) }.count
    let tail = (a.suffix(Int(fs)) + b.suffix(Int(fs))).map(abs).max() ?? 0
    print(String(format: "[beatfx] %.0f kHz extrem: %d ungültige Samples, Spitze nach 2 s Stille %.2e", fs / 1000, bad, tail))
    #expect(bad == 0 && tail < 1e-3)
}

/// Rechenzeit je Effekt (MIX741_BENCH=1): 1 Deck, 512 Frames, ein Effekt an; Bezug Delay
@Test(.enabled(if: ProcessInfo.processInfo.environment["MIX741_BENCH"] == "1"))
func beatFXCPU() {
    func measure(_ setup: (Rig) -> Void) -> Double {
        let w = white(5)
        let r = Rig(seconds: 100) { _ in let v = w(); return (v, v) }   // 7700 Blöcke = 89 s
        setup(r)
        r.play(true)
        for _ in 0..<200 { r.bufs.withUnsafeMutableBufferPointer { mdsp_render(r.e, $0.baseAddress, 2, 512) } }
        // kürzeste von 5 Runden (andere Last auf der Maschine)
        var best = Double.infinity
        for _ in 0..<5 {
            let count = 1500, t0 = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<count { r.bufs.withUnsafeMutableBufferPointer { mdsp_render(r.e, $0.baseAddress, 2, 512) } }
            best = min(best, Double(DispatchTime.now().uptimeNanoseconds - t0) / 1000 / Double(count))
        }
        return best
    }
    let base = measure { _ in }
    let delay = measure { $0.fx(MDFX_DELAY_ON, 1) } - base
    var line = String(format: "[beatfx] cpu 1 deck · 512 frames · ohne fx %.1f µs/block · je effekt: delay %.1f", base, delay)
    for fx in Effect.allCases {
        let us = measure { r in r.set(fx, on: true); r.fx(MDFX_PHASER_STAGES, 8) } - base
        line += String(format: " · %@ %.1f", "\(fx)", us)
    }
    line += String(format: " · phaser 4 stufen %.1f", measure { r in r.set(.phaser, on: true) } - base)
    print(line + " µs")
}

/// FFT (Radix 2, an Ort und Stelle)
private func fft(_ re: inout [Double], _ im: inout [Double]) {
    let n = re.count
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
                let wr = cos(ang * Double(k)), wi = sin(ang * Double(k))
                let ur = re[i + k], ui = im[i + k]
                let vr = re[i + k + len / 2] * wr - im[i + k + len / 2] * wi, vi = re[i + k + len / 2] * wi + im[i + k + len / 2] * wr
                re[i + k] = ur + vr; im[i + k] = ui + vi
                re[i + k + len / 2] = ur - vr; im[i + k + len / 2] = ui - vi
            }
        }
        len *= 2
    }
}
