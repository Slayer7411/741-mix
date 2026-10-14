import Foundation

/// Geschnittener Track aus Stücken der Quelle (Frame-Bereiche, hintereinander). An jeder Naht ein linearer Crossfade
/// über `fade` Frames, mittig auf der Naht – die Länge bleibt die Summe der Stücke (Grid-Rechnung bleibt genau).
/// Beginnt bzw. endet die Ausgabe mitten in der Quelle, blendet sie dort über `fade` Frames ein bzw. aus.
/// Stumme Stücke sind Stille gleicher Länge (Nähte blenden in sie hinein). `loopSeam`: ein Stück, Ende läuft nahtlos
/// in den Anfang (Crossfade mit dem Audio vor dem Anfang bzw. nach dem Ende statt Blenden an den Rändern)
public struct AudioSplice: Equatable, Sendable {
    public let pieces: [Range<Int>]
    /// je Stück: stumm
    public let muted: [Bool]
    public let loopSeam: Bool
    public let sourceFrames: Int
    public let fade: Int
    /// Länge der Ausgabe
    public let frames: Int
    /// Ausgabe-Anfang je Stück
    let starts: [Int]
    /// halbe Crossfade-Länge je Naht (0 = harte Naht oder Stücke liegen in der Quelle direkt hintereinander)
    let halves: [Int]

    public init(pieces: [Range<Int>], sourceFrames: Int, fade: Int, muted: [Bool] = [], loopSeam: Bool = false) {
        let all = pieces.map { $0.clamped(to: 0..<max(0, sourceFrames)) }
        let keep = all.indices.filter { !all[$0].isEmpty }
        let p = keep.map { all[$0] }
        let m = keep.map { muted.indices.contains($0) ? muted[$0] : false }
        self.pieces = p
        self.muted = m
        self.loopSeam = loopSeam && p.count == 1
        self.sourceFrames = sourceFrames
        self.fade = max(0, fade)
        var s: [Int] = [], at = 0
        for r in p { s.append(at); at += r.count }
        starts = s
        frames = at
        let h = max(0, fade) / 2
        halves = p.indices.dropLast().map { k in
            let a = p[k], b = p[k + 1]
            if a.upperBound == b.lowerBound, m[k] == m[k + 1] { return 0 }
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

    /// Tool-Loop: nur `r`, Ende nahtlos in den Anfang
    public static func toolLoop(_ r: Range<Int>, frames n: Int, fade: Int) -> AudioSplice {
        AudioSplice(pieces: [r], sourceFrames: n, fade: fade, loopSeam: true)
    }

    /// Ausgabe-Frames `from ..< from + count` eines Kanals nach `out`
    public func render(_ src: UnsafePointer<Float>, into out: UnsafeMutablePointer<Float>, from: Int, count: Int) {
        let lo = max(0, from), hi = min(frames, from + count)
        guard hi > lo else { return }
        let o = out - from   // o[j] = Ausgabe-Frame j
        // Stücke kopieren, stumme als Stille
        for (k, r) in pieces.enumerated() {
            let a = max(lo, starts[k]), b = min(hi, starts[k] + r.count)
            guard b > a else { continue }
            if muted[k] { (o + a).update(repeating: 0, count: b - a) } else { (o + a).update(from: src + r.lowerBound + (a - starts[k]), count: b - a) }
        }
        // Nähte: ausgehendes Stück läuft h Frames über sein Ende weiter, eingehendes beginnt h Frames vor seinem Anfang
        for (k, h) in halves.enumerated() where h > 0 {
            let join = starts[k + 1], len = Double(2 * h)
            let a = max(lo, join - h), b = min(hi, join + h)
            guard b > a else { continue }
            let outBase = pieces[k].lowerBound - starts[k], inBase = pieces[k + 1].lowerBound - join
            let outOn: Float = muted[k] ? 0 : 1, inOn: Float = muted[k + 1] ? 0 : 1
            for j in a..<b {
                let w = Float((Double(j - (join - h)) + 0.5) / len)
                o[j] = outOn * src[outBase + j] * (1 - w) + inOn * src[inBase + j] * w
            }
        }
        if loopSeam, let p = pieces.first, !muted[0] {
            let h = min(fade, frames / 2)
            if h > 0, p.lowerBound >= h {
                // Ende -> Audio vor dem Anfang: der letzte Frame geht in den ersten über wie in der Quelle
                for j in stride(from: max(lo, frames - h), to: hi, by: 1) {
                    let i = j - (frames - h), w = Float(Double(i + 1) / Double(h))   // letzter Frame = Frame vor dem Anfang
                    o[j] = src[p.lowerBound + j] * (1 - w) + src[p.lowerBound - h + i] * w
                }
                return
            }
            if h > 0, p.upperBound + h <= sourceFrames {
                // Anfang <- Audio nach dem Ende
                for j in stride(from: lo, to: min(hi, h), by: 1) {
                    let w = Float(Double(j) / Double(h))   // erster Frame = Frame nach dem Ende
                    o[j] = src[p.lowerBound + j] * w + src[p.upperBound + j] * (1 - w)
                }
                return
            }
        }
        // Ränder mitten in der Quelle (Loop ohne Platz für die Naht: beide Ränder)
        if let first = pieces.first, first.lowerBound > 0 || loopSeam {
            let f = min(fade, frames)
            for j in stride(from: lo, to: min(hi, f), by: 1) { o[j] *= Float((Double(j) + 0.5) / Double(f)) }
        }
        if let last = pieces.last, last.upperBound < sourceFrames || loopSeam {
            let f = min(fade, frames)
            for j in stride(from: max(lo, frames - f), to: hi, by: 1) { o[j] *= Float((Double(frames - j) - 0.5) / Double(f)) }
        }
    }

    /// Crossfade-Länge für 2 ms bei dieser Rate
    public static func fadeFrames(sampleRate: Double) -> Int { max(2, Int((sampleRate * 0.002).rounded())) }
}
