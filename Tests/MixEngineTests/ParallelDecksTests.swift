import Foundation
import Testing
import MixDSP

/// Decks parallel (Worker-Threads) gegen seriell: gleiche Eingaben, gleiche Blöcke -> identische Ausgabe.
/// Vier Decks mit verschiedenen Sinussen, Keylock auf B und D, EQ, Filter, Delay + Hall auf FX 1 (A/C) und FX 2 (B/D).
private final class FourDecks {
    let e: OpaquePointer
    let fs = 48000.0
    let frames: Int
    var bufs: [UnsafeMutablePointer<Float>] = []

    init(parallel: Bool, seconds: Double = 4) {
        e = mdsp_create(fs)
        frames = Int(seconds * fs)
        for d in 0..<4 {
            let f = [110.0, 220, 330, 440][d]
            let l = UnsafeMutablePointer<Float>.allocate(capacity: frames), r = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            for i in 0..<frames {
                let t = Double(i) / fs
                l[i] = Float(sin(2 * .pi * f * t)) * 0.4
                r[i] = Float(sin(2 * .pi * f * 1.5 * t)) * 0.3
            }
            bufs += [l, r]
            mdsp_set_track(e, Int32(d), l, r, Int64(frames), fs, 0)
            mdsp_set_param(e, Int32(d), MD_OUT_CHANNEL, Float(d * 2))
            mdsp_set_param(e, Int32(d), MD_KEYLOCK, d % 2 == 1 ? 1 : 0)
            mdsp_set_param(e, Int32(d), MD_RATE, [1.0, 1.04, 0.97, 1.1][d])
            mdsp_set_param(e, Int32(d), MD_EQ_LOW, Float(d) - 2)
            mdsp_set_param(e, Int32(d), MD_FILTER, Float(d) * 0.2 - 0.3)
            mdsp_set_param(e, Int32(d), MD_FX1_ASSIGN, d % 2 == 0 ? 1 : 0)
            mdsp_set_param(e, Int32(d), MD_FX2_ASSIGN, d % 2 == 1 ? 1 : 0)
            mdsp_set_param(e, Int32(d), MD_PLAYING, 1)
        }
        for u in 0..<2 {
            setRack(e, Int32(u), groupRack)
            mdsp_set_fx(e, Int32(u), MDFX_DELAY_ON, 1); mdsp_set_fx(e, Int32(u), MDFX_REVERB_ON, 1)
            mdsp_set_fx(e, Int32(u), MDFX_DRYWET, 0.5)
        }
        mdsp_set_parallel(e, parallel)
    }
    deinit { mdsp_destroy(e); for b in bufs { b.deallocate() } }

    /// `blocks` Blöcke zu `n` Frames auf 8 Kanälen rendern, alle Ausgaben hintereinander
    func render(blocks: Int, n: Int = 256) -> [Float] {
        var out = [Float](repeating: 0, count: 8 * n), all: [Float] = []
        all.reserveCapacity(8 * n * blocks)
        for _ in 0..<blocks {
            out.withUnsafeMutableBufferPointer { o in
                var chans: [UnsafeMutablePointer<Float>?] = (0..<8).map { o.baseAddress! + $0 * n }
                chans.withUnsafeMutableBufferPointer { mdsp_render(e, $0.baseAddress, 8, Int32(n)) }
            }
            all += out
        }
        return all
    }
}

@Test func parallelDecksMatchSerial() {
    let serial = FourDecks(parallel: false), parallel = FourDecks(parallel: true)
    #expect(!mdsp_parallel(serial.e) && mdsp_parallel(parallel.e))
    let a = serial.render(blocks: 60), b = parallel.render(blocks: 60)
    #expect(a.count == b.count)
    var peak: Float = 0
    for i in 0..<min(a.count, b.count) { peak = max(peak, abs(a[i] - b[i])) }
    #expect(peak == 0, "Abweichung parallel/seriell \(peak)")
    #expect(a.contains { abs($0) > 0.05 }, "Ausgabe darf nicht still sein")
    #expect(abs(mdsp_position(serial.e, 1) - mdsp_position(parallel.e, 1)) < 1e-9)
}

@Test func parallelToggleWhileRendering() {
    let c = FourDecks(parallel: false)
    let before = c.render(blocks: 10)
    mdsp_set_parallel(c.e, true)
    let mid = c.render(blocks: 10)
    mdsp_set_parallel(c.e, false)
    let after = c.render(blocks: 10)
    for x in before + mid + after { #expect(x.isFinite) }
    #expect(mid.contains { abs($0) > 0.05 } && after.contains { abs($0) > 0.05 })
    // Position läuft durchgehend weiter: 30 Blöcke à 256 Frames, Deck A Tempo 1
    #expect(abs(mdsp_position(c.e, 0) - 30 * 256 / 48000.0) < 0.002)
}

@Test func parallelWithWorkgroupUnsetAndDestroy() {
    for _ in 0..<3 {
        let c = FourDecks(parallel: true, seconds: 1)
        mdsp_set_workgroup(c.e, nil, 256 / 48000.0)
        _ = c.render(blocks: 5)
    }   // mdsp_destroy beendet die Worker ohne zu hängen
}

@Test func renderProfileReportsWorstBlock() {
    let c = FourDecks(parallel: false, seconds: 1)
    _ = c.render(blocks: 20, n: 256)
    var parts = [UInt64](repeating: 0, count: 8), frames: UInt32 = 0
    mdsp_render_profile(c.e, &parts, 8, &frames)
    #expect(frames == 256)
    let total = parts.reduce(0, +)
    #expect(total > 0 && total < 50_000_000, "Gesamt \(total) ns")           // unter 50 ms
    #expect(parts[0] > 0 && parts[1] > 0 && parts[4] == 0, "seriell: Decks gemessen, kein Warten")
    mdsp_set_parallel(c.e, true)
    _ = c.render(blocks: 20, n: 256)
    mdsp_render_profile(c.e, &parts, 8, &frames)
    #expect(parts[0] > 0 && parts[1] == 0 && parts[4] > 0, "parallel: A hier, B–D im Warten")
    // Abholen setzt zurück: ohne neuen Block bleibt der letzte Wert stehen (Audio-Thread schreibt nur bei total > worst)
    mdsp_render_profile(c.e, &parts, 8, &frames)
    #expect(frames == 256)
}
