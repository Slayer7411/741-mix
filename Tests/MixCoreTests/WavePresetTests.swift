import Foundation
import Testing
@testable import MixCore

private let builtIn = [WavePreset(id: "b.a", name: "A", builtIn: true), WavePreset(id: "b.b", name: "B", builtIn: true, look: .init(.rgb, highBoost: 2))]

@Test func wavePresetCodableRoundTrip() throws {
    var p = WavePreset(name: "Mein Raster", base: "b.a")
    p.analysis = BlendParams(low: 200, mid: nil, high: 4000, attackMs: .init(1, 2, 3), releaseMs: .init(40, 50, 60), weights: .init(0.5, 0.9, 1.5))
    p.look.low = WaveColor(0.1, 0.2, 0.3)
    p.look.direct = false
    p.look.gain = .init(1.1, 0.7, 2)
    p.look.highBoost = 1.5
    let back = try JSONDecoder().decode(WavePreset.self, from: JSONEncoder().encode(p))
    #expect(back == p)
    #expect(back.analysis.mid == nil && abs(back.analysis.midHz - (200 * 4000.0).squareRoot()) < 1e-9)
}

@Test func wavePresetMissingFieldsGetDefaults() throws {
    let p = try JSONDecoder().decode(WavePreset.self, from: Data(#"{"id": "x", "name": "Alt", "analysis": {"low": 120}, "look": {"base": 0.5}}"#.utf8))
    #expect(p.analysis.low == 120 && p.analysis.mid == 670 && p.analysis.high == 3000 && p.analysis.weights == BlendParams.standard.weights)
    #expect(p.look.base == 0.5 && p.look.fade == BlendPaint.fade && p.look.direct && !p.builtIn)
    let auto = try JSONDecoder().decode(BlendParams.self, from: Data(#"{"mid": null}"#.utf8))
    #expect(auto.mid == nil && auto.low == 150)
}

@Test func lookPaletteMatchesPaletteValues() {
    let p = WavePreset.Look(.rgb).palette, r = BlendPaint.Palette.rgb
    #expect(p.direct && p.gain.r == r.gain.r && p.gain.g == r.gain.g && p.gain.b == r.gain.b)
    #expect(p.highOpen == r.highOpen && p.lowWarm == r.lowWarm && p.saturation == r.saturation && p.window == r.window)
    // Höhen-Betonung 2 = Höhen ×2
    #expect(WavePreset.Look(.rgb, highBoost: 2).palette.gain.b == r.gain.b * 2)
}

@Test func presetListCopyRenameDeleteReset() {
    var l = WavePresetList(builtIn: builtIn)
    let c = l.copy("b.b", suffix: "Kopie")!
    #expect(l.custom.count == 1 && l.preset(c)?.name == "B Kopie" && l.preset(c)?.base == "b.b" && l.preset(c)?.builtIn == false)
    #expect(l.preset(c)?.look == builtIn[1].look)
    let c2 = l.copy("b.b", suffix: "Kopie")!
    #expect(l.preset(c2)?.name == "B Kopie 2")
    l.update(c) { $0.analysis.low = 300; $0.look.base = 0.9 }
    l.update("b.a") { $0.analysis.low = 1 }   // eingebaut bleibt
    #expect(l.preset(c)?.analysis.low == 300 && l.preset("b.a")?.analysis.low == 150)
    l.rename(c, to: "  Raster  ")
    l.rename("b.a", to: "X")
    #expect(l.preset(c)?.name == "Raster" && l.preset("b.a")?.name == "A")
    l.reset(c)
    #expect(l.preset(c)?.analysis == builtIn[1].analysis && l.preset(c)?.look == builtIn[1].look && l.preset(c)?.name == "Raster")
    #expect(l.delete("b.a") == nil && l.builtIn.count == 2)
    #expect(l.delete(c) == "b.b" && l.preset(c) == nil)
    #expect(l.resolved("weg").id == "b.a")
}

@Test func presetListFileRoundTripDropsBuiltInIDs() throws {
    var l = WavePresetList(builtIn: builtIn)
    l.copy("b.a", suffix: "Kopie")
    l.custom.append(WavePreset(id: "eigen", name: "Eigen", analysis: BlendParams(low: 90)))
    let back = WavePresetList(builtIn: builtIn, custom: try WavePresetList.decodeCustom(l.encoded()))
    #expect(back == l)
    // Datei mit eingebauter ID, doppelter ID und builtIn-Markierung: nur eigene, einmal, nie eingebaut
    var bad = l.custom
    bad.append(WavePreset(id: "b.a", name: "fremd", builtIn: true))
    bad.append(WavePreset(id: "eigen", name: "doppelt"))
    bad[0].builtIn = true
    let clean = WavePresetList(builtIn: builtIn, custom: bad)
    #expect(clean.custom.count == 2 && clean.custom.allSatisfy { !$0.builtIn } && clean.preset("b.a")?.name == "A")
}
