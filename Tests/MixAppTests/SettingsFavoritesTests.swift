import Foundation
import Testing
@testable import MixApp

// Favoriten der Einstellungen (☆/★): reine Logik, Reihenfolge, unbekannte IDs; ERWEITERT und Anker im Index

@Test func favoritesToggleKeepsStarOrder() {
    var list: [String] = []
    list = SettingsFavorites.toggled(list, "decks.snap")
    list = SettingsFavorites.toggled(list, "mixer.autogain")
    list = SettingsFavorites.toggled(list, "decks.snap")          // wieder aus
    #expect(list == ["mixer.autogain"])
    list = SettingsFavorites.toggled(list, "decks.snap")          // neu markiert -> ans Ende
    #expect(list == ["mixer.autogain", "decks.snap"])
}

@Test func favoritesResolvedIgnoresUnknownAndDuplicates() {
    let known: Set<String> = ["a", "b"]
    #expect(SettingsFavorites.resolved(["b", "x", "a", "b"], known: known) == ["b", "a"])
    #expect(SettingsFavorites.resolved(["entfernt"], known: known).isEmpty)
    #expect(SettingsFavorites.resolved([], known: known).isEmpty)
}

@Test func favoriteAnchorsAreInIndex() {
    #expect(SettingsIndex.anchors.contains("decks.snap"))
    #expect(SettingsIndex.anchors.contains("general.setup"))
    #expect(!SettingsIndex.anchors.contains("gibt.es.nicht"))
    // jeder Abschnitt von ERWEITERT entspricht einem echten Abschnitt im Index
    for key in SettingsIndex.advancedSections {
        #expect(SettingsIndex.entries.contains { $0.tab + "|" + $0.section == key }, "ERWEITERT \(key) ohne Eintrag")
    }
    #expect(SettingsIndex.entries.first { $0.anchor == "decks.loopsnap.cues" }?.advanced == true)
    #expect(SettingsIndex.entries.first { $0.anchor == "decks.snap" }?.advanced == false)
}

@MainActor @Test func allgemeinIsFirstTab() {
    #expect(SettingsView.tabs.first?.id == "ALLGEMEIN")
    #expect(SettingsView.favoritesID == "FAVORITEN")
    #expect(!SettingsView.tabs.contains { $0.id == SettingsView.favoritesID })
}
