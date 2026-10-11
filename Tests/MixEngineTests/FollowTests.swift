import Foundation
import Testing
import MixDSP

/// Instant Double im Kern: mdsp_follow übernimmt die hörbare Position des Quell-Decks am Blockanfang.
/// Rampe als Signal (jedes Sample ein eigener Wert): gleiche Ausgabe = gleiche Position, sample-genau.
private final class TwoDecks {
    let e: OpaquePointer
    let fs = 44100.0
    let frames = 44100 * 4
    let buf: UnsafeMutablePointer<Float>
    var out = [[Float]](repeating: [], count: 4)

    init() {
        e = mdsp_create(fs)
        buf = .allocate(capacity: frames)
        for i in 0..<frames { buf[i] = Float(i) / Float(frames) }
        for d in 0..<2 {
            mdsp_set_param(e, Int32(d), MD_VOLUME, 1)
            mdsp_set_param(e, Int32(d), MD_RATE, 1)
            mdsp_set_param(e, Int32(d), MD_OUT_CHANNEL, Float(d * 2))
        }
    }
    deinit { mdsp_destroy(e); buf.deallocate() }

    func load(_ d: Int, at s: Double) { mdsp_set_track(e, Int32(d), buf, buf, Int64(frames), fs, s) }

    func render(_ n: Int = 512) {
        out = (0..<4).map { _ in [Float](repeating: 0, count: n) }
        let ptrs = (0..<4).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: n) }
        defer { ptrs.forEach { $0.deallocate() } }
        var chans: [UnsafeMutablePointer<Float>?] = ptrs
        chans.withUnsafeMutableBufferPointer { mdsp_render(e, $0.baseAddress, 4, Int32(n)) }
        for c in 0..<4 { out[c] = Array(UnsafeBufferPointer(start: ptrs[c], count: n)) }
    }
}

/// Quelle `src` spielt, Ziel lädt dieselbe Datei woanders und folgt: danach dieselben Samples (Pegelrampe abgewartet)
private func followMatches(src: Int, dst: Int, block: Int) -> Bool {
    let k = TwoDecks()
    k.load(src, at: 1.0)
    mdsp_set_param(k.e, Int32(src), MD_PLAYING, 1)
    for _ in 0..<7 { k.render(block) }
    k.load(dst, at: 0.2)
    mdsp_follow(k.e, Int32(dst), Int32(src))
    mdsp_set_param(k.e, Int32(dst), MD_PLAYING, 1)
    var worst: Float = 0
    let settle = 8192 / block   // Lautstärke des Ziels glättet sich ein (~0,2 s)
    for i in 0..<(settle + 10) {
        k.render(block)
        guard i >= settle else { continue }
        let a = k.out[src * 2], b = k.out[dst * 2]
        for j in 0..<block where a[j] > 0 { worst = max(worst, abs(b[j] / a[j] - 1)) }
    }
    return worst < 1e-3 && abs(mdsp_position(k.e, Int32(src)) - mdsp_position(k.e, Int32(dst))) < 1e-9
}

@Test func followIsSampleExactBothDeckOrders() {
    #expect(followMatches(src: 1, dst: 0, block: 512))   // Quelle wird nach dem Ziel gerechnet
    #expect(followMatches(src: 0, dst: 1, block: 512))   // Quelle wird vor dem Ziel gerechnet
    #expect(followMatches(src: 0, dst: 1, block: 64))
}

@Test func followReportsSourcePositionBeforeNextBlock() {
    let k = TwoDecks()
    k.load(0, at: 1.5)
    k.render()
    k.load(1, at: 0)
    mdsp_follow(k.e, 1, 0)
    #expect(abs(mdsp_position(k.e, 1) - 1.5) < 1e-9)
    mdsp_follow(k.e, 1, 1)   // auf sich selbst: nichts
    mdsp_follow(k.e, 1, 7)   // außerhalb: nichts
    k.render()
    #expect(abs(mdsp_position(k.e, 1) - 1.5) < 1e-9)
}
