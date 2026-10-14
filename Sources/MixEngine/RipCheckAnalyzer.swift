import Accelerate
import AVFoundation
import Foundation
import MixCore

/// Rip-Prüfung über ein dekodiertes Signal (gleicher Durchlauf wie `TrackAnalyzer`, nie im Render-Pfad).
///
/// Verfahren:
/// * Stille: 100-ms-Blöcke (Leistung beider Kanäle) gegen `silenceDb`; Beginn auf 10 ms genau (Mono, ~11 kHz).
///   Schnitt IN auf den Beat davor (nichts Hörbares abschneiden), Schnitt OUT auf den Beat danach
/// * Fremder Anfang / fremdes Ende: Merkmale je Bild (Chroma 12 je 125 ms mit der Schwelle der Tonart, Bandpegel
///   10 Bänder je ~10 ms, Bass-Anschläge) als Präfixsummen; je Kandidat (alle 125 ms im Suchbereich) Mittel „fremd“
///   (Musikbeginn bis Kandidat), „Track“ (16 s dahinter) und „Rest“ (bis Musikende). Bruch, wenn beide Seiten tonal
///   sind, sich die Chroma kaum ähneln, die Tonarten nicht verwandt sind, der fremde Teil weder dem Rest im Mittel noch
///   einem 8-s-Fenster darin ähnelt, „Track“ dem Rest ähnelt, der fremde Teil laut ist und an der Dateigrenze hart
///   anliegt. Ohne Tonart nur über das Tempo: eigenes, deutlich anderes Tempo und ein Klang, den der Rest nicht hat.
///   Reine Lautheits- oder Spektrumswechsel (Breakdown-Intro, Filter, Ausklang) sind kein Befund. Stelle auf den
///   stärksten Anschlag ±0,25 s, dann auf den Beat dahinter (Anfang) bzw. davor (Ende)
/// * Loop-Hinweis: fremder Teil ≥ 2 × 4 bzw. 8 Takte (eigenes Tempo) und Bandverlauf um diese Länge versetzt korreliert
/// * Grid-Verdacht: Anker im fremden Anfang, Beat-Phase der ersten 30 s gegen den Rest versetzt, lokales Tempo der
///   ersten 30 s abweichend
extension RipCheck {
    public struct Params: Sendable, Equatable {
        /// Musik beginnt über diesem Pegel (dBFS, mittlere Leistung): leises Rauschen alter Aufnahmen liegt darunter
        public var silenceDb = -45.0
        /// Stille vorne ab dieser Länge ist ein Befund (s); kürzere Pausen sind Absicht oder Encoder-Vorlauf
        public var minSilence = 2.0
        /// Stille hinten ab dieser Länge (s): Veröffentlichungen enden oft mit 2–5 s Ausklang unter der Schwelle
        public var minSilenceEnd = 6.0
        /// Suchbereich für fremdes Material (s ab Musikbeginn bzw. vor Musikende), höchstens `maxShare` der Dauer
        public var searchSpan = 90.0
        public var maxShare = 0.4
        public init() {}
    }

