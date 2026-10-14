import AVFoundation
import Foundation
import Testing
@testable import MixMedia

// Aufnahme-Datei: n Frames rein = n Frames in der Datei, Format, Rate, Bit-Tiefe je Art

@Test(arguments: [RecordingFile.Kind.alac, .wav, .aiff])
func recordingFileKeepsFramesAndFormat(_ kind: RecordingFile.Kind) throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("minos-recfile-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("set." + kind.ext)
    let rate = 48000.0, total = 123_457
    let f = try RecordingFile(url: url, kind: kind, sampleRate: rate, blockFrames: 10_000)
    let l = (0..<total).map { Float(sin(Double($0) * 0.01)) * 0.5 }, r = l.map { -$0 }
    // ungleiche Blöcke, einer größer als der Schreibblock
    var at = 0
    for n in [1, 999, 48_000, 30_001] + Array(repeating: 11_114, count: 4) where at < total {
        let k = min(n, total - at)
        try l.withUnsafeBufferPointer { pl in try r.withUnsafeBufferPointer { pr in
            try f.append(left: pl.baseAddress! + at, right: pr.baseAddress! + at, count: k) } }
        at += k
    }
    #expect(at == total && f.frames == total)
    f.close()
    #expect(throws: RecordingFile.FileError.closed) { try l.withUnsafeBufferPointer { try f.append(left: $0.baseAddress!, right: $0.baseAddress!, count: 1) } }
    let file = try AVAudioFile(forReading: url)
    let d = file.fileFormat.streamDescription.pointee
    #expect(Int(file.length) == total)
    #expect(file.fileFormat.sampleRate == rate && file.fileFormat.channelCount == 2)
    switch kind {
    case .alac: #expect(d.mFormatID == kAudioFormatAppleLossless && AudioCutWriter.bitDepth(file.fileFormat) == 24)
    case .wav, .aiff:
        #expect(d.mFormatID == kAudioFormatLinearPCM && d.mBitsPerChannel == 24)
        #expect((d.mFormatFlags & kAudioFormatFlagIsBigEndian != 0) == (kind == .aiff))
    }
    let buf = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(total)))
    try file.read(into: buf)
    var err: Float = 0
    for i in stride(from: 0, to: total, by: 97) { err = max(err, abs(buf.floatChannelData![1][i] - r[i])) }
    #expect(err < 1e-5)
}
