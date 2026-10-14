import Testing
@testable import MixCore

@Test func rgbPaletteMapsBandsToChannels() {
    var p = BlendPaint.Palette.rgb
    p.gain = (1, 1, 1)
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
    // Standard-Gewichte: Höhen vor, Mitten zurück
    let std = BlendPaint.color((0.2, 0.2, 0.2), weight: 1, .rgb)
    #expect(std.b > std.r && std.r > std.g)
}

/// ein Block: unten volle Deckung, nach oben dunkler, über der Spitze nichts; Bänder gestapelt – stärkstes Band
/// (Bass) als Körper in der Mitte, schwächstes (Höhen) außen an der Spitze
@Test func columnStacksBandsAndFadesTowardsThePeak() {
    var blend = [UInt8](repeating: 0, count: WaveBlend.stride)
    blend[WaveBlend.rmsSlot] = WaveBlend.byte(amplitude: 0.2)
    let bands: [Float] = [0.4, 0.1, 0.02]   // Tief, Mitte, Hoch (Analyse-gewichtet); Stapel L M H
    for k in 0..<3 {
        blend[WaveBlend.meanSlot + k] = WaveBlend.byte(amplitude: bands[k])
        blend[WaveBlend.peakSlot + k] = WaveBlend.byte(amplitude: bands[k])
    }
    let peak: [Float] = [0.8]
    var rows: [Int: (UInt8, UInt8, UInt8, UInt8)] = [:]
    peak.withUnsafeBufferPointer { pk in
        blend.withUnsafeBufferPointer { bl in
            BlendPaint.column(peak: pk, blend: bl, from: 0, to: 1, half: 100, palette: .rgb) { j, r, g, b, a in rows[j] = (r, g, b, a) }
        }
    }
    #expect(rows.count == 80)                                   // bis zur Spitze 0,8
    #expect(rows[10]!.3 == 255 && rows[10]!.0 > rows[10]!.2 * 3)  // Körper: voll, rot
    #expect(rows[70]!.3 < rows[30]!.3)                          // nach oben dunkler
    #expect(rows[78]!.2 > rows[78]!.0 && rows[78]!.2 > rows[78]!.1)  // Spitze: Höhen (blau)
    #expect(rows[85] == nil)
}

/// Farbfenster: die Nachbarspalte färbt mit, die Höhe bleibt die eigene
@Test func columnColorWindowKeepsOwnHeight() {
    var blend = [UInt8](repeating: 0, count: WaveBlend.stride * 2)
    for b in 0..<2 {
        let o = b * WaveBlend.stride
        blend[o + WaveBlend.rmsSlot] = WaveBlend.byte(amplitude: 0.1)
        for k in 0..<3 {
            let v: Float = (b == 0 ? k == 0 : k == 2) ? 0.3 : 0.01   // Block 0 Bass, Block 1 Höhen
            blend[o + WaveBlend.meanSlot + k] = WaveBlend.byte(amplitude: v)
            blend[o + WaveBlend.peakSlot + k] = WaveBlend.byte(amplitude: v)
        }
    }
    let peak: [Float] = [0.3, 0.9]
    var p = BlendPaint.Palette.rgb
    p.window = 1
    var rows: [Int: (UInt8, UInt8, UInt8, UInt8)] = [:]
    peak.withUnsafeBufferPointer { pk in
        blend.withUnsafeBufferPointer { bl in
            BlendPaint.column(peak: pk, blend: bl, from: 0, to: 1, half: 100, palette: p) { j, r, g, b, a in rows[j] = (r, g, b, a) }
        }
    }
    #expect(rows.count == 30)              // Höhe des eigenen Blocks (0,3), nicht des Nachbarn
    #expect(rows[5]!.2 > 0)                // der Nachbar (Höhen) färbt mit
}

