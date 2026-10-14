import Foundation
import Testing
@testable import MixApp

// Gespeicherte Einstellungen (prefs.v1) von vor einer neuen Deck-Zeile laden weiter: neue Felder bekommen ihren
// Standard, gespeicherte Werte bleiben.

@MainActor @Test func prefsWithoutNewDeckRowsKeepSavedValues() throws {
    // wie vor Kommentar/Tags im Deck-Kopf: deckRows ohne comment/tags, Pitch-Fader und Hotcues aus
    let old = """
    {"ui": {"showGridTools": false, "tagSeparators": "·",
            "deckRows": {"info": true, "phaseBar": false, "overview": true, "transport": true,
                         "hotcues": false, "loop": true, "jump": true, "tempo": false}}}
    """
    let p = AppPrefs.decode(Data(old.utf8))
    let r = p.ui.deckRows
    #expect(r.comment && r.tags)
    #expect(!r.tempo && !r.hotcues && !r.phaseBar && r.info && r.loop)
    #expect(!p.ui.showGridTools && p.ui.tagSeparators == "·")
    #expect(p.ui.compactDecks)

    // ganz ohne deckRows: alle Zeilen an
    let none = AppPrefs.decode(Data(#"{"ui": {"zoom": 1.25}}"#.utf8))
    #expect(none.ui.deckRows == DeckRows() && none.ui.zoom == 1.25)

    // neu gespeichert und wieder geladen: gleich
    let again = AppPrefs.decode(try JSONEncoder().encode(p))
    #expect(again == p)
}

@MainActor @Test func compactDecksAndAllRows() {
    var ui = UIPrefs()
    #expect(!ui.compactDecks)
    ui.compactDecks = true
    #expect(!ui.deckRows.tempo && !ui.deckRows.hotcues && !ui.showGridTools)
    #expect(ui.deckRows.comment && ui.deckRows.tags && ui.deckRows.loop)
    ui.deckRows.info = false
    ui.showAllDeckRows()
    var all = DeckRows()
    all.groove = true   // Standard aus, „alle Zeilen“ schaltet sie mit ein
    #expect(ui.deckRows == all && ui.showGridTools && !ui.compactDecks)
    // jede Zeile genau einmal in Menü und Einstellungen
    #expect(Set(DeckRows.all.map(\.1)).count == DeckRows.all.count && DeckRows.all.count == 12)
}
