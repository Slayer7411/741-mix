import Foundation
import Testing
import MixDSP
import MixEngine

/// Hall-Messbericht (nur mit MIX741_REVERB_REPORT=1, Typ FDN, MIX741_REVERB_TYPE=0: Allpass-Ring): Nachhallzeit je Größe, Fahne (Höhen, Flachheit, Spitzen),
/// Stereo-Korrelation, Pegel beim Einschalten, Rechenzeit. MIX741_REVERB_TRACK=<datei> + MIX741_REVERB_WAV=<präfix>:
/// echten Track mit Hall rendern (Einsatz, Drop, Fahne) und als WAV schreiben.
private let report = ProcessInfo.processInfo.environment["MIX741_REVERB_REPORT"] == "1"
/// MIX741_REVERB_TYPE=0: Bericht für den Allpass-Ring statt FDN
private let reportType: Float = ProcessInfo.processInfo.environment["MIX741_REVERB_TYPE"] == "0" ? 0 : 1

private final class Rig {
    let e: OpaquePointer
    let fs: Double
    var left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>
    var frames: Int
    var outL = [Float](repeating: 0, count: 512), outR = [Float](repeating: 0, count: 512)

    init(seconds: Double, fs: Double = 44100, make: (Int) -> (Float, Float)) {
        self.fs = fs
        e = mdsp_create(fs)
        frames = Int(seconds * fs)
        left = .allocate(capacity: frames); right = .allocate(capacity: frames)
        for i in 0..<frames { let (l, r) = make(i); left[i] = l; right[i] = r }
        mdsp_set_track(e, 0, left, right, Int64(frames), fs, 0)
        render()
        mdsp_set_param(e, 0, MD_FX1_ASSIGN, 1)
        mdsp_set_fx(e, 0, MDFX_REVERB_TYPE, reportType)   // Standard: FDN (reverbFreezeStaysBounded braucht ihn)
    }
    deinit { mdsp_destroy(e); left.deallocate(); right.deallocate() }

    func fx(_ p: MDFXParam, _ v: Float) { mdsp_set_fx(e, 0, p, v) }
    func set(_ p: MDParam, _ v: Float) { mdsp_set_param(e, 0, p, v) }

    /// Gruppenmodus: Hall-Anteil = amount × D/W, Eingang voll
    func group(size: Float) {
        fx(MDFX_REVERB_AMOUNT, 1); fx(MDFX_DRYWET, 1); fx(MDFX_REVERB_SIZE, size)
        fx(MDFX_REVERB_HP, 0); fx(MDFX_REVERB_LP, 1); fx(MDFX_REVERB_DWSEND, 0)
    }
    /// Single-Modus: D/W = wie viel in den Hall geht
    func single(size: Float, hp: Float = 0, lp: Float = 1, dw: Float = 1) {
        fx(MDFX_REVERB_AMOUNT, 1); fx(MDFX_DRYWET, dw); fx(MDFX_REVERB_SIZE, size)
        fx(MDFX_REVERB_HP, hp); fx(MDFX_REVERB_LP, lp); fx(MDFX_REVERB_DWSEND, 1)
    }

    func render(_ n: Int = 512) {
        outL.withUnsafeMutableBufferPointer { l in
            outR.withUnsafeMutableBufferPointer { r in
                var chans: [UnsafeMutablePointer<Float>?] = [l.baseAddress, r.baseAddress]
                chans.withUnsafeMutableBufferPointer { mdsp_render(e, $0.baseAddress, 2, Int32(n)) }
            }
        }
    }
    /// `seconds` rendern, Ausgang L/R
    func capture(_ seconds: Double) -> ([Float], [Float]) {
        var l: [Float] = [], r: [Float] = []
        let blocks = Int(seconds * fs / 512)
        l.reserveCapacity(blocks * 512); r.reserveCapacity(blocks * 512)
        for _ in 0..<blocks { render(); l += outL; r += outR }
        return (l, r)
    }
}

