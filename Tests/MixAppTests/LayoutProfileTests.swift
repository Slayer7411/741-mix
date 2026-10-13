import Foundation
import Testing
@testable import MixApp

// Ansichts-Profile: aufnehmen / anwenden, JSON, alte Einstellungen, „geändert“

@MainActor @Test func layoutProfileCaptureApplyRoundTrip() {
    var ui = UIPrefs()
    ui.deckCount = 1
    ui.showMixer = false
    ui.showFXUnits = false
    ui.fxUnitCount = 4
    ui.compactDecks = true
    ui.deckRows.comment = false
    ui.browserLayout = .stacked
    ui.browserHeight = 512
    ui.hideTreeWithDecks = true
    ui.statusBar = .auto
    ui.waveformHeight = 90
    ui.showDeckCover = false
    ui.showCoverPreview = false
    ui.previewMode = .behindTitle
    ui.showMeters = false
    ui.waveformStyle = .mono   // gehört nicht zum Profil
    let p = LayoutProfile(name: "Test", ui: ui, maximized: true)
    #expect(p.matches(ui, maximized: true))
    #expect(!p.matches(ui, maximized: false))

    var other = UIPrefs()
    other.tagSeparators = "·"
    p.apply(to: &other)
    #expect(p.matches(other, maximized: true))
    #expect(other.deckCount == 1 && !other.showMixer && other.fxUnitCount == 4 && other.compactDecks && !other.deckRows.comment)
    #expect(other.browserLayout == .stacked && other.browserHeight == 512 && other.statusBar == .auto && other.previewMode == .behindTitle)
    // Felder außerhalb des Profils bleiben
    #expect(other.waveformStyle == UIPrefs().waveformStyle && other.tagSeparators == "·")

    // BrowserState: Browser groß kommt mit
    let browser = BrowserState()
    var ui2 = UIPrefs()
    p.apply(to: &ui2, browser: browser)
    #expect(browser.maximized)
    var q = LayoutProfile(name: "Q")
    q.capture(from: ui2, browser: browser)
    #expect(q.sameView(as: p) && q.id != p.id)
}

@MainActor @Test func layoutProfileCodable() throws {
    var ui = UIPrefs()
    ui.deckCount = 2
    ui.statusBar = .hidden
    let p = LayoutProfile(name: "Zwei", ui: ui, maximized: true)
    let back = try JSONDecoder().decode(LayoutProfile.self, from: JSONEncoder().encode(p))
    #expect(back == p)

    // ganze Einstellungen mit Profilen: Rundreise über AppPrefs.decode
    var prefs = AppPrefs()
    prefs.ui.layoutProfiles = [p] + LayoutProfile.defaults(from: prefs.ui)
    prefs.ui.activeLayoutProfile = p.id.uuidString
    let again = AppPrefs.decode(try JSONEncoder().encode(prefs))
    #expect(again == prefs)

    // Profil mit fehlenden / unbekannten Feldern: Rest Standard, Profil bleibt
    let partial = #"{"id": "\#(p.id.uuidString)", "name": "Alt", "deckCount": 1, "statusBar": "gibt es nicht", "deckRows": {"info": false}}"#
    let old = try JSONDecoder().decode(LayoutProfile.self, from: Data(partial.utf8))
    #expect(old.name == "Alt" && old.deckCount == 1 && old.id == p.id)
    #expect(old.statusBar == LayoutProfile(name: "").statusBar && !old.deckRows.info && old.deckRows.transport)
}

