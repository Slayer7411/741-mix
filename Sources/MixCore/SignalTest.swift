import Foundation

/// Signal-Test (Deck -> Pult -> Eingang): Testsignal erzeugen und die Aufnahme dagegen auswerten.
/// Aufbau (Sekunden bei `rate`): Stille, Klicks (Latenz), Töne in Stufen (Frequenzgang), 1 kHz (Pegel, THD+N),
/// Stille (Grundrauschen), Rauschen (Aussetzer), Klicks (Taktdrift)
public enum SignalTest {
    public static let tones: [Double] = [31.5, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 12000, 16000, 18000, 20000]
    public static let toneLevel = 0.25            // −12 dBFS Spitze
    public static let clickLevel: Float = 0.5

    /// Abschnitte in Samples
    public struct Layout: Sendable {
        public let rate: Double
        public var lead: Int { Int(rate * 0.5) }
        public var clickGap: Int { Int(rate * 0.5) }
        public var clicks: Int { 4 }
        public var clicksA: Int { lead }
        public var toneLen: Int { Int(rate * 0.4) }
        public var tonesStart: Int { clicksA + clicks * clickGap }
        public var sineStart: Int { tonesStart + SignalTest.tones.count * toneLen }
        public var sineLen: Int { Int(rate * 3) }
        public var silenceStart: Int { sineStart + sineLen }
        public var silenceLen: Int { Int(rate * 2) }
        public var noiseStart: Int { silenceStart + silenceLen }
        public var noiseLen: Int { Int(rate * 6) }
        public var clicksB: Int { noiseStart + noiseLen + Int(rate * 0.5) }
        public var total: Int { clicksB + clicks * clickGap + lead }
        public init(rate: Double) { self.rate = rate }
    }

    /// Testsignal (stereo gleich)
    public static func signal(rate: Double) -> [Float] {
        let L = Layout(rate: rate)
        var s = [Float](repeating: 0, count: L.total)
        for k in 0..<L.clicks { s[L.clicksA + k * L.clickGap] = clickLevel; s[L.clicksB + k * L.clickGap] = clickLevel }
        for (j, f) in tones.enumerated() where f < rate / 2 {
            let o = L.tonesStart + j * L.toneLen
            for i in 0..<L.toneLen { s[o + i] = Float(toneLevel * sin(2 * .pi * f * Double(i) / rate)) * fade(i, L.toneLen, rate) }
        }
        for i in 0..<L.sineLen { s[L.sineStart + i] = Float(toneLevel * sin(2 * .pi * 1000 * Double(i) / rate)) * fade(i, L.sineLen, rate) }
        var seed: UInt64 = 741
        for i in 0..<L.noiseLen {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let u = Double(seed >> 11) / Double(1 << 53)
            s[L.noiseStart + i] = Float((u - 0.5) * 0.25)
        }
        return s
    }

    /// 5 ms Ein-/Ausblenden (keine Klicks an den Tonkanten)
    static func fade(_ i: Int, _ n: Int, _ rate: Double) -> Float {
        let f = Int(rate * 0.005)
        return Float(min(1, Double(min(i, n - 1 - i)) / Double(max(1, f))))
    }

    public struct Report: Sendable, CustomStringConvertible {
        public var latencyFrames = 0
        public var latencyMs = 0.0
        public var driftPPM = 0.0
        public var gainDb = 0.0
        public var thdnDb = 0.0
        public var noiseFloorDb = 0.0
        public var response: [(hz: Double, db: Double)] = []
        public var dropouts: [Double] = []          // Sekunden im Rauschabschnitt
        public var clipped = 0
        public var ok = false
        public var problem: String?

        public var description: String {
            if let problem { return "Signal-Test: \(problem)" }
            let fr = response.map { String(format: "%@ %+.2f", $0.hz >= 1000 ? String(format: "%.1fk", $0.hz / 1000) : String(format: "%.0f", $0.hz), $0.db) }.joined(separator: " · ")
            return String(format: "Latenz %.2f ms (%d Frames) · Drift %.1f ppm · Pegel %+.2f dB · THD+N %.1f dB · Grundrauschen %.1f dBFS · Übersteuert %d · Aussetzer %d",
                          latencyMs, latencyFrames, driftPPM, gainDb, thdnDb, noiseFloorDb, clipped, dropouts.count) + "\nFrequenzgang (rel. 1 kHz, dB): " + fr
        }
    }