private func pink(seed s: UInt32) -> () -> Float {
    var seed = s, b0: Float = 0, b1: Float = 0, b2: Float = 0
    return {
        seed = seed &* 1664525 &+ 1013904223; let w = Float(seed >> 8) / Float(1 << 24) - 0.5
        b0 = 0.99765 * b0 + w * 0.0990; b1 = 0.963 * b1 + w * 0.2965; b2 = 0.57 * b2 + w * 1.0526
        return (b0 + b1 + b2 + w * 0.1848) * 0.2
    }
}
private func white(seed s: UInt32) -> () -> Float {
    var seed = s
    return { seed = seed &* 1664525 &+ 1013904223; return (Float(seed >> 8) / Float(1 << 24) - 0.5) * 0.6 }
}
private func rms(_ x: ArraySlice<Float>) -> Double { var s = 0.0; for v in x { s += Double(v) * Double(v) }; return (s / Double(max(1, x.count))).squareRoot() }
private func rms(_ x: [Float]) -> Double { rms(x[...]) }
private func db(_ x: Double) -> Double { 20 * log10(max(x, 1e-12)) }

/// radix-2 FFT (in place)
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
                let c = cos(ang * Double(k)), s = sin(ang * Double(k))
                let a = i + k, b = i + k + len / 2
                let tr = re[b] * c - im[b] * s, ti = re[b] * s + im[b] * c
                re[b] = re[a] - tr; im[b] = im[a] - ti; re[a] += tr; im[a] += ti
            }
        }
        len <<= 1
    }
}

/// Welch-Spektrum, jedes Segment auf gleiche Energie normiert (die Fahne klingt ab)
private func welch(_ x: [Float], n: Int = 4096) -> [Double] {
    var acc = [Double](repeating: 0, count: n / 2)
    var segs = 0
    var start = 0
    while start + n <= x.count {
        var re = [Double](repeating: 0, count: n), im = [Double](repeating: 0, count: n)
        for i in 0..<n { re[i] = Double(x[start + i]) * (0.5 - 0.5 * cos(2 * .pi * Double(i) / Double(n))) }
        fft(&re, &im)
        var p = [Double](repeating: 0, count: n / 2), tot = 0.0
        for k in 0..<n / 2 { p[k] = re[k] * re[k] + im[k] * im[k]; tot += p[k] }
        for k in 0..<n / 2 { acc[k] += p[k] / max(tot, 1e-30) }
        segs += 1; start += n / 2
    }
    return acc.map { $0 / Double(max(1, segs)) }
}

private struct TailStats { var hf = 0.0, flat = 0.0, peak = 0.0, corr = 0.0, corrHi = 0.0 }

/// Fahne: Anteil > 4 kHz, Flachheit 150 Hz … 2,5 kHz, größte Spitze über dem lokalen Median (± 1/6 Oktave, 200 Hz … 12 kHz),
/// Korrelation L/R (breitbandig und über 1 kHz)
private func tailStats(_ l: [Float], _ r: [Float], fs: Double) -> TailStats {
    let n = 4096
    let p = welch(l, n: n), pr = welch(r, n: n)
    let ps = zip(p, pr).map { ($0 + $1) / 2 }
    let bin = fs / Double(n)
    var s = TailStats()
    var hi = 0.0, all = 0.0
    for k in 1..<ps.count { let f = Double(k) * bin; if f < 20 { continue }; all += ps[k]; if f > 4000 { hi += ps[k] } }
    s.hf = hi / max(all, 1e-30)
    var lg = 0.0, ar = 0.0, cnt = 0.0
    for k in 0..<ps.count { let f = Double(k) * bin; if f >= 150 && f <= 2500 { lg += log(ps[k] + 1e-30); ar += ps[k]; cnt += 1 } }
    s.flat = exp(lg / cnt) / (ar / cnt)
    var worst = 0.0
    for k in 0..<ps.count {
        let f = Double(k) * bin
        if f < 200 || f > 12000 { continue }
        let lo = max(1, Int(f * pow(2, -1.0 / 6) / bin)), hiK = min(ps.count - 1, Int(f * pow(2, 1.0 / 6) / bin))
        let med = Array(ps[lo...hiK]).sorted()[(hiK - lo) / 2]
        worst = max(worst, ps[k] / max(med, 1e-30))
    }
    s.peak = 10 * log10(worst)
    func corr(_ a: [Float], _ b: [Float]) -> Double {
        var ab = 0.0, aa = 0.0, bb = 0.0
        for i in 0..<min(a.count, b.count) { ab += Double(a[i]) * Double(b[i]); aa += Double(a[i]) * Double(a[i]); bb += Double(b[i]) * Double(b[i]) }
        return ab / max(1e-30, (aa * bb).squareRoot())
    }
    s.corr = corr(l, r)
    func hp(_ x: [Float]) -> [Float] {   // 2 × Einpol-Hochpass 1 kHz
        let a = Float(1 - exp(-2 * Double.pi * 1000 / fs)); var l1: Float = 0, l2: Float = 0
        return x.map { v in l1 += a * (v - l1); let h = v - l1; l2 += a * (h - l2); return h - l2 }
    }
    s.corrHi = corr(hp(l), hp(r))
    return s
}