@MainActor @Test func layoutProfileOldPrefs() {
    // vor den Profilen gespeichert: showFourDecks statt deckCount, keine layoutProfiles
    let old = #"{"ui": {"showFourDecks": false, "showMixer": true, "browserHeight": 300, "fxUnitCount": 4}}"#
    let p = AppPrefs.decode(Data(old.utf8))
    #expect(p.ui.deckCount == 2 && !p.ui.showFourDecks && p.ui.browserHeight == 300)
    #expect(p.ui.layoutProfiles.map(\.id) == [LayoutProfile.defaultSetupID, LayoutProfile.searchID])
    #expect(p.ui.activeLayoutProfile.isEmpty && p.ui.activeProfile == nil)
    let live = p.ui.layoutProfiles[0], search = p.ui.layoutProfiles[1]
    #expect(live.deckCount == 4 && !live.showMixer && !live.showFXUnits && live.statusBar == .auto && !live.showDeckCover)
    #expect(live.deckRows.info && live.deckRows.phaseBar && live.deckRows.transport && live.deckRows.loop)
    #expect(!live.deckRows.jump && !live.deckRows.hotcues && !live.deckRows.tempo && !live.showGridTools && live.browserLayout == .sideBySide)
    #expect(live.fxUnitCount == 4)   // aus der gespeicherten Ansicht
    #expect(search.deckCount == 1 && !search.showMixer && search.browserHeight >= 500 && !search.hideTreeWithDecks)
    #expect(search.previewMode == .fullRow && search.showCoverPreview && search.statusBar == .always)

    // 4 Decks alt -> 4; ohne alles -> Standard 4 Decks, Standard-Profile
    #expect(AppPrefs.decode(Data(#"{"ui": {"showFourDecks": true}}"#.utf8)).ui.deckCount == 4)
    let none = AppPrefs.decode(Data(#"{"ui": {}}"#.utf8))
    #expect(none.ui.deckCount == 4 && none.ui.layoutProfiles.count == 2)

    // leere Liste gespeichert (alle gelöscht) bleibt leer
    let empty = AppPrefs.decode(Data(#"{"ui": {"layoutProfiles": [], "deckCount": 1}}"#.utf8))
    #expect(empty.ui.layoutProfiles.isEmpty && empty.ui.deckCount == 1)

    // 2 / 4 umschalten: von 1 Deck aus -> 4
    var ui = UIPrefs()
    ui.deckCount = 1
    ui.showFourDecks.toggle()
    #expect(ui.deckCount == 4)
    ui.showFourDecks.toggle()
    #expect(ui.deckCount == 2)
}

@MainActor @Test func layoutProfileModified() {
    let browser = BrowserState()
    var ui = UIPrefs()
    ui.layoutProfiles = LayoutProfile.defaults(from: ui)
    #expect(!ui.profileModified(maximized: false) && ui.nextProfileIndex == 0)

    ui.applyProfile(ui.layoutProfiles[1])
    #expect(ui.activeProfile?.id == LayoutProfile.searchID && ui.deckCount == 1)
    #expect(!ui.profileModified(maximized: false))
    #expect(LayoutProfiles.title(ui, maximized: false) == ui.layoutProfiles[1].name)

    // Nutzer ändert etwas -> Name bleibt, „geändert“
    ui.showMixer = true
    #expect(ui.activeProfile?.id == LayoutProfile.searchID && ui.profileModified(maximized: false))
    #expect(LayoutProfiles.title(ui, maximized: false)?.hasSuffix(" *") == true)
    // Browser groß zählt mit
    ui.showMixer = false
    #expect(!ui.profileModified(maximized: false) && ui.profileModified(maximized: true))
    // Profil aktualisieren übernimmt die Ansicht
    ui.updateProfile(nil, maximized: true)
    #expect(!ui.profileModified(maximized: true) && ui.layoutProfiles[1].browserMaximized)

    // nächstes Profil: 1 -> 0 (Ende -> Anfang), Browser groß kommt mit
    browser.maximized = true
    let next = ui.layoutProfiles[ui.nextProfileIndex ?? -1]
    #expect(next.id == LayoutProfile.defaultSetupID)
    next.apply(to: &ui, browser: browser)
    ui.applyProfile(next)
    #expect(ui.activeProfile?.id == next.id && ui.deckCount == 4 && !browser.maximized)

    // speichern unter vorhandenem Namen überschreibt, neuer Name hängt an; verschieben, löschen
    ui.statusBar = .hidden
    ui.saveProfile(name: next.name.uppercased(), maximized: false)
    #expect(ui.layoutProfiles.count == 2 && ui.layoutProfiles[0].statusBar == .hidden && ui.layoutProfiles[0].id == next.id)
    let p = ui.saveProfile(name: "Drei", maximized: false)
    #expect(ui.layoutProfiles.count == 3 && ui.activeProfile?.id == p.id && ui.nextProfileIndex == 0)
    ui.moveProfile(p.id, by: -1)
    #expect(ui.layoutProfiles[1].id == p.id)
    ui.moveProfile(ui.layoutProfiles[0].id, by: -1)   // schon oben: nichts
    #expect(ui.layoutProfiles[1].id == p.id)
    ui.deleteProfile(p.id)
    #expect(ui.layoutProfiles.count == 2 && ui.activeProfile == nil && !ui.profileModified(maximized: false))
}
