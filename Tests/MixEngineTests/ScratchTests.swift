import Foundation
import Testing
import MixDSP

/// Wellenform greifen im Kern (mdsp_scratch): die Hand legt das Ziel fest, der Lesekopf läuft ihm nach; losgelassen läuft
/// er auf das Ziel aus. Ein laufendes Deck spielt danach mit dem alten Tempo weiter, ein stehendes bleibt stehen.
private final class ScratchDeck {
    let e: OpaquePointer
    let fs = 44100.0
    let frames = 44100 * 20
    let buf: UnsafeMutablePointer<Float>
    var out: [Float] = []

    init(start: Double, playing: Bool) {
        e = mdsp_create(fs)
        buf = .allocate(capacity: frames)
        for i in 0..<frames { buf[i] = sin(Float(i) * 0.05) * 0.5 }
        mdsp_set_param(e, 0, MD_VOLUME, 1)
        mdsp_set_param(e, 0, MD_RATE, 1)
        mdsp_set_param(e, 0, MD_OUT_CHANNEL, 0)
        mdsp_set_track(e, 0, buf, buf, Int64(frames), fs, start)
        mdsp_set_param(e, 0, MD_PLAYING, playing ? 1 : 0)
    }
    deinit { mdsp_destroy(e); buf.deallocate() }

    var position: Double { mdsp_position(e, 0) }

    /// einen Block rechnen; Ausgabe des ersten Kanals in `out`
    func render(_ n: Int = 512) {
        let ptrs = (0..<4).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: n) }
        defer { ptrs.forEach { $0.deallocate() } }
        var chans: [UnsafeMutablePointer<Float>?] = ptrs
        chans.withUnsafeMutableBufferPointer { mdsp_render(e, $0.baseAddress, 4, Int32(n)) }
        out = Array(UnsafeBufferPointer(start: ptrs[0], count: n))
    }

    func run(blocks: Int) { for _ in 0..<blocks { render() } }
}

@Test func scratchFollowsTheHandAndSettlesOnTheTarget() {
    let k = ScratchDeck(start: 10, playing: true)
    k.run(blocks: 10)
    // die Hand zieht 0,5 s zurück, dann hält sie
    var target = 10.0
    for _ in 0..<40 {
        target -= 0.5 / 40
        mdsp_scratch(k.e, 0, target, true)
        k.render()
    }
    k.run(blocks: 20)
    #expect(abs(k.position - 9.5) < 1e-4)
}

@Test func scratchIsAudibleWhileStoppedAndStopsAtTheReleasePoint() {
    let k = ScratchDeck(start: 10, playing: false)
    k.run(blocks: 4)
    mdsp_scratch(k.e, 0, 9.5, true)
    k.run(blocks: 60)
    #expect(abs(k.position - 9.5) < 1e-4)
    #expect(k.out.contains { abs($0) > 0.01 })   // der Teller klingt, obwohl das Deck steht
    mdsp_scratch(k.e, 0, 9.2, false)              // losgelassen: läuft aufs Ziel aus …
    k.run(blocks: 60)
    #expect(abs(k.position - 9.2) < 1e-4)
    k.run(blocks: 20)                             // … und bleibt dort
    #expect(abs(k.position - 9.2) < 1e-4)
    #expect(mdsp_playing(k.e, 0) == false)
}

@Test func scratchReleaseKeepsPlayingAtThePreviousRate() {
    let k = ScratchDeck(start: 10, playing: true)
    k.run(blocks: 4)
    mdsp_scratch(k.e, 0, 9.0, true)
    k.run(blocks: 60)
    mdsp_scratch(k.e, 0, 9.0, false)
    k.run(blocks: 60)
    // nach dem Loslassen wieder das alte Tempo (1×) ab dem Ziel; der Block des Loslassens rechnet noch auf dem Ziel
    #expect(abs(k.position - (9.0 + 59 * 512 / 44100)) < 1e-4)
    #expect(mdsp_playing(k.e, 0))
}

@Test func scratchStopsAtTheEndOfTheTrack() {
    let k = ScratchDeck(start: 5, playing: false)
    k.run(blocks: 2)
    mdsp_scratch(k.e, 0, 1000, true)              // weit hinter dem Ende: auf das Track-Ende begrenzt
    k.run(blocks: 600)                            // höchstens 4× Tempo: 15 s brauchen rund 320 Blöcke
    #expect(abs(k.position - 20) < 1e-3)
}