/// Nachhallzeit aus der Abklingkurve (10-ms-Fenster, Regression −5 … −35 dB bzw. bis Fensterende)
private func rt60(_ x: [Float], fs: Double, hfOnly: Bool = false) -> Double {
    var sig = x
    if hfOnly {
        let a = Float(1 - exp(-2 * Double.pi * 4000 / fs)); var l1: Float = 0, l2: Float = 0
        sig = x.map { v in l1 += a * (v - l1); let h = v - l1; l2 += a * (h - l2); return h - l2 }
    }
    let w = Int(0.01 * fs)
    var env: [Double] = []
    var i = 0
    while i + w <= sig.count { env.append(db(rms(sig[i..<i + w]))); i += w }
    guard let e0 = env.prefix(5).max() else { return 0 }
    var xs: [Double] = [], ys: [Double] = []
    for (k, v) in env.enumerated() {
        if v > e0 - 5 { continue }
        if v < e0 - 35 || v < -110 { break }
        xs.append(Double(k) * 0.01); ys.append(v)
    }
    guard xs.count > 10 else { return 0 }
    let mx = xs.reduce(0, +) / Double(xs.count), my = ys.reduce(0, +) / Double(ys.count)
    var num = 0.0, den = 0.0
    for k in 0..<xs.count { num += (xs[k] - mx) * (ys[k] - my); den += (xs[k] - mx) * (xs[k] - mx) }
    let slope = num / den
    return slope < 0 ? -60 / slope : .infinity
}

/// Größe 1 (fast eingefroren) bei 44,1 und 192 kHz: bleibt endlich, wächst nicht, klingt weiter
@Test func reverbFreezeStaysBounded() {
    for fs in [44100.0, 192000.0] {
        let w = white(seed: 7)
        let r = Rig(seconds: 3, fs: fs) { _ in let v = w(); return (v, v) }
        r.group(size: 1); r.fx(MDFX_REVERB_ON, 1)
        r.set(MD_PLAYING, 1); _ = r.capture(2)
        r.set(MD_PLAYING, 0); _ = r.capture(0.5)
        let (a, _) = r.capture(1)
        _ = r.capture(12)
        let (b, _) = r.capture(1)
        let ra = rms(a), rb = rms(b)
        print(String(format: "[reverb] freeze %.0f Hz: rms 0,5 s %.4f · 13,5 s %.4f (%+.1f dB)", fs, ra, rb, db(rb / ra)))
        #expect(a.allSatisfy { $0.isFinite } && b.allSatisfy { $0.isFinite })
        #expect(rb < ra && rb > ra * 0.3)   // Nachhall > 60 s: in 13 s höchstens ~10 dB leiser, nie lauter
    }
}

