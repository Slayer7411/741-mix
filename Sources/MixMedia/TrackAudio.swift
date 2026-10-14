import AVFoundation
import MixCore

/// Ein komplett dekodierter Track (Stereo, Float32, Engine-Samplerate) plus Wellenform-Zusammenfassung.
/// Nur lesbar: entweder eigener Speicher (Dekodieren im Prozess) oder eine Sicht auf eine eingeblendete
/// `.mtrk`-Datei (Datei-Dienst). Freigegeben (bzw. ausgeblendet) wird erst im deinit – der Kern darf den Puffer
/// bis `mdsp_track_consumed` lesen, deshalb hält der Steuerkern die Instanz bis dahin.
public final class TrackAudio: @unchecked Sendable {
    public let left: UnsafePointer<Float>
    public let right: UnsafePointer<Float>
    public let frames: Int
    public let sampleRate: Double

    /// Wellenform: pro Block Spitze (0–1) und Energieanteil Bass/Mitte/Höhe (Summe 1).
    public static let blocksPerSecond = 300.0
    public let peak: UnsafeBufferPointer<Float>
    public let low: UnsafeBufferPointer<Float>
    public let mid: UnsafeBufferPointer<Float>
    public let high: UnsafeBufferPointer<Float>
    /// feines Spektrum je Block (6 Bänder + Höhen-Dauer), gleiche Blöcke wie `peak`
    public let spectrum: WaveSpectrum
    /// Band-Hüllkurven je Block (Stil 3-Band Mischung), gleiche Blöcke wie `peak`
    public let blend: WaveBlend

    /// Eigentümer des Speichers (Heap oder Abbildung); gibt ihn im eigenen deinit frei
    private let owner: AnyObject
    /// eingeblendete Datei (nil = eigener Speicher)
    public var mapping: TrackFile.Mapping? { owner as? TrackFile.Mapping }

    public var duration: Double { Double(frames) / sampleRate }
    /// Größe der Audiodaten (L + R)
    public var bytes: Int { frames * 2 * MemoryLayout<Float>.size }

    /// Samples je Wellenform-Block bei dieser Rate
    public static func blockFrames(sampleRate: Double) -> Int { max(1, Int(sampleRate / blocksPerSecond)) }

    init(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int, sampleRate: Double,
         peak: UnsafeBufferPointer<Float>, low: UnsafeBufferPointer<Float>, mid: UnsafeBufferPointer<Float>,
         high: UnsafeBufferPointer<Float>, spectrum: WaveSpectrum, blend: WaveBlend, owner: AnyObject) {
        self.left = left; self.right = right; self.frames = frames; self.sampleRate = sampleRate
        self.peak = peak; self.low = low; self.mid = mid; self.high = high
        self.spectrum = spectrum; self.blend = blend; self.owner = owner
    }

    public enum DecodeError: Error { case format, convert(String), cancelled }

    /// Blockweise Dekodierung
    private static let chunk: AVAudioFrameCount = 1 << 16

    /// Liest die Datei blockweise direkt in den Deck-Puffer (Stereo, `sampleRate`) – keine zweite Kopie des ganzen Tracks.
    /// `progress` bekommt nach jedem Block die bisher gelesenen Frames; false = abbrechen (wirft `.cancelled`)
    public static func decode(url: URL, sampleRate: Double, progress: ((Int) -> Bool)? = nil) throws -> TrackAudio {
        let file = try AVAudioFile(forReading: url)
        let inFmt = file.processingFormat
        guard inFmt.sampleRate > 0, sampleRate > 0, inFmt.channelCount > 0 else { throw DecodeError.format }   // sonst Int(inf) beim Anlegen
        let total = max(0, Int(file.length))
        let mono = inFmt.channelCount == 1
        let t = HeapPCM(capacity: Int(Double(total) * sampleRate / inFmt.sampleRate) + 8192)
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: chunk) else { throw DecodeError.format }

