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

/// mittlerer RMS nach dem Einschwingen (Blöcke 10…40 nach dem Fehler)
private func recoveredLevel(_ c: Engine) -> Float {
    for _ in 0..<10 { _ = c.render(512) }
    var acc: Float = 0
    for _ in 0..<30 { let o = c.render(512); acc += (o[0].reduce(0) { $0 + $1 * $1 } / 512).squareRoot() }
    return acc / 30
}

private func allFinite(_ blocks: [[Float]]) -> Bool { blocks.allSatisfy { $0.allSatisfy { $0.isFinite } } }

/// NaN im Track (kaputte Datei, Dekoder) darf nicht zum Ausgang durchschlagen und das Deck nicht dauerhaft stumm schalten
@Test func nanInTrackIsContainedAndDeckRecovers() {
    let c = Engine()
    c.load(deck: 0, seconds: 4) { i, t in (t > 1.0 && t < 1.01) ? .nan : Float(sin(2 * .pi * 220 * Double(i) / 44100)) * 0.5 }
    c.set(0, MD_PLAYING, 1)
    c.set(0, MD_EQ_LOW, 6)            // rekursive Filter halten NaN sonst fest
    c.set(0, MD_FILTER, -0.3)
    var finite = true
    for _ in 0..<Int(1.5 * 44100 / 512) { finite = finite && allFinite(c.render(512)) }
    #expect(finite)
    // nach dem Fehler klingt das Deck wieder (Zustand zurückgesetzt, Pegel da)
    #expect(recoveredLevel(c) > 0.25)
    var r: Float = 0, p: Float = 0
    mdsp_levels(c.e, 0, &r, &p)
    #expect(r.isFinite && p.isFinite)
}

/// Gerät mit niedriger Rate (z. B. 22,05 kHz): Filterfrequenzen über Nyquist dürfen keinen instabilen Filter ergeben
@Test func filtersStayStableAtLowDeviceRate() {
    for fs in [16000.0, 22050, 32000] {
        let c = Engine(fs: fs)
        c.load(deck: 0, seconds: 3) { i, _ in Float(sin(2 * .pi * 440 * Double(i) / fs)) * 0.5 }
        c.set(0, MD_PLAYING, 1)
        c.set(0, MD_FILTER, -0.05)    // Lowpass knapp unter 20 kHz
        c.set(0, MD_EQ_HIGH, 6)       // Shelf bei 10 kHz
        var peak: Float = 0, finite = true
        for _ in 0..<Int(2 * fs / 512) {
            let o = c.render(512)
            finite = finite && allFinite(o)
            peak = max(peak, o[0].map { abs($0) }.max() ?? 0)
        }
        #expect(finite, "fs \(fs)")
        #expect(peak <= 1 && peak > 0.1, "fs \(fs): peak \(peak)")
    }
}

/// Denormals: ausklingende Filter erzeugen keine subnormalen Werte (Intel: sonst Rechenzeit ×100);
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

/// Randfälle der Schnittstelle: kein Kanal, ein Kanal (Mono-Gerät), Rate 0 beim Laden
@Test func renderEdgeCases() {
    let c = Engine()
    c.loadMusic(deck: 0, seconds: 2)
    c.set(0, MD_PLAYING, 1)
    _ = c.render(256, channels: 0)               // darf nicht abstürzen
    _ = c.render(0, channels: 2)
    let mono = c.render(512, channels: 1)
    #expect(allFinite(mono))
    #expect((mono[0].map { abs($0) }.max() ?? 0) > 0.01)
    // Track mit Rate 0 (kaputte Datei): Position bleibt endlich
    let l = UnsafeMutablePointer<Float>.allocate(capacity: 1000), r = UnsafeMutablePointer<Float>.allocate(capacity: 1000)
    defer { l.deallocate(); r.deallocate() }
    l.initialize(repeating: 0, count: 1000); r.initialize(repeating: 0, count: 1000)
    let gen = mdsp_set_track(c.e, 1, l, r, 1000, 0, 0)
    c.set(1, MD_PLAYING, 1)
    for _ in 0..<4 { _ = c.render(512) }
    #expect(mdsp_track_consumed(c.e, 1, gen))
    #expect(mdsp_position(c.e, 1).isFinite)
}

/// Nicht-endliche Steuerwerte (NaN/Inf aus einer kaputten Rechnung) erreichen den Kern nicht: ein Deck liefe sonst mit
/// Position NaN stumm weiter (healDeck greift nur bei NaN am Ausgang), die Clock stünde
@Test func nonFiniteControlValuesAreIgnored() {
    let c = Engine()
    c.load(deck: 0, seconds: 4) { i, _ in Float(sin(2 * .pi * 220 * Double(i) / 44100)) * 0.5 }
    c.set(0, MD_PLAYING, 1)
    _ = c.render(512)
    c.set(0, MD_RATE, .nan); c.set(0, MD_GAIN_DB, .infinity); c.set(0, MD_VOLUME, .nan); c.set(0, MD_EQ_LOW, -.infinity)
    mdsp_seek(c.e, 0, .infinity); mdsp_seek(c.e, 0, .nan)
    mdsp_set_loop(c.e, 0, true, .nan, 1)
    mdsp_set_fx(c.e, 0, MDFX_DELAY_SECONDS, .nan)
    mdsp_clock_set_bpm(c.e, 120); mdsp_clock_set_beat(c.e, 0)
    mdsp_clock_set_bpm(c.e, .nan); mdsp_clock_set_beat(c.e, .infinity); mdsp_set_master(c.e, .nan)
    var finite = true
    for _ in 0..<40 { finite = finite && allFinite(c.render(512)) }
    #expect(finite)
    let p = mdsp_position(c.e, 0)
    #expect(p.isFinite && p > 0.4)            // läuft mit Rate 1 weiter (41 Blöcke ≈ 0,48 s)
    #expect(mdsp_playing(c.e, 0))
    #expect(mdsp_clock_beat(c.e).isFinite && mdsp_clock_beat(c.e) > 0.5)
    var s = 0.0, en = 0.0
    #expect(!mdsp_loop(c.e, 0, &s, &en))      // Loop mit NaN-Grenze nicht übernommen
    #expect(recoveredLevel(c) > 0.25)         // Sinus 0,5 -> RMS 0,35: Gain/Volume unverändert
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

/// NaN mit eingeschaltetem Hall (Filter vor dem Hall halten NaN fest, wenn sie nicht zurückgesetzt werden)
@Test func nanWithReverbRecovers() {
    let c = Engine()
    c.load(deck: 0, seconds: 4) { i, t in (t > 1.0 && t < 1.01) ? .nan : Float(sin(2 * .pi * 220 * Double(i) / 44100)) * 0.5 }
    c.set(0, MD_PLAYING, 1)
    c.set(0, MD_FX1_ASSIGN, 1)
    mdsp_set_fx(c.e, 0, MDFX_REVERB_ON, 1)
    mdsp_set_fx(c.e, 0, MDFX_REVERB_HP, 0.5)
    mdsp_set_fx(c.e, 0, MDFX_REVERB_LP, 0.5)
    var finite = true
    for _ in 0..<Int(1.5 * 44100 / 512) { finite = finite && allFinite(c.render(512)) }
    #expect(finite)
    #expect(recoveredLevel(c) > 0.25)   // Sinus 0.5 -> RMS 0.35; ohne Rücksetzen der Hall-Filter ~0.1 mit Aussetzern
}
