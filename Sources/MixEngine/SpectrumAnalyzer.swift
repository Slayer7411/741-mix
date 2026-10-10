import Accelerate
import MixCore

/// Feine Spektralanalyse für die Wellenform, blockweise fütterbar (Deck: ganzer Puffer, Vorschau: Lese-Blöcke).
/// Tiefen (Sub, Bass, untere Mitten): Biquads auf ein auf ~4,4 kHz heruntergesetztes Mono-Signal – genaue Trennung bei
/// 60 und 250 Hz. Obere Mitten, Höhen, Luft: 256er FFT (5,8 ms, Hann) je Block, auf die Blockmitte zentriert – scharfe Hats.
/// Höhen-Dauer: Anteil der Blöcke im Fenster von ~150 ms, in denen die Höhen höchstens 8 dB unter ihrer Fensterspitze liegen.
public final class SpectrumAnalyzer {
    public let sampleRate: Double
    public let block: Int

    // FFT (obere Bänder)
    private let n: Int, log2n: vDSP_Length
    private let setup: FFTSetup
    private var window: [Float]
    private let fftScale: Float
    private let bins: [Int]   // Kanten: obere Mitten, Höhen, Luft
    private var frame: [Float], re: [Float], im: [Float], mag: [Float]

    // Mono-Verlauf für die FFT-Rahmen: mono[0] = Sample `monoBase`
    private var mono: [Float] = []
    private var monoBase = 0
    private var fed = 0
    private var nextBlock = 0

    // Tiefen-Pfad: Anti-Alias (Vollrate) → jedes `decim`-te Sample → Bandfilter
    private let decim: Int
    private let aa: vDSP_biquad_Setup, sub: vDSP_biquad_Setup, bass: vDSP_biquad_Setup, lowMid: vDSP_biquad_Setup
    private var aaDelay: [Float], subDelay: [Float], bassDelay: [Float], lowMidDelay: [Float]
    private var aaOut: [Float] = [], dec: [Float] = [], ySub: [Float] = [], yBass: [Float] = [], yLowMid: [Float] = []

    // je Block: Energiesummen (Tiefen: Summe + Anzahl, FFT: mittleres Quadrat)
    private var eSub: [Float] = [], eBass: [Float] = [], eLowMid: [Float] = [], nLow: [Float] = []
    private var eHighMid: [Float] = [], eHigh: [Float] = [], eAir: [Float] = []

    public init(sampleRate: Double, block: Int) {
        self.sampleRate = sampleRate
        self.block = max(1, block)
        // ~5,8 ms Fenster unabhängig von der Rate
        let size = sampleRate > 100_000 ? 1024 : sampleRate > 50_000 ? 512 : 256
        n = size
        log2n = vDSP_Length(log2(Double(size)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: size)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_DENORM))
        var wpow: Float = 0
        vDSP_measqv(window, 1, &wpow, vDSP_Length(size))
        // zrip liefert 2·X; Parseval einseitig: Σx² = 2/N·Σ|X|² → mittleres Quadrat = Σ|Z|² / (2·N²·mean(w²))
        fftScale = 1 / (2 * Float(size * size) * wpow)
        let nyq = sampleRate / 2
        bins = [1000, 4000, 10000, min(20000, nyq * 0.98)].map { min(size / 2, max(1, Int(($0 * Double(size) / sampleRate).rounded()))) }
        frame = [Float](repeating: 0, count: size)
        re = [Float](repeating: 0, count: size / 2); im = re; mag = re

