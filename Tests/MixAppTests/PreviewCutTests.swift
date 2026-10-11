import Testing
import MixCore
@testable import MixApp

// Vorhören mit Schnitt: Bereich, Startpunkt, Klick-Klemmen, Ende, Restzeit

@Test func previewCutWithoutTrimIsWholeFile() {
    let c = PreviewCut(trim: nil, duration: 300)
    #expect(c.lo == 0 && c.hi == 300 && !c.isCut)
    #expect(c.start(fraction: 0) == 0)
    #expect(c.start(fraction: 0.3) == 90)
    #expect(c.clamp(-5) == 0)
    #expect(c.clamp(400) == 300 - PreviewCut.tail)
    #expect(PreviewCut(trim: TrackTrim(), duration: 300) == c)
}

@Test func previewCutStartsInsideTheCut() {
    let c = PreviewCut(trim: TrackTrim(start: 20, end: 220), duration: 300)
    #expect(c.lo == 20 && c.hi == 220 && c.length == 200)
    #expect(c.cutStart && c.cutEnd && c.isCut)
    #expect(c.start(fraction: 0) == 20)
    #expect(c.start(fraction: 0.5) == 120)
    #expect(c.start(fraction: 2) == 220)
    #expect(c.start(fraction: .nan) == 20)
}

@Test func previewCutClampsClicksToTheNearestEdgeInside() {
    let c = PreviewCut(trim: TrackTrim(start: 20, end: 220), duration: 300)
    #expect(c.clamp(5) == 20)
    #expect(c.clamp(20) == 20)
    #expect(c.clamp(100) == 100)
    #expect(c.clamp(219.5) == 219.5)
    #expect(c.clamp(220) == 220)
    #expect(c.clamp(250) == 220 - PreviewCut.tail)
    #expect(c.clamp(.infinity) == 20)
    // sehr kurzer Schnitt: nie vor den Anfang
    let s = PreviewCut(trim: TrackTrim(start: 10, end: 10.5 + TrackTrim.minLength), duration: 300)
    #expect(s.clamp(299) >= s.lo)
}

@Test func previewCutEndAndRemaining() {
    let c = PreviewCut(trim: TrackTrim(end: 200), duration: 300)
    #expect(c.lo == 0 && c.hi == 200 && !c.cutStart && c.cutEnd)
    #expect(c.remaining(at: 150) == 50)
    #expect(c.remaining(at: 250) == 0)
    #expect(c.remaining(at: -3) == 200)
    #expect(!c.isOver(199.9))
    #expect(c.isOver(199.99) && c.isOver(260))
}

@Test func previewCutIgnoresInvalidTrim() {
    // Ende vor dem Anfang / kürzer als minLength: ganze Datei (wie das Deck)
    #expect(PreviewCut(trim: TrackTrim(start: 100, end: 100.5), duration: 300) == PreviewCut(trim: nil, duration: 300))
    #expect(PreviewCut(trim: TrackTrim(start: 400), duration: 300) == PreviewCut(trim: nil, duration: 300))
    // Rand jenseits der Datei fällt weg
    let c = PreviewCut(trim: TrackTrim(start: 30, end: 500), duration: 300)
    #expect(c.lo == 30 && c.hi == 300 && c.cutStart && !c.cutEnd)
    #expect(PreviewCut(trim: TrackTrim(start: 10), duration: .nan).length == 0)
}
