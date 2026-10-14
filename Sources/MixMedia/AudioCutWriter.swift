import AVFoundation
import AudioToolbox
import Foundation
import MixCore

/// Schreibt einen geschnittenen Track als Apple Lossless (.m4a). Nur auf einem Hintergrund-Thread aufrufen
/// (liest und schreibt Dateien, auch im Cloud-Ordner). Das Original wird nie geöffnet zum Schreiben.
public enum AudioCutWriter {
    public enum CutError: Error, Equatable {
        case format
        case cancelled
        case empty
    }

    /// PCM der Quelle, nicht verschachtelt, Rate der Datei. Hält den Speicher (eigener Puffer oder der dekodierte Track)
    public final class Source: @unchecked Sendable {
        public let channels: [UnsafePointer<Float>]
        public let frames: Int
        public let sampleRate: Double
        /// Bit-Tiefe für die neue Datei: 16 bei 16-Bit-Quellen, sonst 24
        public let bitDepth: Int
        /// dekodierter Track des Decks benutzt (keine zweite Dekodierung)
        public let fromDeck: Bool
        private let owner: AnyObject?
        private let buffers: [UnsafeMutablePointer<Float>]

        init(channels: [UnsafePointer<Float>], frames: Int, sampleRate: Double, bitDepth: Int, fromDeck: Bool,
             owner: AnyObject?, buffers: [UnsafeMutablePointer<Float>] = []) {
            self.channels = channels; self.frames = frames; self.sampleRate = sampleRate; self.bitDepth = bitDepth
            self.fromDeck = fromDeck; self.owner = owner; self.buffers = buffers
        }

        deinit { buffers.forEach { $0.deallocate() } }

        /// Testquelle aus Arrays (je Kanal)
        public static func samples(_ chans: [[Float]], sampleRate: Double, bitDepth: Int = 24) -> Source {
            let n = chans.map(\.count).min() ?? 0
            let bufs = chans.map { c -> UnsafeMutablePointer<Float> in
                let p = UnsafeMutablePointer<Float>.allocate(capacity: max(1, n))
                c.withUnsafeBufferPointer { p.update(from: $0.baseAddress!, count: n) }
                return p
            }
            return Source(channels: bufs.map { UnsafePointer($0) }, frames: n, sampleRate: sampleRate, bitDepth: bitDepth,
                          fromDeck: false, owner: nil, buffers: bufs)
        }
    }

