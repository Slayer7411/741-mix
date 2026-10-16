import Foundation
import MixCore

extension AudioSplice {
    /// Schnittliste als Stücke bei `rate` (Stumm, Rückwärts und Stille inklusive): der eine Weg von der Liste zur Ausgabe
    public init(_ e: EditList, rate: Double, sourceFrames n: Int, fade: Int) {
        let f = e.frames(rate: rate, sourceFrames: n)
        self.init(pieces: f.pieces, sourceFrames: n, fade: fade, muted: f.muted, reversed: f.reversed, silent: f.silent)
    }
}

extension TrackAudio {
    /// Schnittliste hörbar machen: Stücke von `source` (Rate und Kanäle des Decks) in einen neuen Puffer. Wellenform-Blöcke
    /// aus denen der Quelle zusammengesetzt (auf einen Block = 3,3 ms genau, stumm = leer), nicht neu analysiert.
    /// Nur im Hintergrund aufrufen (kopiert den ganzen Track)
    public static func rendered(_ splice: AudioSplice, from source: TrackAudio) -> TrackAudio {
        let t = HeapPCM(capacity: splice.frames + 1)
        splice.render(source.left, into: t.left, from: 0, count: splice.frames)
        splice.render(source.right, into: t.right, from: 0, count: splice.frames)
        t.setFrames(splice.frames)
        return t.finish(sampleRate: source.sampleRate, analysis: splicedAnalysis(splice, from: source))
    }

    /// Blöcke der Ausgabe: Block der Quelle am Anfang jedes Ausgabe-Blocks
    static func splicedAnalysis(_ splice: AudioSplice, from a: TrackAudio) -> Analysis {
        let block = blockFrames(sampleRate: a.sampleRate)
        let count = splice.frames / block + 1, srcBlocks = a.peak.count
        var peak = [Float](repeating: 0, count: count), low = peak, mid = peak, high = peak
        let ss = WaveSpectrum.stride, bs = WaveBlend.stride
        let hasSpec = a.spectrum.data.count >= srcBlocks * ss, hasBlend = a.blend.data.count >= srcBlocks * bs
        var spec = [UInt8](repeating: 0, count: hasSpec ? count * ss : 0)
        var blend = [UInt8](repeating: 0, count: hasBlend ? count * bs : 0)
        var k = 0, start = 0
        for b in 0..<count {
            let f = b * block
            while k < splice.pieces.count - 1, f >= start + splice.pieces[k].count { start += splice.pieces[k].count; k += 1 }
            guard k < splice.pieces.count, !splice.muted[k] else { continue }
            let within = f - start, r = splice.pieces[k]
            let srcFrame = splice.reversed[k] ? r.upperBound - 1 - within : r.lowerBound + within
            let sb = min(srcBlocks - 1, max(0, srcFrame / block))
            guard sb >= 0, srcBlocks > 0 else { continue }
            peak[b] = a.peak[sb]; low[b] = a.low[sb]; mid[b] = a.mid[sb]; high[b] = a.high[sb]
            if hasSpec { for i in 0..<ss { spec[b * ss + i] = a.spectrum.data[sb * ss + i] } }
            if hasBlend { for i in 0..<bs { blend[b * bs + i] = a.blend.data[sb * bs + i] } }
        }
        return Analysis(peak: peak, low: low, mid: mid, high: high,
                        spectrum: hasSpec ? WaveSpectrum(data: spec) : .empty, blend: hasBlend ? WaveBlend(data: blend) : .empty)
    }
}

extension AudioCutWriter.Source {
    /// dekodierter Track als Quelle (Rate und Kanäle des Decks, Stereo)
    public static func audio(_ a: TrackAudio, bitDepth: Int) -> AudioCutWriter.Source {
        AudioCutWriter.Source(channels: [a.left, a.right], frames: a.frames, sampleRate: a.sampleRate, bitDepth: bitDepth, fromDeck: true, owner: a)
    }
}
