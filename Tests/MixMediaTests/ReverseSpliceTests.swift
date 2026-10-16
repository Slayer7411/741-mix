import Foundation
import Testing
import MixCore
@testable import MixMedia

// Rückwärts und Stille im Render-Pfad (AudioSplice): Reihenfolge der Samples, exakte Länge, Nähte

struct ReverseSpliceTests {
    /// Rampe 0, 1, 2, … – jeder Frame eindeutig
    private func ramp(_ n: Int) -> [Float] { (0..<n).map { Float($0) } }

    private func render(_ s: AudioSplice, _ src: [Float]) -> [Float] {
        var out = [Float](repeating: .nan, count: s.frames)
        src.withUnsafeBufferPointer { sp in
            out.withUnsafeMutableBufferPointer { op in
                s.render(sp.baseAddress!, into: op.baseAddress!, from: 0, count: s.frames)
            }
        }
        return out
    }

    @Test func reversedPieceReadsBackwards() {
        let src = ramp(4_000)
        let s = AudioSplice(pieces: [1_000..<2_000], sourceFrames: 4_000, fade: 0, reversed: [true])
        #expect(s.frames == 1_000)
        #expect(render(s, src) == (0..<1_000).map { Float(1_999 - $0) })
    }

    @Test func reversedPieceKeepsLengthWithFade() {
        let src = ramp(4_000)
        let s = AudioSplice(pieces: [1_000..<2_000], sourceFrames: 4_000, fade: 88, reversed: [true])
        let out = render(s, src)
        #expect(out.count == 1_000)
        // Ränder blenden über 88 Frames, die Mitte ist exakt rückwärts
        #expect(out[100..<900].enumerated().allSatisfy { $0.element == Float(1_999 - (100 + $0.offset)) })
    }

    @Test func reversedNextToForwardCrossfades() {
        let src = ramp(4_000)
        let s = AudioSplice(pieces: [0..<500, 1_000..<1_500], sourceFrames: 4_000, fade: 88, reversed: [false, true])
        #expect(s.frames == 1_000)
        let out = render(s, src)
        #expect(out[0..<400].enumerated().allSatisfy { $0.element == Float($0.offset) })
        // hinter der Naht (Ausgabe 500) liest das rückwärts Stück von hinten: Quelle 1499, 1498 …
        #expect(out[600..<800].enumerated().allSatisfy { $0.element == Float(1_999 - (600 + $0.offset)) })
        // Naht selbst: zwischen Quelle 500 (vorwärts) und 1499 (rückwärts) gemischt, nie außerhalb
        #expect(out[500] > 500 && out[500] < 1_499)
    }

    @Test func silentPieceIsZeroAndLengthExact() {
        let src = (0..<3_000).map { Float($0 + 1) }
        let s = AudioSplice(pieces: [0..<1_000, 0..<500, 1_000..<2_000], sourceFrames: 3_000, fade: 0,
                            muted: [false, true, false], silent: [false, true, false])
        #expect(s.frames == 2_500)
        let out = render(s, src)
        #expect(out[1_000..<1_500].allSatisfy { $0 == 0 })
        #expect(out[1_500] == 1_001)
        #expect(out[2_499] == 2_000)
    }

    @Test func editListSpliceCarriesSilenceAndReverse() {
        // 1 s bei 1000 Hz (1000 Frames): Stille nach 0,5 s (0,25 s), dann die zweite Hälfte rückwärts
        var e = EditList(duration: 1)
        e.insertSilence(at: 0.5, length: 0.25)
        e.reverse(TrackRange(0.75, 1.25))
        let s = AudioSplice(e, rate: 1_000, sourceFrames: 1_000, fade: 0)
        #expect(s.frames == 1_250)
        let out = render(s, ramp(1_000))
        #expect(out[0..<500] == (0..<500).map { Float($0) }[...])
        #expect(out[500..<750].allSatisfy { $0 == 0 })
        #expect(out[750..<1_250].enumerated().allSatisfy { $0.element == Float(1_749 - (750 + $0.offset)) })
    }

    @Test func reversedAnalysisFollowsSource() {
        // Blöcke: die Spitze der Ausgabe kommt aus dem gespiegelten Block der Quelle
        let s = AudioSplice(pieces: [0..<1_000], sourceFrames: 1_000, fade: 0, reversed: [true])
        #expect(s.reversed == [true] && s.silent == [false] && s.muted == [false])
        #expect(s.frames == 1_000)
    }
}