/// gehaltene Höhen (offene Hats, Ride) färben hellblau, kurze Höhen bleiben blau
@Test func heldHighsTurnLightBlue() {
    var blend = [UInt8](repeating: 0, count: WaveBlend.stride)
    blend[WaveBlend.rmsSlot] = WaveBlend.byte(amplitude: 0.05)
    let bands: [Float] = [0.02, 0.02, 0.4]   // nur Höhen
    for k in 0..<3 {
        blend[WaveBlend.meanSlot + k] = WaveBlend.byte(amplitude: bands[k])
        blend[WaveBlend.peakSlot + k] = WaveBlend.byte(amplitude: bands[k])
    }
    let peak: [Float] = [0.5]
    func row10(open: UInt8) -> (UInt8, UInt8, UInt8) {
        var rows: [Int: (UInt8, UInt8, UInt8)] = [:]
        let o: [UInt8] = [open]
        peak.withUnsafeBufferPointer { pk in
            blend.withUnsafeBufferPointer { bl in
                o.withUnsafeBufferPointer { op in
                    BlendPaint.column(peak: pk, blend: bl, open: op, from: 0, to: 1, half: 100, palette: .rgb) { j, r, g, b, _ in rows[j] = (r, g, b) }
                }
            }
        }
        return rows[10]!
    }
    let closed = row10(open: 0), held = row10(open: 255)
    #expect(closed.2 > 200 && closed.0 < 40 && closed.1 < 40)
    #expect(held.2 > 200 && held.0 > 100 && held.1 > 150)
}

/// gehaltene Tiefen: ein Kick-Anschlag ragt über das laufende Minimum (rot), eine Bassline liegt darauf (orange)
@Test func heldLowsTurnOrange() {
    // 100 Blöcke: Bassline bei 0,3, ab Block 50 Kick-Anschlag auf 0,8, der über 30 Blöcke abklingt
    var blend = [UInt8](repeating: 0, count: WaveBlend.stride * 100)
    for i in 0..<100 {
        let o = i * WaveBlend.stride
        let v: Float = i >= 50 && i < 80 ? 0.8 - Float(i - 50) / 30 * 0.5 : 0.3
        blend[o + WaveBlend.rmsSlot] = WaveBlend.byte(amplitude: v * 0.5)
        blend[o + WaveBlend.peakSlot] = WaveBlend.byte(amplitude: v)
        blend[o + WaveBlend.peakSlot + 1] = WaveBlend.byte(amplitude: 0.01)
        blend[o + WaveBlend.peakSlot + 2] = WaveBlend.byte(amplitude: 0.01)
    }
    let warm = BlendPaint.warmth(blend: blend, count: 100)
    #expect(warm[45] == 255)            // Bassline: gehalten
    #expect(warm[52] < 110)             // Anschlag: weit über dem Minimum (0,3 / 0,8)
    #expect(warm[99] > 200)             // nach dem Fenster wieder gehalten
    let body = BlendPaint.paint((0.95, 0.03, 0.02), .rgb, warm: 1)
    let hit = BlendPaint.paint((0.95, 0.03, 0.02), .rgb, warm: 0)
    #expect(body.r > 0.9 && body.g > 0.4 && body.g < 0.6)   // orange
    #expect(hit.r > 0.9 && hit.g < 0.1)                     // rot
}

/// Blöcke mit gleichen Bändern und Spitze `peaks`, Effektivwert = halbe Spitze
private func blocks(_ peaks: [Float]) -> [UInt8] {
    var blend = [UInt8](repeating: 0, count: WaveBlend.stride * peaks.count)
    for (i, pk) in peaks.enumerated() {
        let o = i * WaveBlend.stride
        blend[o + WaveBlend.rmsSlot] = WaveBlend.byte(amplitude: pk * 0.5)
        for k in 0..<3 {
            blend[o + WaveBlend.meanSlot + k] = WaveBlend.byte(amplitude: 0.1)
            blend[o + WaveBlend.peakSlot + k] = WaveBlend.byte(amplitude: 0.1)
        }
    }
    return blend
}