@Test(.enabled(if: report))
func reverbReport() throws {
    let fs = 44100.0
    // 1) Nachhallzeit je Größe (Gruppenmodus, rosa Rauschen 2 s, dann Deck stoppen)
    print("[report] size · RT60 · RT60 >4 kHz")
    for size: Float in [0, 0.25, 0.5, 0.6, 0.75, 0.9, 0.95, 1] {
        let p = pink(seed: 99)
        let r = Rig(seconds: 3) { _ in let v = p(); return (v, v) }
        r.group(size: size); r.fx(MDFX_REVERB_ON, 1)
        r.set(MD_PLAYING, 1); _ = r.capture(2)
        r.set(MD_PLAYING, 0)
        let secs: Double = size >= 0.9 ? 60 : 30
        let (l, rr) = r.capture(secs)
        let m = zip(l, rr).map { ($0 + $1) / 2 }
        print(String(format: "[report] %.2f · %.2f s · %.2f s", size, rt60(m, fs: fs), rt60(m, fs: fs, hfOnly: true)))
    }
    // 2) Fahne: weißes Rauschen (mono) 1,5 s, Stopp, 0,5 s überspringen, 2 s auswerten
    print("[report] size · tail >4 kHz · flatness · peak/median dB · corr L/R · corr >1 kHz")
    for size: Float in [0.6, 0.7, 0.9] {
        let wn = white(seed: 12345)
        let r = Rig(seconds: 3) { _ in let v = wn(); return (v, v) }
        r.group(size: size); r.fx(MDFX_REVERB_ON, 1)
        r.set(MD_PLAYING, 1); _ = r.capture(1.5)
        r.set(MD_PLAYING, 0); _ = r.capture(0.5)
        let (l, rr) = r.capture(2)
        let s = tailStats(l, rr, fs: fs)
        print(String(format: "[report] %.2f · %.1f dB · %.3f · %.1f dB · %.3f · %.3f", size, 10 * log10(max(s.hf, 1e-12)), s.flat, s.peak, s.corr, s.corrHi))
    }
    do {   // Bezug: unkorreliertes weißes Rauschen (Grenze der Messung: Flachheit/Spitze ohne jede Resonanz)
        let a = white(seed: 1), b = white(seed: 2)
        let l = (0..<Int(2 * fs)).map { _ in a() }, r = (0..<Int(2 * fs)).map { _ in b() }
        let s = tailStats(l, r, fs: fs)
        print(String(format: "[report] noise ref · %.1f dB · %.3f · %.1f dB · %.3f · %.3f", 10 * log10(s.hf), s.flat, s.peak, s.corr, s.corrHi))
    }
    // 3) Pegel beim Einschalten: rosa Rauschen, 2 s trocken, dann Hall an; gesamt ÷ trocken je Zeitfenster, Fahne nach Stopp
    print("[report] mode · size · total/dry 0–0.25 s · 0.25–1 s · 1–3 s · 3–6 s · wet >4 kHz · tail after stop 0.5 s / 2 s / 5 s (dB re dry)")
    for (single, size) in [(false, Float(0.6)), (true, Float(0.6)), (true, Float(0.9))] {
        func run(_ on: Bool) -> ([Float], [Float], [Float]) {
            let p = pink(seed: 777)
            let r = Rig(seconds: 12) { _ in let v = p(); return (v, v) }
            if single { r.single(size: size) } else { r.group(size: size) }
            r.set(MD_PLAYING, 1); _ = r.capture(2)
            r.fx(MDFX_REVERB_ON, on ? 1 : 0)
            let (l, _) = r.capture(6)
            r.set(MD_PLAYING, 0)
            let (t, _) = r.capture(6)
            return (l, t, [])
        }
        let (dry, _, _) = run(false), (wet, tail, _) = run(true)
        let dr = rms(dry)
        func ratio(_ a: Double, _ b: Double) -> Double {
            let i0 = Int(a * fs), i1 = Int(b * fs)
            return rms(wet[i0..<i1]) / max(rms(dry[i0..<i1]), 1e-12)
        }
        // Hall allein (gesamt − trocken) über 4 kHz im Fenster 1–6 s
        let a = 1 - exp(-2 * Double.pi * 4000 / fs)
        var lp = 0.0, hfE = 0.0, tot = 0.0
        for i in Int(1 * fs)..<min(wet.count, dry.count) { let w = Double(wet[i] - dry[i]); lp += a * (w - lp); let h = w - lp; hfE += h * h; tot += w * w }
        // Klangkurve: Hall allein ÷ trocken je Oktave (1–6 s), Fahne je Oktave (0,5–2,5 s nach Stopp) relativ zu 1 kHz
        if !single || size == 0.6 {
            let wetOnly = (Int(1 * fs)..<min(wet.count, dry.count)).map { wet[$0] - dry[$0] }
            let dryPart = Array(dry[Int(1 * fs)..<min(wet.count, dry.count)])
            let pw = welch(wetOnly, n: 8192), pd = welch(dryPart, n: 8192), pt = welch(Array(tail[Int(0.5 * fs)..<Int(2.5 * fs)]), n: 8192)
            func band(_ p: [Double], _ fc: Double) -> Double {
                let lo = Int(fc / sqrt(2) / (fs / 8192)), hi = min(p.count - 1, Int(fc * sqrt(2) / (fs / 8192)))
                return p[lo...hi].reduce(0, +)
            }
            let bands: [Double] = [125, 250, 500, 1000, 2000, 4000, 8000, 16000]
            let ref = band(pw, 1000) / band(pd, 1000), tref = band(pt, 1000) / band(pd, 1000)
            print("[report]   octave      " + bands.map { String(format: "%6.0f", $0) }.joined())
            print("[report]   wet/dry dB  " + bands.map { String(format: "%6.1f", 10 * log10(band(pw, $0) / band(pd, $0) / ref)) }.joined())
            print("[report]   tail/dry dB " + bands.map { String(format: "%6.1f", 10 * log10(band(pt, $0) / band(pd, $0) / tref)) }.joined())
        }
        func tl(_ t: Double) -> Double { let i = Int(t * fs); return db(rms(tail[i..<min(tail.count, i + Int(0.25 * fs))]) / dr) }
        print(String(format: "[report] %@ · %.2f · %.2f · %.2f · %.2f · %.2f · %.1f dB · %.1f / %.1f / %.1f",
                     single ? "single" : "group", size, ratio(0, 0.25), ratio(0.25, 1), ratio(1, 3), ratio(3, 5.9),
                     10 * log10(max(hfE / max(tot, 1e-30), 1e-12)), tl(0.5), tl(2), tl(5)))
    }
    // 4) Rechenzeit: 1 Deck, Hall an vs. aus, 512 Frames
    for on in [false, true] {
        let p = pink(seed: 5)
        let r = Rig(seconds: 60) { _ in let v = p(); return (v, v) }
        r.group(size: 0.6); r.fx(MDFX_REVERB_ON, on ? 1 : 0)
        r.set(MD_PLAYING, 1)
        var bl: [UnsafeMutablePointer<Float>?] = [.allocate(capacity: 512), .allocate(capacity: 512)]
        defer { bl.forEach { $0?.deallocate() } }
        for _ in 0..<200 { bl.withUnsafeMutableBufferPointer { mdsp_render(r.e, $0.baseAddress, 2, 512) } }
        let count = 4000
        let t0 = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<count { bl.withUnsafeMutableBufferPointer { mdsp_render(r.e, $0.baseAddress, 2, 512) } }
        let us = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1000 / Double(count)
        print(String(format: "[report] cpu 1 deck reverb %@ · 512 frames · %.1f µs/block", on ? "on " : "off", us))
    }
    // 5) echter Track
    let env = ProcessInfo.processInfo.environment
    if let path = env["MIX741_REVERB_TRACK"], let prefix = env["MIX741_REVERB_WAV"] {
        let t = try TrackAudio.decode(url: URL(fileURLWithPath: path), sampleRate: fs)
        let start = Int(min(90, t.duration / 3) * fs)
        let len = Int(30 * fs)
        // a) Gruppe, Größe 0,6: 6 s trocken, 4 s Hall, Stopp, 10 s Fahne
        // b) Single, Größe 0,95, HP 0,55: 6 s trocken, D/W 0 -> 1 in 4 s, Stopp, 14 s Fahne
        // Single-Modus, HP-Sweep: gesamt ÷ trocken bei vollem D/W (1–3 s nach dem Einschalten), Größe 0,6
        var line = "[report] track single D/W 1 · total/dry by HP:"
        for hp: Float in [0, 0.25, 0.5, 0.75, 0.9] {
            func run(_ on: Bool) -> [Float] {
                let r = Rig(seconds: 8) { i in (t.left[start + i], t.right[start + i]) }
                r.single(size: 0.6, hp: hp)
                r.fx(MDFX_REVERB_ON, on ? 1 : 0)
                r.set(MD_PLAYING, 1); _ = r.capture(1)
                return r.capture(2).0
            }
            line += String(format: " %.2f -> %.2f", hp, rms(run(true)) / max(rms(run(false)), 1e-9))
        }
        print(line)
        for (name, single) in [("group", false), ("single-hp", true)] {
            /// 6 s trocken, 4 s Hall (Single: D/W-Rampe), Stopp, Fahne; ohne Hall = trockener Bezug derselben Stelle
            func run(_ on: Bool) -> ([Float], [Float]) {
                let r = Rig(seconds: 30) { i in (t.left[start + min(i, len - 1)], t.right[start + min(i, len - 1)]) }
                if single { r.single(size: 0.95, hp: 0.55, dw: 0) } else { r.group(size: 0.6) }
                r.set(MD_PLAYING, 1)
                var l: [Float] = [], rr: [Float] = []
                let (a0, b0) = r.capture(6); l += a0; rr += b0
                r.fx(MDFX_REVERB_ON, on ? 1 : 0)
                for k in 0..<Int(4 * fs / 512) {
                    if single { r.fx(MDFX_DRYWET, min(1, Float(k) / Float(4 * fs / 512) * 1.25)) }
                    r.render(); l += r.outL; rr += r.outR
                }
                r.set(MD_PLAYING, 0)
                let (a1, b1) = r.capture(single ? 14 : 10); l += a1; rr += b1
                return (l, rr)
            }
            let (l, rr) = run(true), (dl, _) = run(false)
            let e0 = l.count - (single ? 14 : 10) * Int(fs) / 512 * 512 - Int(fs)   // letzte Sekunde vor dem Stopp
            let engaged = rms(l[e0..<e0 + Int(fs)]) / max(rms(dl[e0..<e0 + Int(fs)]), 1e-9)
            let dryRef = rms(dl[Int(6 * fs)..<e0 + Int(fs)])
            let tailStart = e0 + Int(1.5 * fs)
            let tl = Array(l[tailStart..<tailStart + Int(2 * fs)]), tr = Array(rr[tailStart..<tailStart + Int(2 * fs)])
            let s = tailStats(tl, tr, fs: fs)
            print(String(format: "[report] track %@: engaged/dry %.2f · tail 0.5-2.5 s %.1f dB re dry · >4 kHz %.1f dB · peak %.1f dB · corr %.3f",
                         name, engaged, db(rms(tl) / max(dryRef, 1e-9)), 10 * log10(max(s.hf, 1e-12)), s.peak, s.corr))
            try writeWAV16(URL(fileURLWithPath: "\(prefix)-\(name).wav"), l, rr, fs: fs)
        }
    }
}

private func writeWAV16(_ url: URL, _ l: [Float], _ r: [Float], fs: Double) throws {
    var d = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    let n = min(l.count, r.count)
    d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + n * 4)); d.append(contentsOf: Array("WAVEfmt ".utf8))
    u32(16); u16(1); u16(2); u32(UInt32(fs)); u32(UInt32(fs) * 4); u16(4); u16(16)
    d.append(contentsOf: Array("data".utf8)); u32(UInt32(n * 4))
    for i in 0..<n {
        for v in [l[i], r[i]] { u16(UInt16(bitPattern: Int16(max(-1, min(1, v)) * 32767))) }
    }
    try d.write(to: url)
}