    /// Schwellen der Bruch-Erkennung
    enum Limits {
        /// kürzester fremder Teil (s): zwei Takte bei 160 BPM; kürzer sind Effekte, Fills, Schlussakkorde
        static let minForeign = 3.0
        /// Vergleichsfenster „Track“ hinter dem Bruch (s): 8 Takte bei 120 BPM
        static let trackWindow = 16.0
        /// Abstand der Fenster zur Bruchstelle (s): Chroma-Bilder sind 250 ms lang
        static let guardSpan = 0.15
        /// Chroma-Korrelation fremd ↔ Track höchstens: gleiche Tonart, Relativ und Nachbar liegen über 0,5
        static let maxCorrForeign = 0.3
        /// fremd ↔ Rest höchstens: auch der übrige Track hat diese Tonart nicht
        static let maxCorrRest = 0.4
        /// fremd ↔ jedes 8-s-Fenster im Rest höchstens: Intro- und Outro-Teile eines Tracks kommen im Track wieder
        /// (Breakdown, Bridge), Reste eines anderen Tracks nicht
        static let maxRecurrence = 0.5
        /// fremder Teil höchstens so viel leiser als der Track (dB): Reste sind volle Musik bis zum harten Schnitt,
        /// Ausklang, Hall-Fahnen und Einblendungen sind leiser
        static let maxQuieter = 8.0
        /// Rand an der Dateigrenze (Musikbeginn bzw. -ende, 1 s) höchstens so viel leiser als der fremde Teil (dB):
        /// ein Rest ist dort hart angeschnitten, ein Ausklang oder eine Einblendung nicht
        static let maxEdgeDrop = 6.0
        /// Tempo-Weg: kein Fenster im Rest klingt so nah am fremden Teil (Vielfaches des üblichen Abstands)
        static let minSpectrumRecurrence = 1.0
        /// Track ↔ Rest mindestens: der Teil hinter dem Bruch gehört zum Track
        static let minCorrTrack = 0.6
        /// tonal: mindestens 3 Tonklassen über 20 % der stärksten (Akkord, Bass + Melodie; Kick allein ist eine)
        static let minPitchClasses = 3
        /// tonal: Chroma-Masse je Bild mindestens dieser Anteil des Medians im Track (leise Reste zählen nicht)
        static let minMass = 0.2
        /// Tempo-Weg: Tempo des fremden Teils weicht mindestens so viel ab (relativ), Phasenbindung ans eigene Tempo
        /// mindestens `minOwnR` und um `minRGain` stärker als ans Grid
        static let minTempoShift = 0.012
        static let minOwnR = 0.5
        static let minRGain = 0.25
        /// Tempo-Weg: Bandpegel-Abstand mindestens dieses Vielfache des üblichen Abstands im Track
        static let minSpectrumRatio = 1.5
        /// Loop: Bandverlauf um 4 bzw. 8 Takte versetzt mindestens so korreliert
        static let loopCorr = 0.8
        /// Grid: Phasenversatz der ersten 30 s ab 25 ms, lokales Tempo ab 1 % Abweichung
        static let phaseMs = 25.0
        static let drift = 0.01
    }

    // MARK: Einstieg

    /// Prüfung eines fertig dekodierten Signals (Tests). `bpm` 0 = ohne Grid (Schnitte nicht auf dem Beat)
    public static func check(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int, sampleRate rate: Double,
                             bpm: Double, anchor: Double, params: Params = Params(), checkpoint: () throws -> Void = {}) throws -> Result {
        var s = TrackAnalyzer.Stream(rate: rate, frames: frames)
        var i = 0
        while i < frames {
            let n = min(1 << 15, frames - i)
            s.feed(left + i, right + i, n)
            i += n
        }
        guard s.frames > 0 else { throw TrackAudio.DecodeError.format }
        return try check(stream: s, bpm: bpm, anchor: anchor, params: params, checkpoint: checkpoint)
    }

    static func check(stream s: TrackAnalyzer.Stream, bpm: Double, anchor: Double, params p: Params,
                      checkpoint: () throws -> Void) throws -> Result {
        let duration = Double(s.frames) / s.rate
        var r = Result(duration: duration)
        guard let audible = audibleRange(s, params: p), let nov = TrackAnalyzer.novelty(s.x, rate: s.lowRate) else { return r }
        try checkpoint()
        let f = Features(stream: s, novelty: nov)
        let grid = bpm > 0 && bpm.isFinite ? (bpm: bpm, anchor: anchor) : nil
        let ctx = Context(f: f, grid: grid, audible: audible, duration: duration, params: p)
        var startCut = audible.lowerBound
        if let fs = ctx.foreign(edge: .start) {
            r.findings.append(fs)
            startCut = fs.time
        } else if audible.lowerBound >= p.minSilence {
            var x = Finding(kind: .silence, edge: .start, time: ctx.snap(audible.lowerBound, after: false), confidence: 0.95, cues: [.silence])
            x.time = min(x.time, audible.lowerBound)
            r.findings.append(x)
        }
        try checkpoint()
        if let fe = ctx.foreign(edge: .end) {
            r.findings.append(fe)
        } else if duration - audible.upperBound >= p.minSilenceEnd {
            r.findings.append(Finding(kind: .silence, edge: .end, time: ctx.snap(audible.upperBound, after: true), confidence: 0.95, cues: [.silence]))
        }
        try checkpoint()
        if let g = ctx.gridSuspect(from: startCut, foreign: r.start?.kind == .foreign) { r.findings.append(g) }
        return r
    }

