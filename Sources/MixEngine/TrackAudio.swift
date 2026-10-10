import AVFoundation
import MixCore

/// Ein komplett dekodierter Track (Stereo, Float32, Engine-Samplerate) plus Wellenform-Zusammenfassung.
public final class TrackAudio: @unchecked Sendable {
    public let left: UnsafeMutablePointer<Float>
    public let right: UnsafeMutablePointer<Float>
    public private(set) var frames: Int = 0
    public let sampleRate: Double
    private let capacity: Int

    /// Wellenform: pro Block Spitze (0–1) und Energieanteil Bass/Mitte/Höhe (Summe 1).
    public static let blocksPerSecond = 300.0
    public private(set) var peak: [Float] = []
    public private(set) var low: [Float] = []
    public private(set) var mid: [Float] = []
    public private(set) var high: [Float] = []
    /// feines Spektrum je Block (6 Bänder + Höhen-Dauer), gleiche Blöcke wie `peak`
    public private(set) var spectrum = WaveSpectrum.empty

    public var duration: Double { Double(frames) / sampleRate }

    init(capacity: Int, sampleRate: Double) {
        self.capacity = max(capacity, 1)
        self.sampleRate = sampleRate
        left = .allocate(capacity: self.capacity)
        right = .allocate(capacity: self.capacity)
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }

    public enum DecodeError: Error { case format, convert(String) }

    /// Blockweise Dekodierung
    private static let chunk: AVAudioFrameCount = 1 << 16

    /// Liest die Datei blockweise direkt in den Deck-Puffer (Stereo, `sampleRate`) – keine zweite Kopie des ganzen Tracks.
    public static func decode(url: URL, sampleRate: Double) throws -> TrackAudio {
        let file = try AVAudioFile(forReading: url)
        let inFmt = file.processingFormat
        guard inFmt.sampleRate > 0, sampleRate > 0, inFmt.channelCount > 0 else { throw DecodeError.format }   // sonst Int(inf) beim Anlegen
        let total = max(0, Int(file.length))
        let mono = inFmt.channelCount == 1
        let t = TrackAudio(capacity: Int(Double(total) * sampleRate / inFmt.sampleRate) + 8192, sampleRate: sampleRate)
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: chunk) else { throw DecodeError.format }

        if inFmt.sampleRate == sampleRate, inFmt.commonFormat == .pcmFormatFloat32, !inFmt.isInterleaved {
            while file.framePosition < file.length {
                try file.read(into: inBuf, frameCount: chunk)
                guard inBuf.frameLength > 0 else { break }
                t.append(inBuf, mono: mono)
            }
        } else {
            // Rate/Format wandeln; Mono bleibt Mono und wird beim Anhängen auf beide Seiten gelegt
            // (der Konverter legt Mono sonst nur links an)
            guard let outFmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: mono ? 1 : 2),
                  let conv = AVAudioConverter(from: inFmt, to: outFmt),
                  let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: chunk) else { throw DecodeError.format }
            conv.sampleRateConverterQuality = AVAudioQuality.high.rawValue
            var eof = false
            var readError: Error?
            while true {
                var err: NSError?
                let status = conv.convert(to: outBuf, error: &err) { _, st in
                    // am Dateiende nicht mehr lesen (read wirft dort statt 0 Frames zu liefern)
                    if !eof, file.framePosition < file.length {
                        do { try file.read(into: inBuf, frameCount: chunk) } catch { readError = error }
                    } else { eof = true }
                    if eof || readError != nil || inBuf.frameLength == 0 { eof = true; st.pointee = .endOfStream; return nil }
                    st.pointee = .haveData
                    return inBuf
                }
                if let readError { throw readError }
                if status == .error { throw DecodeError.convert(err?.localizedDescription ?? "?") }
                t.append(outBuf, mono: mono)
                if status == .endOfStream || status == .inputRanDry { break }
            }
        }
        t.analyze()
        return t
    }

    /// Block an den Puffer anhängen (Mono auf beide Seiten)
    private func append(_ b: AVAudioPCMBuffer, mono: Bool) {
        let n = min(Int(b.frameLength), capacity - frames)
        guard n > 0, let ch = b.floatChannelData else { return }
        (left + frames).update(from: ch[0], count: n)
        (right + frames).update(from: ch[mono || b.format.channelCount < 2 ? 0 : 1], count: n)
        frames += n
    }

    /// Einfache 3-Band-Analyse mit Einpol-Filtern (Schichten-Stil, Browser-Übersicht) und parallel dazu das feine
    /// Spektrum (6 Bänder) auf einem zweiten Kern – die Ladezeit wächst nur um den Teil, der länger dauert.
    private func analyze() {
        let block = max(1, Int(sampleRate / Self.blocksPerSecond))
        let count = frames / block + 1
        final class Box: @unchecked Sendable { var spectrum = WaveSpectrum.empty }
        let box = Box()
        let group = DispatchGroup()
        let (l, r, n, rate) = (left, right, frames, sampleRate)
        DispatchQueue.global(qos: .userInitiated).async(group: group) {
            let sa = SpectrumAnalyzer(sampleRate: rate, block: block)
            sa.feed(left: l, right: r, count: n)
            box.spectrum = sa.finish(blocks: count)
        }
        peak = .init(repeating: 0, count: count)
        low = .init(repeating: 0, count: count)
        mid = .init(repeating: 0, count: count)
        high = .init(repeating: 0, count: count)
        let aLow = Float(1 - exp(-2 * Double.pi * 250 / sampleRate))
        let aHigh = Float(1 - exp(-2 * Double.pi * 3000 / sampleRate))
        var lp1: Float = 0, lp2: Float = 0
        var i = 0
        for b in 0..<count {
            var pk: Float = 0, eL: Float = 0, eM: Float = 0, eH: Float = 0
            let end = min(frames, i + block)
            while i < end {
                let x = (left[i] + right[i]) * 0.5
                lp1 += aLow * (x - lp1)
                lp2 += aHigh * (x - lp2)
                let l = lp1, h = x - lp2, m = lp2 - lp1
                eL += l * l; eM += m * m; eH += h * h
                pk = max(pk, abs(left[i]), abs(right[i]))
                i += 1
            }
            // Höhen sind energetisch schwach → leicht anheben, damit Hats sichtbar werden
            eH *= 4; eM *= 2
            let sum = max(eL + eM + eH, 1e-12)
            peak[b] = pk; low[b] = eL / sum; mid[b] = eM / sum; high[b] = eH / sum
        }
        // nicht normalisieren: volle Höhe = 0 dBFS der Datei
        for b in 0..<count { peak[b] = min(1, peak[b]) }
        group.wait()
        spectrum = box.spectrum
    }
}