    /// Aufnahme `rec` (ein Kanal) gegen das Signal auswerten
    public static func analyze(rec: [Float], rate: Double) -> Report {
        var r = Report()
        let L = Layout(rate: rate), ref = signal(rate: rate)
        r.clipped = rec.reduce(0) { $0 + (abs($1) >= 0.999 ? 1 : 0) }
        // Latenz: erster Klick über der Schwelle (Grundrauschen der ersten 0,4 s × 8, mind. 0,01)
        let pre = rec.prefix(Int(rate * 0.4)).map { abs($0) }.max() ?? 0
        let thr = max(0.01, pre * 8)
        guard let first = rec.firstIndex(where: { abs($0) > thr }) else { r.problem = "kein Signal in der Aufnahme"; return r }
        let peakA = peak(rec, around: first, span: Int(rate * 0.003))
        let lat = peakA - L.clicksA
        r.latencyFrames = lat; r.latencyMs = Double(lat) / rate * 1000
        // Drift: zweite Klickgruppe
        let expB = L.clicksB + lat
        if expB + Int(rate * 0.01) < rec.count {
            let pb = peak(rec, around: expB, span: Int(rate * 0.01))
            r.driftPPM = Double(pb - expB) / Double(L.clicksB - L.clicksA) * 1e6
        }
        func seg(_ start: Int, _ len: Int) -> ArraySlice<Float>? {
            let a = start + lat, b = a + len
            return a >= 0 && b <= rec.count ? rec[a..<b] : nil
        }
        // Pegel und THD+N am 1-kHz-Abschnitt (Rand 10 % weg)
        let m = L.sineLen / 10
        guard let s1 = seg(L.sineStart + m, L.sineLen - 2 * m) else { r.problem = "Aufnahme zu kurz"; return r }
        let fit = sineFit(Array(s1), hz: 1000, rate: rate)
        r.gainDb = 20 * log10(max(fit.amp, 1e-12) / toneLevel)
        r.thdnDb = 20 * log10(max(fit.residualRMS, 1e-12) / max(fit.amp / sqrt(2), 1e-12))
        // Frequenzgang: Stufen, relativ zu 1 kHz
        for (j, f) in tones.enumerated() where f < rate / 2 {
            let mm = L.toneLen / 5
            guard let s = seg(L.tonesStart + j * L.toneLen + mm, L.toneLen - 2 * mm) else { continue }
            let a = sineFit(Array(s), hz: f, rate: rate).amp
            r.response.append((f, 20 * log10(max(a, 1e-12) / max(fit.amp, 1e-12))))
        }
        // Grundrauschen
        if let s = seg(L.silenceStart + L.silenceLen / 4, L.silenceLen / 2) {
            let rms = sqrt(s.reduce(0) { $0 + Double($1) * Double($1) } / Double(s.count))
            r.noiseFloorDb = 20 * log10(max(rms, 1e-12))
        }
        // Aussetzer: 10-ms-Fenster im Rauschen, Korrelation Aufnahme / Signal (mit Pegel und Drift-Korrektur)
        let g = Float(pow(10, r.gainDb / 20)), w = Int(rate * 0.01)
        var i = 0
        while i + w <= L.noiseLen {
            let drift = Int((Double(L.noiseStart + i - L.clicksA) * r.driftPPM / 1e6).rounded())
            let a = L.noiseStart + i + lat + drift
            guard a >= 0, a + w <= rec.count else { break }
            var dot = 0.0, ee = 0.0, rr = 0.0
            for k in 0..<w {
                let x = Double(ref[L.noiseStart + i + k] * g), y = Double(rec[a + k])
                dot += x * y; ee += x * x; rr += y * y
            }
            let c = dot / max(sqrt(ee * rr), 1e-12)
            if c < 0.5 { r.dropouts.append(Double(i) / rate) }
            i += w
        }
        r.ok = r.problem == nil
        return r
    }

    /// größter Betrag um `at` (± span)
    static func peak(_ x: [Float], around at: Int, span: Int) -> Int {
        let a = max(0, at - span), b = min(x.count - 1, at + span)
        guard a <= b else { return at }
        var best = a
        for i in a...b where abs(x[i]) > abs(x[best]) { best = i }
        return best
    }

    /// Sinus bekannter Frequenz einpassen (kleinste Quadrate auf sin/cos + Gleichanteil): Amplitude, Rest-RMS
    public static func sineFit(_ x: [Float], hz: Double, rate: Double) -> (amp: Double, residualRMS: Double) {
        var ss = 0.0, cc = 0.0, sc = 0.0, xs = 0.0, xc = 0.0, sum = 0.0
        let n = Double(x.count)
        for (i, v) in x.enumerated() {
            let p = 2 * .pi * hz * Double(i) / rate, s = sin(p), c = cos(p), d = Double(v)
            ss += s * s; cc += c * c; sc += s * c; xs += d * s; xc += d * c; sum += d
        }
        let det = ss * cc - sc * sc
        guard abs(det) > 1e-12 else { return (0, 0) }
        let a = (xs * cc - xc * sc) / det, b = (xc * ss - xs * sc) / det, dc = sum / n
        var res = 0.0
        for (i, v) in x.enumerated() {
            let p = 2 * .pi * hz * Double(i) / rate
            let e = Double(v) - (a * sin(p) + b * cos(p) + dc)
            res += e * e
        }
        return (sqrt(a * a + b * b), sqrt(res / n))
    }
}