    /// Musikbereich: erster / letzter 100-ms-Block über `silenceDb`, Beginn auf 10 ms genau
    static func audibleRange(_ s: TrackAnalyzer.Stream, params p: Params) -> ClosedRange<Double>? {
        var blocks = s.blocks
        if s.inBlock > s.block / 2 { blocks.append(Float(s.acc / Double(s.inBlock))) }
        let thr = Float(pow(10, p.silenceDb / 10))
        guard let first = blocks.firstIndex(where: { $0 > thr }), let last = blocks.lastIndex(where: { $0 > thr }) else { return nil }
        let sec = Double(s.block) / s.rate
        var start = Double(first) * sec
        // fein: erstes 10-ms-Stück über der Schwelle im Block davor bis Blockende
        let n = max(1, Int(s.lowRate / 100))
        let a = max(0, Int((start - sec) * s.lowRate)), b = min(s.x.count, Int((start + sec) * s.lowRate))
        var i = a
        while i + n <= b {
            var ms: Float = 0
            s.x.withUnsafeBufferPointer { vDSP_measqv($0.baseAddress! + i, 1, &ms, vDSP_Length(n)) }
            if ms > thr { start = Double(i) / s.lowRate; break }
            i += n
        }
        let end = min(Double(s.frames) / s.rate, Double(last + 1) * sec)
        return start...max(start, end)
    }

    // MARK: Merkmale

    struct Features {
        /// Chroma je Bild (12, Pegel über der Tonart-Schwelle, maskiert), Masse je Bild; Bild i mittig bei (i+1)·hop
        var chroma: [Double]
        var mass: [Double]
        let chromaHop: Double
        let chromaCount: Int
        /// Präfixsummen: Chroma (12 je Bild), Masse, Bänder (je Novelty-Bild), Bass-Anschläge
        var chromaSum: [Double], massSum: [Double], bandSum: [Double]
        let bandCount: Int
        let nov: TrackAnalyzer.Novelty
        /// üblicher Abstand der Bandpegel zweier 8-s-Fenster im Track (dB)
        var spectrumScale = 1.0
        /// Median der Chroma-Masse tonaler Bilder
        var medianMass = 0.0

