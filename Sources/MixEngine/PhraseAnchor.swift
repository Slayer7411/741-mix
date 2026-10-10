import Accelerate
import Foundation
import MixCore

/// Phrasen-Anker: liegt Beat 0 des Grids auf einem Takt- und 8-Takt-Phrasenanfang?
/// Der Anker aus der Collection sitzt oft auf dem ersten hörbaren Schlag – abgeschnittener erster Schlag oder Auftakt
/// verschieben dann Takte und Phrasen um 1–3 Beats. Gesucht wird die Verschiebung in ganzen Beats (BPM bleibt,
/// Rasterlinien bleiben, nur die Zählung wandert), bei der die Strukturwechsel des Tracks auf 8-Takt-Grenzen fallen.
public enum PhraseAnchor {
    public struct Result: Equatable, Sendable {
        /// Anker um so viele ganze Beats verschieben (+ = später), −15 … +16; 0 = passt
        public var shiftBeats: Int
        /// Sicherheit 0 … 1: Anteil der Wechsel-Stärke, den die Verschiebung zusätzlich auf Phrasengrenzen bringt
        public var confidence: Double
        /// gefundene Strukturwechsel
        public var boundaries: Int

        public init(shiftBeats: Int, confidence: Double, boundaries: Int) {
            self.shiftBeats = shiftBeats; self.confidence = confidence; self.boundaries = boundaries
        }
        public static let none = Result(shiftBeats: 0, confidence: 0, boundaries: 0)

        /// Vorschlag, der angezeigt bzw. übernommen wird
        public var suggests: Bool { shiftBeats != 0 && confidence >= PhraseAnchor.threshold }
    }

    /// ab dieser Sicherheit gilt ein Vorschlag
    public static let threshold = 0.3
    /// Phrase = 8 Takte
    public static let phraseBeats = 32

    /// Gewicht eines Wechsels je Lage in der Phrase (Beats ab Phrasenanfang): Phrase 1, halbe 0.5, Viertel 0.3, Takt 0.12, sonst 0
    static let lattice: [Double] = (0..<phraseBeats).map { j in
        j == 0 ? 1 : j % 16 == 0 ? 0.5 : j % 8 == 0 ? 0.3 : j % 4 == 0 ? 0.12 : 0
    }

    public static func analyze(_ a: TrackAudio, grid: BeatGrid) -> Result {
        analyze(left: a.left, right: a.right, frames: a.frames, sampleRate: a.sampleRate, grid: grid)
    }

    public static func analyze(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int, sampleRate: Double,
                               grid: BeatGrid) -> Result {
        guard let f = beatFeatures(left: left, right: right, frames: frames, sampleRate: sampleRate, grid: grid) else { return .none }
        return decide(boundaries(f.features, from: f.start, to: f.end), firstBeat: f.firstBeat)
    }

    // MARK: Merkmale je Beat

    /// Bandgrenzen (Hz), ungefähr Terzen/Oktaven: Kick, Bass, Mitten, Hats getrennt
    static let bandEdges: [Double] = [30, 60, 100, 160, 250, 400, 630, 1000, 1600, 2500, 4000, 6300, 10000, 16000]

    struct Features {
        /// je Beat die Bandpegel in dB (Index 0 = Beat `firstBeat` relativ zum Anker)
        var features: [[Float]]
        var firstBeat: Int
        /// Musikbereich (Indizes), davor/danach Stille
        var start: Int, end: Int
    }

    /// Spektrum (2048er FFT, Hop 1024) → mittlere Bandenergie je Beat → dB, nach unten auf 50 dB unter dem lauten Pegel begrenzt
    static func beatFeatures(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int, sampleRate: Double,
                             grid: BeatGrid) -> Features? {
        let n = 2048, hop = 1024, log2n = vDSP_Length(11)
        guard grid.bpm > 0, frames > n * 4, let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(setup) }
        let beat = grid.beat
        let firstBeat = Int(((0 - grid.anchor) / beat).rounded(.up))
        let lastBeat = Int(((Double(frames) / sampleRate - grid.anchor) / beat).rounded(.down)) - 1
        let beats = lastBeat - firstBeat + 1
        guard beats >= 64 else { return nil }
        let bands = bandEdges.count - 1
        let bins = bandEdges.map { min(n / 2, max(1, Int(($0 * Double(n) / sampleRate).rounded()))) }

        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        var frame = [Float](repeating: 0, count: n)
        var re = [Float](repeating: 0, count: n / 2), im = [Float](repeating: 0, count: n / 2)
        var mag = [Float](repeating: 0, count: n / 2)
        var acc = [Float](repeating: 0, count: beats * bands)
        var cnt = [Int](repeating: 0, count: beats)

