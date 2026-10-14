import AudioToolbox
import Foundation
import Testing
import MixDSP
@testable import MixEngine

// Plugin-Ketten im Kern (FX-Unit: Plugins in Reihe, D/W gegen den Eingang der Kette) und Master-Bus (nach der Summe der Decks).
// Referenz: dieselben Plugins (frische Instanzen) außerhalb des Kerns auf dasselbe Signal, gleiche Blockgröße.

private let fs = 48000.0
private let block = 512

private func fcc(_ s: String) -> UInt32 { s.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) } }

/// Apple-AU im Kern-Format öffnen; Tiefpass 300 Hz bzw. Limiter mit +20 dB Vorverstärkung (nichtlinear: Reihenfolge zählt)
private func open(_ sub: String) throws -> OpaquePointer {
    var err = [CChar](repeating: 0, count: 256)
    let p = try #require(mdplug_open(fcc("aufx"), fcc(sub), fcc("appl"), fs, UInt32(MDSP_MAX_FRAMES), &err, Int32(err.count)),
                         "\(String(cString: err))")
    let au = AudioUnit(OpaquePointer(mdplug_audio_unit(p)!))
    switch sub {
    case "lpas": AudioUnitSetParameter(au, AudioUnitParameterID(kLowPassParam_CutoffFrequency), kAudioUnitScope_Global, 0, 300, 0)
    case "lmtr": AudioUnitSetParameter(au, AudioUnitParameterID(kLimiterParam_PreGain), kAudioUnitScope_Global, 0, 20, 0)
    default: break
    }
    return p
}

/// Rauschen (fest gesät), Stereo
private func noise(_ frames: Int, seed s0: UInt32, amp: Float) -> ([Float], [Float]) {
    var seed = s0, l = [Float](repeating: 0, count: frames), r = l
    for i in 0..<frames {
        seed = seed &* 1664525 &+ 1013904223; l[i] = (Float(seed >> 8) / Float(1 << 24) - 0.5) * 2 * amp
        seed = seed &* 1664525 &+ 1013904223; r[i] = (Float(seed >> 8) / Float(1 << 24) - 0.5) * 2 * amp
    }
    return (l, r)
}

/// Kern mit Decks auf Rauschen, gerendert in Blöcken auf `channels` Kanälen
private final class Rig {
    let e: OpaquePointer
    let frames: Int
    let channels: Int
    var tracks: [UnsafeMutablePointer<Float>] = []
    var input: [([Float], [Float])] = []

    init(decks: [Int] = [0], pairs: [Int] = [0, 0, 0, 0], seconds: Double = 2, channels: Int = 4) {
        e = mdsp_create(fs)
        frames = Int(seconds * fs)
        self.channels = channels
        for d in decks {
            let (l, r) = noise(frames, seed: UInt32(17 + d * 101), amp: d == 0 ? 0.5 : 0.3)
            input.append((l, r))
            let pl = UnsafeMutablePointer<Float>.allocate(capacity: frames), pr = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            pl.initialize(from: l, count: frames); pr.initialize(from: r, count: frames)
            tracks += [pl, pr]
            mdsp_set_track(e, Int32(d), pl, pr, Int64(frames), fs, 0)
            mdsp_set_param(e, Int32(d), MD_OUT_CHANNEL, Float(pairs[d]))
            mdsp_set_param(e, Int32(d), MD_KEYLOCK, 0)
            mdsp_set_param(e, Int32(d), MD_PLAYING, 1)
        }
    }
    deinit { mdsp_destroy(e); for t in tracks { t.deallocate() } }

    /// FX-Unit `u` auf Deck `d`, Plugin-Kette an, D/W
    func chain(_ u: Int, deck d: Int, _ plugs: [OpaquePointer?], dw: Float = 1) {
        mdsp_set_param(e, Int32(d), MDParam(rawValue: MD_FX1_ASSIGN.rawValue + UInt32(u)), 1)
        mdsp_set_fx(e, Int32(u), MDFX_DRYWET, dw)
        mdsp_set_fx(e, Int32(u), MDFX_PLUGIN_ON, 1)
        var p = plugs
        p.withUnsafeMutableBufferPointer { mdsp_set_fx_chain(e, Int32(u), Int32(d), $0.baseAddress, Int32($0.count)) }
    }

