import Foundation
import Testing
import MixCore
@testable import MixApp

// Gespielte Tracks ausblenden (◆ UNGESPIELT) und Reihenfolge der Einstellungs-Bereiche.

private func track(_ k: String, _ title: String) -> Track {
    var t = Track(key: k, path: "/\(k).mp3")
    t.title = title
    t.buildSearchText()
    return t
}

/// gespielter Track fällt aus Collection, Playlists, Smartlists, Ordnern und der Suche; gezählt wird nach den anderen Filtern
@Test func playedTracksHidden() {
    let base = [track("a", "Night"), track("b", "Day"), track("c", "Nightfall")]
    let played: Set<String> = ["b", "c"]
    for src in [BrowserSource.collection, .own(OwnRef(PlaylistItem(name: "x", kind: .smartlist))), .folder("/m"), .cuts] {
        var c = BrowserPaneModel.Criteria()
        c.exclude = BrowserPaneModel.hiddenKeys(source: src, played: played, hidePlayed: true)
        let r = BrowserPaneModel.filteredCounting(base, c, index: .init())
        #expect(r.rows.map(\.key) == ["a"] && r.hidden == 2)
        c.words = [Track.fold("night")]
        let s = BrowserPaneModel.filteredCounting(base, c, index: .init())
        #expect(s.rows.map(\.key) == ["a"] && s.hidden == 1)
        #expect(BrowserPaneModel.filtered(base, c, index: .init()).map(\.key) == ["a"])
    }
    // aus oder nichts gespielt: kein Filter
    #expect(BrowserPaneModel.hiddenKeys(source: .collection, played: played, hidePlayed: false) == nil)
    #expect(BrowserPaneModel.hiddenKeys(source: .collection, played: [], hidePlayed: true) == nil)
    var c = BrowserPaneModel.Criteria()
    #expect(BrowserPaneModel.filteredCounting(base, c, index: .init()).hidden == 0)
    c.exclude = []
    #expect(BrowserPaneModel.filteredCounting(base, c, index: .init()).rows.count == 3)
}

/// History, RUNNING und Preparation (+ Archiv) zeigen gespielte Tracks weiter
@Test func historyAndPreparationKeepPlayed() {
    let played: Set<String> = ["b"]
    let session = HistorySession(url: URL(fileURLWithPath: "/tmp/history_2026-10-14-01.nml"), date: Date(), source: .live)
    for src in [BrowserSource.historyLive, .history(session), .running, .preparation, .prepArchive(session)] {
        #expect(!BrowserPaneModel.hidesPlayed(in: src))
        #expect(BrowserPaneModel.hiddenKeys(source: src, played: played, hidePlayed: true) == nil)
    }
    #expect(BrowserPaneModel.hidesPlayed(in: .collection))
}

/// Kürzel frei belegbar, Gruppe BROWSER, ID bleibt
@Test func hidePlayedShortcut() {
    #expect(ShortcutID.hidePlayed.rawValue == "browser.hideplayed")
    #expect(ShortcutID.hidePlayed.group == .browser && ShortcutID.hidePlayed.defaultCombo == nil)
    var m = ShortcutMap(overrides: [:])
    m.set(.hidePlayed, KeyCombo("u", [.option, .command]))
    #expect(m.action(for: KeyCombo("u", [.option, .command])) == .hidePlayed)
}

/// Standard allgemein -> speziell; gespeicherte Reihenfolge, unbekannte fallen weg, neue stehen hinter dem Vorgänger
@MainActor @Test func settingsTabOrder() {
    let ids = SettingsView.tabs.map(\.id)
    #expect(ids == ["ALLGEMEIN", "AUDIO", "DECKS", "MIXER & FX", "PLUGINS", "BROWSER", "ANZEIGE", "CONTROLLER", "LIVE & SYNC", "TASTATUR", "CLOUD"])
    #expect(SettingsView.ordered([]).map(\.id) == ids)
    #expect(SettingsTabOrder.merged(["C", "X", "A"], defaults: ["A", "B", "C", "D"]) == ["C", "D", "A", "B"])
    #expect(SettingsTabOrder.merged([], defaults: ["A", "B"]) == ["A", "B"])
    #expect(SettingsTabOrder.moved(["A", "B", "C"], "C", before: "A") == ["C", "A", "B"])
    #expect(SettingsTabOrder.moved(["A", "B", "C"], "A", before: nil) == ["B", "C", "A"])
    #expect(SettingsTabOrder.moved(["A", "B", "C"], "B", before: "B") == ["A", "B", "C"])
    #expect(SettingsTabOrder.moved(["A", "B"], "fremd", before: "A") == ["A", "B"])
    #expect(SettingsView.ordered(["CONTROLLER", "AUDIO"]).map(\.id).filter { ["CONTROLLER", "AUDIO"].contains($0) } == ["CONTROLLER", "AUDIO"])
}

/// neues Feld: alte Einstellungen ohne Reihenfolge -> Standard, gespeicherte bleiben
@Test func settingsTabOrderDecodes() throws {
    var p = AppPrefs()
    #expect(p.ui.settingsTabOrder.isEmpty)
    p.ui.settingsTabOrder = ["BROWSER", "AUDIO"]
    let back = AppPrefs.decode(try JSONEncoder().encode(p))
    #expect(back.ui.settingsTabOrder == ["BROWSER", "AUDIO"])
    #expect(AppPrefs.decode(Data(#"{"ui":{"zoom":1}}"#.utf8)).ui.settingsTabOrder.isEmpty)
}