        init(stream s: TrackAnalyzer.Stream, novelty: TrackAnalyzer.Novelty) {
            nov = novelty
            let k = TrackAnalyzer.KeyParams()
            let fr = s.chroma
            let p = TrackAnalyzer.ChromaFrames.count, n = fr.db.count / p
            chromaCount = n
            chromaHop = Double(fr.hop) / s.midRate
            chroma = [Double](repeating: 0, count: n * 12)
            mass = [Double](repeating: 0, count: n)
            if n > 0 {
                var maxima = [Float](repeating: 0, count: n)
                fr.db.withUnsafeBufferPointer { d in
                    for i in 0..<n { vDSP_maxv(d.baseAddress! + i * p, 1, &maxima[i], vDSP_Length(p)) }
                }
                let ref = PhraseAnchor.percentile(maxima, 0.95)
                // wie TrackAnalyzer.chroma, nur je Bild
                let thr = (0..<p).map { i -> Float in
                    let m = TrackAnalyzer.ChromaFrames.low + i
                    let lift = m < k.tiltEnd ? k.tilt * Float(k.tiltEnd - max(m, k.foldLow)) / Float(max(1, k.tiltEnd - k.foldLow)) : 0
                    return ref - k.range + lift
                }
                var v = [Float](repeating: 0, count: p)
                for i in 0..<n {
                    for j in 0..<p { v[j] = max(0, fr.db[i * p + j] - thr[j]) }
                    for j in 0..<p {
                        let m = TrackAnalyzer.ChromaFrames.low + j
                        guard m >= k.foldLow, m <= k.foldHigh, v[j] > 0 else { continue }
                        var sum: Float = 0, cnt = 0
                        for d in 1...k.maskWidth {
                            if j - d >= 0 { sum += v[j - d]; cnt += 1 }
                            if j + d < p { sum += v[j + d]; cnt += 1 }
                        }
                        let e = v[j] - sum / Float(max(1, cnt))
                        if e > 0 { chroma[i * 12 + m % 12] += Double(e); mass[i] += Double(e) }
                    }
                }
            }
            chromaSum = [Double](repeating: 0, count: (n + 1) * 12)
            massSum = [Double](repeating: 0, count: n + 1)
            for i in 0..<n {
                for c in 0..<12 { chromaSum[(i + 1) * 12 + c] = chromaSum[i * 12 + c] + chroma[i * 12 + c] }
                massSum[i + 1] = massSum[i] + mass[i]
            }
            bandCount = novelty.bandCount
            let m = novelty.bands.count / max(1, bandCount)
            bandSum = [Double](repeating: 0, count: (m + 1) * bandCount)
            for i in 0..<m {
                for b in 0..<bandCount { bandSum[(i + 1) * bandCount + b] = bandSum[i * bandCount + b] + Double(novelty.bands[i * bandCount + b]) }
            }
            let tonal = mass.filter { $0 > 0 }.sorted()
            medianMass = tonal.isEmpty ? 0 : tonal[tonal.count / 2]
            // üblicher Abstand: Nachbarfenster 8 s, Hop 4 s, Median
            let total = Double(m) / novelty.fps
            var d: [Double] = []
            var t = 0.0
            while t + 16 <= total {
                if let a = bands(t, t + 8), let b = bands(t + 8, t + 16) { d.append(Self.distance(a, b)) }
                t += 4
            }
            spectrumScale = max(1, d.isEmpty ? 1 : d.sorted()[d.count / 2])
        }

        /// Chroma-Bilder mit Mitte in [a, b)
        func chromaFrames(_ a: Double, _ b: Double) -> Range<Int> {
            let i0 = max(0, min(chromaCount, Int(ceil(a / chromaHop - 1)))), i1 = max(0, min(chromaCount, Int(ceil(b / chromaHop - 1))))
            return i0..<max(i0, i1)
        }

        /// Mittel-Chroma und mittlere Masse je Bild in [a, b)
        func chroma(_ a: Double, _ b: Double) -> (c: [Double], mass: Double)? {
            let r = chromaFrames(a, b)
            guard r.count >= 4 else { return nil }
            let c = (0..<12).map { (chromaSum[r.upperBound * 12 + $0] - chromaSum[r.lowerBound * 12 + $0]) / Double(r.count) }
            return (c, (massSum[r.upperBound] - massSum[r.lowerBound]) / Double(r.count))
        }

        /// Bandpegel in dB, um ihr Mittel verschoben (Form, nicht Lautheit) in [a, b)
        func bands(_ a: Double, _ b: Double) -> [Double]? {
            let m = bandSum.count / bandCount - 1
            let i0 = max(0, min(m, Int(a * nov.fps))), i1 = max(0, min(m, Int(b * nov.fps)))
            guard i1 - i0 >= 20 else { return nil }
            let db = (0..<bandCount).map { 10 * log10(max(1e-12, (bandSum[i1 * bandCount + $0] - bandSum[i0 * bandCount + $0]) / Double(i1 - i0))) }
            let mean = db.reduce(0, +) / Double(db.count)
            return db.map { $0 - mean }
        }