    /// `blocks` Blöcke rendern; je Kanal alle Samples hintereinander
    func render(_ blocks: Int) -> [[Float]] {
        var all = [[Float]](repeating: [], count: channels)
        var out = [Float](repeating: 0, count: channels * block)
        for _ in 0..<blocks {
            out.withUnsafeMutableBufferPointer { o in
                var chans: [UnsafeMutablePointer<Float>?] = (0..<channels).map { o.baseAddress! + $0 * block }
                chans.withUnsafeMutableBufferPointer { mdsp_render(e, $0.baseAddress, Int32(channels), Int32(block)) }
            }
            for c in 0..<channels { all[c] += out[(c * block)..<((c + 1) * block)] }
        }
        return all
    }
}

/// Referenz der Kette außerhalb des Kerns: Eingang mit derselben Einblend-Rampe, Plugins in Reihe, D/W = 1
private func reference(_ x: ([Float], [Float]), _ plugs: [OpaquePointer], blocks: Int) -> ([Float], [Float]) {
    var send: Float = 0
    var outL: [Float] = [], outR: [Float] = []
    for b in 0..<blocks {
        let r = (b * block)..<((b + 1) * block)
        var l = Array(x.0[r]), rr = Array(x.1[r])
        let dryL = l, dryR = rr
        var s = send
        for i in 0..<block { s += (1 - s) * 0.002; l[i] *= s; rr[i] *= s }
        l.withUnsafeMutableBufferPointer { lb in rr.withUnsafeMutableBufferPointer { rb in
            for p in plugs { mdplug_process(p, lb.baseAddress, rb.baseAddress, Int32(block)) }
        } }
        for i in 0..<block {
            send += (1 - send) * 0.002
            l[i] = dryL[i] * (1 - send) + l[i]; rr[i] = dryR[i] * (1 - send) + rr[i]
        }
        outL += l; outR += rr
    }
    return (outL, outR)
}

private func rms(_ a: ArraySlice<Float>) -> Float { (a.reduce(0) { $0 + $1 * $1 } / Float(max(1, a.count))).squareRoot() }
private func maxDiff(_ a: ArraySlice<Float>, _ b: ArraySlice<Float>) -> Float { zip(a, b).reduce(0) { max($0, abs($1.0 - $1.1)) } }

/// Deck-Lautstärke rampt von 0 auf 1 (wie im Kern), dann Master-Lautstärke 0,85: Ausgang = Kette · Rampe · 0,85
private func faded(_ x: [Float]) -> [Float] {
    var v: Float = 0
    return x.map { v += (1 - v) * 0.002; return $0 * v * 0.85 }
}

/// zwei Plugins in Reihe = f(g(x)); getauscht = g(f(x)), hörbar anders (Limiter nach / vor dem Tiefpass)
@Test func chainRunsPluginsInSeries() throws {
    let blocks = 120
    for order in [["lpas", "lmtr"], ["lmtr", "lpas"]] {
        let rig = Rig()
        let a = try open(order[0]), b = try open(order[1])
        rig.chain(3, deck: 0, [a, b])
        let out = rig.render(blocks)
        let ra = try open(order[0]), rb = try open(order[1])
        let ref = reference(rig.input[0], [ra, rb], blocks: blocks)
        let n = blocks * block
        let dl = maxDiff(out[0][0..<n], faded(ref.0)[0..<n]), dr = maxDiff(out[1][0..<n], faded(ref.1)[0..<n])
        print(String(format: "[chain] %@ -> %@: Abweichung zur Referenz L %.2e R %.2e · RMS %.3f", order[0], order[1], dl, dr, rms(out[0][(n / 2)...])))
        #expect(dl < 1e-4 && dr < 1e-4)
        for p in [a, b, ra, rb] { mdplug_close(p) }
    }
    // Reihenfolge: Tiefpass -> Limiter ist laut, Limiter -> Tiefpass leise (der Tiefpass nimmt fast alles weg)
    var level: [Float] = []
    for order in [["lpas", "lmtr"], ["lmtr", "lpas"]] {
        let rig = Rig()
        let a = try open(order[0]), b = try open(order[1])
        rig.chain(3, deck: 0, [a, b])
        let out = rig.render(blocks)
        level.append(rms(out[0][(blocks * block / 2)...]))
        for p in [a, b] { mdplug_close(p) }
    }
    #expect(level[0] > level[1] * 3)
}