/// Zeilen einer Spalte: Index → Alpha
private func columnAlpha(_ peaks: [Float], from: Int, to: Int, edges: (first: Float, last: Float) = (1, 1),
                         between: BlendPaint.Between? = nil, half: Int = 100) -> [Int: UInt8] {
    let blend = blocks(peaks)
    var rows: [Int: UInt8] = [:]
    peaks.withUnsafeBufferPointer { pk in
        blend.withUnsafeBufferPointer { bl in
            BlendPaint.column(peak: pk, blend: bl, from: from, to: to, edges: edges, between: between, half: half, palette: .rgb) { j, _, _, _, a in rows[j] = a }
        }
    }
    return rows
}

/// Spalte schmaler als ein Block: Höhe steigt zwischen zwei Block-Mitten gleichmäßig (keine Stufe je Block)
@Test func narrowColumnsInterpolateBetweenBlockCenters() {
    let peaks: [Float] = [0.2, 0.6]
    let bps = 300.0
    var heights: [Int] = []
    for x in 0...10 {
        let t = (0.5 + Double(x) / 10) / bps   // Mitte von Block 0 … Mitte von Block 1
        let b = BlendPaint.Between.at(t, bps: bps, count: peaks.count)
        heights.append(columnAlpha(peaks, from: 0, to: 2, between: b).count)
    }
    #expect(heights.first == 20 && heights.last == 60)
    #expect(zip(heights, heights.dropFirst()).allSatisfy { $0 <= $1 })   // monoton
    #expect(Set(heights).count >= 8)                                     // viele Zwischenhöhen statt einer Stufe
    // Block-Mitten und Ränder
    #expect(BlendPaint.Between.at(0.5 / bps, bps: bps, count: 2).f == 0)
    #expect(BlendPaint.Between.at(0, bps: bps, count: 2).k == 0)
    #expect(BlendPaint.Between.at(5 / bps, bps: bps, count: 2).k == 1)
}

/// mehrere Blöcke je Spalte: Höhe = höchster Block; ein angeschnittener Randblock zählt nur anteilig
@Test func wideColumnsKeepMaximumAndWeighEdges() {
    let peaks: [Float] = [0.3, 0.8, 0.4, 0.5]
    #expect(columnAlpha(peaks, from: 0, to: 4).count == 80)
    // Block 1 mit 5 % angeschnitten: Höhe bleibt, oberhalb der übrigen Blöcke aber kaum Deckung
    let full = columnAlpha(peaks, from: 1, to: 4), edge = columnAlpha(peaks, from: 1, to: 4, edges: (0.05, 1))
    #expect(edge.count == full.count)
    #expect(edge[70]! < full[70]! / 4)
}

/// oberste Zeile: Alpha nach dem Bruchteil, den die Spitze erreicht; darunter voll wie bisher
@Test func topRowHasFractionalCoverage() {
    let a = columnAlpha([0.503], from: 0, to: 1, half: 100)   // Spitze bei 50,3 Zeilen
    let b = columnAlpha([0.508], from: 0, to: 1, half: 100)   // 50,8 Zeilen
    #expect(a.count == 51 && b.count == 51)
    #expect(a[50]! > 0 && a[50]! < b[50]!)
    #expect(a[10] == 255 && b[10] == 255)
    #expect(columnAlpha([0.5], from: 0, to: 1, half: 100).count == 50)   // genau auf der Kante: keine Zusatzzeile
}

/// Anzeige-Spitzen: Einzelblock-Kerben gefüllt, einzelne Spitzen bleiben
@Test func displayPeaksFillSingleBlockNotches() {
    #expect(BlendPaint.displayPeaks([0.8, 0.2, 0.7, 0.1, 0.1, 0.9, 0.1]) == [0.8, 0.7, 0.7, 0.1, 0.1, 0.9, 0.1])
    #expect(BlendPaint.displayPeaks([0.5, 0.1]) == [0.5, 0.1])
}
