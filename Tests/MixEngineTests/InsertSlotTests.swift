import Foundation
import Testing
import MixDSP
@testable import MixEngine

// Insert-Slots im Kern: Reihenfolge = Signalfluss, Umordnen im Betrieb ohne Knacken und ohne Speicheranforderung,
// aus = durchgereicht mit Ausklang, herausgenommen = klingt hinter den Slots aus.

private let fs = 48000.0
private let block = 512

private final class Rig {
    let e: OpaquePointer
    let l: UnsafeMutablePointer<Float>, r: UnsafeMutablePointer<Float>
    let frames: Int
    var bufs: [UnsafeMutablePointer<Float>?] = [.allocate(capacity: block), .allocate(capacity: block)]

    init(seconds: Double = 12, decks: Int = 1, make: (Int) -> Float) {
        e = mdsp_create(fs)
        frames = Int(seconds * fs)
        l = .allocate(capacity: frames); r = .allocate(capacity: frames)
        for i in 0..<frames { let v = make(i); l[i] = v; r[i] = v }
        for d in 0..<decks {
            mdsp_set_track(e, Int32(d), l, r, Int64(frames), fs, 0)
            mdsp_set_param(e, Int32(d), MD_KEYLOCK, 0)
            mdsp_set_param(e, Int32(d), MD_PLAYING, 1)
        }
        mdsp_clock_set_bpm(e, 125)
    }
    deinit { mdsp_destroy(e); l.deallocate(); r.deallocate(); bufs.forEach { $0?.deallocate() } }

    func fx(_ p: MDFXParam, _ v: Float, unit: Int32 = 0) { mdsp_set_fx(e, unit, p, v) }
    /// einen Block, Ausgang links
    @discardableResult
    func render() -> [Float] {
        bufs.withUnsafeMutableBufferPointer { mdsp_render(e, $0.baseAddress, 2, Int32(block)) }
        return Array(UnsafeBufferPointer(start: bufs[0], count: block))
    }
}

private func rms(_ a: [Float]) -> Float { (a.reduce(0) { $0 + $1 * $1 } / Float(max(1, a.count))).squareRoot() }

/// Delay, Filter, Hall in wechselnder Reihenfolge, im Betrieb alle 10 Blöcke umgeordnet: an der Umschaltstelle kein Sprung
/// (größer als die Schritte, die das neue Signal danach selbst macht), keine Speicheranforderung im Render-Pfad
@Test func reorderWhilePlayingIsClickFreeAndAllocationFree() {
    let rig = Rig { i in Float(sin(2 * .pi * 220 * Double(i) / fs)) * 0.4 }
    mdsp_set_param(rig.e, 0, MD_FX1_ASSIGN, 1)
    let orders: [[MDFXKind]] = [[MDFX_KIND_DELAY, MDFX_KIND_FILTER, MDFX_KIND_REVERB], [MDFX_KIND_REVERB, MDFX_KIND_DELAY, MDFX_KIND_FILTER],
                                [MDFX_KIND_FILTER, MDFX_KIND_REVERB, MDFX_KIND_DELAY], [MDFX_KIND_DELAY, MDFX_KIND_REVERB, MDFX_KIND_FILTER],
                                [MDFX_KIND_DELAY, MDFX_KIND_REVERB]]   // zuletzt Filter herausgenommen
    setRack(rig.e, 0, orders[0])
    rig.fx(MDFX_DRYWET, 1)
    rig.fx(MDFX_DELAY_ON, 1); rig.fx(MDFX_DELAY_AMOUNT, 0.5); rig.fx(MDFX_DELAY_SECONDS, 0.18); rig.fx(MDFX_DELAY_FEEDBACK, 0.5)
    rig.fx(MDFX_FILTER_ON, 1); rig.fx(MDFX_FILTER_AMOUNT, 0.35); rig.fx(MDFX_FILTER_RES, 0.4)
    rig.fx(MDFX_REVERB_ON, 1); rig.fx(MDFX_REVERB_AMOUNT, 0.5); rig.fx(MDFX_REVERB_SIZE, 0.5); rig.fx(MDFX_REVERB_LP, 1)
    for _ in 0..<200 { rig.render() }
    var prev: Float = rig.render().last ?? 0
    var worstRatio: Float = 0, worstJump: Float = 0, allocs: Int64 = 0, switches = 0
    for n in 0..<150 {
        let switched = n % 10 == 0
        if switched { setRack(rig.e, 0, orders[(n / 10) % orders.count]); switches += 1 }   // Steuer-Thread-Seite (hier derselbe Thread)
        mdsp_alloc_probe_begin()
        rig.bufs.withUnsafeMutableBufferPointer { mdsp_render(rig.e, $0.baseAddress, 2, Int32(block)) }
        allocs += mdsp_alloc_probe_end()
        let b = Array(UnsafeBufferPointer(start: rig.bufs[0], count: block))
        if switched {
            let jump = abs(b[0] - prev)
            var local: Float = 1e-6
            for i in 1..<64 { local = max(local, abs(b[i] - b[i - 1])) }
            worstJump = max(worstJump, jump); worstRatio = max(worstRatio, jump / local)
        }
        prev = b[block - 1]
    }
    print(String(format: "[slots] umordnen (%d×): größter Sprung an der Umschaltstelle %.5f (%.2f × Schritte danach) · Anforderungen im Render %lld",
                 switches, worstJump, worstRatio, allocs))
    #expect(allocs == 0)
    #expect(worstRatio < 1.5)
}

