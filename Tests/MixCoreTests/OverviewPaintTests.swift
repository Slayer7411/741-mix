import Foundation
import Testing
@testable import MixCore

private let red = OverviewPaint.RGB(1, 0.22, 0.10), green = OverviewPaint.RGB(0.25, 0.90, 0.40), blue = OverviewPaint.RGB(0.35, 0.45, 1)

/// Übersicht aus Abschnitten (Punkte, Spitze, Bass, Mitten, Höhen)
private func overview(_ parts: [(Int, Float, Float, Float, Float)]) -> TrackOverview {
    var b: [UInt8] = []
    let q = { (v: Float) in UInt8(max(0, min(255, (v * 255).rounded()))) }
    for (n, pk, lo, mi, hi) in parts { for _ in 0..<n { b += [q(pk), q(lo), q(mi), q(hi)] } }
    return TrackOverview(duration: Double(b.count / 4), bytes: b)
}

private func dominant(_ c: OverviewPaint.RGB) -> String { c.r >= c.g && c.r >= c.b ? "r" : (c.g >= c.b ? "g" : "b") }

/// Bass-lastig -> rot, Synth-Fläche -> grün, Hats -> blau; gesättigt (kleinster Kanal deutlich unter dem größten)
@Test func paintBandsToColors() {
    let o = overview([(100, 1, 0.85, 0.12, 0.03), (100, 1, 0.25, 0.65, 0.10), (100, 1, 0.30, 0.25, 0.45)])
    let cols = OverviewPaint.columns(o, width: 300, low: red, mid: green, high: blue)
    #expect(cols.count == 300)
    #expect(dominant(cols[50].color) == "r")
    #expect(dominant(cols[150].color) == "g")
    #expect(dominant(cols[250].color) == "b")
    for c in [cols[50], cols[150], cols[250]] {
        let mx = max(c.color.r, c.color.g, c.color.b), mn = min(c.color.r, c.color.g, c.color.b)
        #expect(mn < mx * 0.5)
    }
}

/// ganzer Track bass-lastig bleibt rot getönt (Referenz = typischer Track, nicht nur der Track selbst)
@Test func paintKeepsTrackTint() {
    let bassy = overview([(320, 1, 0.80, 0.15, 0.05)]), hatty = overview([(320, 1, 0.45, 0.30, 0.25)])
    let a = OverviewPaint.columns(bassy, width: 10, low: red, mid: green, high: blue)[5].color
    let b = OverviewPaint.columns(hatty, width: 10, low: red, mid: green, high: blue)[5].color
    #expect(dominant(a) == "r")
    #expect(b.b > a.b + 0.2)
}

/// Break leiser + ohne Bass -> deutlich niedriger als der Drop; Sprung zum Drop wird gefunden
@Test func paintBreakLowerAndDropFound() {
    let o = overview([(120, 1, 0.75, 0.2, 0.05), (80, 0.6, 0.15, 0.6, 0.25), (120, 1, 0.75, 0.2, 0.05)])
    let cols = OverviewPaint.columns(o, width: 320, low: red, mid: green, high: blue)
    #expect(cols[160].amp < cols[60].amp * 0.4)
    let d = OverviewPaint.drops(o)
    #expect(d.count == 1)
    #expect(abs((d.first ?? 0) - 200.0 / 320) < 0.02)
}

/// gleichmäßiger Track: keine Drop-Linien; leere Übersicht: nichts
@Test func paintNoDropsOnFlatTrack() {
    #expect(OverviewPaint.drops(overview([(320, 0.9, 0.6, 0.3, 0.1)])).isEmpty)
    #expect(OverviewPaint.columns(TrackOverview(duration: 0, bytes: []), width: 10, low: red, mid: green, high: blue).isEmpty)
    #expect(OverviewPaint.drops(TrackOverview(duration: 0, bytes: [])).isEmpty)
}