        static func distance(_ a: [Double], _ b: [Double]) -> Double {
            (zip(a, b).map { ($0 - $1) * ($0 - $1) }.reduce(0, +) / Double(max(1, a.count))).squareRoot()
        }

        /// tonal: genug Masse und mindestens drei deutliche Tonklassen
        func tonal(_ c: (c: [Double], mass: Double)) -> Bool {
            guard medianMass > 0, c.mass >= Limits.minMass * medianMass, let top = c.c.max(), top > 0 else { return false }
            return c.c.filter { $0 >= 0.2 * top }.count >= Limits.minPitchClasses
        }

        /// mittlere Leistung aller Bänder in [a, b) (dB)
        func level(_ a: Double, _ b: Double) -> Double {
            let m = bandSum.count / bandCount - 1
            let i0 = max(0, min(m, Int(a * nov.fps))), i1 = max(0, min(m, Int(b * nov.fps)))
            guard i1 > i0 else { return -200 }
            var e = 0.0
            for k in 0..<bandCount { e += bandSum[i1 * bandCount + k] - bandSum[i0 * bandCount + k] }
            return 10 * log10(max(1e-12, e / Double(i1 - i0)))
        }

        /// größte Chroma-Korrelation mit einem tonalen 8-s-Fenster (Hop 1 s) in `r`
        func recurrence(_ c: [Double], in r: (Double, Double)) -> Double {
            var best = -1.0, t = r.0
            while t + 8 <= r.1 {
                if let w = chroma(t, t + 8), tonal(w) { best = max(best, TrackAnalyzer.correlation(c, w.c)) }
                t += 1
            }
            return best
        }

        /// kleinster Bandpegel-Abstand (Vielfaches des üblichen) zu einem 8-s-Fenster (Hop 1 s) in `r`
        func spectrumRecurrence(_ b: [Double], in r: (Double, Double)) -> Double {
            var best = Double.infinity, t = r.0
            while t + 8 <= r.1 {
                if let w = bands(t, t + 8) { best = min(best, Self.distance(b, w) / spectrumScale) }
                t += 1
            }
            return best
        }

        /// Bindung der Bass-Anschläge an ein Beat-Raster in [a, b): Länge des mittleren Zeigers 0…1, Phase in Beats
        /// (−0,5…0,5), mittlere Stärke
        func circular(_ a: Double, _ b: Double, bpm: Double, origin: Double) -> (r: Double, phase: Double, energy: Double) {
            let v = nov.low, fps = nov.fps, period = 60 / bpm
            let i0 = max(0, Int(a * fps)), i1 = min(v.count, Int(b * fps))
            guard i1 > i0 else { return (0, 0, 0) }
            var sc = 0.0, ss = 0.0, sum = 0.0
            for i in i0..<i1 where v[i] > 0 {
                let w = Double(v[i]), th = 2 * Double.pi * ((Double(i) / fps - origin) / period)
                sc += w * cos(th); ss += w * sin(th); sum += w
            }
            guard sum > 0 else { return (0, 0, 0) }
            return ((sc * sc + ss * ss).squareRoot() / sum, atan2(ss, sc) / (2 * .pi), sum / Double(i1 - i0))
        }

        /// stärkstes eigenes Tempo ±8 % um `bpm` in [a, b) (freie Phase)
        func ownTempo(_ a: Double, _ b: Double, around bpm: Double) -> (bpm: Double, r: Double) {
            var best = (bpm: bpm, r: 0.0)
            var x = bpm * 0.92
            while x <= bpm * 1.08 {
                let c = circular(a, b, bpm: x, origin: a)
                if c.r > best.r { best = (x, c.r) }
                x += 0.1
            }
            return best
        }

