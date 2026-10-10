import AVFoundation

/// Ein komplett dekodierter Track (Stereo, Float32, Engine-Samplerate) plus Wellenform-Zusammenfassung.
public final class TrackAudio: @unchecked Sendable {
    public let left: UnsafeMutablePointer<Float>
    public let right: UnsafeMutablePointer<Float>
    public let frames: Int
    public let sampleRate: Double

    /// Wellenform: pro Block Spitze (0–1) und Energieanteil Bass/Mitte/Höhe (Summe 1).
    public static let blocksPerSecond = 300.0
    public private(set) var peak: [Float] = []
    public private(set) var low: [Float] = []
    public private(set) var mid: [Float] = []
    public private(set) var high: [Float] = []

    public var duration: Double { Double(frames) / sampleRate }

    init(frames: Int, sampleRate: Double) {
        self.frames = frames
        self.sampleRate = sampleRate
        left = .allocate(capacity: max(frames, 1))
        right = .allocate(capacity: max(frames, 1))
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }

    public enum DecodeError: Error { case format, convert(String) }

    /// Liest die Datei und wandelt sie auf `sampleRate` / Stereo um.
    public static func decode(url: URL, sampleRate: Double) throws -> TrackAudio {
        let file = try AVAudioFile(forReading: url)
        let inFmt = file.processingFormat
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw DecodeError.format
        }
        try file.read(into: inBuf)

        var src = inBuf
        // Mono → Stereo selbst duplizieren (der Konverter legt Mono sonst nur links an)
        if inFmt.channelCount == 1 {
            guard let st = AVAudioFormat(standardFormatWithSampleRate: inFmt.sampleRate, channels: 2),
                  let b = AVAudioPCMBuffer(pcmFormat: st, frameCapacity: inBuf.frameLength),
                  let m = inBuf.floatChannelData?[0], let o = b.floatChannelData else { throw DecodeError.format }
            b.frameLength = inBuf.frameLength
            o[0].update(from: m, count: Int(inBuf.frameLength))
            o[1].update(from: m, count: Int(inBuf.frameLength))
            src = b
        }

        let outFmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let out: AVAudioPCMBuffer
        if src.format.sampleRate == sampleRate, src.format.commonFormat == .pcmFormatFloat32, !src.format.isInterleaved,
           src.format.channelCount == 2 {
            out = src
        } else {
            guard let conv = AVAudioConverter(from: src.format, to: outFmt) else { throw DecodeError.format }
            conv.sampleRateConverterQuality = AVAudioQuality.high.rawValue
            let cap = AVAudioFrameCount(Double(src.frameLength) * sampleRate / src.format.sampleRate) + 8192
            guard let o = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: cap) else { throw DecodeError.format }
            var fed = false
            var err: NSError?
            let input = src
            let status = conv.convert(to: o, error: &err) { _, st in
                if fed { st.pointee = .endOfStream; return nil }
                fed = true
                st.pointee = .haveData
                return input
            }
            if status == .error { throw DecodeError.convert(err?.localizedDescription ?? "?") }
            out = o
        }

        let n = Int(out.frameLength)
        let t = TrackAudio(frames: n, sampleRate: sampleRate)
        guard let ch = out.floatChannelData else { throw DecodeError.format }
        t.left.update(from: ch[0], count: n)
        t.right.update(from: ch[out.format.channelCount > 1 ? 1 : 0], count: n)
        t.analyze()
        return t
    }

    /// Einfache 3-Band-Analyse mit Einpol-Filtern (reicht für eine farbige Wellenform wie in Traktor).
    private func analyze() {
        let block = max(1, Int(sampleRate / Self.blocksPerSecond))
        let count = frames / block + 1
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
    }
}