/// Platz tauschen im Betrieb (ein Schritt, keine Lücke), Platz aus = durchreichen, herausgenommenes Plugin erst nach einem Block frei
@Test func chainSwapSlotOffAndRelease() throws {
    let rig = Rig(seconds: 6)
    let lp = try open("lpas"), lim = try open("lmtr")
    rig.chain(0, deck: 0, [lp, lim])
    _ = rig.render(40)
    let before = rms(rig.render(20)[0][...])
    var swapped: [OpaquePointer?] = [lim, lp]
    swapped.withUnsafeMutableBufferPointer { mdsp_set_fx_chain(rig.e, 0, 0, $0.baseAddress, 2) }
    _ = rig.render(40)
    let after = rms(rig.render(20)[0][...])
    #expect(before > after * 3)
    #expect(!mdsp_fx_plugin_released(rig.e, 0, 0, lp))   // noch in der Kette (verschoben)
    // Platz 1 (Tiefpass) aus: nur noch der Limiter
    mdsp_set_fx_chain_on(rig.e, 0, 1, false)
    _ = rig.render(Int(1.5 * fs) / block)   // Rampe + 1 s Fahne
    let limOnly = rms(rig.render(20)[0][...])
    #expect(limOnly > after * 3)
    // herausnehmen: frei erst nach dem nächsten Block
    var one: [OpaquePointer?] = [lim]
    one.withUnsafeMutableBufferPointer { mdsp_set_fx_chain(rig.e, 0, 0, $0.baseAddress, 1) }
    #expect(!mdsp_fx_plugin_released(rig.e, 0, 0, lp) && !mdsp_fx_plugin_released(rig.e, 0, 0, lim))
    _ = rig.render(1)
    #expect(mdsp_fx_plugin_released(rig.e, 0, 0, lp) && !mdsp_fx_plugin_released(rig.e, 0, 0, lim))
    mdplug_close(lp)
    _ = rig.render(4)
    var none: [OpaquePointer?] = []
    none.withUnsafeMutableBufferPointer { mdsp_set_fx_chain(rig.e, 0, 0, $0.baseAddress, 0) }
    _ = rig.render(1)
    #expect(mdsp_fx_plugin_released(rig.e, 0, 0, lim))
    mdplug_close(lim)
}

/// Master-Bus: wirkt nach der Summe (Limiter auf A + B = f(a + b)), nur auf seinem Paar; aus = Paar -1
@Test func masterChainActsOnTheSum() throws {
    let blocks = 100, n = blocks * block
    // trocken: A und B auf Paar 0, C auf Paar 2
    let dry = Rig(decks: [0, 1, 2], pairs: [0, 0, 2, 0]).render(blocks)
    let rig = Rig(decks: [0, 1, 2], pairs: [0, 0, 2, 0])
    let lim = try open("lmtr")
    var one: [OpaquePointer?] = [lim]
    one.withUnsafeMutableBufferPointer { mdsp_set_fx_chain(rig.e, MDSP_MASTER_UNIT, 0, $0.baseAddress, 1) }
    mdsp_set_master_fx(rig.e, true, 1)
    mdsp_set_master_fx_channel(rig.e, 0)
    let out = rig.render(blocks)
    // Referenz: Summe vor der Master-Lautstärke (0,85) durch einen frischen Limiter
    let ref = try open("lmtr")
    let sum = (dry[0].map { $0 / 0.85 }, dry[1].map { $0 / 0.85 })
    let r = reference(sum, [ref], blocks: blocks)
    let d = maxDiff(out[0][0..<n], r.0.map { max(-1, min(1, $0 * 0.85)) }[0..<n])
    print(String(format: "[master] Abweichung zur Referenz %.2e · RMS trocken %.3f · mit Limiter %.3f", d, rms(dry[0][(n / 2)...]), rms(out[0][(n / 2)...])))
    #expect(d < 1e-4)
    #expect(abs(rms(out[0][(n / 2)...]) - rms(dry[0][(n / 2)...])) > rms(dry[0][(n / 2)...]) * 0.5)
    #expect(out[2] == dry[2] && out[3] == dry[3])   // Paar von Deck C unberührt
    var lv: (Float, Float) = (0, 0)
    mdsp_master_levels(rig.e, &lv.0, &lv.1)
    #expect(lv.0 > 0.01 && lv.1 <= 1.2)
    // Paar aus (externer Mixer): kein Summenpunkt, nichts verändert, kein Pegel
    let off = Rig(decks: [0, 1, 2], pairs: [0, 0, 2, 0])
    let lim2 = try open("lmtr")
    var two: [OpaquePointer?] = [lim2]
    two.withUnsafeMutableBufferPointer { mdsp_set_fx_chain(off.e, MDSP_MASTER_UNIT, 0, $0.baseAddress, 1) }
    mdsp_set_master_fx(off.e, true, 1)
    mdsp_set_master_fx_channel(off.e, -1)
    #expect(off.render(blocks) == dry)
    mdsp_master_levels(off.e, &lv.0, &lv.1)
    #expect(lv.0 == 0)
    for p in [lim, ref, lim2] { mdplug_close(p) }
}