    /// Quelle für den Schnitt: der dekodierte Track des Decks, wenn er Rate, Kanäle (Stereo) und Länge der Datei hat;
    /// sonst die Datei in ihrer eigenen Rate und Kanalzahl neu dekodieren. `progress` 0…1, false = abbrechen
    public static func source(url: URL, deck audio: TrackAudio?, progress: (Double) -> Bool = { _ in true }) throws -> Source {
        let file = try AVAudioFile(forReading: url)
        let fmt = file.processingFormat
        let rate = fmt.sampleRate, chans = Int(fmt.channelCount)
        guard rate > 0, chans > 0 else { throw CutError.format }
        let depth = bitDepth(file.fileFormat)
        if let a = audio, a.sampleRate == rate, chans == 2, abs(a.frames - Int(file.length)) <= 1 {
            return Source(channels: [a.left, a.right], frames: a.frames, sampleRate: rate, bitDepth: depth, fromDeck: true, owner: a)
        }
        let total = max(0, Int(file.length))
        let chunk: AVAudioFrameCount = 1 << 16
        let capacity = total + Int(chunk)
        let bufs = (0..<chans).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: capacity) }
        var done = 0
        do {
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk) else { throw CutError.format }
            while file.framePosition < file.length {
                try file.read(into: buf, frameCount: chunk)
                let n = min(Int(buf.frameLength), capacity - done)
                guard n > 0, let ch = buf.floatChannelData else { break }
                for c in 0..<chans { (bufs[c] + done).update(from: ch[c], count: n) }
                done += n
                if !progress(total > 0 ? Double(done) / Double(total) : 1) { throw CutError.cancelled }
            }
        } catch {
            bufs.forEach { $0.deallocate() }
            throw error
        }
        return Source(channels: bufs.map { UnsafePointer($0) }, frames: done, sampleRate: rate, bitDepth: depth, fromDeck: false,
                      owner: nil, buffers: bufs)
    }

    /// Bit-Tiefe für eine neue Datei aus dieser Quelldatei (24, wenn sie sich nicht öffnen lässt)
    public static func bitDepth(url: URL) -> Int {
        (try? AVAudioFile(forReading: url)).map { bitDepth($0.fileFormat) } ?? 24
    }

    /// 16 bei 16-Bit-PCM bzw. verlustfreien 16-Bit-Quellen, sonst 24
    static func bitDepth(_ f: AVAudioFormat) -> Int {
        let d = f.streamDescription.pointee
        switch d.mFormatID {
        case kAudioFormatLinearPCM: return d.mBitsPerChannel > 0 && d.mBitsPerChannel <= 16 ? 16 : 24
        case kAudioFormatAppleLossless, kAudioFormatFLAC: return d.mFormatFlags == 1 ? 16 : 24   // …_16BitSourceData
        default: return 24
        }
    }

    /// Apple Lossless in `url` (Endung .m4a) schreiben: erst eine versteckte Datei daneben, fertig -> umbenennen.
    /// `progress` 0…1 je Block, false = abbrechen (nichts bleibt liegen)
    public static func write(_ splice: AudioSplice, source: Source, to url: URL, progress: (Double) -> Bool = { _ in true }) throws {
        guard splice.frames > 0, splice.sourceFrames <= source.frames else { throw CutError.empty }
        try write(frames: splice.frames, channels: source.channels.count, sampleRate: source.sampleRate, format: .alac(source.bitDepth),
                  to: url, render: { c, out, from, n in splice.render(source.channels[c], into: out, from: from, count: n) },
                  progress: progress)
    }

    /// Kanal `c`, Ausgabe-Frames `from ..< from + count` nach `out`
    public typealias Render = (_ channel: Int, _ out: UnsafeMutablePointer<Float>, _ from: Int, _ count: Int) -> Void

    /// Ausgabe blockweise in `url` schreiben (Format `format`, die Endung von `url` wählt den Container): versteckte
    /// Datei daneben, fertig -> umbenennen. `gain` = Faktor je Sample (1 = Bit-genau die gerenderten Samples),
    /// `clamp` = auf ±1 begrenzen. `progress` 0…1 je Block, false = abbrechen (nichts bleibt liegen)
    public static func write(frames: Int, channels chans: Int, sampleRate: Double, format: Format, to url: URL, gain: Float = 1,
                             clamp: Bool = false, render: Render, progress: (Double) -> Bool = { _ in true }) throws {
        guard frames > 0, chans > 0 else { throw CutError.empty }
        let tmp = url.deletingLastPathComponent().appendingPathComponent("." + url.deletingPathExtension().lastPathComponent
                                                                           + ".partial-\(UUID().uuidString.prefix(6))." + url.pathExtension)
        var settings = try format.settings(sampleRate: sampleRate, channels: chans)
        if format.container == .alac, chans > 2 {   // Apple Lossless kennt nur feste Belegungen bis 8 Kanäle
            let tags: [Int: AudioChannelLayoutTag] = [3: kAudioChannelLayoutTag_MPEG_3_0_B, 4: kAudioChannelLayoutTag_MPEG_4_0_B,
                                                      5: kAudioChannelLayoutTag_MPEG_5_0_D, 6: kAudioChannelLayoutTag_MPEG_5_1_D,
                                                      7: kAudioChannelLayoutTag_MPEG_6_1_A, 8: kAudioChannelLayoutTag_MPEG_7_1_A]
            guard let tag = tags[chans] else { throw CutError.format }
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = tag
            settings[AVChannelLayoutKey] = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
        }
        do {
            let file = try AVAudioFile(forWriting: tmp, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let block = 1 << 16
            guard file.processingFormat.channelCount == AVAudioChannelCount(chans),
                  let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(block)),
                  let out = buf.floatChannelData else { throw CutError.format }
            var at = 0
            while at < frames {
                let n = min(block, frames - at)
                for c in 0..<chans {
                    render(c, out[c], at, n)
                    Amplify.apply(out[c], count: n, factor: gain, clamp: clamp)
                }
                buf.frameLength = AVAudioFrameCount(n)
                try file.write(from: buf)
                at += n
                if !progress(Double(at) / Double(frames)) { throw CutError.cancelled }
            }
            file.close()
            try FileManager.default.moveItem(at: tmp, to: url)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }
}
