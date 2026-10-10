import Foundation
import Testing
import MixDSP

/// Echtzeit-Regeln des Kerns offline geprüft: keine NaN/Inf am Ausgang, keine Denormals, stabile Filter bei
/// niedrigen Raten, Randfälle der Render-Schnittstelle. MIX741_BENCH=1: zusätzlich CPU-Messung je Block.
private final class Engine {
    let e: OpaquePointer
    let fs: Double
    var tracks: [(UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>, Int)] = []

    init(fs: Double = 44100) {
        self.fs = fs
        e = mdsp_create(fs)
    }
    deinit {
        mdsp_destroy(e)
        for t in tracks { t.0.deallocate(); t.1.deallocate() }
    }

    /// Track aus `make(i, sekunde)` laden (Engine-Rate)
    func load(deck: Int, seconds: Double, _ make: (Int, Double) -> Float) {
        let n = Int(seconds * fs)
        let l = UnsafeMutablePointer<Float>.allocate(capacity: n), r = UnsafeMutablePointer<Float>.allocate(capacity: n)
        for i in 0..<n { let v = make(i, Double(i) / fs); l[i] = v; r[i] = v }
        tracks.append((l, r, n))
        mdsp_set_track(e, Int32(deck), l, r, Int64(n), fs, 0)
    }

    /// musikähnlich: Kick, Bass, Akkord, Rauschen
    func loadMusic(deck: Int, seconds: Double = 60) {
        var seed: UInt32 = 0x2545F491 &+ UInt32(deck)
        load(deck: deck, seconds: seconds) { _, t in
            seed = seed &* 1664525 &+ 1013904223
            let noise = Float(Int32(bitPattern: seed)) / Float(Int32.max)
            let beat = t.truncatingRemainder(dividingBy: 0.4688)
            let kick = Float(sin(2 * .pi * 55 * beat) * exp(-beat * 18))
            let chord = Float(sin(2 * .pi * 220 * t) + sin(2 * .pi * 277.2 * t) + sin(2 * .pi * 329.6 * t)) / 3
            return 0.5 * kick + 0.15 * chord + 0.05 * noise
        }
    }

    func set(_ d: Int, _ p: MDParam, _ v: Float) { mdsp_set_param(e, Int32(d), p, v) }

    /// Block rendern, Ausgang aller Kanäle zurück
    func render(_ n: Int, channels: Int = 2) -> [[Float]] {
        var ptrs: [UnsafeMutablePointer<Float>?] = (0..<channels).map { _ in .allocate(capacity: max(1, n)) }
        defer { ptrs.forEach { $0?.deallocate() } }
        ptrs.withUnsafeMutableBufferPointer { mdsp_render(e, $0.baseAddress, Int32(channels), Int32(n)) }
        return ptrs.map { Array(UnsafeBufferPointer(start: $0, count: n)) }
    }

    /// Ausgang in vorab angelegte Puffer (für die Messung: keine Allokation im Takt)
    func renderInto(_ bufs: inout [UnsafeMutablePointer<Float>?], _ n: Int) {
        bufs.withUnsafeMutableBufferPointer { mdsp_render(e, $0.baseAddress, Int32($0.count), Int32(n)) }
    }
}

@inline(never) private func opaque(_ v: Float) -> Float { v }

private func allFinite(_ blocks: [[Float]]) -> Bool { blocks.allSatisfy { $0.allSatisfy { $0.isFinite } } }

/// die Gleitkomma-Einstellung des aufrufenden Threads bleibt unverändert
@Test func noDenormalsInDecayingTail() {
    let c = Engine()
    // kurzer Impuls, danach Stille
    c.load(deck: 0, seconds: 40) { i, _ in i < 64 ? 0.8 : 0 }
    c.set(0, MD_PLAYING, 1)
    c.set(0, MD_EQ_LOW, 9); c.set(0, MD_EQ_MID, 6); c.set(0, MD_EQ_HIGH, 6)
    c.set(0, MD_FILTER, -0.5); c.set(0, MD_FILTER_RES, 1.4)
    var sub = 0
    for _ in 0..<Int(30 * 44100 / 512) {
        for ch in c.render(512) { sub += ch.filter { $0 != 0 && abs($0) < Float.leastNormalMagnitude }.count }
    }
    #expect(sub == 0)
    // Thread-Umgebung: subnormale Zahlen nach dem Rendern weiterhin darstellbar (FTZ nur innerhalb von mdsp_render)
    #expect(Float.leastNormalMagnitude / opaque(4) != 0)
}

/// Rechenzeit je Block: 2 Decks Keylock, 4 Decks Keylock + FX. Nur mit MIX741_BENCH=1 (Zahlen für CHANGELOG/PR).
@Test(.enabled(if: ProcessInfo.processInfo.environment["MIX741_BENCH"] == "1"))
func benchRenderCPU() {
    for (decks, fx, block) in [(2, false, 512), (2, false, 128), (4, true, 512), (4, true, 128)] {
        let c = Engine()
        for d in 0..<decks {
            c.loadMusic(deck: d, seconds: 70)
            c.set(d, MD_PLAYING, 1)
            c.set(d, MD_KEYLOCK, 1)
            c.set(d, MD_RATE, d % 2 == 0 ? 1.03 : 0.97)
            c.set(d, MD_EQ_LOW, -6); c.set(d, MD_FILTER, 0.2)
            if fx { c.set(d, MDParam(rawValue: MD_FX1_ASSIGN.rawValue + UInt32(d)), 1) }
        }
        if fx {
            for u in 0..<4 {
                mdsp_set_fx(c.e, Int32(u), u % 2 == 0 ? MDFX_REVERB_ON : MDFX_DELAY_ON, 1)
            }
        }
        var bufs: [UnsafeMutablePointer<Float>?] = (0..<2).map { _ in .allocate(capacity: block) }
        defer { bufs.forEach { $0?.deallocate() } }
        // einschwingen
        for _ in 0..<50 { c.renderInto(&bufs, block) }
        let seconds = 60.0
        let count = Int(seconds * c.fs) / block
        var times = [UInt64](repeating: 0, count: count)
        let t0 = DispatchTime.now().uptimeNanoseconds
        for i in 0..<count {
            let a = DispatchTime.now().uptimeNanoseconds
            c.renderInto(&bufs, block)
            times[i] = DispatchTime.now().uptimeNanoseconds - a
        }
        let total = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
        let sorted = times.sorted()
        let deadline = Double(block) / c.fs * 1e6
        print(String(format: "[bench] %d decks keylock%@ · %d frames: %.2f %% of one core · avg %.1f µs · p99 %.1f µs · max %.1f µs (deadline %.0f µs)",
                     decks, fx ? " + fx" : "", block, total / seconds * 100,
                     Double(times.reduce(0, +)) / Double(count) / 1000, Double(sorted[count * 99 / 100]) / 1000,
                     Double(sorted.last ?? 0) / 1000, deadline))
    }
}
