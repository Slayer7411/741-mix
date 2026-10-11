import Foundation
import Testing
@testable import MixEngine

// FX-Belegung: D/W, Regler 1–3, Tasten 1–3 je Unit auf Parameter des geladenen Effekts (eigene, AU, VST3),
// gemerkt je Effekt-Kennung (EnginePrefs.fxMappings), Unit-Belegung in der Sitzung (FXUnitState).

private func control(_ s: MixState, _ u: Int, _ c: FXControl) -> FXControlInfo { s.fxControls[u][c.slot] }

private func waitFor(_ seconds: Double = 15, _ cond: () -> Bool) async throws {
    let end = Date().addingTimeInterval(seconds)
    while !cond(), Date() < end { try await Task.sleep(for: .milliseconds(20)) }
}

private func tempDir() throws -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("minos-fxassign-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

/// Katalog nur mit eigenem Ordner (keine System-VST3-Ordner einlesen)
private func catalog(_ dir: URL, vst3: URL? = nil) -> PluginCatalog {
    let c = PluginCatalog(directory: dir.appendingPathComponent("store"), folders: [], vst3Folders: [])
    if let vst3 { c.update { $0.folders = [vst3.path] } }
    return c
}

@Test func fxDefaultMappingKeepsOldLayout() {
    let core = MixController()
    var s = core.snapshot()
    #expect(s.fxControls[0].map(\.label) == ["D/W", "FILTER", "DELAY", "REVERB", "ON", "ON", "ON"])
    #expect(s.fxControls[0].allSatisfy { $0.isDefault })
    // Gruppe: Regler = Stärke, Tasten = Slot an/aus
    core.setFXControl(0, .knob1, 0.8)
    core.setFXControl(0, .dryWet, 0.4)
    core.pressFXButton(0, 1)
    s = core.snapshot()
    #expect(s.fx[0].slots[0].amount == 0.8 && s.fx[0].dryWet == 0.4 && s.fx[0].slots[1].on && !s.fx[0].slots[0].on)
    #expect(control(s, 0, .button2).active && !control(s, 0, .button1).active)
    // Single-Delay: Regler 3 = Delay-Zeit (6 Stufen), Taste 1 = an/aus, Tasten 2/3 frei
    core.updateFX(1) { $0.single = true; $0.singleType = FXUnitState.Effect.delay.rawValue }
    s = core.snapshot()
    #expect(s.fxControls[1].map(\.label) == ["D/W", "FILTER", "FEEDB", "RATE", "ON", "—", "—"])
    core.setFXControl(1, .knob3, 0.33)
    core.pressFXButton(1, 0)
    core.pressFXButton(1, 2)
    s = core.snapshot()
    #expect(abs(s.fx[1].params[2] - 0.4) < 1e-9)   // gerastet auf Stufe 2 (3/4 Beat)
    #expect(control(s, 1, .knob3).param?.text(s.fx[1].params[2]) == "3/4")
    #expect(s.fx[1].singleOn && !control(s, 1, .button3).active)
}

@Test func fxMappingRemapsAndIsRememberedPerEffect() {
    let core = MixController()
    core.setFXMapping(0, .knob1, "reverb.size")
    core.setFXMapping(0, .knob2, "")
    core.setFXMapping(0, .button2, "delay.time")
    var s = core.snapshot()
    #expect(s.prefs.fxMappings["GROUP"]?[.knob1] == "reverb.size")
    #expect(control(s, 0, .knob1).label == "ROOM" && !control(s, 0, .knob1).isDefault)
    #expect(control(s, 0, .knob2).param == nil && control(s, 0, .knob2).label == "—")
    let amount = s.fx[0].slots[0].amount, delay = s.fx[0].slots[1].amount
    core.setFXControl(0, .knob1, 0.3)
    core.setFXControl(0, .knob2, 0.9)   // nicht zugewiesen: nichts
    s = core.snapshot()
    #expect(s.fx[0].reverbSize == 0.3 && s.fx[0].slots[0].amount == amount && s.fx[0].slots[1].amount == delay)
    // Liste: eine Stufe weiter, am Ende zurück auf die erste
    let start = s.fx[0].delayIndex
    for n in 1...MixEngine.delayBeats.count {
        core.pressFXButton(0, 1)
        #expect(core.snapshot().fx[0].delayIndex == (start + n) % MixEngine.delayBeats.count)
    }
    // anderer Effekt: dessen Belegung (hier Standard); zurück zur Gruppe: gemerkte Belegung wieder da
    core.updateFX(0) { $0.single = true; $0.singleType = FXUnitState.Effect.filter.rawValue }
    s = core.snapshot()
    #expect(s.fx[0].mapping.isEmpty && s.fx[0].mappingKey == "FILTER" && control(s, 0, .knob1).label == "CUTOFF")
    core.updateFX(0) { $0.single = false }
    s = core.snapshot()
    #expect(s.fx[0].mapping[.knob1] == "reverb.size" && control(s, 0, .knob1).label == "ROOM")
    // andere Unit behält ihre eigene Belegung
    #expect(control(s, 1, .knob1).label == "FILTER")
    // Standard wiederherstellen: aus den Einstellungen entfernt
    core.resetFXMapping(0)
    s = core.snapshot()
    #expect(s.fx[0].mapping.isEmpty && s.prefs.fxMappings["GROUP"] == nil && control(s, 0, .knob1).label == "FILTER")
}

@Test func fxMappingFromPrefsAndSessionWins() throws {
    var prefs = EnginePrefs()
    var m = FXMapping()
    m[.knob3] = "reverb.size"
    m[.button1] = ""
    prefs.fxMappings["GROUP"] = m
    // Einstellungen als JSON hin und zurück (prefs.v1)
    prefs = try JSONDecoder().decode(EnginePrefs.self, from: JSONEncoder().encode(prefs))
    let core = MixController()
    core.setPrefs(prefs)
    var s = core.snapshot()
    #expect(control(s, 0, .knob3).label == "ROOM" && control(s, 0, .button1).param == nil)
    #expect(control(s, 2, .knob3).label == "ROOM")
    // Sitzung: eigene Belegung der Unit geht vor die gemerkte
    var fx = FXUnitState()
    fx.mapping[.knob1] = "delay"
    fx.mappingKey = "GROUP"
    let saved = try JSONDecoder().decode(FXUnitState.self, from: JSONEncoder().encode(fx))
    #expect(saved.mapping == fx.mapping && saved.mappingKey == "GROUP")
    core.restore { $0.fx[0] = saved }
    s = core.snapshot()
    #expect(control(s, 0, .knob1).label == "DELAY" && control(s, 0, .knob3).label == "REVERB")
    #expect(s.prefs.fxMappings["GROUP"] == m)
}

@Test func fxUnitStateReadsOlderSessions() throws {
    // ohne Belegung: Standard; Plugin-Regler 1–3 werden als "@i" (i-ter Parameter) übernommen
    let old = #"{"single":true,"singleType":3,"singleOn":true,"params":[0.1,0.2,0.3],"pluginID":"aufx:mrev:appl","dryWet":1}"#
    let fx = try JSONDecoder().decode(FXUnitState.self, from: Data(old.utf8))
    #expect(fx.mapping.isEmpty && fx.mappingKey == nil && fx.effectKey == "aufx:mrev:appl")
    #expect(fx.pluginValues == ["@0": 0.1, "@1": 0.2, "@2": 0.3])
    let group = try JSONDecoder().decode(FXUnitState.self, from: Data(#"{"dryWet":0.5}"#.utf8))
    #expect(group.pluginValues.isEmpty && group.effectKey == "GROUP")
}

@Test func fxParamScalesAndFormats() {
    var f = FXParam(id: "p1", name: "Filter Frequency", short: "FILTER", unit: "Hz", min: 10, max: 22050)
    f.curve = .logarithmic
    #expect(abs(f.plain(0.5) - (10 * 22050).squareRoot()) < 0.01)
    for x in [0.0, 0.2, 0.77, 1.0] { #expect(abs(f.position(f.plain(x)) - x) < 1e-9) }
    #expect(f.text(1) == "22.05 kHz" && f.text(0) == "10 Hz")
    let list = FXParam(id: "p2", name: "Mode", short: "MODE", min: 0, max: 2, steps: 2, valueNames: ["A", "B", "C"])
    #expect(list.snapped(0.6) == 0.5 && list.text(0.6) == "B" && list.plain(1) == 2)
    let db = FXParam(id: "p3", name: "Gain", short: "GAIN", unit: "dB", min: -18, max: 18)
    #expect(db.text(0.5) == "+0.0 dB")
    #expect(FXParam.shortName("Small/Large Mix") == "SMALL/L" && FXParam.shortName("Gain") == "GAIN")
}

/// Audio Unit (Apple, im Prozess): Parameterbaum mit Einheit, Bereich, Gruppe, Kurve; D/W auf den Mix des Plugins
@Test func fxMappingDrivesAudioUnitParameterTree() async throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let core = MixController()
    core.pluginCatalog = catalog(dir)
    let id = "aufx:mrev:appl"
    core.setPlugin(0, id: id)
    try await waitFor { core.snapshot().fxParams[0].contains { $0.pluginParam != nil } }
    var s = core.snapshot()
    let params = s.fxParams[0].filter { $0.pluginParam != nil }
    #expect(params.count >= 10)
    let mix = try #require(params.first { $0.name == "Dry/Wet Mix" })
    let freq = try #require(params.first { $0.name == "Filter Frequency" })
    #expect(mix.unit == "%" && mix.max == 100 && !mix.group.isEmpty)
    #expect(freq.unit == "Hz" && freq.curve == .logarithmic)
    #expect(Set(params.map(\.group)).count >= 3)
    // Standard: Regler 1–3 = erste drei Parameter, D/W = Unit
    #expect(control(s, 0, .knob1).param?.id == params[0].id && control(s, 0, .dryWet).param?.id == "dw")
    // D/W -> Mix des Plugins, Regler 2 -> Filterfrequenz
    core.setFXMapping(0, .dryWet, mix.id)
    core.setFXMapping(0, .knob2, freq.id)
    core.setFXControl(0, .dryWet, 0.3)
    core.setFXControl(0, .knob2, 0.5)
    let inst = try #require(core.beginPluginEdit(0))
    defer { core.endPluginEdit(0, inst) }
    #expect(abs(inst.value(mix.pluginParam!) - 30) < 0.01)
    #expect(abs(Double(inst.value(freq.pluginParam!)) - (10 * 22050).squareRoot()) < 1)
    s = core.snapshot()
    #expect(!s.fxControls[0].contains { $0.param?.id == "dw" })   // Unit-D/W aus dem Spiel -> voll nass
    #expect(abs(control(s, 0, .dryWet).value - 0.3) < 1e-6 && control(s, 0, .dryWet).label == "DRY/WET")
    #expect(s.prefs.fxMappings[id]?[.dryWet] == mix.id)
    #expect(core.pluginParamNames(0).count == 3)
    core.setPlugin(0, id: nil)
}

/// VST3 (Test-Plugin "AGain Sample Accurate"): Regler/Taste auf Gain, gemerkt je Plugin-ID, Sitzung setzt die Stellung wieder
@Test func fxMappingDrivesVST3AndComesBackWithSession() async throws {
    let src = try #require(VST3Fixture.bundle)
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let folder = dir.appendingPathComponent("vst3")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: src, to: folder.appendingPathComponent(src.lastPathComponent))
    let id = "vst3:C18D3C1E719E4E29924D3ECAA5E4DA18"

    let core = MixController()
    core.pluginCatalog = catalog(dir, vst3: folder)
    core.setPlugin(0, id: id)
    try await waitFor { core.snapshot().fxParams[0].contains { $0.pluginParam != nil } }
    var s = core.snapshot()
    let gain = try #require(s.fxParams[0].first { $0.name == "Gain" })
    let pid = try #require(gain.pluginParam)
    #expect(gain.unit == "%" && gain.normalized && gain.steps == 0)
    #expect(control(s, 0, .knob1).param?.id == gain.id && control(s, 0, .knob2).param == nil)
    #expect(control(s, 0, .button1).param?.id == "on")

    core.setFXMapping(0, .knob3, gain.id)
    core.setFXMapping(0, .knob1, "")
    core.setFXMapping(0, .button2, gain.id)
    let inst = try #require(core.beginPluginEdit(0))
    core.setFXControl(0, .knob3, 0.25)
    #expect(abs(inst.value(pid) - 0.25) < 1e-6)
    core.setFXControl(0, .knob1, 0.9)   // nicht zugewiesen
    #expect(abs(inst.value(pid) - 0.25) < 1e-6)
    // Taste auf stufenlosem Parameter: min/max
    core.pressFXButton(0, 1)
    #expect(inst.value(pid) == 1 && control(core.snapshot(), 0, .button2).active)
    core.pressFXButton(0, 1)
    #expect(inst.value(pid) == 0)
    core.setFXControl(0, .knob3, 0.6)
    s = core.snapshot()
    #expect(abs(control(s, 0, .knob3).value - 0.6) < 1e-9 && control(s, 0, .knob3).label == "GAIN")
    #expect(core.pluginText(0, gain, 0.6)?.hasSuffix("%") == true)
    core.endPluginEdit(0, inst)
    #expect(s.prefs.fxMappings[id]?[.knob3] == gain.id && s.prefs.fxMappings[id]?[.knob1] == "")

    // anderer Effekt und zurück: Belegung des Plugins wieder da
    core.updateFX(0) { $0.singleType = FXUnitState.Effect.reverb.rawValue }
    #expect(core.snapshot().fx[0].mappingKey == "REVERB" && core.snapshot().fx[0].mapping.isEmpty)
    core.updateFX(0) { $0.singleType = FXUnitState.Effect.plugin.rawValue }
    #expect(core.snapshot().fx[0].mapping[.knob3] == gain.id)

    // Neustart: Einstellungen + gespeicherte Unit (Plugin-Zustand von vor den Reglern) -> Stellung 0,6 kommt zurück
    let session = try JSONEncoder().encode(core.snapshot().fx[0])
    let prefs = core.snapshot().prefs
    core.setPlugin(0, id: nil)
    let next = MixController()
    next.pluginCatalog = catalog(dir, vst3: folder)
    next.setPrefs(prefs)
    let fx = try JSONDecoder().decode(FXUnitState.self, from: session)
    #expect(fx.pluginState != nil && fx.pluginValues[gain.id] == 0.6)
    next.restore { $0.fx[0] = fx }
    try await waitFor { next.snapshot().fxParams[0].contains { $0.pluginParam != nil } }
    let inst2 = try #require(next.beginPluginEdit(0))
    defer { next.endPluginEdit(0, inst2) }
    #expect(abs(inst2.value(pid) - 0.6) < 1e-6)
    s = next.snapshot()
    #expect(control(s, 0, .knob3).param?.id == gain.id && abs(control(s, 0, .knob3).value - 0.6) < 1e-9)
    #expect(control(s, 0, .knob1).param == nil)
    next.setPlugin(0, id: nil)
}

/// Single-REVERB: Taste 2 = Freeze (FRZ), Gruppe: Freeze zuweisbar; Freeze kommt nicht aus der Sitzung zurück
@Test func fxReverbFreezeButton() throws {
    let core = MixController()
    core.updateFX(1) { $0.single = true; $0.singleType = FXUnitState.Effect.reverb.rawValue }
    var s = core.snapshot()
    #expect(s.fxControls[1].map(\.label) == ["D/W", "SIZE", "HP", "LP", "ON", "FRZ", "—"])
    core.pressFXButton(1, 1)
    s = core.snapshot()
    #expect(s.fx[1].reverbFreeze && control(s, 1, .button2).active)
    let again = try JSONDecoder().decode(FXUnitState.self, from: JSONEncoder().encode(s.fx[1]))
    #expect(!again.reverbFreeze && again.singleType == FXUnitState.Effect.reverb.rawValue)
    core.setFXMapping(0, .button3, "reverb.freeze")
    core.pressFXButton(0, 2)
    #expect(core.snapshot().fx[0].reverbFreeze && control(core.snapshot(), 0, .button3).label == "FRZ")
    #expect(core.snapshot().prefs.reverbType == .classic)
}
