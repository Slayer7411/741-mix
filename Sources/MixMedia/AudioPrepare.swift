import Accelerate
import AVFoundation
import AudioToolbox
import Foundation
import MixCore

extension AudioCutWriter {
    /// Format einer neuen Datei: Apple Lossless (.m4a), AAC (.m4a) oder PCM wie die Quelle (WAV, AIFF)
    public struct Format: Equatable, Sendable {
        public enum Container: Sendable { case alac, wav, aiff, aac }
        public var container: Container
        public var bitDepth: Int
        /// PCM als Float (nur WAV)
        public var float = false
        /// Endung der neuen Datei
        public var ext: String
        /// Abtastrate der Datei (nil = wie die Quelle)
        public var rate: Double?
        /// TPDF-Dither beim Schritt auf 16 Bit
        public var dither = false
        /// AAC: Bitrate in kbit/s
        public var kbps = 256

        public init(container: Container, bitDepth: Int, float: Bool = false, ext: String, rate: Double? = nil, dither: Bool = false,
                    kbps: Int = 256) {
            self.container = container; self.bitDepth = bitDepth; self.float = float; self.ext = ext
            self.rate = rate; self.dither = dither; self.kbps = kbps
        }

        public static func alac(_ depth: Int) -> Format { Format(container: .alac, bitDepth: depth == 16 ? 16 : 24, ext: "m4a") }

        /// Sample-Format der Datei für den Schreibpuffer: Float (WAV Float, AAC), sonst Ganzzahl 16 Bit oder 24 Bit in Int32
        var processing: AVAudioCommonFormat {
            if container == .aac || float { return .pcmFormatFloat32 }
            return bitDepth == 16 ? .pcmFormatInt16 : .pcmFormatInt32
        }

        func settings(sampleRate: Double, channels: Int) throws -> [String: Any] {
            var s: [String: Any] = [AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels]
            switch container {
            case .alac:
                s[AVFormatIDKey] = kAudioFormatAppleLossless
                s[AVEncoderBitDepthHintKey] = bitDepth
            case .aac:
                s[AVFormatIDKey] = kAudioFormatMPEG4AAC
                s[AVEncoderBitRateKey] = kbps * 1000
            case .wav, .aiff:
                s[AVFormatIDKey] = kAudioFormatLinearPCM
                s[AVLinearPCMBitDepthKey] = bitDepth
                s[AVLinearPCMIsFloatKey] = float
                s[AVLinearPCMIsBigEndianKey] = container == .aiff
                s[AVLinearPCMIsNonInterleaved] = false
            }
            return s
        }
    }

    /// Format für eine neue Datei aus dieser Quelle: WAV / AIFF (ganzzahlig, 16 / 24 / 32 Bit, WAV auch Float) bleiben
    /// WAV / AIFF in Bit-Tiefe und Endung der Quelle, alles andere wird Apple Lossless (16 Bit aus 16-Bit-Quellen,
    /// sonst 24). Lässt sich die Datei nicht öffnen: Apple Lossless 24 Bit
    public static func format(matching url: URL) -> Format {
        guard let f = try? AVAudioFile(forReading: url) else { return .alac(24) }
        let d = f.fileFormat.streamDescription.pointee
        let ext = url.pathExtension.lowercased()
        if d.mFormatID == kAudioFormatLinearPCM {
            let float = d.mFormatFlags & kAudioFormatFlagIsFloat != 0
            let bits = Int(d.mBitsPerChannel)
            let depth = float ? 32 : (bits <= 16 ? 16 : bits <= 24 ? 24 : 32)
            if ["wav", "wave"].contains(ext) { return Format(container: .wav, bitDepth: depth, float: float, ext: ext) }
            if ["aif", "aiff"].contains(ext), !float { return Format(container: .aiff, bitDepth: depth, ext: ext) }
        }
        return .alac(bitDepth(f.fileFormat))
    }