        /// Bandverlauf (Summe der Bänder, log) um `lag` versetzt korreliert in [a, b)
        func selfSimilarity(_ a: Double, _ b: Double, lag: Double) -> Double {
            let fps = nov.fps, m = bandSum.count / bandCount - 1
            let i0 = max(0, Int(a * fps)), i1 = min(m, Int(b * fps)), l = Int(lag * fps)
            guard i1 - i0 - l > Int(fps) else { return 0 }
            func e(_ i: Int) -> Double {
                var s = 0.0
                for k in 0..<bandCount { s += Double(nov.bands[i * bandCount + k]) }
                return log10(1e-9 + s)
            }
            let x = (i0..<(i1 - l)).map(e), y = (i0..<(i1 - l)).map { e($0 + l) }
            return TrackAnalyzer.correlation(x, y)
        }

        /// stärkster Anschlag (Spektralfluss) in [a, b)
        func strongestOnset(_ a: Double, _ b: Double) -> Double? {
            let v = nov.frames, fps = nov.fps
            let i0 = max(0, Int(a * fps)), i1 = min(v.count, Int(b * fps))
            guard i1 > i0, let j = (i0..<i1).max(by: { v[$0] < v[$1] }), v[j] > 0 else { return nil }
            return Double(j) / fps
        }
    }

    // MARK: Bruch

    struct Context {
        let f: Features
        let grid: (bpm: Double, anchor: Double)?
        let audible: ClosedRange<Double>
        let duration: Double
        let params: Params

        /// auf den Beat: `after` = Beat an oder nach `t` (Spiel `tol`), sonst an oder vor `t`
        func snap(_ t: Double, after: Bool, tol: Double = 0.008) -> Double {
            guard let g = grid else { return t }
            let beat = 60 / g.bpm
            var b = g.anchor + ((t - g.anchor) / beat).rounded() * beat
            if after, b < t - tol { b += beat }
            if !after, b > t + tol { b -= beat }
            return max(0, min(duration, b))
        }

        struct Candidate {
            var cut: Double
            var score: Double
            var corrForeign = 0.0, corrRest = 0.0, corrTrack = 0.0
            var keyForeign: Int?, keyTrack: Int?
            var spectrum = 0.0
            var tempo: (bpm: Double, r: Double, rGrid: Double)?
        }