/// NaN aus einem Plugin: Platz wird durchgereicht und meldet sich zum Zurücksetzen, die folgenden Plätze bleiben sauber
@Test func chainSlotResetProtocol() throws {
    let rig = Rig()
    let lp = try open("lpas")
    rig.chain(0, deck: 0, [nil, lp])
    _ = rig.render(4)
    #expect(!mdsp_fx_chain_needs_reset(rig.e, 0, 0, 1))
    // Deck mit NaN-Sample: das Deck wird geheilt, alle Plätze mit Plugin warten auf das Zurücksetzen
    rig.tracks[0][Int(fs / 2)] = .nan
    let out = rig.render(Int(fs) / block)
    #expect(out[0].allSatisfy { $0.isFinite })
    #expect(mdsp_fx_chain_needs_reset(rig.e, 0, 0, 1) && !mdsp_fx_chain_needs_reset(rig.e, 0, 0, 0))
    mdplug_reset(lp)
    mdsp_fx_chain_reset_done(rig.e, 0, 0, 1)
    #expect(!mdsp_fx_chain_needs_reset(rig.e, 0, 0, 1))
    var none: [OpaquePointer?] = []
    none.withUnsafeMutableBufferPointer { mdsp_set_fx_chain(rig.e, 0, 0, $0.baseAddress, 0) }
    _ = rig.render(1)
    mdplug_close(lp)
}

