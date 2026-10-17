import Testing
@testable import MixApp

@Test func deckLayoutColumnsFollowSlots() {
    let def = DeckLayout.defaultSlots
    #expect(DeckLayout.columns(visible: [0, 1, 2, 3], slots: def) == ([0, 2], [1, 3]))
    #expect(DeckLayout.columns(visible: [0, 1], slots: def) == ([0], [1]))
    #expect(DeckLayout.columns(visible: [0], slots: def) == ([0], []))
    // nur rechts belegt -> links, volle Breite
    #expect(DeckLayout.columns(visible: [1, 3], slots: def, twoSideBySide: false) == ([1, 3], []))
    // B links oben, D rechts oben -> nebeneinander
    let s = DeckLayout.setting(DeckLayout.setting(def, slot: 0, deck: 1), slot: 2, deck: 3)
    #expect(Set(s) == [0, 1, 2, 3] && s[0] == 1 && s[2] == 3)
    #expect(DeckLayout.columns(visible: [1, 3], slots: s) == ([1], [3]))
    #expect(DeckLayout.normalized([0, 0, 1, 2]) == def)
}

@Test func deckLayoutVisibleAndPairDecks() {
    var p = PairSetup()
    #expect(DeckLayout.visible(deckCount: 2, pair: p) == [0, 1])
    p.on = true
    p.decks = [1, 3]
    #expect(DeckLayout.visible(deckCount: 4, pair: p) == [1, 3])
    #expect(PairSetup.toggled([1, 3], 0) == [0, 3])
    #expect(PairSetup.toggled([1], 1) == [1])
    #expect(PairSetup.toggled([1], 2) == [1, 2])
    #expect(PairSetup.valid([5, 2, 2, 0, 1]) == [0, 1])
}

@Test func pairInitiatorIsTheSmallerName() {
    #expect(PairLink.keeps(initiator: "TIO-00001", over: "TIO-00245"))
    #expect(!PairLink.keeps(initiator: "TIO-00245", over: "TIO-00001"))
    #expect(!PairLink.keeps(initiator: "TIO-00001", over: "TIO-00001"))
}

@Test func deckLayoutTwoDecksSideBySideOrStacked() {
    let def = DeckLayout.defaultSlots
    // B rechts oben, D rechts unten: nebeneinander in Platz-Reihenfolge, übereinander auf voller Breite
    #expect(DeckLayout.columns(visible: [1, 3], slots: def, twoSideBySide: true) == ([1], [3]))
    #expect(DeckLayout.columns(visible: [1, 3], slots: def, twoSideBySide: false) == ([1, 3], []))
    #expect(DeckLayout.columns(visible: [0, 1], slots: def, twoSideBySide: true) == ([0], [1]))
}
