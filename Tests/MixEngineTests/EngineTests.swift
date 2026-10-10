import Foundation
import Testing
import MixDSP

/// Der C++-Kern offline: kein Audiogerät, Blöcke direkt über mdsp_render. Ein Deck mit 10 s Sinus (220 Hz, Pegel 0.5).
private final class Core {
    let e: OpaquePointer
    let fs = 44100.0
    let frames: Int
    let left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>
    var outL: [Float] = [], outR: [Float] = []

    init(seconds: Double = 10) {
        e = mdsp_create(fs)
        frames = Int(seconds * fs)
        left = .allocate(capacity: frames); right = .allocate(capacity: frames)
        for i in 0..<frames { let v = Float(sin(2 * .pi * 220 * Double(i) / fs)) * 0.5; left[i] = v; right[i] = v }
    }
    deinit { mdsp_destroy(e); left.deallocate(); right.deallocate() }

    @discardableResult
    func load(start: Double = 0) -> UInt32 { mdsp_set_track(e, 0, left, right, Int64(frames), fs, start) }
    func set(_ p: MDParam, _ v: Float) { mdsp_set_param(e, 0, p, v) }
    func fx(_ p: MDFXParam, _ v: Float) { mdsp_set_fx(e, 0, p, v) }
    var position: Double { mdsp_position(e, 0) }
    var playing: Bool { mdsp_playing(e, 0) }

    /// einen Block rendern, liefert den RMS des Kanalpaars 1/2
    @discardableResult
    func render(_ n: Int = 512) -> Float {
        outL = [Float](repeating: 0, count: n); outR = [Float](repeating: 0, count: n)
        var sum: Float = 0
        outL.withUnsafeMutableBufferPointer { l in
            outR.withUnsafeMutableBufferPointer { r in
                var chans: [UnsafeMutablePointer<Float>?] = [l.baseAddress, r.baseAddress]
                chans.withUnsafeMutableBufferPointer { mdsp_render(e, $0.baseAddress, 2, Int32(n)) }
                for i in 0..<n { sum += l[i] * l[i] }
            }
        }
        return (sum / Float(n)).squareRoot()
    }

    /// `seconds` lang rendern, liefert den mittleren RMS
    @discardableResult
    func render(seconds: Double) -> Float {
        let blocks = max(1, Int(seconds * fs / 512))
        var acc: Float = 0
        for _ in 0..<blocks { acc += render(512) }
        return acc / Float(blocks)
    }
}

@Test func playsAndReportsPosition() {
    let c = Core()
    c.load(); c.render()
    #expect(c.render(seconds: 0.5) == 0)          // steht: Stille
    #expect(c.position == 0)
    c.set(MD_PLAYING, 1)
    let rms = c.render(seconds: 1)
    #expect(abs(c.position - 1.0) < 0.03)
    #expect(rms > 0.2)                             // 0.5 Sinus ≈ 0.35 RMS × Master 0.85
    c.set(MD_PLAYING, 0)
    c.render(seconds: 0.2)
    let p = c.position
    #expect(c.render(seconds: 0.2) == 0 && c.position == p)
}

@Test func seekLandsOnTarget() {
    let c = Core()
    c.load(); c.render()
    c.set(MD_PLAYING, 1); c.render(seconds: 0.3)
    mdsp_seek(c.e, 0, 7.0)
    #expect(c.position == 7.0)                     // sofort sichtbar, auch vor dem nächsten Block
    c.render()
    #expect(abs(c.position - (7.0 + 512 / c.fs)) < 0.002)
}

@Test func loopWrapsInsideBounds() {
    let c = Core()
    c.load(start: 2.0); c.render()
    mdsp_set_loop(c.e, 0, true, 2.0, 2.5)
    c.set(MD_PLAYING, 1)
    for _ in 0..<200 {
        c.render()
        let p = c.position
        #expect(p >= 1.99 && p <= 2.51)
    }
    var s = 0.0, en = 0.0
    #expect(mdsp_loop(c.e, 0, &s, &en) && s == 2.0 && en == 2.5)
}

@Test func reverseRunsBackwards() {
    let c = Core()
    c.load(start: 5.0); c.render()
    c.set(MD_REVERSE, 1); c.set(MD_PLAYING, 1)
    c.render(seconds: 1)
    #expect(abs(c.position - 4.0) < 0.03)
}

@Test func tempoWithAndWithoutKeylock() {
    for keylock: Float in [0, 1] {
        let c = Core()
        c.load(); c.render()
        c.set(MD_RATE, 1.25); c.set(MD_KEYLOCK, keylock); c.set(MD_PLAYING, 1)
        let rms = c.render(seconds: 2)
        #expect(abs(c.position - 2.5) < (keylock == 1 ? 0.1 : 0.03), "keylock \(keylock)")
        #expect(rms > 0.15, "keylock \(keylock)")
    }
}

@Test func delayTailRingsOutThenStops() {
    let c = Core()
    c.load(); c.render()
    c.set(MD_FX1_ASSIGN, 1)
    c.fx(MDFX_DELAY_ON, 1); c.fx(MDFX_DELAY_AMOUNT, 1); c.fx(MDFX_DELAY_SECONDS, 0.25); c.fx(MDFX_DELAY_FEEDBACK, 0.5)
    c.set(MD_PLAYING, 1); c.render(seconds: 1)
    c.set(MD_PLAYING, 0)
    #expect(c.render(seconds: 0.3) > 0.01)         // Echo-Fahne nach dem Stopp
    c.render(seconds: 5)
    #expect(c.render(seconds: 0.5) < 1e-4)         // verklungen
}

@Test func masterHardLimit() {
    let c = Core()
    c.load(); c.render()
    c.set(MD_GAIN_DB, 24); c.set(MD_PLAYING, 1)
    c.render(seconds: 0.5)
    c.render(2048)
    #expect(c.outL.allSatisfy { abs($0) <= 1 } && c.outR.allSatisfy { abs($0) <= 1 })
    #expect(c.outL.contains { abs($0) > 0.99 })
}

@Test func clockFollowsBPM() {
    let c = Core()
    mdsp_clock_set_bpm(c.e, 120)
    mdsp_clock_set_beat(c.e, 0)
    c.render(seconds: 2)
    #expect(abs(mdsp_clock_beat(c.e) - 4.0) < 0.02)
}

@Test func trackHandoffIsConfirmedByAudioThread() {
    let c = Core()
    let g1 = c.load()
    #expect(!mdsp_track_consumed(c.e, 0, g1))
    c.render()
    #expect(mdsp_track_consumed(c.e, 0, g1))
    // zwei Übergaben vor dem nächsten Block: die letzte zählt, beide gelten danach als übernommen
    let g2 = c.load(start: 1), g3 = c.load(start: 2)
    #expect(!mdsp_track_consumed(c.e, 0, g2) && !mdsp_track_consumed(c.e, 0, g3))
    c.render()
    #expect(mdsp_track_consumed(c.e, 0, g2) && mdsp_track_consumed(c.e, 0, g3))
    #expect(c.position == 2.0)
}
