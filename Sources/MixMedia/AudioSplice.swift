import Foundation

/// Geschnittener Track aus Stücken der Quelle (Frame-Bereiche, hintereinander). An jeder Naht ein linearer Crossfade
/// über `fade` Frames, mittig auf der Naht – die Länge bleibt die Summe der Stücke (Grid-Rechnung bleibt genau).
/// Beginnt bzw. endet die Ausgabe mitten in der Quelle, blendet sie dort über `fade` Frames ein bzw. aus.
/// Stumme Stücke sind Stille gleicher Länge (Nähte blenden in sie hinein). `loopSeam`: ein Stück, Ende läuft nahtlos
/// in den Anfang (Crossfade mit dem Audio vor dem Anfang bzw. nach dem Ende statt Blenden an den Rändern).
/// `reversed`: Stück rückwärts (Ausgabe von `upperBound - 1` nach `lowerBound`), Nähte blenden wie sonst.
/// `silent`: Stille ohne Quelle, Länge = Größe des Bereichs, Lage wird nicht gelesen
public struct AudioSplice: Equatable, Sendable {
    public let pieces: [Range<Int>]
    /// je Stück: stumm (Stille gleicher Länge)
    public let muted: [Bool]
    /// je Stück: rückwärts gelesen
    public let reversed: [Bool]
    /// je Stück: Stille ohne Quelle (immer auch stumm)
    public let silent: [Bool]
    public let loopSeam: Bool
    public let sourceFrames: Int
    public let fade: Int
    /// Länge der Ausgabe
    public let frames: Int
    /// Ausgabe-Anfang je Stück
    let starts: [Int]
    /// halbe Crossfade-Länge je Naht (0 = harte Naht oder Stücke liegen in der Quelle direkt hintereinander)
    let halves: [Int]

    public init(pieces: [Range<Int>], sourceFrames: Int, fade: Int, muted: [Bool] = [], loopSeam: Bool = false,
                reversed: [Bool] = [], silent: [Bool] = []) {
        func flag(_ a: [Bool], _ k: Int) -> Bool { a.indices.contains(k) && a[k] }
        let all = pieces.indices.map { k in flag(silent, k) ? pieces[k] : pieces[k].clamped(to: 0..<max(0, sourceFrames)) }
        let keep = all.indices.filter { !all[$0].isEmpty }
        let p = keep.map { all[$0] }
        let sl = keep.map { flag(silent, $0) }
        let m = keep.map { flag(muted, $0) || flag(silent, $0) }
        let rv = keep.map { flag(reversed, $0) && !flag(silent, $0) }
        self.pieces = p
        self.muted = m
        self.reversed = rv
        self.silent = sl
        self.loopSeam = loopSeam && p.count == 1 && !rv[0] && !sl[0]
        self.sourceFrames = sourceFrames
        self.fade = max(0, fade)
        var s: [Int] = [], at = 0
        for r in p { s.append(at); at += r.count }
        starts = s
        frames = at
        let h = max(0, fade) / 2
        halves = p.indices.dropLast().map { k in
            let a = p[k], b = p[k + 1]
            let joined = rv[k] ? a.lowerBound == b.upperBound : a.upperBound == b.lowerBound
            if !sl[k], !sl[k + 1], m[k] == m[k + 1], rv[k] == rv[k + 1], joined { return 0 }
            // wie weit die Quelle über das Stück hinaus reicht (Stille liest nichts)
            let outLim = sl[k] ? Int.max : rv[k] ? a.lowerBound : sourceFrames - a.upperBound
            let inLim = sl[k + 1] ? Int.max : rv[k + 1] ? sourceFrames - b.upperBound : b.lowerBound
            return max(0, min(h, a.count, b.count, outLim, inLim))
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
        // Stücke kopieren, stumme als Stille, rückwärtige von hinten nach vorn
        for (k, r) in pieces.enumerated() {
            let a = max(lo, starts[k]), b = min(hi, starts[k] + r.count)
            guard b > a else { continue }
            if muted[k] {
                (o + a).update(repeating: 0, count: b - a)
            } else if reversed[k] {
                for j in a..<b { o[j] = src[r.upperBound - 1 - (j - starts[k])] }
            } else {
                (o + a).update(from: src + r.lowerBound + (a - starts[k]), count: b - a)
            }
        }
        // Sample von Stück k an Position i (ab seinem Anfang in der Ausgabe; über das Ende hinaus = Quelle danach)
        func sample(_ k: Int, _ i: Int) -> Float {
            reversed[k] ? src[pieces[k].upperBound - 1 - i] : src[pieces[k].lowerBound + i]
        }
        // Nähte: ausgehendes Stück läuft h Frames über sein Ende weiter, eingehendes beginnt h Frames vor seinem Anfang
        for (k, h) in halves.enumerated() where h > 0 {
            let join = starts[k + 1], len = Double(2 * h)
            let a = max(lo, join - h), b = min(hi, join + h)
            guard b > a else { continue }
            let outOn: Float = muted[k] ? 0 : 1, inOn: Float = muted[k + 1] ? 0 : 1
            for j in a..<b {
                let w = Float((Double(j - (join - h)) + 0.5) / len)
                let x = outOn > 0 ? sample(k, j - starts[k]) : 0
                let y = inOn > 0 ? sample(k + 1, j - join) : 0
                o[j] = outOn * x * (1 - w) + inOn * y * w
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
        // Ränder mitten in der Quelle (Loop ohne Platz für die Naht: beide Ränder); rückwärts zählt die Quelle davor
        let edgeIn = pieces.first.map { p in !silent[0] && (reversed[0] ? p.upperBound < sourceFrames : p.lowerBound > 0) } ?? false
        if edgeIn || loopSeam {
            let f = min(fade, frames)
            for j in stride(from: lo, to: min(hi, f), by: 1) { o[j] *= Float((Double(j) + 0.5) / Double(f)) }
        }
        let last = pieces.count - 1
        let edgeOut = pieces.last.map { p in !silent[last] && (reversed[last] ? p.lowerBound > 0 : p.upperBound < sourceFrames) } ?? false
        if edgeOut || loopSeam {
            let f = min(fade, frames)
            for j in stride(from: max(lo, frames - f), to: hi, by: 1) { o[j] *= Float((Double(frames - j) - 0.5) / Double(f)) }
        }
    }

    /// Crossfade-Länge für 2 ms bei dieser Rate
    public static func fadeFrames(sampleRate: Double) -> Int { max(2, Int((sampleRate * 0.002).rounded())) }
}
