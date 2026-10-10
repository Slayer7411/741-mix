import Foundation
import Testing
import MixDSP

/// Der C++-Kern offline: kein Audiogerät, Blöcke direkt über mdsp_render. Ein Deck mit 10 s Sinus (220 Hz, Pegel 0.5).
private final class Core {
    let e: OpaquePointer
    let fs = 44100.0
    let frames: Int
    let left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>
    var outL: [Float] = [], outR: [Float] = []

    init(seconds: Double = 10) {
        e = mdsp_create(fs)
        frames = Int(seconds * fs)
        left = .allocate(capacity: frames); right = .allocate(capacity: frames)
        for i in 0..<frames { let v = Float(sin(2 * .pi * 220 * Double(i) / fs)) * 0.5; left[i] = v; right[i] = v }
    }
    deinit { mdsp_destroy(e); left.deallocate(); right.deallocate() }

    @discardableResult
    func load(start: Double = 0) -> UInt32 { mdsp_set_track(e, 0, left, right, Int64(frames), fs, start) }
    func set(_ p: MDParam, _ v: Float) { mdsp_set_param(e, 0, p, v) }
    func fx(_ p: MDFXParam, _ v: Float) { mdsp_set_fx(e, 0, p, v) }
    var position: Double { mdsp_position(e, 0) }
    var playing: Bool { mdsp_playing(e, 0) }

    /// einen Block rendern, liefert den RMS des Kanalpaars 1/2
    @discardableResult
    func render(_ n: Int = 512) -> Float {
        outL = [Float](repeating: 0, count: n); outR = [Float](repeating: 0, count: n)
        var sum: Float = 0
        outL.withUnsafeMutableBufferPointer { l in
            outR.withUnsafeMutableBufferPointer { r in
                var chans: [UnsafeMutablePointer<Float>?] = [l.baseAddress, r.baseAddress]
                chans.withUnsafeMutableBufferPointer { mdsp_render(e, $0.baseAddress, 2, Int32(n)) }
                for i in 0..<n { sum += l[i] * l[i] }
            }
        }
        return (sum / Float(n)).squareRoot()
    }

    /// `seconds` lang rendern, liefert den mittleren RMS
    @discardableResult
    func render(seconds: Double) -> Float {
        let blocks = max(1, Int(seconds * fs / 512))
        var acc: Float = 0
        for _ in 0..<blocks { acc += render(512) }
        return acc / Float(blocks)
    }
}

@Test func playsAndReportsPosition() {
    let c = Core()
    c.load(); c.render()
    #expect(c.render(seconds: 0.5) == 0)          // steht: Stille
    #expect(c.position == 0)
    c.set(MD_PLAYING, 1)
    let rms = c.render(seconds: 1)
    #expect(abs(c.position - 1.0) < 0.03)
    #expect(rms > 0.2)                             // 0.5 Sinus ≈ 0.35 RMS × Master 0.85
    c.set(MD_PLAYING, 0)
    c.render(seconds: 0.2)
    let p = c.position
    #expect(c.render(seconds: 0.2) == 0 && c.position == p)
}

@Test func seekLandsOnTarget() {
    let c = Core()
    c.load(); c.render()
    c.set(MD_PLAYING, 1); c.render(seconds: 0.3)
    mdsp_seek(c.e, 0, 7.0)
    #expect(c.position == 7.0)                     // sofort sichtbar, auch vor dem nächsten Block
    c.render()
    #expect(abs(c.position - (7.0 + 512 / c.fs)) < 0.002)
}

@Test func loopWrapsInsideBounds() {
    let c = Core()
    c.load(start: 2.0); c.render()
    mdsp_set_loop(c.e, 0, true, 2.0, 2.5)
    c.set(MD_PLAYING, 1)
    for _ in 0..<200 {
        c.render()
        let p = c.position
        #expect(p >= 1.99 && p <= 2.51)
    }
    var s = 0.0, en = 0.0
    #expect(mdsp_loop(c.e, 0, &s, &en) && s == 2.0 && en == 2.5)
}

@Test func reverseRunsBackwards() {
    let c = Core()
    c.load(start: 5.0); c.render()
    c.set(MD_REVERSE, 1); c.set(MD_PLAYING, 1)
    c.render(seconds: 1)
    #expect(abs(c.position - 4.0) < 0.03)
}

@Test func tempoWithAndWithoutKeylock() {
    for keylock: Float in [0, 1] {
        let c = Core()
        c.load(); c.render()
        c.set(MD_RATE, 1.25); c.set(MD_KEYLOCK, keylock); c.set(MD_PLAYING, 1)
        let rms = c.render(seconds: 2)
        #expect(abs(c.position - 2.5) < (keylock == 1 ? 0.1 : 0.03), "keylock \(keylock)")
        #expect(rms > 0.15, "keylock \(keylock)")
    }
}

