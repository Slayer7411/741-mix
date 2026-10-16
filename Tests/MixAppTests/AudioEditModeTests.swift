import Foundation
import Testing
@testable import MixApp

// Audio-Edit-Modus: Ansicht (ein Deck, Zeilen, Übersicht) und Rückkehr zur gemerkten Ansicht

@MainActor @Test func audioEditProfileShowsWorkRowsAndRestoresView() {
    var ui = UIPrefs()
    ui.deckCount = 4
    ui.showMixer = true
    ui.browserHeight = 410
    ui.overviewHeight = 18
    ui.deckRows.comment = true
    ui.deckRows.transport = true
    let before = LayoutProfile(name: "", ui: ui, maximized: false)

    var on = ui
    LayoutProfile.audioEdit(from: ui).apply(to: &on)
    #expect(on.deckCount == 1 && !on.showMixer && !on.showFXUnits)
    #expect(on.deckRows.prepare && on.deckRows.hotcues && on.deckRows.overview && on.deckRows.info)
    #expect(!on.deckRows.transport && !on.deckRows.comment && !on.deckRows.loop && !on.deckRows.phaseBar)
    #expect(on.overviewHeight >= 48 && on.browserHeight == 300 && !on.showGridTools)
    #expect(on.activeLayoutProfile == ui.activeLayoutProfile)

    // Verlassen: die gemerkte Ansicht kommt zurück, genau
    var back = on
    before.apply(to: &back)
    #expect(LayoutProfile(name: "", ui: back, maximized: false).sameView(as: before))
    #expect(back.deckCount == 4 && back.browserHeight == 410 && back.deckRows.transport)
}

@MainActor @Test func audioEditProfileIsNotAProfileOfTheList() {
    let ui = UIPrefs()
    #expect(!LayoutProfile.defaults(from: ui).contains { $0.id == LayoutProfile.audioEditID })
    #expect(LayoutProfile.audioEdit(from: ui).id == LayoutProfile.audioEditID)
}
