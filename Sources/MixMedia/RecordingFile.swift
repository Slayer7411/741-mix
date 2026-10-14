import AVFoundation
import Foundation

/// Aufnahme-Datei (Stereo, Float rein): Apple Lossless 24 Bit, WAV 24 Bit oder AIFF 24 Bit. Blockweise anhängen,
/// direkt unter dem endgültigen Namen (die Aufnahme ist im Finder sichtbar, solange sie läuft). Nur ein Thread.
public final class RecordingFile {
    public enum Kind: String, CaseIterable, Codable, Sendable {
        case alac, wav, aiff
        public var ext: String {
            switch self {
            case .alac: "m4a"
            case .wav: "wav"
            case .aiff: "aif"
            }
        }
        public var format: AudioCutWriter.Format {
            switch self {
            case .alac: .alac(24)
            case .wav: AudioCutWriter.Format(container: .wav, bitDepth: 24, ext: ext)
            case .aiff: AudioCutWriter.Format(container: .aiff, bitDepth: 24, ext: ext)
            }
        }
    }

    public enum FileError: Error, Equatable { case format, closed }

    public let url: URL
    public let sampleRate: Double
    public private(set) var frames = 0
    private var file: AVAudioFile?
    private let buffer: AVAudioPCMBuffer
    private let block: Int

    /// `blockFrames` = größter Block je `append` (größere werden geteilt)
    public init(url: URL, kind: Kind, sampleRate: Double, blockFrames: Int = 1 << 16) throws {
        self.url = url
        self.sampleRate = sampleRate
        block = max(1024, blockFrames)
        let settings = try kind.format.settings(sampleRate: sampleRate, channels: 2)
        let f = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard f.processingFormat.channelCount == 2,
              let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(block)) else { throw FileError.format }
        file = f
        buffer = b
    }

    /// `count` Frames je Kanal anhängen
    public func append(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int) throws {
        guard let file else { throw FileError.closed }
        guard let ch = buffer.floatChannelData else { throw FileError.format }
        var at = 0
        while at < count {
            let n = min(block, count - at)
            ch[0].update(from: left + at, count: n)
            ch[1].update(from: right + at, count: n)
            buffer.frameLength = AVAudioFrameCount(n)
            try file.write(from: buffer)
            at += n
            frames += n
        }
    }

    /// Datei abschließen (Kopf / Index schreiben). Danach kein `append` mehr
    public func close() {
        file?.close()
        file = nil
    }

    deinit { close() }
}
