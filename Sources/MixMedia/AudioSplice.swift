import Foundation

/// Geschnittener Track aus Stücken der Quelle (Frame-Bereiche, hintereinander). An jeder Naht ein linearer Crossfade
/// über `fade` Frames, mittig auf der Naht – die Länge bleibt die Summe der Stücke (Grid-Rechnung bleibt genau).
/// Beginnt bzw. endet die Ausgabe mitten in der Quelle, blendet sie dort über `fade` Frames ein bzw. aus.
public struct AudioSplice: Equatable, Sendable {
    public let pieces: [Range<Int>]
    public let sourceFrames: Int
    public let fade: Int
    /// Länge der Ausgabe
    public let frames: Int
    /// Ausgabe-Anfang je Stück
    let starts: [Int]
    /// halbe Crossfade-Länge je Naht (0 = harte Naht oder Stücke liegen in der Quelle direkt hintereinander)
    let halves: [Int]

    public init(pieces: [Range<Int>], sourceFrames: Int, fade: Int) {
        let p = pieces.map { $0.clamped(to: 0..<max(0, sourceFrames)) }.filter { !$0.isEmpty }
        self.pieces = p
        self.sourceFrames = sourceFrames
        self.fade = max(0, fade)
        var s: [Int] = [], at = 0
        for r in p { s.append(at); at += r.count }
        starts = s
        frames = at
        let h = max(0, fade) / 2
        halves = p.indices.dropLast().map { k in
            let a = p[k], b = p[k + 1]
            if a.upperBound == b.lowerBound { return 0 }
            return max(0, min(h, a.count, b.count, sourceFrames - a.upperBound, b.lowerBound))
        }
    }

    /// Quelle ohne den Bereich `r`
    public static func removing(_ r: Range<Int>, frames n: Int, fade: Int) -> AudioSplice {
        let r = r.clamped(to: 0..<max(0, n))
        return AudioSplice(pieces: [0..<r.lowerBound, r.upperBound..<n], sourceFrames: n, fade: fade)
    }

    /// nur der Bereich `r`
    public static func keeping(_ r: Range<Int>, frames n: Int, fade: Int) -> AudioSplice {
        AudioSplice(pieces: [r], sourceFrames: n, fade: fade)
    }

    /// Ausgabe-Frames `from ..< from + count` eines Kanals nach `out`
    public func render(_ src: UnsafePointer<Float>, into out: UnsafeMutablePointer<Float>, from: Int, count: Int) {
        let lo = max(0, from), hi = min(frames, from + count)
        guard hi > lo else { return }
        let o = out - from   // o[j] = Ausgabe-Frame j
        // Stücke kopieren
        for (k, r) in pieces.enumerated() {
            let a = max(lo, starts[k]), b = min(hi, starts[k] + r.count)
            guard b > a else { continue }
            (o + a).update(from: src + r.lowerBound + (a - starts[k]), count: b - a)
        }
        // Nähte: ausgehendes Stück läuft h Frames über sein Ende weiter, eingehendes beginnt h Frames vor seinem Anfang
        for (k, h) in halves.enumerated() where h > 0 {
            let join = starts[k + 1], len = Double(2 * h)
            let a = max(lo, join - h), b = min(hi, join + h)
            guard b > a else { continue }
            let outBase = pieces[k].lowerBound - starts[k], inBase = pieces[k + 1].lowerBound - join
            for j in a..<b {
                let w = Float((Double(j - (join - h)) + 0.5) / len)
                o[j] = src[outBase + j] * (1 - w) + src[inBase + j] * w
            }
        }
        // Ränder mitten in der Quelle
        if let first = pieces.first, first.lowerBound > 0 {
            let f = min(fade, frames)
            for j in stride(from: lo, to: min(hi, f), by: 1) { o[j] *= Float((Double(j) + 0.5) / Double(f)) }
        }
        if let last = pieces.last, last.upperBound < sourceFrames {
            let f = min(fade, frames)
            for j in stride(from: max(lo, frames - f), to: hi, by: 1) { o[j] *= Float((Double(frames - j) - 0.5) / Double(f)) }
        }
    }

    /// Crossfade-Länge für 2 ms bei dieser Rate
    public static func fadeFrames(sampleRate: Double) -> Int { max(2, Int((sampleRate * 0.002).rounded())) }
}
