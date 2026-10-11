import Foundation
import Testing
import MixDSP
import MixEngine

/// Vorhören im Kern offline (kein Gerät): eigenes Paar auf 12 Kanälen, Decks auf 1/2 … 7/8 unberührt, Schnitt, Sprung,
/// Wechsel ohne Knacken, stumm = nur Pegel, Paar nicht am Gerät = nichts.
private final class Rig {
    let e: OpaquePointer
    let fs = 44100.0
    let channels: Int
    var buffers: [UnsafeMutablePointer<Float>] = []
    private var owned: [UnsafeMutablePointer<Float>] = []

    init(channels: Int = 12) {
        self.channels = channels
        e = mdsp_create(fs)
        mdsp_set_master(e, 1)
    }
    deinit { mdsp_destroy(e); owned.forEach { $0.deallocate() } }

    /// Sinus `hz` (L = R), `seconds` lang
    func tone(_ hz: Double, seconds: Double, amp: Float = 0.5) -> (UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>, Int) {
        let n = Int(seconds * fs)
        let l = UnsafeMutablePointer<Float>.allocate(capacity: n), r = UnsafeMutablePointer<Float>.allocate(capacity: n)
        for i in 0..<n { let v = Float(sin(2 * .pi * hz * Double(i) / fs)) * amp; l[i] = v; r[i] = v }
        owned += [l, r]
        return (l, r, n)
    }

    func deck(_ d: Int, pair: Int) {
        let t = tone(220 + Double(d) * 50, seconds: 10)
        mdsp_set_track(e, Int32(d), t.0, t.1, Int64(t.2), fs, 0)
        mdsp_set_param(e, Int32(d), MD_OUT_CHANNEL, Float(pair))
        mdsp_set_param(e, Int32(d), MD_PLAYING, 1)
    }

    @discardableResult
    func preview(seconds: Double = 10, hz: Double = 1000, start: Double = 0) -> UInt32 {
        let t = tone(hz, seconds: seconds)
        let g = mdsp_preview_set_track(e, t.0, t.1, Int64(t.2), fs, start)
        mdsp_preview_play(e, true)
        return g
    }

    /// Block rendern, alle Kanäle zurück
    func render(_ n: Int = 512) -> [[Float]] {
        let ptrs: [UnsafeMutablePointer<Float>?] = (0..<channels).map { _ in .allocate(capacity: n) }
        defer { ptrs.forEach { $0?.deallocate() } }
        var p = ptrs
        p.withUnsafeMutableBufferPointer { mdsp_render(e, $0.baseAddress, Int32(channels), Int32(n)) }
        return ptrs.map { Array(UnsafeBufferPointer(start: $0, count: n)) }
    }

    /// größter Betrag je Kanal über `blocks` Blöcke
    func peaks(_ blocks: Int) -> [Float] {
        var m = [Float](repeating: 0, count: channels)
        for _ in 0..<blocks {
            for (c, b) in render().enumerated() { m[c] = max(m[c], b.map(abs).max() ?? 0) }
        }
        return m
    }
}