/// Slot aus: trocken durch, der Ausklang läuft weiter; herausgenommen: klingt hinter den Slots aus
@Test func bypassAndRemovalKeepTheTail() {
    let rig = Rig { i in i < Int(0.5 * fs) ? Float(sin(2 * .pi * 330 * Double(i) / fs)) * 0.4 : 0 }
    mdsp_set_param(rig.e, 0, MD_FX1_ASSIGN, 1)
    setRack(rig.e, 0, [MDFX_KIND_DELAY, MDFX_KIND_REVERB])
    rig.fx(MDFX_DRYWET, 1)
    rig.fx(MDFX_DELAY_ON, 1); rig.fx(MDFX_DELAY_AMOUNT, 1); rig.fx(MDFX_DELAY_SECONDS, 0.25); rig.fx(MDFX_DELAY_FEEDBACK, 0.6)
    for _ in 0..<Int(0.5 * fs) / block { rig.render() }
    // Signal ist zu Ende, Delay aus: Echo klingt weiter
    rig.fx(MDFX_DELAY_ON, 0)
    var tail: [Float] = []
    for _ in 0..<Int(0.6 * fs) / block { tail += rig.render() }
    #expect(rms(tail) > 0.01)
    // Delay herausnehmen (nur noch Hall): Echo klingt weiter, bis es verklungen ist
    setRack(rig.e, 0, [MDFX_KIND_REVERB])
    var after: [Float] = []
    for _ in 0..<Int(0.3 * fs) / block { after += rig.render() }
    #expect(rms(after) > 0.003)
    for _ in 0..<Int(8 * fs) / block { rig.render() }
    #expect(rms(rig.render()) < 1e-4)
    print(String(format: "[slots] Ausklang: aus %.4f · herausgenommen %.4f", rms(tail), rms(after)))
}

/// leere Unit = durchgereicht (bitgleich trocken), ein Effekt ohne Slot rechnet nicht, auch wenn er „an“ ist
@Test func emptyRackPassesThrough() {
    let make = { (i: Int) in Float(sin(2 * .pi * 110 * Double(i) / fs)) * 0.3 }
    let dry = Rig(seconds: 2, make: make), wet = Rig(seconds: 2, make: make)
    mdsp_set_param(wet.e, 0, MD_FX1_ASSIGN, 1)
    setRack(wet.e, 0, [])
    wet.fx(MDFX_DELAY_ON, 1); wet.fx(MDFX_DELAY_AMOUNT, 1); wet.fx(MDFX_REVERB_ON, 1)
    for _ in 0..<60 { #expect(dry.render() == wet.render()) }
}

/// Budget: 4 Decks, 4 Units mit je 6 eingebauten Effekten in Slots (Hall, Delay, Flanger, Phaser, Gater, Roll), alle an
@Test func sixSlotsFitTheBudget() {
    let rig = Rig(seconds: 20, decks: 4) { i in Float(sin(2 * .pi * 220 * Double(i) / fs)) * 0.3 }
    for u in 0..<4 {
        for d in 0..<4 { mdsp_set_param(rig.e, Int32(d), MDParam(rawValue: MD_FX1_ASSIGN.rawValue + UInt32(u)), 1) }
        setRack(rig.e, Int32(u), [MDFX_KIND_REVERB, MDFX_KIND_DELAY, MDFX_KIND_FLANGER, MDFX_KIND_PHASER, MDFX_KIND_GATER, MDFX_KIND_ROLL])
        for p in [MDFX_REVERB_ON, MDFX_DELAY_ON, MDFX_FLANGER_ON, MDFX_PHASER_ON, MDFX_GATER_ON, MDFX_ROLL_ON] { rig.fx(p, 1, unit: Int32(u)) }
        rig.fx(MDFX_DELAY_AMOUNT, 0.5, unit: Int32(u)); rig.fx(MDFX_REVERB_AMOUNT, 0.5, unit: Int32(u)); rig.fx(MDFX_PHASER_STAGES, 8, unit: Int32(u))
    }
    for _ in 0..<100 { rig.render() }
    var times: [Double] = []
    for _ in 0..<600 {
        let t = DispatchTime.now().uptimeNanoseconds
        rig.render()
        times.append(Double(DispatchTime.now().uptimeNanoseconds - t) / 1000)
    }
    times.sort()
    let mean = times.reduce(0, +) / Double(times.count), p99 = times[times.count * 99 / 100], budget = Double(block) / fs * 1e6
    print(String(format: "[slots] 4 Decks × 4 Units × 6 eingebaute Slots, Block %d: Mittel %.0f µs · p99 %.0f µs · Budget %.0f µs (%.0f %%)",
                 block, mean, p99, budget, mean / budget * 100))
    #expect(mean < budget * 0.5)
}