    /// Ein Kanal eines Blocks in den Schreibpuffer: Float unverändert, Ganzzahl mit Wandlung (16 Bit mit Dither, 24 Bit)
    static func store(_ x: UnsafeMutablePointer<Float>, count n: Int, into buf: AVAudioPCMBuffer, channel c: Int, format: Format,
                      rng: inout AudioDither, quant: UnsafeMutablePointer<Int32>) {
        switch format.processing {
        case .pcmFormatInt16:
            AudioDither.quantize(x, count: n, bits: 16, dither: format.dither, rng: &rng, into: quant)
            let o = buf.int16ChannelData![c]
            for i in 0..<n { o[i] = Int16(truncatingIfNeeded: quant[i]) }
        case .pcmFormatInt32:
            AudioDither.quantize(x, count: n, bits: 24, dither: false, rng: &rng, into: quant)
            let o = buf.int32ChannelData![c]
            for i in 0..<n { o[i] = quant[i] << 8 }
        default:
            buf.floatChannelData![c].update(from: x, count: n)
        }
    }

    /// Spitze (Betrag, linear) der Ausgabe über alle Kanäle
    public static func peak(frames: Int, channels: Int, render: Render) -> Float {
        let block = 1 << 16
        let buf = UnsafeMutablePointer<Float>.allocate(capacity: block)
        defer { buf.deallocate() }
        var peak: Float = 0
        var at = 0
        while at < frames {
            let n = min(block, frames - at)
            for c in 0..<channels {
                render(c, buf, at, n)
                var m: Float = 0
                vDSP_maxmgv(buf, 1, &m, vDSP_Length(n))
                peak = max(peak, m)
            }
            at += n
        }
        return peak
    }

    /// Spitze von Kanälen im Speicher
    public static func peak(_ channels: [UnsafePointer<Float>], frames: Int) -> Float {
        var peak: Float = 0
        for c in channels where frames > 0 {
            var m: Float = 0
            vDSP_maxmgv(c, 1, &m, vDSP_Length(frames))
            peak = max(peak, m)
        }
        return peak
    }

    /// Quelle in `rate` und `channels` Kanälen, abgespielt mit `speed` (1 = Tempo und Tonhöhe bleiben): Kanäle
    /// verteilt (Mono -> alle, Stereo -> Mono gemittelt, sonst die ersten), dann Abtastrate gewandelt (beste Qualität).
    /// Gleiche Rate, gleiches Tempo, gleiche Kanäle -> die Quelle selbst
    public static func converted(_ s: Source, rate: Double, channels: Int, speed: Double = 1) throws -> Source {
        let inRate = s.sampleRate * speed
        let sameRate = abs(inRate - rate) < 1e-9
        guard channels > 0, s.frames > 0 else { throw CutError.format }
        if sameRate, s.channels.count == channels { return s }
        // Kanäle
        let mapped = (0..<channels).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: s.frames) }
        for c in 0..<channels {
            if channels == 1, s.channels.count > 1 {
                mapped[0].update(repeating: 0, count: s.frames)
                for src in s.channels { vDSP_vadd(mapped[0], 1, src, 1, mapped[0], 1, vDSP_Length(s.frames)) }
                var k = 1 / Float(s.channels.count)
                vDSP_vsmul(mapped[0], 1, &k, mapped[0], 1, vDSP_Length(s.frames))
            } else {
                mapped[c].update(from: s.channels[min(c, s.channels.count - 1)], count: s.frames)
            }
        }
        if sameRate {
            return Source(channels: mapped.map { UnsafePointer($0) }, frames: s.frames, sampleRate: rate, bitDepth: s.bitDepth,
                          fromDeck: false, owner: nil, buffers: mapped)
        }
        defer { mapped.forEach { $0.deallocate() } }
        guard let inF = AVAudioFormat(standardFormatWithSampleRate: inRate, channels: AVAudioChannelCount(channels)),
              let outF = AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(channels)),
              let conv = AVAudioConverter(from: inF, to: outF) else { throw CutError.format }
        conv.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        conv.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        let block: AVAudioFrameCount = 1 << 14
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inF, frameCapacity: block),
              let outBuf = AVAudioPCMBuffer(pcmFormat: outF, frameCapacity: block) else { throw CutError.format }
        let capacity = Int((Double(s.frames) * rate / inRate).rounded(.up)) + Int(block) * 2
        let bufs = (0..<channels).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: capacity) }
        var read = 0, done = 0
        let total = s.frames
        while true {
            outBuf.frameLength = 0
            var err: NSError?
            let st = conv.convert(to: outBuf, error: &err) { want, status in
                guard read < total else { status.pointee = .endOfStream; return nil }
                let n = min(Int(want), Int(block), total - read)
                for c in 0..<channels { inBuf.floatChannelData![c].update(from: mapped[c] + read, count: n) }
                inBuf.frameLength = AVAudioFrameCount(n)
                read += n
                status.pointee = .haveData
                return inBuf
            }
            let n = min(Int(outBuf.frameLength), capacity - done)
            if n > 0, let ch = outBuf.floatChannelData { for c in 0..<channels { (bufs[c] + done).update(from: ch[c], count: n) } }
            done += max(0, n)
            if st == .error {
                bufs.forEach { $0.deallocate() }
                throw err ?? CutError.format
            }
            if st == .endOfStream || (st == .inputRanDry && read >= total && outBuf.frameLength == 0) { break }
        }
        // Länge wie gerechnet (der Wandler liefert am Ende ggf. ein paar Frames mehr oder weniger)
        let want = min(capacity, Int((Double(total) * rate / inRate).rounded()))
        if done < want { for c in 0..<channels { (bufs[c] + done).update(repeating: 0, count: want - done) } }
        return Source(channels: bufs.map { UnsafePointer($0) }, frames: want, sampleRate: rate, bitDepth: s.bitDepth,
                      fromDeck: false, owner: nil, buffers: bufs)
    }
}

