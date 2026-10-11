import Accelerate
import AVFoundation
import Foundation
import MixCore

/// Eigene Analyse einer Audiodatei: Tempo + Grid-Anker, Tonart, Lautheit. Offline, deterministisch, nur Accelerate.
/// Läuft nie im Render-Pfad (Hintergrund-Arbeiter der Warteschlange, siehe `OverviewJobs`).
///
/// Verfahren:
/// * Datei einmal blockweise lesen; Spitze am vollen Stereosignal, Mono (L+R)/2 um ganzzahlige Faktoren auf ~22 kHz
///   (Tonart, Lautheit, im Durchlauf) und ~11 kHz (Tempo, Anker; ~20 MB je 8 Minuten) dezimiert (FIR, `vDSP_desamp`)
/// * Tempo: Spektralfluss (512er FFT, ~100 Bilder/s) -> Fourier-Tempogramm (FFT des Flusses) mit Kamm über die
///   Beat-Frequenz und ihre Harmonischen (1, ½, ¼) über 60–200 BPM -> Feinsuche als Fourier-Betrag genau bei der
///   Beat-Frequenz (0,001 BPM) -> ganze Beats zwischen Anfang und Ende des Tracks -> BPM aus der Beat-Zahl
///   (Tempo-Konstanz vorausgesetzt); Gegenprobe mit der Mehrheit lokaler Tempi (8-s-Fenster); Ergebnis in die
///   eingestellte Oktave gefaltet. Autokorrelation taugt hier nicht: Lag 1,5·Beat korreliert mit 3 und 6 Beats
/// * Anker: Anschlagsstärke (Anstieg der Hüllkurve, Bass < 150 Hz und ganzes Band) mit 1 ms Auflösung über den ganzen
///   Track auf die Beat-Periode gefaltet -> Lage des Anschlags im Beat auf 1 ms; welcher Beat der Phrasenanfang ist,
///   entscheidet die Phrasen-Logik (`PhraseAnchor`: Strukturwechsel auf 8-Takt-Grenzen), sonst der erste Beat des Tracks
/// * Tonart: Halbton-Pegel in dB je 250-ms-Bild, Schwelle (Tiefen höher), lokale Maskierung, 55 Hz–6,6 kHz gefaltet,
///   gegen Krumhansl- und Temperley-Profile (24 Tonarten, Moll +5 %), Ausgabe wie MUSICAL_KEY (0–11 Dur, 12–23 Moll)
/// * Lautheit: ReplayGain-Verfahren (Kurve gleicher Lautstärke, ~70 ms, 95. Perzentil); PERCEIVED_DB der Collection ist
///   die Verstärkung auf eine Referenz (`loudnessReference` − Pegel)
public enum TrackAnalyzer {
    public struct Result: Equatable, Sendable {
        public var duration: Double
        /// Tempo (0 = nicht gefunden) und Anker (erster Phrasen-/Taktanfang) in Sekunden
        public var bpm: Double
        public var anchor: Double
        /// Sicherheit des Tempos 0…1 (Kamm-Spitze der Autokorrelation)
        public var tempoConfidence: Double
        /// Phrasen-Sicherheit 0…1 (0 = Anker auf dem ersten Beat)
        public var phraseConfidence: Double
        /// MUSICAL_KEY 0–23, −1 = nicht gefunden
        public var musicalKey: Int
        /// Abstand der besten zur zweitbesten Tonart (Korrelation)
        public var keyClarity: Double
        public var perceivedDb: Double
        public var peakDb: Double

        /// als Überlagerung für den Track (fehlende Werte bleiben weg)
        public var analysis: TrackAnalysis {
            TrackAnalysis(bpm: bpm > 0 ? bpm : nil, gridAnchorMs: bpm > 0 ? anchor * 1000 : nil,
                          musicalKey: musicalKey >= 0 ? musicalKey : nil, perceivedDb: perceivedDb, peakDb: peakDb)
        }
    }

    /// Rate für Tonart und Lautheit (Hz); Tempo und Anker auf der Hälfte. Je ein ganzzahliger Dezimierungsfaktor
    static let keyRate = 22050.0
    static let targetRate = 11025.0
    /// Suchbereich des Kamms (mit leichter Bevorzugung von 90–170 BPM gegen 3:2-Verwechslungen); das Ergebnis wird danach
    /// in die eingestellte Oktave gefaltet
    public static let bpmRange = 60.0...200.0
    /// Standard-Oktave des Ergebnisses
    public static let defaultOctave = 100.0...200.0
    /// Lautheit: Referenz minus Pegel (dB, 95. Perzentil der gewichteten 46-ms-Leistung) = PERCEIVED_DB der Collection
    /// (Verstärkung, positiv = leiser Track); Median der Abweichung über 116 lokale Tracks der Collection
    public static let loudnessReference = -14.3

    // MARK: Datei

    /// `octave`: BPM-Bereich des Ergebnisses, genau eine Oktave (Untergrenze zählt, Obergrenze = 2 × Untergrenze)
    public static func analyze(url: URL, octave: ClosedRange<Double> = defaultOctave, checkpoint: () throws -> Void = {}) throws -> Result {
        let s = try decode(url: url, checkpoint: checkpoint)
        return try analyze(stream: s, octave: octave, checkpoint: checkpoint)
    }