        /// fremder Teil am Anfang ([Musikbeginn, c)) bzw. am Ende ([c, Musikende)), Befund mit Schnitt
        func foreign(edge: Edge) -> Finding? {
            let s0 = audible.lowerBound, e0 = audible.upperBound, len = e0 - s0
            let span = min(params.searchSpan, params.maxShare * len)
            guard span >= Limits.minForeign + 1, len >= Limits.trackWindow + 20 else { return nil }
            let g = Limits.guardSpan, w = Limits.trackWindow
            // Bereiche je Kandidat: fremd, Track, Rest
            func parts(_ c: Double) -> (foreign: (Double, Double), track: (Double, Double), rest: (Double, Double)) {
                edge == .start ? ((s0, c - g), (c + g, c + w), (c + g, e0))
                    : ((c + g, e0), (c - w, c - g), (s0, c - g))
            }
            let lo = edge == .start ? s0 + Limits.minForeign : e0 - span
            let hi = edge == .start ? s0 + span : e0 - Limits.minForeign
            var best: Candidate?
            var bestTempo: Candidate?
            var c = lo, step = 0
            while c <= hi {
                defer { c += f.chromaHop; step += 1 }
                let p = parts(c)
                guard let cf = f.chroma(p.foreign.0, p.foreign.1), let ct = f.chroma(p.track.0, p.track.1),
                      let cr = f.chroma(p.rest.0, p.rest.1),
                      let bf = f.bands(p.foreign.0, p.foreign.1), let bt = f.bands(p.track.0, p.track.1) else { continue }
                let spec = Features.distance(bf, bt) / f.spectrumScale
                let lf = f.level(p.foreign.0, p.foreign.1)
                let edgeLevel = edge == .start ? f.level(s0, s0 + 1) : f.level(e0 - 1, e0)
                guard lf >= f.level(p.track.0, p.track.1) - Limits.maxQuieter, edgeLevel >= lf - Limits.maxEdgeDrop else { continue }
                if f.tonal(cf), f.tonal(ct) {
                    let ft = TrackAnalyzer.correlation(cf.c, ct.c), fr = TrackAnalyzer.correlation(cf.c, cr.c)
                    let tr = TrackAnalyzer.correlation(ct.c, cr.c)
                    guard tr >= Limits.minCorrTrack, ft <= Limits.maxCorrForeign, fr <= Limits.maxCorrRest,
                          let kf = TrackAnalyzer.key(chroma: cf.c)?.code, let kt = TrackAnalyzer.key(chroma: ct.c)?.code,
                          Harmony.relation(kf, to: kt).step == .clash,
                          f.recurrence(cf.c, in: p.rest) <= Limits.maxRecurrence else { continue }
                    let score = (1 - ft) + (1 - fr) + 0.2 * min(2, spec)
                    if score > best?.score ?? -1 {
                        best = Candidate(cut: c, score: score, corrForeign: ft, corrRest: fr, corrTrack: tr,
                                         keyForeign: kf, keyTrack: kt, spectrum: spec)
                    }
                } else if best == nil, step % 4 == 0, let gr = grid, spec >= Limits.minSpectrumRatio {
                    // ohne Tonart: eigenes, deutlich anderes Tempo im fremden Teil (alle 0,5 s, höchstens 12 s am Bruch)
                    let a = f.circular(p.track.0, p.track.1, bpm: gr.bpm, origin: gr.anchor)
                    let near = edge == .start ? (max(p.foreign.0, p.foreign.1 - 12), p.foreign.1) : (p.foreign.0, min(p.foreign.1, p.foreign.0 + 12))
                    let b = f.circular(near.0, near.1, bpm: gr.bpm, origin: gr.anchor)
                    guard a.r >= 0.5, b.energy >= 0.3 * a.energy, near.1 - near.0 >= 3 else { continue }
                    let own = f.ownTempo(near.0, near.1, around: gr.bpm)
                    guard own.r >= Limits.minOwnR, own.r - b.r >= Limits.minRGain,
                          abs(own.bpm - gr.bpm) / gr.bpm >= Limits.minTempoShift,
                          f.spectrumRecurrence(bf, in: p.rest) >= Limits.minSpectrumRecurrence else { continue }
                    let score = spec + (own.r - b.r)
                    if score > bestTempo?.score ?? -1 {
                        bestTempo = Candidate(cut: c, score: score, spectrum: spec, tempo: (own.bpm, own.r, b.r))
                    }
                }
            }
            guard let hit = best ?? bestTempo else { return nil }
            // harter Schnitt: stärkster Anschlag ±0,25 s, dann auf den Beat (Anfang: danach, Ende: davor)
            let onset = f.strongestOnset(hit.cut - 0.25, hit.cut + 0.25) ?? hit.cut
            // Spiel 60 ms: das Flussbild liegt ~30 ms vor dem Anschlag
            let cut = snap(onset, after: edge == .start, tol: 0.06)
            let p = parts(hit.cut)
            var x = Finding(kind: .foreign, edge: edge, time: cut, confidence: 0, cues: [])
            var conf: Double
            if hit.tempo == nil {
                x.cues.append(.key)
                x.keyForeign = hit.keyForeign
                x.keyTrack = hit.keyTrack
                conf = 0.45 + 0.25 * min(1, (Limits.maxCorrForeign - hit.corrForeign) / 0.5)
                    + 0.15 * min(1, (hit.corrTrack - Limits.minCorrTrack) / 0.3)
            } else {
                x.cues.append(.tempo)
                x.localBPM = hit.tempo?.bpm
                conf = 0.4 + 0.2 * min(1, ((hit.tempo?.r ?? 0) - (hit.tempo?.rGrid ?? 0)) / 0.5)
            }
            if hit.spectrum >= Limits.minSpectrumRatio { x.cues.append(.spectrum); conf += 0.05 }
            // Länge in Takten (eigenes Tempo des fremden Teils, sonst Grid) und Loop
            if let gr = grid {
                let ownBPM = hit.tempo?.bpm ?? f.ownTempo(p.foreign.0, p.foreign.1, around: gr.bpm).bpm
                let bar = 4 * 60 / ownBPM, length = p.foreign.1 - p.foreign.0 + Limits.guardSpan
                let bars = Int((length / bar).rounded())
                if bars >= 1, abs(length / bar - Double(bars)) < 0.25 { x.bars = bars }
                for n in [4, 8] where length >= 2 * Double(n) * bar - 0.5 {
                    if f.selfSimilarity(p.foreign.0, p.foreign.1, lag: Double(n) * bar) >= Limits.loopCorr {
                        x.cues.append(.loop); x.bars = n; conf += 0.1
                        break
                    }
                }
            }
            x.confidence = min(1, conf)
            return x
        }