@Test func delayTailRingsOutThenStops() {
    let c = Core()
    c.load(); c.render()
    c.set(MD_FX1_ASSIGN, 1)
    c.fx(MDFX_DELAY_ON, 1); c.fx(MDFX_DELAY_AMOUNT, 1); c.fx(MDFX_DELAY_SECONDS, 0.25); c.fx(MDFX_DELAY_FEEDBACK, 0.5)
    c.set(MD_PLAYING, 1); c.render(seconds: 1)
    c.set(MD_PLAYING, 0)
    #expect(c.render(seconds: 0.3) > 0.01)         // Echo-Fahne nach dem Stopp
    c.render(seconds: 5)
    #expect(c.render(seconds: 0.5) < 1e-4)         // verklungen
}

@Test func masterHardLimit() {
    let c = Core()
    c.load(); c.render()
    c.set(MD_GAIN_DB, 24); c.set(MD_PLAYING, 1)
    c.render(seconds: 0.5)
    c.render(2048)
    #expect(c.outL.allSatisfy { abs($0) <= 1 } && c.outR.allSatisfy { abs($0) <= 1 })
    #expect(c.outL.contains { abs($0) > 0.99 })
}

@Test func clockFollowsBPM() {
    let c = Core()
    mdsp_clock_set_bpm(c.e, 120)
    mdsp_clock_set_beat(c.e, 0)
    c.render(seconds: 2)
    #expect(abs(mdsp_clock_beat(c.e) - 4.0) < 0.02)
}

@Test func trackHandoffIsConfirmedByAudioThread() {
    let c = Core()
    let g1 = c.load()
    #expect(!mdsp_track_consumed(c.e, 0, g1))
    c.render()
    #expect(mdsp_track_consumed(c.e, 0, g1))
    // zwei Übergaben vor dem nächsten Block: die letzte zählt, beide gelten danach als übernommen
    let g2 = c.load(start: 1), g3 = c.load(start: 2)
    #expect(!mdsp_track_consumed(c.e, 0, g2) && !mdsp_track_consumed(c.e, 0, g3))
    c.render()
    #expect(mdsp_track_consumed(c.e, 0, g2) && mdsp_track_consumed(c.e, 0, g3))
    #expect(c.position == 2.0)
}

/// Hall-Pegel: Single-Modus, volles D/W, rosa Rauschen (Spektrum ähnlich wie Musik) – mit Hall soll der Ausgang
/// kaum lauter sein als trocken (Selbsttest-Zeile „Pegel A … Reverb“ misst dasselbe Verhältnis an einem Track).
/// Vorher (fester +10-dB-Zuschlag): gesamt/trocken 4,19, Hall allein 4,08 (+12,2 dB), über 4 kHz 0,054.
@Test func reverbLevelMatchesDry() {
    func run(reverb: Bool, bright: Float? = nil) -> [Float] {
        let c = Core()
        var seed: UInt32 = 777, b0: Float = 0, b1: Float = 0, b2: Float = 0
        for i in 0..<c.frames {
            seed = seed &* 1664525 &+ 1013904223; let w = Float(seed >> 8) / Float(1 << 24) - 0.5
            b0 = 0.99765 * b0 + w * 0.0990; b1 = 0.963 * b1 + w * 0.2965; b2 = 0.57 * b2 + w * 1.0526   // rosa (P. Kellet)
            let v = (b0 + b1 + b2 + w * 0.1848) * 0.2; c.left[i] = v; c.right[i] = v
        }
        c.load(); c.render()
        c.set(MD_FX1_ASSIGN, 1)
        c.fx(MDFX_REVERB_ON, reverb ? 1 : 0); c.fx(MDFX_REVERB_AMOUNT, 1); c.fx(MDFX_REVERB_HP, 0); c.fx(MDFX_REVERB_LP, 1)
        c.fx(MDFX_REVERB_DWSEND, 1); c.fx(MDFX_DRYWET, 1)   // Single-Reverb, D/W 1 = alles geht in den Hall; Pegel/Vorverzögerung = Standard
        if let bright { c.fx(MDFX_REVERB_BRIGHT, bright) }
        c.set(MD_PLAYING, 1); c.render(seconds: 3)           // Hall aufbauen
        var out: [Float] = []
        for _ in 0..<172 { c.render(512); out += c.outL }    // ~2 s
        return out
    }
    func rms(_ x: [Float]) -> Float { var s: Float = 0; for v in x { s += v * v }; return (s / Float(max(1, x.count))).squareRoot() }
    let a = 1 - exp(-2 * Float.pi * 4000 / Float(44100))
    let dry = run(reverb: false)
    /// Hall allein und sein Anteil über 4 kHz (Einpol-Hochpass)
    func wetOnly(_ wet: [Float]) -> (level: Float, hf: Float) {
        var sum: Float = 0, hf: Float = 0, lp: Float = 0
        for i in 0..<dry.count { let w = wet[i] - dry[i]; sum += w * w; lp += a * (w - lp); let h = w - lp; hf += h * h }
        return ((sum / Float(dry.count)).squareRoot() / max(rms(dry), 1e-9), hf / max(sum, 1e-12))
    }
    let wet = run(reverb: true), w = wetOnly(wet)
    let dark = wetOnly(run(reverb: true, bright: 0)).hf, bright = wetOnly(run(reverb: true, bright: 1)).hf
    print(String(format: "[reverb] level single D/W 1: gesamt/trocken %.3f · hall allein %.3f (%+.1f dB) · hall >4 kHz %.3f (dunkel %.3f · hell %.3f)",
                 rms(wet) / max(rms(dry), 1e-9), w.level, 20 * log10(w.level), w.hf, dark, bright))
    let total = rms(wet) / max(rms(dry), 1e-9)
    #expect(total > 0.6 && total < 1.2)
    #expect(w.level > 0.4 && w.level < 0.9)   // Hall allein: einige dB unter dem Track
    #expect(w.hf < 0.05)                  // weich: Standard-Helligkeit lässt weniger Höhen durch als vorher (0,054)
    #expect(dark < w.hf && w.hf < bright)  // Helligkeit wirkt in die richtige Richtung
}

