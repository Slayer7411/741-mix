import Foundation
import Testing
@testable import MixApp

// Hilfe-Modus: jeder Eintrag hat Deutsch und Englisch; aus = keine Karte, Hover ohne Modus ohne Wirkung

@MainActor @Test func helpTableHasBothLanguages() {
    #expect(!HelpTable.entries.isEmpty)
    for (id, e) in HelpTable.entries {
        #expect(!e.title.de.isEmpty && !e.title.en.isEmpty, "Titel fehlt: \(id)")
        #expect(!e.body.de.isEmpty && !e.body.en.isEmpty, "Text fehlt: \(id)")
    }
}

@MainActor @Test func helpTableCoversMainControls() {
    let ids = ["topbar.help", "clock.link", "clock.master", "deck.cup", "deck.sync", "deck.master", "deck.keylock", "deck.loop",
               "deck.loopIn", "deck.hotcue", "deck.fxAssign", "mixer.fader", "browser.tags", "browser.played", "browser.matching",
               "tree.collection", "tree.playlists", "fx.slot"]
    for id in ids { #expect(HelpTable.entries[id] != nil, "Id ohne Text: \(id)") }
}

@MainActor @Test func helpModeOffShowsNothing() {
    let h = HelpMode.shared
    h.enabled = false
    h.hover("deck.sync", true)
    #expect(h.shown == nil)
    h.hover("deck.sync", false)
    #expect(h.shown == nil)
}

@MainActor @Test func helpModeOnWaitsForDelay() {
    let h = HelpMode.shared
    h.enabled = true
    defer { h.enabled = false }
    h.hover("deck.sync", true)
    // vor Ablauf der Wartezeit keine Karte; Verlassen bricht den Timer ab
    #expect(h.shown == nil)
    h.hover("deck.sync", false)
    #expect(h.shown == nil)
    // Ausschalten räumt auf
    h.hover("deck.cup", true)
    h.enabled = false
    #expect(h.shown == nil)
}
