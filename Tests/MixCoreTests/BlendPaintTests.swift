import Testing
@testable import MixCore

@Test func rgbPaletteMapsBandsToChannels() {
    let p = BlendPaint.Palette.rgb
    let bass = BlendPaint.color((0.5, 0.01, 0.005), weight: 1, p)
    #expect(bass.r > 0.95 && bass.g < 0.05 && bass.b < 0.05)
    let hats = BlendPaint.color((0.01, 0.02, 0.4), weight: 1, p)
    #expect(hats.b > 0.9 && hats.r < 0.05)
    // Bass + Mitten gleich stark = gelb
    let both = BlendPaint.color((0.3, 0.3, 0), weight: 1, p)
    #expect(both.r > 0.9 && both.g > 0.9 && both.b < 0.01)
    // leise: dunkler
    let quiet = BlendPaint.color((0.01, 0, 0), weight: 1, p)
    #expect(quiet.r < 0.6)
}

/// ein Block: unten volle Deckung, nach oben dunkler, über der Spitze nichts
@Test func columnFadesTowardsThePeak() {
    var blend = [UInt8](repeating: 0, count: WaveBlend.stride)
    blend[WaveBlend.rmsSlot] = WaveBlend.byte(amplitude: 0.2)
    for k in 0..<3 {
        blend[WaveBlend.meanSlot + k] = WaveBlend.byte(amplitude: k == 0 ? 0.4 : 0.01)
        blend[WaveBlend.peakSlot + k] = WaveBlend.byte(amplitude: k == 2 ? 0.4 : 0.01)
    }
    let peak: [Float] = [0.8]
    var rows: [Int: (UInt8, UInt8, UInt8, UInt8)] = [:]
    peak.withUnsafeBufferPointer { pk in
        blend.withUnsafeBufferPointer { bl in
            BlendPaint.column(peak: pk, blend: bl, from: 0, to: 1, half: 100, palette: .rgb) { j, r, g, b, a in rows[j] = (r, g, b, a) }
        }
    }
    #expect(rows.count == 80)                       // bis zur Spitze 0,8
    #expect(rows[10]!.3 == 255 && rows[10]!.0 > 240)  // Körper: voll, rot
    #expect(rows[70]!.3 < rows[30]!.3)              // nach oben dunkler
    #expect(rows[78]!.2 > rows[78]!.0)              // Spitze: Farbe des lautesten Samples (Höhen)
    #expect(rows[85] == nil)
}