/// Sitzung: ein Plugin je Unit (alt) wird Platz 1; Kette mit an/aus und Zustand übersteht Speichern/Laden; Schlüssel je Platz
@Test func chainStateMigratesAndRoundTrips() throws {
    let old = #"{"single":true,"singleType":3,"singleOn":true,"pluginID":"aufx:mrev:appl","pluginState":"AAE=","dryWet":1}"#
    let fx = try JSONDecoder().decode(FXUnitState.self, from: Data(old.utf8))
    #expect(fx.chain.map(\.id) == ["aufx:mrev:appl"] && fx.chain[0].on && fx.chain[0].state == Data([0, 1]))
    #expect(fx.pluginID == "aufx:mrev:appl" && fx.effectKey == "aufx:mrev:appl")
    var two = fx
    two.chain.append(FXPluginSlot(id: "aufx:dely:appl", on: false))
    #expect(two.effectKey == "aufx:mrev:appl > aufx:dely:appl")
    let back = try JSONDecoder().decode(FXUnitState.self, from: JSONEncoder().encode(two))
    #expect(back.chain.map(\.id) == two.chain.map(\.id) && back.chain.map(\.on) == [true, false] && back.chain[0].state == Data([0, 1]))
    // ältere Fassung liest nur pluginID: bleibt das erste Plugin
    let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(two)) as? [String: Any]
    #expect(json?["pluginID"] as? String == "aufx:mrev:appl")
    #expect(FXParam.pluginKey(7, slot: 0) == "p7" && FXParam.pluginKey(7, slot: 2) == "s2.p7")
    #expect(FXParam.pluginSlot(of: "s2.p7")! == (2, "p7") && FXParam.pluginSlot(of: "p7")! == (0, "p7") && FXParam.pluginSlot(of: "@1")! == (0, "@1"))
    #expect(FXParam.pluginSlot(of: "cutoff") == nil && FXParam.pluginSlot(of: "dw") == nil && FXParam.pluginSlot(of: "gater.on") == nil)
    let master = try JSONDecoder().decode(MasterFXState.self, from: Data(#"{"on":true}"#.utf8))
    #expect(master.on && master.dryWet == 1 && master.chain.isEmpty)
}

private func waitFor(_ seconds: Double = 20, _ cond: () -> Bool) async throws {
    let end = Date().addingTimeInterval(seconds)
    while !cond(), Date() < end { try await Task.sleep(for: .milliseconds(20)) }
}

/// Steuerkern: Kette aufbauen, Parameter beider Plätze zuweisbar, Verschieben nimmt Werte und Belegung mit, Master-Kette
@Test func controllerEditsChains() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("minos-chain-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let core = MixController()
    core.pluginCatalog = PluginCatalog(directory: dir.appendingPathComponent("store"), folders: [], vst3Folders: [])
    core.addPlugin(1, id: "aufx:lpas:appl")
    core.addPlugin(1, id: "aufx:lmtr:appl")
    try await waitFor { core.snapshot().fxParams[1].contains { $0.pluginSlot == 1 } }
    var s = core.snapshot()
    #expect(s.fx[1].pluginActive && s.fx[1].chain.map(\.id) == ["aufx:lpas:appl", "aufx:lmtr:appl"])
    let gain = try #require(s.fxParams[1].first { $0.pluginSlot == 1 && $0.name.lowercased().contains("gain") })
    #expect(gain.id.hasPrefix("s1.p") && gain.group.hasPrefix("2 "))
    #expect(s.fxControls[1][FXControl.knob1.slot].param?.pluginSlot == 0)   // Standard: erste Parameter des ersten Plugins
    core.setFXMapping(1, .knob3, gain.id)
    core.setFXControl(1, .knob3, 0.75)
    let lim = try #require(core.beginPluginEdit(1, slot: 1))
    #expect(lim.info.id == "aufx:lmtr:appl" && abs(Double(lim.value(gain.pluginParam!)) - gain.plain(0.75)) < 1e-3)
    core.endPluginEdit(1, lim)
    #expect(core.snapshot().fx[1].chain[1].state != nil)
    // Limiter nach vorn: Wert und Belegung folgen dem Platz, dieselben Instanzen (kein Neuladen)
    core.movePlugin(1, slot: 1, by: -1)
    s = core.snapshot()
    let moved = FXParam.pluginKey(gain.pluginParam!, slot: 0)
    #expect(s.fx[1].chain.map(\.id) == ["aufx:lmtr:appl", "aufx:lpas:appl"])
    #expect(s.fx[1].pluginValues[moved] == 0.75 && s.fx[1].mapping[.knob3] == moved)
    #expect(core.beginPluginEdit(1, slot: 0) === lim)
    core.endPluginEdit(1, lim)
    core.setPluginOn(1, slot: 1, false)
    #expect(core.snapshot().fx[1].chain[1].on == false)
    core.removePlugin(1, slot: 0)
    s = core.snapshot()
    #expect(s.fx[1].chain.map(\.id) == ["aufx:lpas:appl"] && s.fx[1].pluginValues[moved] == nil)
    // Vorlage: Kette merken und auf den Master-Bus laden
    core.saveChainPreset(1, name: "LP")
    core.loadChainPreset(MixController.masterBus, name: "LP")
    core.setMasterFX(on: true, dryWet: 0.5)
    try await waitFor { core.beginPluginEdit(MixController.masterBus).map { core.endPluginEdit(MixController.masterBus, $0); return true } ?? false }
    s = core.snapshot()
    #expect(s.masterFX.on && s.masterFX.dryWet == 0.5 && s.masterFX.chain.map(\.id) == ["aufx:lpas:appl"])
    #expect(core.chainLatency(MixController.masterBus).slots.count == 1)
    core.setPlugin(1, id: nil)
    core.removePlugin(MixController.masterBus, slot: 0)
    #expect(core.snapshot().fx[1].chain.isEmpty && core.snapshot().masterFX.chain.isEmpty)
}