/// JOIN: erste Ausgabe bis zur Naht (danach Stille, falls sie früher endet), zweite ab ihrem Anfangs-Frame dahinter.
/// Linearer Crossfade über `fade` Frames: mittig auf der Naht, wenn die erste über die Naht hinaus Audio hat, sonst
/// endet er auf der Naht (die erste blendet vor ihrem Ende aus). Die zweite beginnt im Crossfade mit dem Audio vor
/// ihrem Anfang (sonst Stille). Länge = Naht + Rest der zweiten: der Anfang der zweiten liegt genau auf der Naht
public struct AudioJoin: Equatable, Sendable {
    /// Frames der ersten (Ausgabe davor)
    public let aFrames: Int
    /// Ausgabe-Frame, an dem die zweite beginnt
    public let joint: Int
    /// erster Frame der zweiten
    public let bStart: Int
    /// Frames der zweiten (Quelle)
    public let bFrames: Int
    public let fade: Int
    public let frames: Int
    /// Crossfade-Bereich der Ausgabe
    let fadeStart: Int, fadeEnd: Int

    public init(aFrames: Int, joint: Int, bStart: Int, bFrames: Int, fade: Int) {
        self.aFrames = max(0, aFrames)
        self.joint = max(0, joint)
        self.bStart = min(max(0, bStart), max(0, bFrames))
        self.bFrames = max(0, bFrames)
        self.fade = max(0, fade)
        frames = self.joint + self.bFrames - self.bStart
        let h = self.fade / 2
        fadeEnd = self.joint + max(0, min(h, self.aFrames - self.joint, self.bFrames - self.bStart))
        fadeStart = max(0, fadeEnd - 2 * h)
    }

    /// Ausgabe-Frames `from ..< from + count` eines Kanals nach `out`; `a(out, from, count)` liefert Frames der ersten
    /// (nur innerhalb 0 ..< aFrames angefragt)
    public func render(a: (UnsafeMutablePointer<Float>, Int, Int) -> Void, b: UnsafePointer<Float>,
                       into out: UnsafeMutablePointer<Float>, from: Int, count: Int) {
        let lo = max(0, from), hi = min(frames, from + count)
        guard hi > lo else { return }
        let o = out - from   // o[j] = Ausgabe-Frame j
        // erste bis zum Ende des Crossfades, Stille hinter ihrem Ende
        if lo < fadeEnd {
            let e = min(hi, fadeEnd), av = min(e, aFrames)
            if av > lo { a(o + lo, lo, av - lo) }
            if e > max(lo, av) { (o + max(lo, av)).update(repeating: 0, count: e - max(lo, av)) }
        }
        // zweite ab dem Ende des Crossfades
        let bOn = max(lo, fadeEnd)
        if hi > bOn { (o + bOn).update(from: b + bStart + (bOn - joint), count: hi - bOn) }
        // Crossfade: erste aus, zweite ein (vor ihrem Anfang das Audio davor, vor dem Dateianfang Stille)
        let fa = max(lo, fadeStart), fb = min(hi, fadeEnd)
        guard fb > fa else { return }
        let len = Double(fadeEnd - fadeStart)
        for j in fa..<fb {
            let w = Float((Double(j - fadeStart) + 0.5) / len)
            let i = bStart + j - joint
            o[j] = o[j] * (1 - w) + (i >= 0 ? b[i] : 0) * w
        }
    }
}