        /// Grid-Verdacht am Anfang ab `start` (Musikbeginn bzw. Schnitt IN)
        func gridSuspect(from start: Double, foreign: Bool) -> Finding? {
            guard let g = grid else { return nil }
            let beat = 60 / g.bpm, e0 = audible.upperBound
            var x = Finding(kind: .grid, edge: .start, time: start, confidence: 0, cues: [])
            var conf = 0.0
            // Anker im fremden Anfang und Takte des Grids nicht auf dem Beginn des Tracks
            let bar = 4 * beat, off = (start - g.anchor) / bar
            if foreign, g.anchor >= audible.lowerBound - 0.01, g.anchor < start - beat / 2, abs(off - off.rounded()) * bar > 0.03 {
                x.cues.append(.anchor); x.time = g.anchor; conf = max(conf, 0.7)
            }
            // Phase der ersten 30 s gegen den Rest
            let head = (start, min(e0, start + 30))
            if e0 - head.1 >= 30 {
                let a = f.circular(head.0, head.1, bpm: g.bpm, origin: g.anchor)
                let b = f.circular(head.1, e0, bpm: g.bpm, origin: g.anchor)
                var d = a.phase - b.phase
                d -= d.rounded()
                if a.r >= 0.4, b.r >= 0.4, abs(d) * beat * 1000 >= Limits.phaseMs {
                    x.cues.append(.phase); x.offsetMs = d * beat * 1000; conf = max(conf, 0.5 + 0.3 * min(1, a.r))
                }
                // lokales Tempo
                let own = f.ownTempo(head.0, head.1, around: g.bpm)
                if own.r >= 0.6, own.r - a.r >= 0.2, abs(own.bpm - g.bpm) / g.bpm >= Limits.drift {
                    x.cues.append(.drift); x.localBPM = own.bpm; conf = max(conf, 0.5)
                }
            }
            guard !x.cues.isEmpty else { return nil }
            x.confidence = conf
            return x
        }
    }
}

extension TrackAnalyzer {
    /// eine Datei einmal dekodieren: Analyse (`analyze`) und / oder Rip-Prüfung (`rip`). Grid der Prüfung: `grid`, sonst
    /// das der Analyse (ohne gewünschte Analyse wird sie dafür gerechnet, aber nicht zurückgegeben)
    public static func analyzeAndCheck(url: URL, analyze: Bool, octave: ClosedRange<Double> = defaultOctave, profiles: KeyProfiles? = nil,
                                       rip: Bool, grid: (bpm: Double, anchor: Double)? = nil, params: RipCheck.Params = RipCheck.Params(),
                                       checkpoint: () throws -> Void = {}) throws -> (analysis: Result?, rip: RipCheck.Result?) {
        let s = try decode(url: url, checkpoint: checkpoint)
        var a: Result?
        if analyze || (rip && grid == nil) { a = try self.analyze(stream: s, octave: octave, profiles: profiles, checkpoint: checkpoint) }
        var r: RipCheck.Result?
        if rip {
            let g = grid ?? a.map { (bpm: $0.bpm, anchor: $0.anchor) } ?? (0, 0)
            r = try RipCheck.check(stream: s, bpm: g.bpm, anchor: g.anchor, params: params, checkpoint: checkpoint)
        }
        return (analyze ? a : nil, r)
    }
}