    /// Datei blockweise lesen: Spitze am vollen Signal, Mono dezimiert, Tonart und Lautheit im Durchlauf
    static func decode(url: URL, checkpoint: () throws -> Void = {}) throws -> Stream {
        let file = try AVAudioFile(forReading: url)
        let fmt = file.processingFormat
        guard fmt.sampleRate > 0, fmt.channelCount > 0, fmt.commonFormat == .pcmFormatFloat32, !fmt.isInterleaved,
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 1 << 15) else { throw TrackAudio.DecodeError.format }
        var stream = Stream(rate: fmt.sampleRate, frames: Int(file.length))
        while file.framePosition < file.length {
            try checkpoint()
            try file.read(into: buf, frameCount: buf.frameCapacity)
            let n = Int(buf.frameLength)
            guard n > 0, let ch = buf.floatChannelData else { break }
            stream.feed(ch[0], ch[fmt.channelCount > 1 ? 1 : 0], n)
        }
        guard stream.frames > 0 else { throw TrackAudio.DecodeError.format }
        return stream
    }

    /// Analyse eines fertig dekodierten Signals (Tests, Deck)
    public static func analyze(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int, sampleRate rate: Double,
                               octave: ClosedRange<Double> = defaultOctave, checkpoint: () throws -> Void = {}) throws -> Result {
        var stream = Stream(rate: rate, frames: frames)
        var i = 0
        while i < frames {
            let n = min(1 << 15, frames - i)
            stream.feed(left + i, right + i, n)
            i += n
        }
        guard stream.frames > 0 else { throw TrackAudio.DecodeError.format }
        return try analyze(stream: stream, octave: octave, checkpoint: checkpoint)
    }

    static func analyze(stream: Stream, octave: ClosedRange<Double>, checkpoint: () throws -> Void) throws -> Result {
        let x = stream.x, rate = stream.lowRate
        let duration = Double(stream.frames) / stream.rate
        var r = Result(duration: duration, bpm: 0, anchor: 0, tempoConfidence: 0, phraseConfidence: 0, musicalKey: -1,
                       keyClarity: 0, perceivedDb: 0, peakDb: 200)
        let music = stream.musicRange()
        r.perceivedDb = loudnessReference - stream.loud.level()
        // PEAK_DB der Collection = Abstand der Spitze zu 0 dBFS (positiv = darunter)
        r.peakDb = -20 * log10(max(Double(stream.peak), 1e-10))
        try checkpoint()
        // Tempo + Anker: ab 8 s Musik
        if let n = novelty(x, rate: rate), n.frames.count > Int(8 * n.fps),
           let tempo = tempo(n, x: x, rate: rate, music: music, octave: octave) {
            r.bpm = tempo.bpm
            r.tempoConfidence = tempo.confidence
            try checkpoint()
            let a = anchor(x, rate: rate, bpm: tempo.bpm, novelty: n, music: music, duration: duration)
            r.anchor = a.anchor
            r.phraseConfidence = a.phraseConfidence
        }
        try checkpoint()
        if let k = key(stream.chroma) { r.musicalKey = k.code; r.keyClarity = k.clarity }
        return r
    }

    // MARK: Lesen: Spitze, Lautheit, Mono

    /// volles Signal: Spitze, Leistung je 100-ms-Block (Musikbereich); Mono (L+R)/2 -> ~22 kHz (Tonart, Lautheit)
    /// -> ~11 kHz (Tempo, Anker)
    struct Stream {
        let rate: Double
        let block: Int
        var frames = 0
        var peak: Float = 0
        /// mittlere Leistung je Block (Mittel beider Kanäle)
        var blocks: [Float] = []
        var acc: Double = 0, inBlock = 0
        var mono: [Float], mid: [Float] = []
        var toMid: Decimator, toLow: Decimator
        let midRate: Double, lowRate: Double
        var loud: Loudness
        var chroma: ChromaFrames
        /// Mono, ~11 kHz
        var x: [Float] = []

        init(rate: Double, frames: Int = 0) {
            self.rate = rate
            block = max(1, Int(rate / 10))
            let d1 = max(1, Int((rate / keyRate).rounded()))
            midRate = rate / Double(d1)
            let d2 = max(1, Int((midRate / targetRate).rounded()))
            lowRate = midRate / Double(d2)
            toMid = Decimator(factor: d1); toLow = Decimator(factor: d2)
            loud = Loudness(rate: midRate)
            chroma = ChromaFrames(rate: midRate)
            mono = [Float](repeating: 0, count: 1 << 15)
            x.reserveCapacity(frames / (d1 * d2) + 64)
        }

        mutating func feed(_ l: UnsafePointer<Float>, _ r: UnsafePointer<Float>, _ n: Int) {
            var pk: Float = 0
            vDSP_maxmgv(l, 1, &pk, vDSP_Length(n)); peak = max(peak, pk)
            vDSP_maxmgv(r, 1, &pk, vDSP_Length(n)); peak = max(peak, pk)
            if mono.count < n { mono = [Float](repeating: 0, count: n) }
            var half: Float = 0.5
            vDSP_vasm(l, 1, r, 1, &half, &mono, 1, vDSP_Length(n))
            var off = 0
            while off < n {
                let m = min(n - off, block - inBlock)
                var sl: Float = 0, sr: Float = 0
                vDSP_svesq(l + off, 1, &sl, vDSP_Length(m))
                vDSP_svesq(r + off, 1, &sr, vDSP_Length(m))
                acc += Double(sl + sr) / 2
                inBlock += m
                off += m
                if inBlock == block { blocks.append(Float(acc / Double(block))); acc = 0; inBlock = 0 }
            }
            frames += n
            mid.removeAll(keepingCapacity: true)
            toMid.feed(mono, n, into: &mid)
            guard !mid.isEmpty else { return }
            loud.feed(mid)
            chroma.feed(mid)
            toLow.feed(mid, mid.count, into: &x)
        }

        /// Musikbereich in Sekunden: Blöcke bis 35 dB unter dem lautesten
        func musicRange() -> ClosedRange<Double> {
            var all = blocks
            if inBlock > block / 2 { all.append(Float(acc / Double(inBlock))) }
            let db = all.map { 10 * log10(max(Double($0), 1e-12)) }
            guard let top = db.max(), top > -70 else { return 0...max(0, Double(frames) / rate) }
            let first = db.firstIndex { $0 > top - 35 } ?? 0
            let last = db.lastIndex { $0 > top - 35 } ?? max(0, db.count - 1)
            let sec = Double(block) / rate
            return (Double(first) * sec)...max(Double(first) * sec, Double(last + 1) * sec)
        }
    }

    /// Lautheit nach dem ReplayGain-Verfahren: Leistung je 46-ms-Bild (1024er FFT, Hop 23 ms), je Frequenz mit der
    /// umgekehrten Kurve gleicher Lautstärke (80 phon, ISO 226) gewichtet, je zwei Bilder gemittelt (~70 ms);
    /// Pegel = 95. Perzentil in dB (mittlere Leistung eines 1-kHz-Sinus = dBFS RMS). Ohne den 150-Hz-Hochpass des
    /// Originals: an 194 Tracks der Collection 0,29 statt 0,42 dB mittlere Abweichung
    struct Loudness {
        static let n = 1024
        /// Kurve gleicher Lautstärke 80 phon relativ zu 1 kHz, umgekehrt (Hz, dB)
        static let contour: [(Double, Double)] = [
            (20, -39.0), (25, -34.2), (31.5, -29.6), (40, -25.3), (50, -21.7), (63, -18.3), (80, -15.2), (100, -12.5),
            (125, -10.1), (160, -7.8), (200, -5.9), (250, -4.3), (315, -2.9), (400, -1.7), (500, -0.9), (630, -0.2),
            (800, 0.3), (1000, 0), (1250, -2.5), (1600, -3.7), (2000, -0.6), (2500, 2.1), (3150, 2.9), (4000, 1.7),
            (5000, -1.6), (6300, -6.8), (8000, -11.4), (10000, -11.7), (12500, -5.4)]

        static func weightDb(_ f: Double) -> Double {
            let c = contour
            let curve: Double
            if f <= c[0].0 { curve = c[0].1 - 40 * log10(c[0].0 / max(f, 1)) }
            else if f >= c[c.count - 1].0 { curve = c[c.count - 1].1 }
            else {
                let i = c.lastIndex { $0.0 <= f }!
                let t = log(f / c[i].0) / log(c[i + 1].0 / c[i].0)
                curve = c[i].1 + t * (c[i + 1].1 - c[i].1)
            }
            return curve
        }

        let fft = FFT(n: n)
        var weights: [Float]
        var carry: [Float] = []
        var power: [Float] = []
        var mag = [Float](repeating: 0, count: n / 2)

        init(rate: Double) {
            let n = Self.n
            var w2: Float = 0
            vDSP_svesq(fft.window, 1, &w2, vDSP_Length(n))
            // Betrag von vDSP_fft_zrip = 2 × DFT; Σ|X|² / (2 n Σw²) = mittlere Leistung
            let scale = Double(1 / (2 * Float(n) * w2))
            weights = (0..<(n / 2)).map { k in
                k == 0 ? 0 : Float(scale * pow(10, Self.weightDb(Double(k) * rate / Double(n)) / 10))
            }
        }

        mutating func feed(_ x: [Float]) {
            carry.append(contentsOf: x)
            let n = Self.n, hop = n / 2
            var off = 0
            carry.withUnsafeBufferPointer { cp in
                while off + n <= cp.count {
                    fft.magnitudes(cp.baseAddress! + off, into: &mag)
                    var p: Float = 0
                    vDSP_vsq(mag, 1, &mag, 1, vDSP_Length(n / 2))
                    vDSP_dotpr(mag, 1, weights, 1, &p, vDSP_Length(n / 2))
                    power.append(p)
                    off += hop
                }
            }
            carry.removeFirst(off)
        }

        /// dB (95. Perzentil); Stille −100
        func level() -> Double {
            guard power.count >= 2 else { return -100 }
            let s = (1..<power.count).map { (power[$0 - 1] + power[$0]) / 2 }.sorted()
            let p = s[min(s.count - 1, Int(0.95 * Double(s.count)))]
            return p > 0 ? max(-100, 10 * log10(Double(p))) : -100
        }
    }

    /// Tiefpass + Dezimierung um einen ganzen Faktor (Fenster-Sinc, 24·Faktor+1 Koeffizienten)
    struct Decimator {
        let factor: Int
        let taps: [Float]
        var carry: [Float] = []

        init(factor d: Int) {
            factor = d
            guard d > 1 else { taps = [1]; return }
            let p = 24 * d + 1, m = Double(p - 1) / 2, fc = 0.42 / Double(d)
            var h = (0..<p).map { i -> Double in
                let t = Double(i) - m
                let sinc = t == 0 ? 2 * fc : sin(2 * .pi * fc * t) / (.pi * t)
                return sinc * (0.54 - 0.46 * cos(2 * .pi * Double(i) / Double(p - 1)))
            }
            let sum = h.reduce(0, +)
            h = h.map { $0 / sum }
            taps = h.map(Float.init)
        }

        mutating func feed(_ mono: [Float], _ n: Int, into out: inout [Float]) {
            if factor == 1 { out.append(contentsOf: mono[0..<n]); return }
            carry.append(contentsOf: mono[0..<n])
            let p = taps.count
            guard carry.count >= p else { return }
            let count = (carry.count - p) / factor + 1
            var o = [Float](repeating: 0, count: count)
            vDSP_desamp(carry, vDSP_Stride(factor), taps, &o, vDSP_Length(count), vDSP_Length(p))
            out.append(contentsOf: o)
            carry.removeFirst(count * factor)
        }
    }

    // MARK: FFT

    final class FFT {
        let n: Int, log2n: vDSP_Length
        let setup: FFTSetup
        var window: [Float]
        var re: [Float], im: [Float], frame: [Float]

        init(n: Int) {
            self.n = n
            log2n = vDSP_Length(log2(Double(n)).rounded())
            setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
            window = [Float](repeating: 0, count: n)
            vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
            re = [Float](repeating: 0, count: n / 2); im = re; frame = [Float](repeating: 0, count: n)
        }
        deinit { vDSP_destroy_fftsetup(setup) }

        /// Betragsspektrum (n/2 Bins, Bin 0 ohne Nyquist) des Blocks ab `p`
        func magnitudes(_ x: UnsafePointer<Float>, into mag: inout [Float]) {
            vDSP_vmul(x, 1, window, 1, &frame, 1, vDSP_Length(n))
            let half = vDSP_Length(n / 2)
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    frame.withUnsafeBufferPointer { fp in
                        fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { vDSP_ctoz($0, 2, &split, 1, half) }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    ip[0] = 0   // Nyquist-Anteil nicht in Bin 0 zählen
                    vDSP_zvabs(&split, 1, &mag, 1, half)
                }
            }
        }
    }

    // MARK: Anschläge

    struct Novelty {
        /// Spektralfluss (Bass vierfach) ohne gleitendes Mittel, halbwellen-gleichgerichtet, ~100 Bilder/s
        var frames: [Float]
        /// dasselbe getrennt: Bass < 250 Hz und Rest – der Kick trägt beides, Bass-Stabs und Hats nur eins
        var low: [Float], high: [Float]
        var fps: Double
        var hop: Int
        /// Bandenergien je Bild (linear), für die Takt-/Phrasen-Merkmale
        var bands: [Float]
        var bandCount: Int
    }

    /// Bandgrenzen der Beat-Merkmale (Hz) wie der Phrasen-Anker, nur bis unter die halbe Analyse-Rate
    static func bandEdges(rate: Double) -> [Double] { PhraseAnchor.bandEdges.filter { $0 < rate / 2 } }

    static func novelty(_ x: [Float], rate: Double) -> Novelty? {
        let n = 512, hop = max(1, Int(rate / 100))
        guard x.count > n * 4 else { return nil }
        let fft = FFT(n: n)
        let half = n / 2
        let edges = bandEdges(rate: rate)
        let bins = edges.map { min(half, max(1, Int(($0 * Double(n) / rate).rounded()))) }
        let bandCount = edges.count - 1
        let count = (x.count - n) / hop + 1
        var mag = [Float](repeating: 0, count: half)
        var cur = [Float](repeating: 0, count: half), prev = [Float](repeating: 0, count: half), diff = cur, lin = cur
        var fluxLow = [Float](repeating: 0, count: count), fluxHigh = fluxLow
        var bands = [Float](repeating: 0, count: count * bandCount)
        let lowBins = min(half - 1, max(2, Int(250 * Double(n) / rate)))
        // Verdichtung: log(1 + 100 · Betrag / Vollaussteuerung)
        var scale = Float(100) / Float(n / 2), one: Float = 1
        x.withUnsafeBufferPointer { xp in
            for f in 0..<count {
                fft.magnitudes(xp.baseAddress! + f * hop, into: &mag)
                mag.withUnsafeBufferPointer { m in
                    for k in 0..<bandCount where bins[k + 1] > bins[k] {
                        var e: Float = 0
                        vDSP_svesq(m.baseAddress! + bins[k], 1, &e, vDSP_Length(bins[k + 1] - bins[k]))
                        bands[f * bandCount + k] = e
                    }
                }
                vDSP_vsmsa(mag, 1, &scale, &one, &lin, 1, vDSP_Length(half))
                var c = Int32(half)
                vvlogf(&cur, lin, &c)
                vDSP_vsub(prev, 1, cur, 1, &diff, 1, vDSP_Length(half))
                var lo: Float = 0, hi: Float = .greatestFiniteMagnitude
                vDSP_vclip(diff, 1, &lo, &hi, &diff, 1, vDSP_Length(half))
                var sl: Float = 0, sh: Float = 0
                diff.withUnsafeBufferPointer { dp in
                    vDSP_sve(dp.baseAddress! + 1, 1, &sl, vDSP_Length(lowBins - 1))   // ohne Bin 0
                    vDSP_sve(dp.baseAddress! + lowBins, 1, &sh, vDSP_Length(half - lowBins))
                }
                fluxLow[f] = f == 0 ? 0 : sl
                fluxHigh[f] = f == 0 ? 0 : sh
                swap(&cur, &prev)
            }
        }
        // gleitendes Mittel (±0,5 s) abziehen, Rest gleichrichten
        let fps = rate / Double(hop)
        let w = max(1, Int(fps / 2))
        func detrend(_ flux: [Float]) -> [Float] {
            var prefix = [Double](repeating: 0, count: count + 1)
            for i in 0..<count { prefix[i + 1] = prefix[i] + Double(flux[i]) }
            var nov = [Float](repeating: 0, count: count)
            for i in 0..<count {
                let a = max(0, i - w), b = min(count, i + w + 1)
                let mean = (prefix[b] - prefix[a]) / Double(b - a)
                nov[i] = max(0, flux[i] - Float(mean))
            }
            return nov
        }
        let low = detrend(fluxLow), high = detrend(fluxHigh)
        // Tempo: Bass vierfach, dann erst gleichgerichtet – Kick vor Hats, sonst gewinnt bei Achtel-Hats das doppelte Tempo
        var mixed = [Float](repeating: 0, count: count)
        var four: Float = 4
        vDSP_vsma(fluxLow, 1, &four, fluxHigh, 1, &mixed, 1, vDSP_Length(count))
        return Novelty(frames: detrend(mixed), low: low, high: high, fps: fps, hop: hop, bands: bands, bandCount: bandCount)
    }

    // MARK: Tempo

    struct Tempo { var bpm: Double; var confidence: Double }

    /// Betrag der Fourier-Komponente bei `cycles` Perioden je Bild (plus halbe Gewichtung der zweiten Harmonischen)
    static func beatSpectrum(_ v: [Float], cyclesPerFrame f: Double) -> Double {
        var total = 0.0
        for (h, w) in [(1.0, 1.0), (2.0, 0.5)] {
            let n = v.count
            var phase = [Float](repeating: 0, count: n)
            var start: Float = 0, step = Float(2 * Double.pi * f * h)
            vDSP_vramp(&start, &step, &phase, 1, vDSP_Length(n))
            var s = [Float](repeating: 0, count: n), c = s
            var cnt = Int32(n)
            vvsincosf(&s, &c, phase, &cnt)
            var ds: Float = 0, dc: Float = 0
            vDSP_dotpr(v, 1, s, 1, &ds, vDSP_Length(n))
            vDSP_dotpr(v, 1, c, 1, &dc, vDSP_Length(n))
            total += w * Double(hypotf(ds, dc))
        }
        return total
    }

    struct TempoDebug {
        var candidates: [(Double, Double)] = []
        var fine = 0.0, refined = 0.0
        /// lokale Tempi (8-s-Fenster), Mehrheit und ihr Anteil
        var local: [Double] = [], majority = 0.0, share = 0.0
    }

    static func tempoDebug(_ nov: Novelty, x: [Float], rate: Double, music: ClosedRange<Double>, octave: ClosedRange<Double> = defaultOctave) -> TempoDebug {
        var dbg = TempoDebug()
        _ = tempo(nov, x: x, rate: rate, music: music, octave: octave, debug: &dbg)
        return dbg
    }

    static func tempo(_ nov: Novelty, x: [Float], rate: Double, music: ClosedRange<Double>, octave: ClosedRange<Double> = defaultOctave) -> Tempo? {
        var dbg = TempoDebug()
        return tempo(nov, x: x, rate: rate, music: music, octave: octave, debug: &dbg)
    }

    /// Ergebnis-Oktave [lo, 2·lo): Obergrenze folgt der Untergrenze
    public static func octaveRange(_ o: ClosedRange<Double>) -> ClosedRange<Double> {
        let lo = max(40, min(150, o.lowerBound))
        return lo...(2 * lo)
    }

    static func fold(_ bpm: Double, into o: ClosedRange<Double>) -> Double {
        guard bpm > 0, bpm.isFinite else { return bpm }
        var b = bpm
        while b < o.lowerBound { b *= 2 }
        while b >= o.upperBound { b /= 2 }
        return b
    }

    /// Tempogramm-Kamm (Beat-Frequenz + 2. und 4. Harmonische) über ein Betragsspektrum mit `binHz` je Bin
    static func comb(_ spec: [Double], binHz: Double, bpm: Double) -> Double {
        func at(_ hz: Double) -> Double {
            let pos = hz / binHz
            let i = Int(pos), f = pos - Double(i)
            guard i + 1 < spec.count else { return 0 }
            return spec[i] * (1 - f) + spec[i + 1] * f
        }
        let f = bpm / 60
        return at(f) + at(2 * f) / 2 + at(4 * f) / 4
    }

    static func tempo(_ nov: Novelty, x: [Float], rate: Double, music: ClosedRange<Double>, octave: ClosedRange<Double>,
                      debug: inout TempoDebug) -> Tempo? {
        let v = nov.frames, fps = nov.fps
        let n = v.count
        let oct = octaveRange(octave)
        guard n > Int(fps * 8) else { return nil }
        // Tempogramm: Betrag der FFT des Flusses (auf 2^k aufgefüllt, mindestens 0,1 BPM Auflösung)
        var size = 1 << 16
        while size < n * 2 { size <<= 1 }
        let spec = spectrum(v, size: size)
        let binHz = fps / Double(size)
        // leichte Bevorzugung von 90–170 BPM: sonst gewinnt bei Triolen-Anteilen 3/2 des Tempos
        func prior(_ bpm: Double) -> Double { bpm < 90 ? 1 - 0.25 * (90 - bpm) / 30 : bpm > 170 ? 1 - 0.25 * (bpm - 170) / 30 : 1 }
        var best = bpmRange.lowerBound, bestScore = -1.0, sum = 0.0, cnt = 0
        var b = bpmRange.lowerBound
        var all: [(Double, Double)] = []
        while b <= bpmRange.upperBound {
            let s = comb(spec, binHz: binHz, bpm: b) * prior(b)
            all.append((b, s))
            sum += s; cnt += 1
            if s > bestScore { bestScore = s; best = b }
            b += 0.1
        }
        // lokale Spitzen zum Nachsehen
        debug.candidates = all.indices.dropFirst().dropLast().filter { all[$0].1 > all[$0 - 1].1 && all[$0].1 >= all[$0 + 1].1 }
            .map { all[$0] }.sorted { $0.1 > $1.1 }.prefix(6).map { $0 }
        guard bestScore > 0 else { return nil }
        let confidence = max(0, min(1, (bestScore - sum / Double(cnt)) / bestScore))
        var bpm = fineSearch(v, fps: fps, around: best, span: 0.6)
        debug.fine = bpm
        // ganze Beats zwischen Anfang und Ende: Anschlag-Lage je Fenster, Beat-Zahl runden, Tempo daraus
        let o = onsets1k(x, rate: rate)
        for _ in 0..<2 {
            guard let refined = integerBeats(o, coarse: nov, bpm: bpm, music: music) else { break }
            bpm = refined
        }
        // Gegenprobe: Mehrheit der lokalen Tempi (8-s-Fenster, Hop 2 s). Weicht sie mehr als 0,3 BPM ab (Drift,
        // Vinyl), gilt das häufigste lokale Tempo, verfeinert über die Fenster der Mehrheit
        let local = localTempi(v, fps: fps, octave: (bpm / 2.squareRoot())...(bpm * 2.squareRoot()))
        debug.local = local
        if let m = majority(local) {
            debug.majority = m.bpm; debug.share = m.share
            if m.share >= 0.5, abs(m.bpm - bpm) > 0.3, abs(m.bpm - bpm) < 0.03 * bpm {
                var masked = [Float](repeating: 0, count: n)
                let w = Int(8 * fps), hop = Int(2 * fps)
                for i in m.members {
                    let a = i * hop, e = min(n, a + w)
                    for j in a..<e { masked[j] = v[j] }
                }
                bpm = fineSearch(masked, fps: fps, around: m.bpm, span: 0.5)
            }
        }
        debug.refined = bpm
        return Tempo(bpm: fold(bpm, into: oct), confidence: confidence)
    }

    /// Fourier-Betrag genau bei der Beat-Frequenz um `around`: 0,02 BPM, dann 0,001 BPM
    static func fineSearch(_ v: [Float], fps: Double, around: Double, span: Double) -> Double {
        var fine = around, fineScore = -1.0
        for (sp, step) in [(span, 0.02), (0.03, 0.001)] {
            let center = fine
            var c = center - sp
            while c <= center + sp + 1e-9 {
                if c > 20 {
                    let s = beatSpectrum(v, cyclesPerFrame: c / 60 / fps)
                    if s > fineScore { fineScore = s; fine = c }
                }
                c += step
            }
        }
        return fine
    }

    /// Tempo je 8-s-Fenster (Hop 2 s) aus dem Kamm über das Fenster-Spektrum, in der Oktave; 0 = Fenster ohne Anschläge
    static func localTempi(_ v: [Float], fps: Double, octave oct: ClosedRange<Double>) -> [Double] {
        let w = Int(8 * fps), hop = Int(2 * fps), size = 8192
        guard v.count >= w, size >= w else { return [] }
        let fft = FFT(n: size)
        for i in 0..<size { fft.window[i] = 1 }
        var hann = [Float](repeating: 0, count: w)
        vDSP_hann_window(&hann, vDSP_Length(w), Int32(vDSP_HANN_NORM))
        var seg = [Float](repeating: 0, count: size), mag = [Float](repeating: 0, count: size / 2)
        let binHz = fps / Double(size)
        var out: [Double] = []
        var a = 0
        while a + w <= v.count {
            var mean: Float = 0
            v.withUnsafeBufferPointer { p in vDSP_meanv(p.baseAddress! + a, 1, &mean, vDSP_Length(w)) }
            guard mean > 0 else { out.append(0); a += hop; continue }
            var neg = -mean
            v.withUnsafeBufferPointer { p in
                seg.withUnsafeMutableBufferPointer { sp in
                    vDSP_vsadd(p.baseAddress! + a, 1, &neg, sp.baseAddress!, 1, vDSP_Length(w))
                    vDSP_vmul(sp.baseAddress!, 1, hann, 1, sp.baseAddress!, 1, vDSP_Length(w))
                }
            }
            seg.withUnsafeBufferPointer { fft.magnitudes($0.baseAddress!, into: &mag) }
            let spec = mag.map(Double.init)
            var best = 0.0, bestS = 0.0
            var b = oct.lowerBound
            while b < oct.upperBound {
                let s = comb(spec, binHz: binHz, bpm: b)
                if s > bestS { bestS = s; best = b }
                b += 0.05
            }
            out.append(best)
            a += hop
        }
        return out
    }

    /// größte Gruppe lokaler Tempi (±2 % um ein Fenster-Tempo): Median, Anteil an allen Fenstern mit Tempo, Fenster
    static func majority(_ local: [Double]) -> (bpm: Double, share: Double, members: [Int])? {
        let valid = local.indices.filter { local[$0] > 0 }
        guard valid.count >= 8 else { return nil }
        var bestMembers: [Int] = []
        for i in valid {
            let c = local[i]
            let m = valid.filter { abs(local[$0] - c) <= 0.02 * c }
            if m.count > bestMembers.count { bestMembers = m }
        }
        let sorted = bestMembers.map { local[$0] }.sorted()
        return (sorted[sorted.count / 2], Double(bestMembers.count) / Double(valid.count), bestMembers)
    }

    /// Betragsspektrum eines reellen Signals, auf `size` (2^k) mit Nullen aufgefüllt, Mittelwert abgezogen
    static func spectrum(_ v: [Float], size: Int) -> [Double] {
        let fft = FFT(n: size)
        var padded = [Float](repeating: 0, count: size)
        var mean: Float = 0
        vDSP_meanv(v, 1, &mean, vDSP_Length(v.count))
        var neg = -mean
        vDSP_vsadd(v, 1, &neg, &padded, 1, vDSP_Length(v.count))
        // ohne Fenster: das Signal ist schon aufgefüllt, ein Fenster würde Anfang und Ende dämpfen
        for i in 0..<size { fft.window[i] = 1 }
        var mag = [Float](repeating: 0, count: size / 2)
        padded.withUnsafeBufferPointer { fft.magnitudes($0.baseAddress!, into: &mag) }
        return mag.map(Double.init)
    }

    // MARK: Anschläge mit 1 ms

    struct Onsets {
        /// Anstieg der Blockenergie (log), halbwellen-gleichgerichtet
        var v: [Float]
        var fs: Double
    }

    /// Hüllkurven (gleichgerichtet, einpolig geglättet) des ganzen Bands (3 ms) und des Basses < 150 Hz (5 ms), je 1 ms
    /// gemittelt; Anschlag = positiver Anstieg, jedes Band auf sein 95. Perzentil bezogen, beide summiert
    static func onsets1k(_ x: [Float], rate: Double) -> Onsets {
        let b = max(1, Int(rate / 1000))
        let count = x.count / b
        var full = [Float](repeating: 0, count: count), low = full
        let aLow = Float(1 - exp(-2 * Double.pi * 150 / rate))
        let aEnvF = Float(1 - exp(-1 / (0.003 * rate))), aEnvL = Float(1 - exp(-1 / (0.005 * rate)))
        var lp1: Float = 0, lp2: Float = 0, envF: Float = 0, envL: Float = 0
        x.withUnsafeBufferPointer { p in
            for i in 0..<count {
                var sf: Float = 0, sl: Float = 0
                for j in (i * b)..<((i + 1) * b) {
                    let v = p[j]
                    lp1 += aLow * (v - lp1)
                    lp2 += aLow * (lp1 - lp2)
                    envF += aEnvF * (abs(v) - envF)
                    envL += aEnvL * (abs(lp2) - envL)
                    sf += envF; sl += envL
                }
                full[i] = sf / Float(b); low[i] = sl / Float(b)
            }
        }
        func rises(_ e: [Float]) -> [Float] {
            var d = [Float](repeating: 0, count: e.count)
            for i in 1..<max(1, e.count) { d[i] = max(0, e[i] - e[i - 1]) }
            let ref = PhraseAnchor.percentile(d.filter { $0 > 0 }, 0.95)
            if ref > 0 { var inv = 1 / ref; vDSP_vsmul(d, 1, &inv, &d, 1, vDSP_Length(d.count)) }
            return d
        }
        let rf = rises(full), rl = rises(low)
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count { out[i] = rl[i] + rf[i] }
        return Onsets(v: out, fs: rate / Double(b))
    }

    /// Anschlagsstärke auf die Periode `period` (Samples) gefaltet, Fenster [from, to) in Samples:
    /// absolute Lage (Samples) des Anschlags im Beat, mod Periode
    static func foldProfile(_ o: Onsets, period: Double, from: Int, to: Int) -> [Double]? {
        let bins = max(8, Int(period.rounded()))
        guard period > 2, to - from > Int(period * 4) else { return nil }
        var prof = [Double](repeating: 0, count: bins)
        let scale = Double(bins) / period
        for i in max(0, from)..<min(to, o.v.count) where o.v[i] > 0 {
            let pos = (Double(i).truncatingRemainder(dividingBy: period)) * scale
            let j = Int(pos), f = pos - Double(j)
            prof[j % bins] += Double(o.v[i]) * (1 - f)
            prof[(j + 1) % bins] += Double(o.v[i]) * f
        }
        return prof
    }

    static func fold(_ o: Onsets, period: Double, from: Int, to: Int) -> (phase: Double, strength: Double)? {
        guard let prof = foldProfile(o, period: period, from: from, to: to) else { return nil }
        let bins = prof.count, scale = Double(bins) / period
        guard let maxV = prof.max(), maxV > 0, let j = prof.firstIndex(of: maxV) else { return nil }
        // Parabel durch die Spitze
        let l = prof[(j + bins - 1) % bins], r = prof[(j + 1) % bins]
        let den = l - 2 * maxV + r
        let delta = den < 0 ? 0.5 * (l - r) / den : 0
        let mean = prof.reduce(0, +) / Double(bins)
        var phase = (Double(j) + delta) / scale
        phase = phase.truncatingRemainder(dividingBy: period)
        if phase < 0 { phase += period }
        return (phase, mean > 0 ? maxV / mean : 0)
    }

    /// Lage des Beats in zwei Stufen: grob über den Spektralfluss (welches Sechzehntel im Beat trägt den Anschlag),
    /// fein ±40 ms darum auf der 1-ms-Anschlagsstärke. Fenster [from, to) in Sekunden; Ergebnis in Samples von `fine`
    static func beatPhase(fine: Onsets, coarse nov: Novelty, bpm: Double, from: Double, to: Double) -> (phase: Double, strength: Double)? {
        let pc = nov.fps * 60 / bpm, pf = fine.fs * 60 / bpm
        let c0 = Int(from * nov.fps), c1 = Int(to * nov.fps)
        guard let pl = foldProfile(Onsets(v: nov.low, fs: nov.fps), period: pc, from: c0, to: c1),
              let ph = foldProfile(Onsets(v: nov.high, fs: nov.fps), period: pc, from: c0, to: c1),
              let prof = foldProfile(fine, period: pf, from: Int(from * fine.fs), to: Int(to * fine.fs)) else { return nil }
        // Kick = Bass und Rest schlagen zusammen an: Produkt der beiden Profile (je auf ihr Maximum bezogen)
        let ml = max(pl.max() ?? 0, 1e-9), mh = max(ph.max() ?? 0, 1e-9)
        let prod = (0..<pl.count).map { (pl[$0] / ml) * (ph[$0] / mh) }
        guard let cm = prod.max(), cm > 0, let cj = prod.firstIndex(of: cm) else { return nil }
        let cmean = prod.reduce(0, +) / Double(prod.count)
        let cl = prod[(cj + prod.count - 1) % prod.count], cr = prod[(cj + 1) % prod.count]
        let cden = cl - 2 * cm + cr
        let cdelta = cden < 0 ? 0.5 * (cl - cr) / cden : 0
        let cphase = (Double(cj) + cdelta) * pc / Double(pl.count)   // Samples des groben Rasters
        let c = (phase: cphase, strength: cmean > 0 ? cm / cmean : 0)
        let bins = prof.count, scale = Double(bins) / pf
        let center = (c.phase / nov.fps * fine.fs).truncatingRemainder(dividingBy: pf) * scale
        let span = Int(0.04 * fine.fs * scale)
        var best = -1, bestV = -1.0
        for d in -span...span {
            let j = ((Int(center.rounded()) + d) % bins + bins) % bins
            if prof[j] > bestV { bestV = prof[j]; best = j }
        }
        guard best >= 0, bestV > 0 else { return nil }
        let l = prof[(best + bins - 1) % bins], r = prof[(best + 1) % bins]
        let den = l - 2 * bestV + r
        let delta = den < 0 ? 0.5 * (l - r) / den : 0
        var phase = ((Double(best) + delta) / scale).truncatingRemainder(dividingBy: pf)
        if phase < 0 { phase += pf }
        return (phase, c.strength)
    }

    /// Tempo aus der ganzen Zahl Beats zwischen einem Anschlag am Anfang und einem am Ende (30-s-Fenster);
    /// nil, wenn die Beat-Zahl nicht eindeutig ist oder die Musik zu kurz
    static func integerBeats(_ o: Onsets, coarse: Novelty, bpm: Double, music: ClosedRange<Double>) -> Double? {
        let period = o.fs * 60 / bpm
        let a0 = Int(music.lowerBound * o.fs), b1 = min(o.v.count, Int(music.upperBound * o.fs))
        let win = Int(30 * o.fs)
        guard b1 - a0 > win * 2 + Int(period * 32) else { return nil }
        guard let pa = beatPhase(fine: o, coarse: coarse, bpm: bpm, from: music.lowerBound, to: music.lowerBound + 30),
              let pb = beatPhase(fine: o, coarse: coarse, bpm: bpm, from: Double(b1) / o.fs - 30, to: Double(b1) / o.fs),
              pa.strength >= 2, pb.strength >= 2 else { return nil }
        // Beat nahe dem Anfang des ersten Fensters / dem Ende des letzten
        let tA = Double(a0) + ((pa.phase - Double(a0)).truncatingRemainder(dividingBy: period) + period).truncatingRemainder(dividingBy: period)
        let tB = Double(b1) - ((Double(b1) - pb.phase).truncatingRemainder(dividingBy: period) + period).truncatingRemainder(dividingBy: period)
        let beats = (tB - tA) / period
        let k = beats.rounded()
        guard k >= 32, abs(beats - k) < 0.3 else { return nil }
        let refined = 60 * o.fs / ((tB - tA) / k)
        guard abs(refined - bpm) < 0.1 else { return nil }
        return refined
    }

    // MARK: Anker + Taktanfang

    struct Anchor { var anchor: Double; var phraseConfidence: Double }

    /// Phase über den ganzen Musikbereich (konstantes Tempo vorausgesetzt)
    static func anchor(_ x: [Float], rate: Double, bpm: Double, novelty nov: Novelty, music: ClosedRange<Double>, duration: Double) -> Anchor {
        let o = onsets1k(x, rate: rate)
        let beat = 60 / bpm
        let end = Double(o.v.count) / o.fs
        let musicStart = music.lowerBound
        let p = beatPhase(fine: o, coarse: nov, bpm: bpm, from: musicStart, to: min(end, music.upperBound))
            ?? beatPhase(fine: o, coarse: nov, bpm: bpm, from: 0, to: end)
        guard let p else { return Anchor(anchor: max(0, musicStart), phraseConfidence: 0) }
        // erster Beat des Rasters ab Musikbeginn (ein Beat darf knapp davor liegen)
        var first = p.phase / o.fs
        let minT = max(0, musicStart - 0.3 * beat)
        first += ((minT - first) / beat).rounded(.up) * beat
        if first < 0 { first += beat }
        guard first < duration else { return Anchor(anchor: max(0, musicStart), phraseConfidence: 0) }
        // Beat-Merkmale (Bandpegel in dB je Beat) -> Strukturwechsel -> Phrasenanfang (PhraseAnchor)
        let beats = Int((duration - first) / beat) - 1
        guard beats >= 64 else { return Anchor(anchor: first, phraseConfidence: 0) }
        let bands = nov.bandCount
        var acc = [Float](repeating: 0, count: beats * bands)
        var cnt = [Int](repeating: 0, count: beats)
        let frameCount = nov.bands.count / bands
        for f in 0..<frameCount {
            // Bildmitte, 1/16 Beat vorgezogen: der Anschlag am Beat zählt zu seinem Beat
            let t = (Double(f * nov.hop) + 256) / rate
            let b = Int(((t - first) / beat + 1.0 / 16).rounded(.down))
            guard b >= 0, b < beats else { continue }
            for k in 0..<bands { acc[b * bands + k] += nov.bands[f * bands + k] }
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
        let loudRef = PhraseAnchor.percentile(loud, 0.9)
        guard let start = loud.firstIndex(where: { $0 > loudRef - 30 }), let end = loud.lastIndex(where: { $0 > loudRef - 30 }),
              end - start >= 64 else { return Anchor(anchor: first, phraseConfidence: 0) }
        for k in 0..<bands {
            let floor = PhraseAnchor.percentile(feats[start...end].map { $0[k] }, 0.95) - 50
            for b in 0..<beats { feats[b][k] = max(feats[b][k], floor) }
        }
        let r = PhraseAnchor.decide(PhraseAnchor.boundaries(feats, from: start, to: end), firstBeat: 0)
        guard r.suggests else { return Anchor(anchor: first, phraseConfidence: r.confidence) }
        // Verschiebung in ganzen Beats, in die erste Phrase gelegt (nie vor den Anfang)
        let s = ((r.shiftBeats % PhraseAnchor.phraseBeats) + PhraseAnchor.phraseBeats) % PhraseAnchor.phraseBeats
        let shifted = first + Double(s) * beat
        return Anchor(anchor: shifted < duration ? shifted : first, phraseConfidence: r.confidence)
    }

    // MARK: Tonart

    struct Key { var code: Int; var clarity: Double }

    /// Krumhansl-Kessler-Profile (Dur, Moll)
    static let krumhanslMajor: [Double] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    static let krumhanslMinor: [Double] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]
    /// Temperley-Profile (Dur, Moll)
    static let temperleyMajor: [Double] = [5.0, 2.0, 3.5, 2.0, 4.5, 4.0, 2.0, 4.5, 2.0, 3.5, 1.5, 4.0]
    static let temperleyMinor: [Double] = [5.0, 2.0, 3.5, 4.5, 2.0, 3.5, 2.0, 4.5, 3.5, 2.0, 1.5, 4.0]

    /// Halbton-Pegel je Bild: 250-ms-Hann-Fenster, 8192er FFT, Hop 125 ms (~22 kHz). Je Halbton (MIDI `low`…`high`)
    /// die größte Bin-Leistung, mit einer Gauß-Kurve (σ = 0,3 Halbtöne) um die Halbtonmitte gewichtet (A = 440 Hz), in dB
    struct ChromaFrames {
        static let low = 28, high = 120
        static var count: Int { high - low + 1 }
        let fft: FFT
        let win: Int, hop: Int
        /// je Halbton (Bin, Gewicht)
        let taps: [[(Int, Float)]]
        var carry: [Float] = []
        var frame: [Float]
        var mag: [Float]
        /// Bilder × `count` Pegel (dB)
        var db: [Float] = []

        init(rate: Double) {
            win = Int(0.25 * rate); hop = win / 2
            var n = 1
            while n < win { n <<= 1 }
            fft = FFT(n: n)
            var w = [Float](repeating: 0, count: win)
            vDSP_hann_window(&w, vDSP_Length(win), Int32(vDSP_HANN_NORM))
            for i in 0..<n { fft.window[i] = i < win ? w[i] : 0 }
            frame = [Float](repeating: 0, count: n)
            mag = [Float](repeating: 0, count: n / 2)
            let binHz = rate / Double(n)
            taps = (Self.low...Self.high).map { p in
                let fc = 440 * pow(2, Double(p - 69) / 12)
                let k0 = max(1, Int(fc * pow(2, -1.0 / 12) / binHz)), k1 = min(n / 2 - 1, Int(fc * pow(2, 1.0 / 12) / binHz) + 1)
                guard k1 >= k0 else { return [] }
                return (k0...k1).compactMap { k in
                    let d = 12 * log2(Double(k) * binHz / fc)
                    return abs(d) <= 1 ? (k, Float(exp(-0.5 * (d / 0.3) * (d / 0.3)))) : nil
                }
            }
        }

        mutating func feed(_ x: [Float]) {
            carry.append(contentsOf: x)
            var off = 0
            let scale = 1 / Float(fft.n)
            while off + win <= carry.count {
                carry.withUnsafeBufferPointer { cp in
                    frame.withUnsafeMutableBufferPointer { fp in
                        _ = memcpy(fp.baseAddress!, cp.baseAddress! + off, win * MemoryLayout<Float>.size)
                    }
                }
                frame.withUnsafeBufferPointer { fft.magnitudes($0.baseAddress!, into: &mag) }
                for t in taps {
                    var e: Float = 0
                    for (k, w) in t { let m = mag[k] * scale; e = max(e, w * m * m) }
                    db.append(10 * log10(e + 1e-12))
                }
                off += hop
            }
            carry.removeFirst(off)
        }
    }

    /// Stellgrößen der Tonart (Tests vergleichen Varianten)
    struct KeyParams {
        /// gezählter Bereich (MIDI): A1 (55 Hz) bis ~6,6 kHz
        var foldLow = 33, foldHigh = 116
        /// Pegel unter (Bezug − `range`) zählen nicht; Bezug = 95. Perzentil der Bild-Maxima
        var range: Float = 50
        /// Schwelle für tiefe Halbtöne: bei `foldLow` um `tilt` dB höher, bis `tiltEnd` linear auf 0
        var tilt: Float = 20, tiltEnd = 84
        /// lokale Maskierung: Halbton minus Mittel der Nachbarn ±`maskWidth`
        var maskWidth = 5
        /// Moll-Korrelation × (1 + `minorBonus`)
        var minorBonus = 0.05
    }

    /// Mittel-Chroma (12, C…B): je Bild Pegel über der Schwelle, lokal maskiert, Oktaven summiert; Bilder gleich gewichtet
    static func chroma(_ f: ChromaFrames, _ k: KeyParams = KeyParams()) -> [Double]? {
        let p = ChromaFrames.count, n = f.db.count / p
        guard n >= 8 else { return nil }
        var maxima = [Float](repeating: 0, count: n)
        f.db.withUnsafeBufferPointer { d in
            for i in 0..<n { vDSP_maxv(d.baseAddress! + i * p, 1, &maxima[i], vDSP_Length(p)) }
        }
        let ref = PhraseAnchor.percentile(maxima, 0.95)
        guard ref > -100 else { return nil }
        let thr = (0..<p).map { i -> Float in
            let m = ChromaFrames.low + i
            let lift = m < k.tiltEnd ? k.tilt * Float(k.tiltEnd - max(m, k.foldLow)) / Float(max(1, k.tiltEnd - k.foldLow)) : 0
            return ref - k.range + lift
        }
        var v = [Float](repeating: 0, count: p)
        var c = [Double](repeating: 0, count: 12)
        for i in 0..<n {
            for j in 0..<p { v[j] = max(0, f.db[i * p + j] - thr[j]) }
            for j in 0..<p {
                let m = ChromaFrames.low + j
                guard m >= k.foldLow, m <= k.foldHigh, v[j] > 0 else { continue }
                var s: Float = 0, cnt = 0
                for d in stride(from: 1, through: k.maskWidth, by: 1) {
                    if j - d >= 0 { s += v[j - d]; cnt += 1 }
                    if j + d < p { s += v[j + d]; cnt += 1 }
                }
                let e = v[j] - s / Float(max(1, cnt))
                if e > 0 { c[m % 12] += Double(e) }
            }
        }
        return c.reduce(0, +) > 0 ? c : nil
    }

    static func correlation(_ a: [Double], _ b: [Double]) -> Double {
        let n = Double(a.count)
        let ma = a.reduce(0, +) / n, mb = b.reduce(0, +) / n
        var num = 0.0, da = 0.0, db = 0.0
        for i in a.indices { let x = a[i] - ma, y = b[i] - mb; num += x * y; da += x * x; db += y * y }
        return da > 0 && db > 0 ? num / (da * db).squareRoot() : 0
    }

    /// Tonart aus dem Chroma: Korrelation (z-normiert) mit beiden Profilsätzen, je Modus die bessere, Moll mit Bonus
    static func key(chroma c: [Double], _ k: KeyParams = KeyParams()) -> Key? {
        guard c.count == 12, c.reduce(0, +) > 0 else { return nil }
        var scores = [Double](repeating: 0, count: 24)
        for tonic in 0..<12 {
            let rotated = (0..<12).map { c[(tonic + $0) % 12] }
            scores[tonic] = max(correlation(rotated, krumhanslMajor), correlation(rotated, temperleyMajor))
            let minor = max(correlation(rotated, krumhanslMinor), correlation(rotated, temperleyMinor))
            scores[12 + tonic] = minor > 0 ? minor * (1 + k.minorBonus) : minor
        }
        let order = scores.indices.sorted { scores[$0] > scores[$1] }
        return Key(code: order[0], clarity: scores[order[0]] - scores[order[1]])
    }

    static func key(_ f: ChromaFrames, _ k: KeyParams = KeyParams()) -> Key? {
        guard let c = chroma(f, k) else { return nil }
        return key(chroma: c, k)
    }
}
