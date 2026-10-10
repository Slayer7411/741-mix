import Testing
@testable import MixCore

@Test func phraseCodeAligned() {
    // Deck Takt 5 (Beat 16), Zähler Takt 13 (Beat 48): 8-Takt-Phrase -> beide 5/8
    let c = PhraseCode(deckBeat: 16.2, sessionBeat: 48.1, phraseBars: 8)
    #expect(c.bar == 5)
    #expect(c.offsetBeats == 0)
    #expect(c.aligned)
    #expect(c.offsetLabel == nil)
}

@Test func phraseCodeOffset() {
    // Deck zwei Takte voraus
    let c = PhraseCode(deckBeat: 24, sessionBeat: 16, phraseBars: 8)
    #expect(c.bar == 7)
    #expect(c.offsetBeats == 8)
    #expect(!c.aligned)
    #expect(c.offsetLabel == "+2 BARS")
    // drei Takte zurück, ein Takt / Beats
    #expect(PhraseCode(deckBeat: 4, sessionBeat: 16, phraseBars: 8).offsetLabel == "\u{2212}3 BARS")
    #expect(PhraseCode(deckBeat: 20, sessionBeat: 16, phraseBars: 8).offsetLabel == "+1 BAR")
    #expect(PhraseCode(deckBeat: 19, sessionBeat: 16, phraseBars: 8).offsetLabel == "+3 BEATS")
    #expect(PhraseCode(deckBeat: 15.6, sessionBeat: 16, phraseBars: 8).offsetLabel == nil)   // knapp vor dem Beat = im Code
}

@Test func phraseCodeWrap() {
    // 8 Takte = 32 Beats: Abweichung −15 … +16 Beats (−3 … +4 Takte)
    #expect(PhraseCode.wrap(16, beats: 32) == 16)
    #expect(PhraseCode.wrap(17, beats: 32) == -15)
    #expect(PhraseCode.wrap(-16, beats: 32) == 16)
    #expect(PhraseCode.wrap(-12, beats: 32) == -12)
    #expect(PhraseCode.wrap(64 + 8, beats: 32) == 8)
    #expect(PhraseCode(deckBeat: 0, sessionBeat: 20, phraseBars: 8).offsetLabel == "+3 BARS")   // −5 Takte = +3
    #expect(PhraseCode(deckBeat: 0, sessionBeat: 16, phraseBars: 8).offsetLabel == "+4 BARS")
    // vor dem Anker (negative Beats) und ohne Zähler
    let c = PhraseCode(deckBeat: -3, sessionBeat: nil, phraseBars: 4)
    #expect(c.bar == 4)
    #expect(c.offsetBeats == nil)
    #expect(!c.aligned)
}

/// Phrasen-Anker: Anker um ganze Beats verschoben -> Start-Cue bleibt am Collection-Anker; feine Verschiebung -> Start-Cue folgt
@Test func phraseAnchorEditKeepsStartCue() {
    var t = Track(key: "k", path: "/x")
    t.bpm = 120   // Beat = 500 ms
    t.cues = [Cue(name: "AutoGrid", kind: .grid, startMs: 1000, lengthMs: 0, hotcue: -1)]
    let renumbered = TrackEdit(gridAnchorMs: 1000 - 3 * 500).apply(to: t)
    #expect(renumbered.gridAnchorMs == -500)
    #expect(renumbered.cues.first { $0.kind == .load }?.startMs == 1000)
    let nudged = TrackEdit(gridAnchorMs: 1010).apply(to: t)
    #expect(nudged.cues.first { $0.kind == .load } == nil)
    #expect(BeatGrid(track: renumbered)!.time(ofBeat: 3) == 1.0)   // Raster bleibt, nur die Zählung wandert
}
