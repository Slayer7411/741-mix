import AVFoundation
import Foundation
import MixCore

/// Abtastratenwandlung im Strom (AVAudioConverter, beste Qualität, Mastering-Algorithmus): Eingabe blockweise aus
/// `render`, Ausgabe blockweise an `sink`. Genau `outFrames` Frames (Ende ggf. auf Stille aufgefüllt, Rest abgeschnitten)
enum StreamResampler {
    static let block: AVAudioFrameCount = 1 << 14

    static func run(frames: Int, channels: Int, from inRate: Double, to outRate: Double, render: AudioCutWriter.Render,
                    progress: (Double) -> Bool, sink: ([UnsafeMutablePointer<Float>], Int) throws -> Void) throws {
        guard frames > 0, channels > 0, inRate > 0, outRate > 0 else { throw AudioCutWriter.CutError.format }
        let outFrames = Int((Double(frames) * outRate / inRate).rounded())
        guard let inF = AVAudioFormat(standardFormatWithSampleRate: inRate, channels: AVAudioChannelCount(channels)),
              let outF = AVAudioFormat(standardFormatWithSampleRate: outRate, channels: AVAudioChannelCount(channels)),
              let conv = AVAudioConverter(from: inF, to: outF) else { throw AudioCutWriter.CutError.format }
        conv.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        conv.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inF, frameCapacity: block),
              let outBuf = AVAudioPCMBuffer(pcmFormat: outF, frameCapacity: block),
              let inCh = inBuf.floatChannelData, let outCh = outBuf.floatChannelData else { throw AudioCutWriter.CutError.format }
        var read = 0, done = 0
        var stopped = false
        while true {
            outBuf.frameLength = 0
            var err: NSError?
            let st = conv.convert(to: outBuf, error: &err) { want, status in
                guard read < frames else { status.pointee = .endOfStream; return nil }
                let n = min(Int(want), Int(block), frames - read)
                for c in 0..<channels { render(c, inCh[c], read, n) }
                inBuf.frameLength = AVAudioFrameCount(n)
                read += n
                status.pointee = .haveData
                return inBuf
            }
            let n = min(Int(outBuf.frameLength), outFrames - done)
            if n > 0 {
                try sink((0..<channels).map { outCh[$0] }, n)
                done += n
            }
            if st == .error { throw err ?? AudioCutWriter.CutError.format }
            if !progress(Double(read) / Double(frames)) { stopped = true; break }
            if st == .endOfStream || (st == .inputRanDry && read >= frames && outBuf.frameLength == 0) { break }
        }
        if stopped { throw AudioCutWriter.CutError.cancelled }
        if done < outFrames {
            let pad = outFrames - done
            let zeros = (0..<channels).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: pad) }
            defer { zeros.forEach { $0.deallocate() } }
            zeros.forEach { $0.update(repeating: 0, count: pad) }
            try sink(zeros, pad)
        }
    }
}
