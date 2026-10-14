import Foundation
import Testing
import MixCore
@testable import MixApp

/// Palette der Mischung bis zur Preset-Liste (Farben + Höhen-Betonung + Variante A…K)
private func legacyPalette(_ p: WaveformPalette, highBoost: Double, preset: Int) -> BlendPaint.Palette {
    let k = Float(pow(2, highBoost - 1))
    var pal: BlendPaint.Palette
    if p == .rgb { pal = .rgb } else {
        let c = RenderedWaveform.Colors.of(p)
        let f = { (v: RenderedWaveform.RGB) in (r: Float(v.r), g: Float(v.g), b: Float(v.b)) }
        pal = BlendPaint.Palette(low: f(c.low), mid: f(c.mid), high: f(c.high))
    }
    pal.gain.b *= k
    let variants: [(inout BlendPaint.Palette) -> Void] = [
        { _ in }, { $0.gain.g = 0.85 }, { $0.gain.g = 1.2; $0.gain.b *= 1.3 }, { $0.base = 0.15 }, { $0.base = 0; $0.gain.g = 0.75 },
        { $0.fade = 0.05; $0.base = 0.25; $0.gain.g = 0.75 }, { $0.stackCurve = 0.45; $0.gain.g = 0.75 },
        { $0.stackCurve = 0.85; $0.base = 0.25; $0.gain.g = 0.85 }, { $0.warmth = 0; $0.gain.g = 0.8 },
        { $0.base = 1; $0.saturation = 1.2; $0.gain.g = 0.8 }, { $0.saturation = 1.0; $0.base = 0.5; $0.gain.g = 0.8 },
    ]
    variants[preset](&pal)
    return pal
}

private func same(_ a: BlendPaint.Palette, _ b: BlendPaint.Palette) -> Bool {
    a.low == b.low && a.mid == b.mid && a.high == b.high && a.highOpen == b.highOpen && a.lowWarm == b.lowWarm && a.direct == b.direct
        && a.highShare == b.highShare && a.saturation == b.saturation && a.window == b.window && a.gain == b.gain && a.base == b.base
        && a.fade == b.fade && a.stackCurve == b.stackCurve && a.warmth == b.warmth && a.openness == b.openness
}

@Test func builtInPresetsEqualOldVariantsAndPalettes() {
    let b = WavePresets.builtIn
    #expect(b.count == 15 && Set(b.map(\.id)).count == 15 && b.allSatisfy { $0.builtIn && $0.analysis == .standard })
    for i in 0..<11 { #expect(same(b[i].palette, legacyPalette(.rgb, highBoost: 1, preset: i)), "Variante \(i)") }
    for (i, p) in [WaveformPalette.bone, .orange, .blue, .classic].enumerated() {
        #expect(same(b[11 + i].palette, legacyPalette(p, highBoost: 1, preset: 0)), "Palette \(p)")
    }
}

@Test func oldSelectionMigratesToPreset() {
    #expect(WavePresets.migrate(palette: .rgb, highBoost: 1, variant: 0) == ("blend.a", nil))
    #expect(WavePresets.migrate(palette: .rgb, highBoost: 1, variant: 5).id == "blend.f")
    #expect(WavePresets.migrate(palette: .rgb, highBoost: 1, variant: 99).id == "blend.k")
    #expect(WavePresets.migrate(palette: .orange, highBoost: 1, variant: 0).id == "palette.orange")
    // Farben + Variante oder andere Höhen-Betonung: eigenes Preset mit demselben Bild
    for (p, hb, v) in [(WaveformPalette.bone, 1.0, 3), (.rgb, 2.0, 2), (.classic, 0.5, 0)] {
        let m = WavePresets.migrate(palette: p, highBoost: hb, variant: v)
        guard let c = m.created else { Issue.record("kein eigenes Preset für \(p) \(hb) \(v)"); continue }
        #expect(m.id.isEmpty && !c.builtIn && c.analysis == .standard)
        let old = legacyPalette(p, highBoost: hb, preset: v), new = c.palette
        #expect(abs(new.gain.b - old.gain.b) < 1e-5 && new.gain.g == old.gain.g && new.base == old.base && new.low == old.low && new.direct == old.direct)
    }
}

@MainActor @Test func oldPrefsKeepBlendFieldsForMigration() throws {
    let p = AppPrefs.decode(Data(#"{"ui": {"blendPreset": 4, "waveformPalette": "Orange", "waveformHighBoost": 1.5}}"#.utf8))
    #expect(p.ui.blendPreset == 4 && p.ui.waveformPalette == .orange && p.ui.waveformHighBoost == 1.5 && p.ui.wavePreset.isEmpty)
    var q = p
    q.ui.wavePreset = "blend.c"
    #expect(AppPrefs.decode(try JSONEncoder().encode(q)).ui.wavePreset == "blend.c")
}

@MainActor @Test func storeWritesAndReadsFile() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wave-presets-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("wave-presets.json")
    let s = WavePresetStore(url: url)
    #expect(s.list.custom.isEmpty && s.all.count == WavePresets.builtIn.count)
    let id = s.copy("blend.b")!
    s.update(id) { $0.analysis.high = 5000 }
    s.rename(id, to: "Raster")
    WavePresetStore.flush()
    let again = WavePresetStore(url: url)
    #expect(again.list == s.list && again.resolved(id).name == "Raster" && again.resolved(id).analysis.high == 5000)
    #expect(s.delete(id) == "blend.b")
    WavePresetStore.flush()
    #expect(WavePresetStore(url: url).list.custom.isEmpty)
    // unlesbare Datei: beiseitegelegt, leer
    try Data("kaputt".utf8).write(to: url)
    #expect(WavePresetStore(url: url).list.custom.isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains { $0.hasPrefix("wave-presets-unlesbar-") })
}