/// Hall-Fahne messen: Anteil über 4 kHz und spektrale Flachheit (niedrig = einzelne Resonanzen = metallisch).
/// Keine festen Grenzen außer "klingt und klingt aus" – die Zahlen stehen im Log zum Vergleich.
@Test func reverbTailMetrics() {
    let c = Core()
    var seed: UInt32 = 12345   // weißes Rauschen als Anregung
    for i in 0..<c.frames { seed = seed &* 1664525 &+ 1013904223; let v = (Float(seed >> 8) / Float(1 << 24) - 0.5) * 0.6; c.left[i] = v; c.right[i] = v }
    c.load(); c.render()
    c.set(MD_FX1_ASSIGN, 1)
    c.fx(MDFX_REVERB_ON, 1); c.fx(MDFX_REVERB_AMOUNT, 1); c.fx(MDFX_REVERB_SIZE, 0.7); c.fx(MDFX_REVERB_HP, 0); c.fx(MDFX_REVERB_LP, 1)
    c.fx(MDFX_REVERB_DWSEND, 1); c.fx(MDFX_DRYWET, 1)
    c.set(MD_PLAYING, 1); c.render(seconds: 1.5)
    c.set(MD_PLAYING, 0); c.render(seconds: 1.0)   // erst die späte Fahne: dort bleiben nur Resonanzen übrig (metallisch)
    var tail: [Float] = []
    for _ in 0..<40 { c.render(512); tail += c.outL }
    let fs = Float(c.fs)
    // Anteil über 4 kHz (Einpol-Hochpass)
    let a = 1 - exp(-2 * Float.pi * 4000 / fs)
    var lp: Float = 0, hf: Float = 0, tot: Float = 0
    for x in tail { lp += a * (x - lp); let h = x - lp; hf += h * h; tot += x * x }
    // spektrale Flachheit 150 Hz … 2,5 kHz (dort liegt bei jeder Abstimmung Energie, die Neigung verfälscht nicht) über 4096 Samples (Hann), 160 log-verteilte Frequenzen
    let n = 4096, seg = Array(tail.prefix(n))
    var logSum: Double = 0, sum: Double = 0, count = 0
    for k in 0..<160 {
        let f = 150 * pow(2500.0 / 150, Double(k) / 159)
        var re = 0.0, im = 0.0
        for i in 0..<n {
            let w = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n))
            let ph = 2 * Double.pi * f * Double(i) / Double(fs)
            re += Double(seg[i]) * w * cos(ph); im -= Double(seg[i]) * w * sin(ph)
        }
        let p = re * re + im * im + 1e-18
        logSum += log(p); sum += p; count += 1
    }
    let flatness = exp(logSum / Double(count)) / (sum / Double(count))
    let rms = (tot / Float(tail.count)).squareRoot()
    print(String(format: "[reverb] tail rms %.4f · >4 kHz %.3f · flatness %.3f", rms, hf / max(tot, 1e-12), flatness))
    #expect(rms > 1e-4)
    c.render(seconds: 25)
    #expect(c.render(seconds: 0.5) < 1e-3)   // klingt aus
}
