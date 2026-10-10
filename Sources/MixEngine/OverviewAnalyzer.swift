import AVFoundation
import MixCore

extension TrackOverview {
    /// aus einem geladenen Deck-Track: die Wellenform-Blöcke liegen schon vor, kostet ~1 ms
    public init(audio a: TrackAudio, points: Int = TrackOverview.points) {
        self.init(peak: a.peak, low: a.low, mid: a.mid, high: a.high, duration: a.duration, points: points)
    }
}

/// Übersicht direkt aus der Datei, ohne den Track ganz zu dekodieren: blockweise lesen, gleiche 3-Band-Analyse wie
/// TrackAudio (Einpol-Filter 250 Hz / 3 kHz, 300 Blöcke/s), nur die Blöcke bleiben im Speicher (~2 MB statt ~150 MB).
public enum OverviewAnalyzer {
    /// `checkpoint` läuft zwischen zwei Lese-Blöcken (Pause: dort warten, Abbruch: werfen)
    public static func analyze(url: URL, checkpoint: () throws -> Void = {}) throws -> TrackOverview {
        let file = try AVAudioFile(forReading: url)
        let fmt = file.processingFormat
        guard fmt.sampleRate > 0, fmt.channelCount > 0, fmt.commonFormat == .pcmFormatFloat32, !fmt.isInterleaved,
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 1 << 15) else { throw TrackAudio.DecodeError.format }
        let rate = fmt.sampleRate
        let block = max(1, Int(rate / TrackAudio.blocksPerSecond))
        let estimate = Int(file.length) / block + 2
        var peak: [Float] = [], low: [Float] = [], mid: [Float] = [], high: [Float] = []
        peak.reserveCapacity(estimate); low.reserveCapacity(estimate); mid.reserveCapacity(estimate); high.reserveCapacity(estimate)
        let aLow = Float(1 - exp(-2 * Double.pi * 250 / rate))
        let aHigh = Float(1 - exp(-2 * Double.pi * 3000 / rate))
        var lp1: Float = 0, lp2: Float = 0
        var pk: Float = 0, eL: Float = 0, eM: Float = 0, eH: Float = 0, inBlock = 0
        var frames = 0
        func close() {
            // wie TrackAudio.analyze: Höhen ×4, Mitten ×2, dann Anteile
            let h = eH * 4, m = eM * 2
            let sum = max(eL + m + h, 1e-12)
            peak.append(min(1, pk)); low.append(eL / sum); mid.append(m / sum); high.append(h / sum)
            pk = 0; eL = 0; eM = 0; eH = 0; inBlock = 0
        }
        while file.framePosition < file.length {
            try checkpoint()
            try file.read(into: buf, frameCount: buf.frameCapacity)
            let n = Int(buf.frameLength)
            guard n > 0, let ch = buf.floatChannelData else { break }
            let l = ch[0], r = ch[fmt.channelCount > 1 ? 1 : 0]
            for i in 0..<n {
                let x = (l[i] + r[i]) * 0.5
                lp1 += aLow * (x - lp1)
                lp2 += aHigh * (x - lp2)
                let lo = lp1, hi = x - lp2, mi = lp2 - lp1
                eL += lo * lo; eM += mi * mi; eH += hi * hi
                pk = max(pk, abs(l[i]), abs(r[i]))
                inBlock += 1
                if inBlock == block { close() }
            }
            frames += n
        }
        close()
        guard frames > 0 else { throw TrackAudio.DecodeError.format }
        return TrackOverview(peak: peak, low: low, mid: mid, high: high, duration: Double(frames) / rate)
    }
}