@Test func previewOnOwnPairOnly() {
    let r = Rig()
    for (d, p) in [0, 4, 2, 6].enumerated() { r.deck(d, pair: p) }
    mdsp_preview_set_output(r.e, 8, false)
    r.preview()
    let m = r.peaks(20)
    for c in 0..<8 { #expect(m[c] > 0.3) }          // Decks laufen weiter
    #expect(m[8] > 0.3 && m[9] > 0.3)                // Vorhören auf 9/10
    #expect(m[10] == 0 && m[11] == 0)
    #expect(mdsp_preview_routed(r.e) == 8)
}

@Test func previewLeavesDeckPairsBitExact() {
    let a = Rig(), b = Rig()
    for r in [a, b] { for (d, p) in [0, 4, 2, 6].enumerated() { r.deck(d, pair: p) } }
    mdsp_preview_set_output(b.e, 8, false)
    b.preview()
    for _ in 0..<20 {
        let x = a.render(), y = b.render()
        for c in 0..<8 { #expect(x[c] == y[c]) }
        #expect(y[8].contains { $0 != 0 })
    }
}

@Test func previewNotOnDeviceIsSilent() {
    let r = Rig(channels: 2)
    mdsp_preview_set_output(r.e, 8, false)           // Paar 9/10 gibt es nicht: nicht auf 1/2 ausweichen
    r.preview()
    #expect(r.peaks(10) == [0, 0])
    #expect(mdsp_preview_routed(r.e) == -1)
    mdsp_preview_set_output(r.e, -1, false)
    #expect(r.peaks(5) == [0, 0])
}

@Test func previewMutedMeasuresOnly() {
    let r = Rig(channels: 2)
    mdsp_preview_set_output(r.e, 0, true)
    r.preview()
    #expect(r.peaks(10) == [0, 0])
    var rms: Float = 0, peak: Float = 0
    mdsp_preview_levels(r.e, &rms, &peak)
    #expect(peak > 0.4 && rms > 0.2)
    #expect(mdsp_preview_routed(r.e) == 0)
}

@Test func previewIgnoresMasterVolume() {
    let r = Rig(channels: 4)
    mdsp_set_master(r.e, 0)
    r.deck(0, pair: 0)
    mdsp_preview_set_output(r.e, 2, false)
    mdsp_preview_set_volume(r.e, 0.5)
    r.preview()
    _ = r.peaks(20)                                  // Lautstärke eingeschwungen
    let m = r.peaks(10)
    #expect(m[0] < 1e-6 && m[1] < 1e-6)              // Master 0
    #expect(abs(m[2] - 0.25) < 0.01)                 // 0,5 × 0,5
}

@Test func previewStopsAtCutEnd() {
    let r = Rig(channels: 2)
    mdsp_preview_set_output(r.e, 0, false)
    mdsp_preview_set_trim(r.e, 2, 3)
    r.preview(start: 0.5)                            // vor dem Schnitt -> am Anfang
    _ = r.render()
    #expect(abs(mdsp_preview_position(r.e) - 2) < 0.02)
    for _ in 0..<Int(1.2 * r.fs / 512) { _ = r.render() }
    #expect(!mdsp_preview_playing(r.e))
    #expect(abs(mdsp_preview_position(r.e) - 3) < 0.001)
    #expect(r.peaks(4) == [0, 0])
}

@Test func previewSeekIntoCutAndPause() {
    let r = Rig(channels: 2)
    mdsp_preview_set_output(r.e, 0, false)
    mdsp_preview_set_trim(r.e, 2, 6)
    r.preview()
    _ = r.render()
    mdsp_preview_seek(r.e, 9)                        // hinter dem Ende -> Ende (Kern), Modell landet 1 s davor
    #expect(abs(mdsp_preview_position(r.e) - 6) < 1e-9)
    mdsp_preview_seek(r.e, 4)
    for _ in 0..<4 { _ = r.render() }
    #expect(abs(mdsp_preview_position(r.e) - (4 + 3.0 * 512 / r.fs)) < 0.02)
    mdsp_preview_play(r.e, false)
    _ = r.render()
    let p = mdsp_preview_position(r.e)
    #expect(r.peaks(3) == [0, 0])
    #expect(mdsp_preview_position(r.e) == p)
}

/// Sprung und Track-Wechsel blenden aus/ein: kein Sprung im Signal größer als die Sinus-Steigung
@Test func previewSwitchWithoutClick() {
    let r = Rig(channels: 2)
    mdsp_preview_set_output(r.e, 0, false)
    let g1 = r.preview(hz: 200)
    for _ in 0..<4 { _ = r.render() }
    let maxStep = Float(0.5 * 2 * Double.pi * 1000 / r.fs) * 1.1   // steilster Sinus (1 kHz, 0,5)
    var worst: Float = 0, last: Float = r.render()[0].last ?? 0
    mdsp_preview_seek(r.e, 7.31)
    for _ in 0..<6 { for v in r.render()[0] { worst = max(worst, abs(v - last)); last = v } }
    let g2 = r.preview(hz: 1000, start: 3.17)
    #expect(!mdsp_preview_track_consumed(r.e, g2))
    for _ in 0..<6 { for v in r.render()[0] { worst = max(worst, abs(v - last)); last = v } }
    #expect(mdsp_preview_track_consumed(r.e, g2) && mdsp_preview_track_consumed(r.e, g1))
    #expect(worst < maxStep)
    #expect(mdsp_preview_playing(r.e))
}

@Test func previewDetachAndNaN() {
    let r = Rig(channels: 2)
    mdsp_preview_set_output(r.e, 0, false)
    let t = r.tone(440, seconds: 2)
    t.0[44100] = .nan; t.1[44100] = .infinity
    mdsp_preview_set_track(r.e, t.0, t.1, Int64(t.2), r.fs, 0.9)
    mdsp_preview_play(r.e, true)
    for _ in 0..<20 { #expect(r.render().allSatisfy { $0.allSatisfy(\.isFinite) }) }
    let g = mdsp_preview_set_track(r.e, nil, nil, 0, r.fs, 0)
    _ = r.render(); _ = r.render()
    #expect(mdsp_preview_track_consumed(r.e, g))
    #expect(!mdsp_preview_playing(r.e))
    #expect(r.peaks(2) == [0, 0])
}

@Test func previewAutoPair() {
    // Extern: erstes freies Paar nach den Decks; keins frei -> keins (nie auf ein Deck-Paar)
    #expect(PreviewPlayer.autoPair(external: true, deckPairs: [0, 4, 2, 6], mainPair: 0, channels: 12) == 8)
    #expect(PreviewPlayer.autoPair(external: true, deckPairs: [0, 2, 4, 6], mainPair: 0, channels: 10) == 8)
    #expect(PreviewPlayer.autoPair(external: true, deckPairs: [4, 6, 8, 10], mainPair: 0, channels: 12) == 0)
    #expect(PreviewPlayer.autoPair(external: true, deckPairs: [0, 2, 4, 6], mainPair: 0, channels: 8) == nil)
    #expect(PreviewPlayer.autoPair(external: true, deckPairs: [0, 0, 0, 0], mainPair: 0, channels: 2) == nil)
    #expect(PreviewPlayer.autoPair(external: false, deckPairs: [0, 0, 0, 0], mainPair: 2, channels: 4) == 2)
}