        decim = max(1, Int(sampleRate / 4410))
        let fd = sampleRate / Double(decim)
        // Anti-Alias 2. Ordnung reicht: Spiegel ins Tiefenband kommen von ≥ 3,4 kHz (≥ 21 dB gedämpft, Hats ≥ 36 dB)
        aa = Self.setup([Self.lowpass(1000, q: 0.7071, fs: sampleRate)])
        sub = Self.setup([Self.highpass(20, q: 0.7071, fs: fd), Self.lowpass(60, q: 0.5412, fs: fd), Self.lowpass(60, q: 1.3066, fs: fd)])
        bass = Self.setup([Self.highpass(60, q: 0.5412, fs: fd), Self.highpass(60, q: 1.3066, fs: fd),
                           Self.lowpass(250, q: 0.5412, fs: fd), Self.lowpass(250, q: 1.3066, fs: fd)])
        lowMid = Self.setup([Self.highpass(250, q: 0.5412, fs: fd), Self.highpass(250, q: 1.3066, fs: fd)])
        aaDelay = [Float](repeating: 0, count: 2 * 1 + 2)
        subDelay = [Float](repeating: 0, count: 2 * 3 + 2)
        bassDelay = [Float](repeating: 0, count: 2 * 4 + 2)
        lowMidDelay = [Float](repeating: 0, count: 2 * 2 + 2)
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
        vDSP_biquad_DestroySetup(aa); vDSP_biquad_DestroySetup(sub)
        vDSP_biquad_DestroySetup(bass); vDSP_biquad_DestroySetup(lowMid)
    }

    // MARK: Filter (RBJ-Kochbuch, Butterworth 4. Ordnung = zwei Stufen mit Q 0,5412 / 1,3066)

    private static func lowpass(_ f: Double, q: Double, fs: Double) -> [Double] {
        let w = 2 * Double.pi * f / fs, a = sin(w) / (2 * q), c = cos(w), a0 = 1 + a
        return [(1 - c) / 2 / a0, (1 - c) / a0, (1 - c) / 2 / a0, -2 * c / a0, (1 - a) / a0]
    }

    private static func highpass(_ f: Double, q: Double, fs: Double) -> [Double] {
        let w = 2 * Double.pi * f / fs, a = sin(w) / (2 * q), c = cos(w), a0 = 1 + a
        return [(1 + c) / 2 / a0, -(1 + c) / a0, (1 + c) / 2 / a0, -2 * c / a0, (1 - a) / a0]
    }

    private static func setup(_ sections: [[Double]]) -> vDSP_biquad_Setup {
        vDSP_biquad_CreateSetup(sections.flatMap { $0 }, vDSP_Length(sections.count))!
    }

    // MARK: Füttern

    /// nächste Samples (Stereo); Mono wird intern gebildet
    public func feed(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int) {
        var done = 0
        while done < count {
            let m = min(1 << 15, count - done)
            feedChunk(left + done, right + done, m)
            done += m
        }
    }

    private func feedChunk(_ l: UnsafePointer<Float>, _ r: UnsafePointer<Float>, _ m: Int) {
        let start = fed
        let old = mono.count
        mono.append(contentsOf: repeatElement(0, count: m))
        mono.withUnsafeMutableBufferPointer { p in
            let dst = p.baseAddress! + old
            vDSP_vadd(l, 1, r, 1, dst, 1, vDSP_Length(m))
            var half: Float = 0.5
            vDSP_vsmul(dst, 1, &half, dst, 1, vDSP_Length(m))
        }
        fed += m
        lowPath(from: old, count: m, absStart: start)
        fftBlocks(final: false)
    }

    /// Tiefen: Anti-Alias auf Vollrate, dezimieren, Bandfilter, Energie je Block
    private func lowPath(from offset: Int, count m: Int, absStart: Int) {
        if aaOut.count < m { aaOut = [Float](repeating: 0, count: m) }
        mono.withUnsafeBufferPointer { src in
            vDSP_biquad(aa, &aaDelay, src.baseAddress! + offset, 1, &aaOut, 1, vDSP_Length(m))
        }
        let first = (decim - absStart % decim) % decim
        guard first < m else { return }
        let k = (m - first + decim - 1) / decim
        if dec.count < k {
            dec = [Float](repeating: 0, count: k); ySub = dec; yBass = dec; yLowMid = dec
        }
        aaOut.withUnsafeBufferPointer { a in
            var zero: Float = 0
            vDSP_vsadd(a.baseAddress! + first, vDSP_Stride(decim), &zero, &dec, 1, vDSP_Length(k))
        }
        vDSP_biquad(sub, &subDelay, dec, 1, &ySub, 1, vDSP_Length(k))
        vDSP_biquad(bass, &bassDelay, dec, 1, &yBass, 1, vDSP_Length(k))
        vDSP_biquad(lowMid, &lowMidDelay, dec, 1, &yLowMid, 1, vDSP_Length(k))
        let lastBlock = (absStart + first + (k - 1) * decim) / block
        grow(to: lastBlock + 1)
        // Quadrate je Block aufsummieren: Blockgrenzen im dezimierten Signal, Summen per vDSP
        var i = 0
        var b = (absStart + first) / block
        while i < k {
            // erstes dezimiertes Sample des nächsten Blocks
            let nextAbs = (b + 1) * block
            let iEnd = min(k, max(i + 1, (nextAbs - absStart - first + decim - 1) / decim))
            let len = vDSP_Length(iEnd - i)
            var a: Float = 0, c: Float = 0, d: Float = 0
            vDSP_svesq(&ySub + i, 1, &a, len)
            vDSP_svesq(&yBass + i, 1, &c, len)
            vDSP_svesq(&yLowMid + i, 1, &d, len)
            eSub[b] += a; eBass[b] += c; eLowMid[b] += d; nLow[b] += Float(iEnd - i)
            i = iEnd
            b += 1
        }
    }

    private func grow(to blocks: Int) {
        guard eSub.count < blocks else { return }
        let add = blocks - eSub.count
        for i in 0..<4 {
            switch i {
            case 0: eSub.append(contentsOf: repeatElement(0, count: add))
            case 1: eBass.append(contentsOf: repeatElement(0, count: add))
            case 2: eLowMid.append(contentsOf: repeatElement(0, count: add))
            default: nLow.append(contentsOf: repeatElement(0, count: add))
            }
        }
    }

    /// FFT-Rahmen je Block (Mitte = Blockmitte), solange genug Samples da sind; am Ende mit Nullen aufgefüllt
    private func fftBlocks(final: Bool) {
        let half = n / 2
        let total = final ? fed / block + 1 : Int.max
        while nextBlock < total {
            let c = nextBlock * block + block / 2
            if !final, c + half > fed { break }
            let s = c - half
            // Rahmen aus dem Mono-Verlauf, außerhalb Nullen
            frame.withUnsafeMutableBufferPointer { f in
                mono.withUnsafeBufferPointer { m in
                    let a0 = s - monoBase
                    if a0 >= 0, a0 + n <= m.count {
                        vDSP_vmul(m.baseAddress! + a0, 1, window, 1, f.baseAddress!, 1, vDSP_Length(n))
                    } else {
                        for i in 0..<n {
                            let a = a0 + i
                            f[i] = a >= 0 && a < m.count ? m[a] * window[i] : 0
                        }
                    }
                }
            }
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    frame.withUnsafeBufferPointer { fp in
                        fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    split.imagp[0] = 0   // Nyquist-Anteil (in imagp[0] gepackt) nicht als Bin 0 zählen
                    vDSP_zvmags(&split, 1, &mag, 1, vDSP_Length(half))
                }
            }
            var e0: Float = 0, e1: Float = 0, e2: Float = 0
            mag.withUnsafeBufferPointer { mp in
                let m = mp.baseAddress!
                if bins[1] > bins[0] { vDSP_sve(m + bins[0], 1, &e0, vDSP_Length(bins[1] - bins[0])) }
                if bins[2] > bins[1] { vDSP_sve(m + bins[1], 1, &e1, vDSP_Length(bins[2] - bins[1])) }
                if bins[3] > bins[2] { vDSP_sve(m + bins[2], 1, &e2, vDSP_Length(bins[3] - bins[2])) }
            }
            eHighMid.append(e0 * fftScale); eHigh.append(e1 * fftScale); eAir.append(e2 * fftScale)
            nextBlock += 1
        }
        // verbrauchte Samples vorne abschneiden (selten, damit es billig bleibt)
        let keep = nextBlock * block + block / 2 - half - monoBase
        if keep > 1 << 16 {
            mono.removeFirst(keep)
            monoBase += keep
        }
    }

    // MARK: Abschluss

    /// Analyse beenden → je Block 8 Bytes; `blocks` = gewünschte Blockzahl (wie die Spitzen des Tracks)
    public func finish(blocks wanted: Int? = nil) -> WaveSpectrum {
        fftBlocks(final: true)
        let count = wanted ?? (fed / block + 1)
        grow(to: count)
        func fit(_ a: inout [Float]) {
            if a.count < count { a.append(contentsOf: repeatElement(0, count: count - a.count)) }
        }
        fit(&eHighMid); fit(&eHigh); fit(&eAir)
        var sub = [Float](repeating: 0, count: count), bass = sub, lowMid = sub
        for b in 0..<count where nLow[b] > 0 {
            sub[b] = eSub[b] / nLow[b]; bass[b] = eBass[b] / nLow[b]; lowMid[b] = eLowMid[b] / nLow[b]
        }
        // Tiefen glätten: eine Blockenergie aus ~15 Samples schwankt mit der doppelten Grundfrequenz
        sub = Self.smooth(sub, radius: 4)      // ~30 ms
        bass = Self.smooth(bass, radius: 2)    // ~17 ms
        lowMid = Self.smooth(lowMid, radius: 1)
        let highs = (0..<count).map { eHigh[$0] + eAir[$0] }
        let sustain = Self.sustain(highs, radius: Int((0.075 * TrackAudio.blocksPerSecond).rounded()))

        let s = WaveSpectrum.stride
        var out = [UInt8](repeating: 0, count: count * s)
        for b in 0..<count {
            let o = b * s
            out[o] = WaveSpectrum.byte(meanSquare: sub[b])
            out[o + 1] = WaveSpectrum.byte(meanSquare: bass[b])
            out[o + 2] = WaveSpectrum.byte(meanSquare: lowMid[b])
            out[o + 3] = WaveSpectrum.byte(meanSquare: eHighMid[b])
            out[o + 4] = WaveSpectrum.byte(meanSquare: eHigh[b])
            out[o + 5] = WaveSpectrum.byte(meanSquare: eAir[b])
            out[o + WaveSpectrum.sustainSlot] = sustain[b]
        }
        return WaveSpectrum(data: out)
    }

    /// gleitender Mittelwert, zentriert
    static func smooth(_ a: [Float], radius r: Int) -> [Float] {
        guard r > 0, a.count > 1 else { return a }
        var prefix = [Double](repeating: 0, count: a.count + 1)
        for i in a.indices { prefix[i + 1] = prefix[i] + Double(a[i]) }
        return a.indices.map { i in
            let lo = max(0, i - r), hi = min(a.count, i + r + 1)
            return Float((prefix[hi] - prefix[lo]) / Double(hi - lo))
        }
    }

    /// Höhen-Dauer je Block: Anteil des Fensters (±radius), in dem die Höhenenergie über 1/6 (−8 dB) der Fensterspitze liegt
    static func sustain(_ e: [Float], radius r: Int) -> [UInt8] {
        let n = e.count
        guard n > 0 else { return [] }
        let peak = slidingMax(e, radius: r)
        var out = [UInt8](repeating: 0, count: n)
        e.withUnsafeBufferPointer { p in
            for i in 0..<n {
                let lo = max(0, i - r), hi = min(n, i + r + 1)
                let th = peak[i] / 6.3
                guard peak[i] > 1e-11 else { continue }
                var c = 0
                for j in lo..<hi where p[j] >= th { c += 1 }
                out[i] = UInt8(min(255, (Float(c) / Float(hi - lo) * 255).rounded()))
            }
        }
        return out
    }

    /// gleitendes Maximum (±radius) in O(n) – van Herk / Gil-Werman
    static func slidingMax(_ a: [Float], radius r: Int) -> [Float] {
        let n = a.count, w = 2 * r + 1
        guard n > 0, r > 0 else { return a }
        var pre = a, suf = a
        for i in 1..<n where i % w != 0 { pre[i] = max(pre[i - 1], a[i]) }
        if n > 1 { for i in stride(from: n - 2, through: 0, by: -1) where (i + 1) % w != 0 { suf[i] = max(suf[i + 1], a[i]) } }
        return (0..<n).map { i in
            let lo = max(0, i - r), hi = min(n - 1, i + r)
            return max(suf[lo], pre[hi])
        }
    }
}
