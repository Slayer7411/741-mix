import Foundation
import Testing
import MixCore
import MixEngine

private let rate = 44100.0
private let block = Int(rate / TrackAudio.blocksPerSecond)

/// Mono-Signal analysieren (links = rechts)
private func analyze(_ x: [Float]) -> WaveSpectrum {
    let a = SpectrumAnalyzer(sampleRate: rate, block: block)
    x.withUnsafeBufferPointer { a.feed(left: $0.baseAddress!, right: $0.baseAddress!, count: x.count) }
    return a.finish()
}

private func sine(_ f: Double, amp: Float = 0.5, seconds: Double = 2) -> [Float] {
    (0..<Int(seconds * rate)).map { amp * Float(sin(2 * .pi * f * Double($0) / rate)) }
}

/// bandbegrenzter Sägezahn (Obertöne bis `upTo`), wie ein gefilterter Synth
private func saw(_ f: Double, upTo top: Double, seconds: Double = 2) -> [Float] {
    let n = Int(top / f)
    return (0..<Int(seconds * rate)).map { i in
        let t = Double(i) / rate
        return Float((1...n).reduce(0.0) { $0 + sin(2 * .pi * f * Double($1) * t) / Double($1) } * 0.25)
    }
}

/// fester Zufall (Tests reproduzierbar)
private struct LCG: RandomNumberGenerator {
    var state: UInt64 = 0x741
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

/// Bandrauschen um `f` (Träger × tiefpassgefiltertes Rauschen), Hüllkurve je Sample
private func noise(around f: Double, seconds: Double = 3, env: (Double) -> Float) -> [Float] {
    var g = LCG()
    var lp: Float = 0
    let a = Float(1 - exp(-2 * Double.pi * 1500 / rate))
    return (0..<Int(seconds * rate)).map { i in
        lp += a * (Float.random(in: -1...1, using: &g) - lp)
        let t = Double(i) / rate
        return 3 * lp * Float(sin(2 * .pi * f * t)) * env(t)
    }
}

/// Mittel eines Bandes (dB) über die Blöcke in der Mitte (Ränder abgeschnitten)
private func mean(_ s: WaveSpectrum, _ b: WaveSpectrum.Band) -> Float {
    let r = (s.count / 5)..<(s.count * 4 / 5)
    return r.reduce(0) { $0 + s.level($1, b) } / Float(r.count)
}

private func dominant(_ s: WaveSpectrum) -> WaveSpectrum.Band {
    WaveSpectrum.Band.allCases.max { mean(s, $0) < mean(s, $1) }!
}

@Test func subSineIsSub() {
    let s = analyze(sine(40))
    #expect(dominant(s) == .sub)
    #expect(abs(mean(s, .sub) - (-9)) < 1.5)            // 0,5 Amplitude = -9 dBFS Effektivwert
    #expect(mean(s, .bass) < mean(s, .sub) - 12)
    #expect(mean(s, .high) < -60)
}

@Test func bassSineIsBass() {
    let s = analyze(sine(120))
    #expect(dominant(s) == .bass)
    #expect(mean(s, .sub) < mean(s, .bass) - 12)
    #expect(mean(s, .lowMid) < mean(s, .bass) - 12)
}

@Test func highSineCalibrated() {
    let s = analyze(sine(6000, amp: 1))
    #expect(dominant(s) == .high)
    #expect(abs(mean(s, .high) - (-3)) < 1)               // FFT-Bänder auf gleicher Skala wie die Filterbänder
}

@Test func midSawIsMid() {
    // Sägezahn 440 Hz: Grundton untere Mitten, Obertöne obere Mitten
    let s = analyze(saw(440, upTo: 4000))
    #expect([.lowMid, .highMid].contains(dominant(s)))
    #expect(mean(s, .bass) < mean(s, .lowMid) - 15)
    #expect(mean(s, .sub) < mean(s, .lowMid) - 15)
}

@Test func closedVersusOpenHats() {
    // geschlossen: 8-kHz-Rauschstöße alle 115 ms, Abklingen 8 ms; offen: gehaltenes 8-kHz-Rauschen
    let closed = analyze(noise(around: 8000) { t in
        let p = t.truncatingRemainder(dividingBy: 0.115)
        return Float(exp(-p / 0.008))
    })
    let open = analyze(noise(around: 8000) { _ in 0.5 })
    #expect(dominant(closed) == .high, "\(WaveSpectrum.Band.allCases.map { mean(closed, $0) })")
    #expect(dominant(open) == .high)
    let mid = { (s: WaveSpectrum) -> Float in
        let r = (s.count / 5)..<(s.count * 4 / 5)
        return r.reduce(0) { $0 + s.sustain($1) } / Float(r.count)
    }
    #expect(mid(closed) < 0.4)
    #expect(mid(open) > 0.85)
}

@Test func blockCountAndSilence() {
    let s = analyze([Float](repeating: 0, count: 44100))
    #expect(s.count == 44100 / block + 1)
    #expect(s.data.allSatisfy { $0 == 0 })
    let r = analyze(sine(40)).reduced(to: 10)
    #expect(r.count == 10)
    #expect(abs(r.level(5, .sub) - (-9)) < 1.5)
}

/// Farbe in der Mitte eines Signals, Bezug = typischer Club-Track (ein Einzelsignal wäre sonst sein eigener Maßstab)
private func colorAt(_ s: WaveSpectrum) -> SpectrumColors.Result {
    SpectrumColors(ref: SpectrumColors.nominal).color(s, s.count / 2)
}

/// Mischung: Sub-Sinus + leise Hats → orange (Sub vorn); Säge mit leisem Bass → grün; Hats kurz → blau, gehalten → hellblau
@Test func colorsFollowTheBands() {
    let sub = colorAt(analyze(sine(45)))
    #expect(sub.dominant == .sub)
    #expect(sub.body.r > 0.9 && sub.body.g > 0.3 && sub.body.g < 0.65 && sub.body.b < 0.2)   // orange

    let bass = colorAt(analyze(sine(110)))
    #expect(bass.dominant == .bass)
    #expect(bass.body.r > 0.9 && bass.body.g < 0.3)                                        // rot

    let mid = colorAt(analyze(saw(440, upTo: 4000)))
    #expect([.lowMid, .highMid].contains(mid.dominant))
    #expect(mid.body.g > 0.9 && mid.body.b < 0.4)                                          // grün

    let closed = colorAt(analyze(noise(around: 8000) { t in Float(exp(-t.truncatingRemainder(dividingBy: 0.115) / 0.008)) }))
    let open = colorAt(analyze(noise(around: 8000) { _ in 0.5 }))
    #expect(closed.highColor.b > 0.95 && closed.highColor.g < 0.6)                         // blau
    #expect(open.highColor.g > 0.85 && open.highColor.r > 0.5)                             // hellblau, heller
    #expect(open.highColor.r + open.highColor.g > closed.highColor.r + closed.highColor.g + 0.6)
}

/// Laufzeit auf echten Dateien (nur mit MIX741_SPECTRUM_BENCH=<pfad>[:<pfad>…]): Dekodieren vs. Spektrum
@Test func benchRealFiles() throws {
    guard let list = ProcessInfo.processInfo.environment["MIX741_SPECTRUM_BENCH"] else { return }
    for path in list.split(separator: ":").map(String.init) {
        let t0 = Date()
        let a = try TrackAudio.decode(url: URL(fileURLWithPath: path), sampleRate: 44100)
        let total = Date().timeIntervalSince(t0)
        let t1 = Date()
        let sa = SpectrumAnalyzer(sampleRate: a.sampleRate, block: Int(a.sampleRate / TrackAudio.blocksPerSecond))
        sa.feed(left: a.left, right: a.right, count: a.frames)
        let s = sa.finish(blocks: a.peak.count)
        let spec = Date().timeIntervalSince(t1)
        print(String(format: "[bench] %.0f s audio: decode+analyse %.3f s, davon Spektrum %.3f s (%.1f %%), %d KB Spektrum – %@",
                     a.duration, total, spec, spec / (total - spec) * 100, s.data.count / 1024, (path as NSString).lastPathComponent))
        print("[bench] ref p95 dB:", s.reference().map { String(format: "%.1f", $0) }.joined(separator: " "))
    }
}

/// Suche nach Tracks mit Wechsel geschlossen → offen (nur mit MIX741_SPECTRUM_SCAN=<datei mit pfaden>)
@Test func scanSustain() throws {
    guard let listFile = ProcessInfo.processInfo.environment["MIX741_SPECTRUM_SCAN"] else { return }
    let paths = try String(contentsOfFile: listFile, encoding: .utf8).split(separator: "\n").map(String.init)
    for path in paths {
        guard let a = try? TrackAudio.decode(url: URL(fileURLWithPath: path), sampleRate: 44100) else { continue }
        let s = a.spectrum
        let ref = s.reference()
        let win = Int(10 * TrackAudio.blocksPerSecond)
        var line: [String] = []
        var lo: Float = 1, hi: Float = 0
        for w in stride(from: 0, to: s.count - win, by: win) {
            var sw: Float = 0, ww: Float = 0
            for i in w..<(w + win) {
                let d = max(s.level(i, .high) - ref[4], s.level(i, .air) - ref[5])
                guard d > -6 else { continue }
                sw += s.sustain(i); ww += 1
            }
            let m = ww > 50 ? sw / ww : -1
            line.append(m < 0 ? "--" : String(format: "%02d", Int(m * 99)))
            if m >= 0 { lo = min(lo, m); hi = max(hi, m) }
        }
        print(String(format: "[scan] %.2f %@ | %@", hi - lo, (path as NSString).lastPathComponent, line.joined(separator: " ")))
    }
}