        let frameCount = (frames - n) / hop + 1
        for fi in 0..<frameCount {
            let s = fi * hop
            // Rahmenmitte, 1/16 Beat vorgezogen: der Anschlag am Beat zählt zu seinem Beat
            let t = (Double(s) + Double(n) / 2) / sampleRate
            let b = Int(((t - grid.anchor) / beat + 1.0 / 16).rounded(.down)) - firstBeat
            guard b >= 0, b < beats else { continue }
            vDSP_vadd(left + s, 1, right + s, 1, &frame, 1, vDSP_Length(n))
            vDSP_vmul(frame, 1, window, 1, &frame, 1, vDSP_Length(n))
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    frame.withUnsafeBufferPointer { fp in
                        fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvmags(&split, 1, &mag, 1, vDSP_Length(n / 2))
                }
            }
            mag.withUnsafeBufferPointer { m in
                for k in 0..<bands where bins[k + 1] > bins[k] {
                    var sum: Float = 0
                    vDSP_sve(m.baseAddress! + bins[k], 1, &sum, vDSP_Length(bins[k + 1] - bins[k]))
                    acc[b * bands + k] += sum
                }
            }
            cnt[b] += 1
        }

        var feats = [[Float]](repeating: [Float](repeating: 0, count: bands), count: beats)
        var loud = [Float](repeating: -200, count: beats)
        for b in 0..<beats where cnt[b] > 0 {
            var total: Float = 0
            for k in 0..<bands {
                let e = acc[b * bands + k] / Float(cnt[b])
                total += e
                feats[b][k] = 10 * log10(e + 1e-12)
            }
            loud[b] = 10 * log10(total + 1e-12)
        }
        // Musikbereich: Beats bis 30 dB unter dem lauten Pegel
        let loudRef = percentile(loud, 0.9)
        guard let start = loud.firstIndex(where: { $0 > loudRef - 30 }),
              let end = loud.lastIndex(where: { $0 > loudRef - 30 }), end - start >= 64 else { return nil }
        // Boden je Band: leise Bänder rauschen sonst in die Abstände
        for k in 0..<bands {
            let floor = percentile(feats[start...end].map { $0[k] }, 0.95) - 50
            for b in 0..<beats { feats[b][k] = max(feats[b][k], floor) }
        }
        return Features(features: feats, firstBeat: firstBeat, start: start, end: end)
    }

    // MARK: Strukturwechsel

    /// Wechsel-Kurve (Abstand der mittleren Bandpegel W Beats vor/nach jedem Beat, W = 4/8/16), Spitzen über dem
    /// gleitenden Median = Strukturwechsel. Ganze Takte je Fenster: Muster innerhalb eines Taktes heben sich auf.
    static func boundaries(_ f: [[Float]], from start: Int, to end: Int) -> [(index: Int, strength: Double)] {
        guard let bands = f.first?.count else { return [] }
        let count = f.count
        // Präfixsummen je Band
        var prefix = [[Double]](repeating: [Double](repeating: 0, count: bands), count: count + 1)
        for i in 0..<count { for k in 0..<bands { prefix[i + 1][k] = prefix[i][k] + Double(f[i][k]) } }
        func mean(_ a: Int, _ b: Int, _ k: Int) -> Double { (prefix[b][k] - prefix[a][k]) / Double(b - a) }

        var nov = [Double](repeating: 0, count: count)
        let scales = [4, 8, 16]
        let lo = start + scales[0], hi = end + 1 - scales[0]   // Fenster ganz in der Musik: kein Wechsel aus der Stille
        guard hi > lo else { return [] }
        for i in lo...hi {
            var sum = 0.0, used = 0
            for w in scales where i - w >= start && i + w <= end + 1 {
                var d2 = 0.0
                for k in 0..<bands { let d = mean(i, i + w, k) - mean(i - w, i, k); d2 += d * d }
                sum += d2.squareRoot(); used += 1
            }
            nov[i] = used > 0 ? sum / Double(used) : 0
        }
        var out: [(Int, Double)] = []
        for i in lo...hi {
            let v = nov[i]
            // Spitze über ±2 Beats (bei Gleichstand zählt die erste)
            guard (max(lo, i - 2)..<i).allSatisfy({ nov[$0] < v }), (i + 1..<min(hi, i + 2) + 1).allSatisfy({ nov[$0] <= v }) else { continue }
            let base = median(Array(nov[max(lo, i - 16)...min(hi, i + 16)]))
            if v - base > 0 { out.append((i, v - base)) }
        }
        // nur deutliche Wechsel: ab einem Drittel der Stärke der kräftigsten
        let strong = out.map(\.1).sorted(by: >)
        let ref = strong.prefix(3).reduce(0, +) / Double(max(1, min(3, strong.count)))
        return out.filter { $0.1 >= ref / 3 }.map { (index: $0.0, strength: $0.1) }
    }

    // MARK: Entscheidung

    /// Verschiebung s (Beats) wählen, die die Wechsel-Stärke auf Phrasen-/Taktgrenzen maximiert; kleine |s| gewinnen bei
    /// Gleichstand, 0 bleibt ohne klaren Vorsprung
    static func decide(_ bounds: [(index: Int, strength: Double)], firstBeat: Int) -> Result {
        guard bounds.count >= 4 else { return Result(shiftBeats: 0, confidence: 0, boundaries: bounds.count) }
        // Gewicht je Wechsel höchstens das Doppelte des mittleren: ein einzelner großer Wechsel (Intro, Ende) entscheidet nicht allein
        let cap = 2 * median(bounds.map(\.strength))
        let weights = bounds.map { min($0.strength, cap) }
        let total = weights.reduce(0, +)
        guard total > 0 else { return Result(shiftBeats: 0, confidence: 0, boundaries: bounds.count) }
        func pos(_ b: Int, _ s: Int) -> Int { ((bounds[b].index + firstBeat - s) % phraseBeats + phraseBeats) % phraseBeats }
        func score(_ s: Int) -> Double { bounds.indices.reduce(0) { $0 + weights[$1] * lattice[pos($1, s)] } }
        // Reihenfolge 0, 1, −1, 2, −2, …, 16: bei Gleichstand gewinnt die kleinere Verschiebung
        var best = 0, bestScore = score(0)
        let zero = bestScore
        for s in (1...16).flatMap({ [$0, -$0] }) where s > -16 {
            let v = score(s)
            if v > bestScore + 1e-9 * total { best = s; bestScore = v }
        }
        // mindestens 3 Wechsel auf Phrasen-Achteln (0/8/16/24) der gewählten Lage, sonst entsprechend unsicher
        let support = bounds.indices.filter { pos($0, best) % 8 == 0 }.count
        let conf = (bestScore - zero) / total * min(1, Double(support) / 3)
        return Result(shiftBeats: best, confidence: conf, boundaries: bounds.count)
    }

    // MARK: Helfer

    static func percentile(_ a: [Float], _ p: Double) -> Float {
        guard !a.isEmpty else { return 0 }
        let s = a.sorted()
        return s[min(s.count - 1, Int(Double(s.count - 1) * p))]
    }

    static func median(_ a: [Double]) -> Double {
        guard !a.isEmpty else { return 0 }
        let s = a.sorted()
        return s[s.count / 2]
    }
}

/// Grid-Anker auf Phrasen ausrichten (Einstellung)
public enum PhraseAnchorMode: String, CaseIterable, Codable, Sendable {
    case off = "Aus", suggest = "Vorschlagen", auto = "Automatisch"
}

extension DeckState {
    /// offener Phrasen-Vorschlag in ganzen Beats relativ zum jetzigen Anker (nil = keiner / schon übernommen)
    public var phraseSuggestion: Int? {
        guard let t = phraseTarget, let g = grid, g.bpm > 0 else { return nil }
        let n = Int(((t - g.anchor) / g.beat).rounded())
        return n == 0 ? nil : n
    }
}
