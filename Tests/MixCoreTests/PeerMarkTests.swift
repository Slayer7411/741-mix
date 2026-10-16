import Testing
@testable import MixCore

@Test func peerMarkOffsetSameBeatIsZero() {
    // Deck B genau auf dem Beat von Deck A: Marke liegt auf dem Spielkopf
    #expect(PeerMark.offsetBeats(own: 40.25, other: 40.25, phraseBeats: 32) == 0)
    // eine Phrase weiter = gleiche Stelle in der Phrase
    #expect(PeerMark.offsetBeats(own: 40, other: 72, phraseBeats: 32) == 0)
    #expect(PeerMark.inPhase(0.04))
    #expect(PeerMark.inPhase(-1.0 / 16))
    #expect(!PeerMark.inPhase(0.1))
}

@Test func peerMarkOffsetPositions() {
    // B drei Beats voraus, B eineinhalb Beats zurück (fraktionale Positionen bleiben erhalten)
    #expect(PeerMark.offsetBeats(own: 10, other: 13, phraseBeats: 32) == 3)
    #expect(PeerMark.offsetBeats(own: 10, other: 8.5, phraseBeats: 32) == -1.5)
    #expect(PeerMark.offsetBeats(own: 10, other: 10.0625, phraseBeats: 32) == 0.0625)
}

@Test func peerMarkOffsetWrapsToHalfPhrase() {
    // 32 Beats: Abweichung −15 … +16 (wie der Code)
    #expect(PeerMark.offsetBeats(own: 0, other: 16, phraseBeats: 32) == 16)
    #expect(PeerMark.offsetBeats(own: 0, other: 17, phraseBeats: 32) == -15)
    #expect(PeerMark.offsetBeats(own: 0, other: -16, phraseBeats: 32) == 16)
    #expect(PeerMark.offsetBeats(own: 0, other: -12, phraseBeats: 32) == -12)
    #expect(PeerMark.offsetBeats(own: 0, other: 72, phraseBeats: 32) == 8)
    #expect(PeerMark.offsetBeats(own: 0, other: 80, phraseBeats: 32) == 16)
    // 64 Beats: 100 Beats voraus liegen 28 Beats zurück
    #expect(PeerMark.offsetBeats(own: 100, other: 0, phraseBeats: 64) == 28)
    // Phrase unter einem Beat: kein Absturz, Länge mindestens 1
    #expect(PeerMark.offsetBeats(own: 0, other: 5, phraseBeats: 0) == 0)
}

@Test func peerMarkPixelMapping() {
    // 128 BPM: Beat 0,46875 s, 100 Punkte je s → 2 Beats = 93,75 Punkte
    let beat = 60.0 / 128
    let p = PeerMark.place(offsetBeats: 2, beatSeconds: beat, pointsPerSecond: 100, limit: 400)
    #expect(abs(p.dx - 93.75) < 1e-9)
    #expect(!p.clamped)
    // links: Vorzeichen bleibt, doppelte Punkte je s (Zoom) verdoppeln den Abstand
    let q = PeerMark.place(offsetBeats: -2, beatSeconds: beat, pointsPerSecond: 200, limit: 400)
    #expect(abs(q.dx + 187.5) < 1e-9)
    // außerhalb des sichtbaren Streifens: am Rand geklemmt
    let far = PeerMark.place(offsetBeats: 16, beatSeconds: beat, pointsPerSecond: 100, limit: 200)
    #expect(far.clamped && far.dx == 200)
    let back = PeerMark.place(offsetBeats: -16, beatSeconds: beat, pointsPerSecond: 100, limit: 200)
    #expect(back.clamped && back.dx == -200)
    // genau am Rand noch nicht geklemmt
    #expect(!PeerMark.place(offsetBeats: 0, beatSeconds: beat, pointsPerSecond: 100, limit: 0).clamped)
}

@Test func peerMarkLabel() {
    #expect(PeerMark.label(0.2) == nil)
    #expect(PeerMark.label(8.4) == "+2 BARS")
    #expect(PeerMark.label(-11.6) == "\u{2212}3 BARS")
    #expect(PeerMark.label(3) == "+3 BEATS")
    #expect(PeerMark.label(-1) == "\u{2212}1 BEAT")
}