        if inFmt.sampleRate == sampleRate, inFmt.commonFormat == .pcmFormatFloat32, !inFmt.isInterleaved {
            while file.framePosition < file.length {
                try file.read(into: inBuf, frameCount: chunk)
                guard inBuf.frameLength > 0 else { break }
                t.append(inBuf, mono: mono)
                if let progress, !progress(t.frames) { throw DecodeError.cancelled }
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
                if let progress, !progress(t.frames) { throw DecodeError.cancelled }
                if status == .endOfStream || status == .inputRanDry { break }
            }
        }
        return t.finish(sampleRate: sampleRate)
    }

    /// Wellenform-Analyse über fertige Samples (Einpol-Filter, Schichten-Stil, Browser-Übersicht) und parallel dazu
    /// das feine Spektrum (6 Bänder) und die Band-Hüllkurven auf weiteren Kernen – die Ladezeit wächst nur um den Teil,
    /// der länger dauert.
    public struct Analysis {
        public var peak: [Float], low: [Float], mid: [Float], high: [Float]
        public var spectrum: WaveSpectrum
        public var blend: WaveBlend
        public var blocks: Int { peak.count }
    }

    public static func analyze(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int, sampleRate: Double) -> Analysis {
        let block = blockFrames(sampleRate: sampleRate)
        let count = frames / block + 1
        final class Box: @unchecked Sendable { var spectrum = WaveSpectrum.empty, blend = WaveBlend.empty }
        let box = Box()
        let group = DispatchGroup()
        DispatchQueue.global(qos: .userInitiated).async(group: group) {
            let sa = SpectrumAnalyzer(sampleRate: sampleRate, block: block)
            sa.feed(left: left, right: right, count: frames)
            box.spectrum = sa.finish(blocks: count)
        }
        DispatchQueue.global(qos: .userInitiated).async(group: group) {
            box.blend = BlendAnalyzer.analyze(left: left, right: right, frames: frames, sampleRate: sampleRate, blocks: count)
        }
        var peak = [Float](repeating: 0, count: count)
        var low = [Float](repeating: 0, count: count)
        var mid = [Float](repeating: 0, count: count)
        var high = [Float](repeating: 0, count: count)
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
        return Analysis(peak: peak, low: low, mid: mid, high: high, spectrum: box.spectrum, blend: box.blend)
    }
}

/// Dekodier-Puffer im eigenen Speicher: wächst beim Dekodieren, danach Eigentümer der fertigen `TrackAudio`
final class HeapPCM {
    let left: UnsafeMutablePointer<Float>
    let right: UnsafeMutablePointer<Float>
    private(set) var frames = 0
    private let capacity: Int
    /// Wellenform-Blöcke (peak, low, mid, high hintereinander)
    private var bands: UnsafeMutableBufferPointer<Float>?

    init(capacity: Int) {
        self.capacity = max(capacity, 1)
        left = .allocate(capacity: self.capacity)
        right = .allocate(capacity: self.capacity)
    }

    deinit {
        left.deallocate()
        right.deallocate()
        bands?.deallocate()
    }

    /// direkt beschrieben (Schnittliste): Länge setzen
    func setFrames(_ n: Int) { frames = min(max(0, n), capacity) }

    /// Block an den Puffer anhängen (Mono auf beide Seiten)
    func append(_ b: AVAudioPCMBuffer, mono: Bool) {
        let n = min(Int(b.frameLength), capacity - frames)
        guard n > 0, let ch = b.floatChannelData else { return }
        (left + frames).update(from: ch[0], count: n)
        (right + frames).update(from: ch[mono || b.format.channelCount < 2 ? 0 : 1], count: n)
        frames += n
    }

    /// Analyse rechnen und als `TrackAudio` übergeben (dieser Puffer wird ihr Eigentümer)
    func finish(sampleRate: Double, analysis: TrackAudio.Analysis? = nil) -> TrackAudio {
        let a = analysis ?? TrackAudio.analyze(left: left, right: right, frames: frames, sampleRate: sampleRate)
        let n = a.blocks
        let all = UnsafeMutableBufferPointer<Float>.allocate(capacity: max(1, n * 4))
        bands = all
        let base = all.baseAddress!
        for (k, src) in [a.peak, a.low, a.mid, a.high].enumerated() { (base + k * n).update(from: src, count: n) }
        let view = { (k: Int) in UnsafeBufferPointer(start: base + k * n, count: n) }
        return TrackAudio(left: left, right: right, frames: frames, sampleRate: sampleRate,
                          peak: view(0), low: view(1), mid: view(2), high: view(3), spectrum: a.spectrum, blend: a.blend, owner: self)
    }
}
