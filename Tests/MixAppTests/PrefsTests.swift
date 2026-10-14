import Foundation
import Testing
import MixEngine
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
    #expect(ui.compactDecks)   // Standard: kompakte Decks (Readouts, Kommentar, Tags, Phase, Übersicht, Transport, Loop)
    #expect(ui.deckRows.info && ui.deckRows.comment && ui.deckRows.tags && ui.deckRows.phaseBar && ui.deckRows.overview
            && ui.deckRows.transport && ui.deckRows.loop && !ui.deckRows.jump && !ui.deckRows.groove)
    ui.compactDecks = false
    #expect(ui.deckRows.tempo && ui.deckRows.hotcues && ui.showGridTools)
    ui.compactDecks = true
    #expect(!ui.deckRows.tempo && !ui.deckRows.hotcues && !ui.showGridTools)
    #expect(ui.deckRows.comment && ui.deckRows.tags && ui.deckRows.loop)
    ui.deckRows.info = false
    ui.showAllDeckRows()
    let r = ui.deckRows   // „alle Zeilen“: wirklich alle, auch die im Standard ausgeschalteten
    #expect(r.info && r.comment && r.tags && r.phaseBar && r.overview && r.transport && r.hotcues && r.loop && r.jump && r.tempo && r.groove)
    #expect(ui.showGridTools && !ui.compactDecks)
    // jede Zeile genau einmal in Menü und Einstellungen
    #expect(Set(DeckRows.all.map(\.1)).count == DeckRows.all.count && DeckRows.all.count == 13)   // mit Vorbereiten (bleibt bei „alle Zeilen“ aus)
}

// Aufnahme: Standard (automatische Quelle, Apple Lossless, Pegel aus) und alte Einstellungen ohne `record`
@MainActor @Test func recordPrefsDefaultsAndOldPrefs() throws {
    let old = AppPrefs.decode(Data(#"{"ui": {"zoom": 1.1}}"#.utf8))
    #expect(old.record == RecordPrefs() && old.ui.zoom == 1.1)
    #expect(old.record.source == .auto && old.record.format == .alac && !old.record.showInputLevel && old.record.inputUID.isEmpty)
    #expect(old.record.folderURL.path.hasSuffix("/MINOS-741/Recordings"))
    var p = old
    p.record.source = .input; p.record.inputFirstChannel = 2; p.record.format = .aiff; p.record.showInputLevel = true; p.record.folder = "/tmp/rec"
    let again = AppPrefs.decode(try JSONEncoder().encode(p))
    #expect(again.record == p.record && again.record.folderURL.path == "/tmp/rec")
    // teilweise gespeichert: fehlende Felder bekommen den Standard
    let part = AppPrefs.decode(Data(#"{"record": {"source": "master"}}"#.utf8))
    #expect(part.record.source == .master && part.record.format == .alac)
}
/// Linien des Beatgrids: Standard fein; alte Einstellungen ohne das Feld laden fein, kräftig bleibt nach der Rundreise
@MainActor @Test func gridLineWeightDefaultsToFine() throws {
    #expect(UIPrefs().gridLineWeight == .fine)
    let old = AppPrefs.decode(Data(#"{"ui": {"colorfulGrid": false, "barMarkers": false}}"#.utf8))
    #expect(old.ui.gridLineWeight == .fine && !old.ui.colorfulGrid && !old.ui.barMarkers)
    var p = AppPrefs()
    p.ui.gridLineWeight = .bold
    #expect(AppPrefs.decode(try JSONEncoder().encode(p)).ui.gridLineWeight == .bold)
    // unbekannter Wert (späteres Update) -> Standard, Rest bleibt
    let odd = AppPrefs.decode(Data(#"{"ui": {"gridLineWeight": "xyz", "zoom": 1.25}}"#.utf8))
    #expect(odd.ui.gridLineWeight == .fine && odd.ui.zoom == 1.25)
}

// Auto-Loop beim Laden: Standard 16 Takte, alte Einstellungen ohne das Feld bekommen ihn, gespeicherte Werte bleiben
@MainActor @Test func autoLoopPrefDefaultAndOldPrefs() throws {
    let old = AppPrefs.decode(Data(#"{"engine": {"snap": false, "defaultLoopSize": 8}}"#.utf8))
    #expect(old.engine.autoLoopBars == 16 && !old.engine.snap && old.engine.defaultLoopSize == 8)
    var p = old
    p.engine.autoLoopBars = 0
    #expect(AppPrefs.decode(try JSONEncoder().encode(p)).engine.autoLoopBars == 0)
    p.engine.autoLoopBars = 32
    #expect(AppPrefs.decode(try JSONEncoder().encode(p)).engine.autoLoopBars == 32)
}

/// Einstellungen von vor den Insert-Slots: gemerkte Gruppen-Belegung wird Rack-Belegung, gemerkte Plugin-Ketten bleiben (als Racks)
@MainActor @Test func prefsMigrateFXMappingsAndChains() throws {
    let old = """
    {"engine": {"fxMappings": {"GROUP": {"k1": "reverb.size", "b2": "delay.time"}, "DELAY": {"k1": "rate"}},
                "pluginChains": {"LP": [{"id": "aufx:lpas:appl", "on": false}]}}}
    """
    let p = AppPrefs.decode(Data(old.utf8))
    #expect(p.engine.fxMappings["FILTER > DELAY > REVERB"]?.targets == ["k1": "s2.size", "b2": "s1.rate"])
    #expect(p.engine.fxMappings["GROUP"] == nil && p.engine.fxMappings["DELAY"]?.targets == ["k1": "rate"])
    #expect(p.engine.pluginChains["LP"]?.map(\.id) == ["aufx:lpas:appl"] && p.engine.pluginChains["LP"]?.first?.on == false)
}
