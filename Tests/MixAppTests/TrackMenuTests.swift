import AppKit
import Foundation
import Testing
import MixCore
@testable import MixApp

// Track-Menü: Eintragsliste für Browser-Tabelle (wie vor dem gemeinsamen Menübau) und Deck (mit Track, leer, spielend).

@MainActor private var rip: [TrackMenuItem] { [.action("Rip prüfen") {}] }

@MainActor @Test func browserMenuUnchanged() {
    let tree = [PlaylistItem.folder("Sets", [.playlist("Friday")]), .smartlist("Smart", SmartRules()), .playlist("Warmup")]
    let full = TrackMenu.BrowserFacts(hasEdits: true, hasAnalysis: true, preparation: true, ownPlaylist: true, cloud: true, playlists: tree)
    let items = TrackMenu.browserItems(full, rip: rip, TrackMenu.Actions())
    #expect(items.outline == ["In Deck A laden", "In Deck B laden", "In Deck C laden", "In Deck D laden", "—",
                              "Bearbeiten …", "Eigene Änderungen verwerfen", "—", "Bewertung ▸", "—",
                              "Analysieren", "Neu analysieren", "Analyse verwerfen", "Rip prüfen", "—",
                              "An Preparation anhängen", "Aus Preparation entfernen", "Zur Playlist hinzufügen ▸", "Aus Playlist entfernen", "—",
                              "Bereitmachen (herunterladen)", "Vorhören", "Im Finder zeigen", "Artist – Titel kopieren", "Pfad kopieren",
                              "(Nach Artist suchen)", "(Nach Label suchen)", "Alle auswählen", "—", "Reset Played State"])
    let menu = items.menu()
    let edit = menu.items[5], remove = menu.items[18]
    #expect(edit.keyEquivalent == "e" && edit.keyEquivalentModifierMask == .command)
    #expect(remove.keyEquivalent == "\u{8}" && remove.keyEquivalentModifierMask == [])
    let sub = menu.items[17].submenu?.items ?? []
    #expect(sub.map(\.title) == [OwnGlyph.folder + " Sets", "   " + OwnGlyph.playlist + " Friday", OwnGlyph.playlist + " Warmup", "",
                                 "Neue Playlist mit der Auswahl"])
    #expect(sub.first?.isEnabled == false && sub[1].isEnabled)

    let plain = TrackMenu.browserItems(TrackMenu.BrowserFacts(), rip: rip, TrackMenu.Actions())
    #expect(plain.outline == ["In Deck A laden", "In Deck B laden", "In Deck C laden", "In Deck D laden", "—",
                              "Bearbeiten …", "—", "Bewertung ▸", "—", "Analysieren", "Neu analysieren", "Rip prüfen", "—",
                              "An Preparation anhängen", "Zur Playlist hinzufügen ▸", "—", "Vorhören", "Im Finder zeigen",
                              "Artist – Titel kopieren", "Pfad kopieren", "(Nach Artist suchen)", "(Nach Label suchen)", "Alle auswählen",
                              "—", "Reset Played State"])
}

private func loaded(deck: Int = 0, decks: Int = 2, playing: Bool = false) -> TrackMenu.DeckFacts {
    TrackMenu.DeckFacts(deck: deck, decks: decks, hasTrack: true, playing: playing, revealable: true, inLibrary: true, rateable: true, rating: 3)
}

@MainActor @Test func deckMenuWithTrack() {
    let items = TrackMenu.deckItems(loaded(), rip: rip, TrackMenu.Actions())
    #expect(items.outline == ["Track bearbeiten …", "Im Browser zeigen", "Im Finder zeigen", "Pfad kopieren", "Artist – Titel kopieren", "Vorhören",
                              "Auf Deck B kopieren", "Auswerfen", "—",
                              "An Preparation anhängen", "Zur Playlist hinzufügen ▸", "—",
                              "Analysieren", "Neu analysieren", "Vorschau berechnen", "Rip prüfen", "—", "Bewertung ▸"])
    // Bewertung: aktuelle Stufe abgehakt
    guard case let .submenu(stars) = items.last?.kind else { Issue.record("Bewertung ohne Untermenü"); return }
    #expect(stars.map(\.title) == ["Keine", "★", "★★", "★★★", "★★★★", "★★★★★"])
    #expect(stars.map(\.checked) == [false, false, false, true, false, false])
}

@MainActor @Test func deckMenuFourDecksAndDAW() {
    var f = loaded(deck: 1, decks: 4)
    f.daw = ("Clip", false)
    f.hasAnalysis = true
    let o = TrackMenu.deckItems(f, rip: rip, TrackMenu.Actions()).outline
    #expect(Array(o.prefix(11)) == ["Track bearbeiten …", "Im Browser zeigen", "Im Finder zeigen", "Pfad kopieren", "Artist – Titel kopieren",
                                    "Vorhören", "Auf Deck A kopieren", "Auf Deck C kopieren", "Auf Deck D kopieren",
                                    "(Grid des DAW-Clips übernehmen (Clip))", "Auswerfen"])
    #expect(o.contains("Analyse verwerfen"))
}

@MainActor @Test func deckMenuPlayingCannotEject() {
    let o = TrackMenu.deckItems(loaded(playing: true), rip: rip, TrackMenu.Actions()).outline
    #expect(o.contains("(Auswerfen (Deck spielt))") && !o.contains("Auswerfen"))
    #expect(o.first == "Track bearbeiten …")
}

@MainActor @Test func deckMenuEmpty() {
    let empty = TrackMenu.deckItems(TrackMenu.DeckFacts(), rip: rip, TrackMenu.Actions()).outline
    #expect(empty == ["Track laden …", "—", "(Track bearbeiten …)", "(Im Browser zeigen)", "(Im Finder zeigen)", "(Auswerfen)"])
    // Ladefehler: Auswerfen leert die Meldung
    let failed = TrackMenu.deckItems(TrackMenu.DeckFacts(busy: true), rip: rip, TrackMenu.Actions()).outline
    #expect(failed.last == "Auswerfen")
}

@MainActor @Test func deckMenuOutsideLibrary() {
    let f = TrackMenu.DeckFacts(hasTrack: true)
    let o = TrackMenu.deckItems(f, rip: rip, TrackMenu.Actions()).outline
    #expect(o.contains("(Im Browser zeigen)") && o.contains("(An Preparation anhängen)") && o.contains("(Zur Playlist hinzufügen ▸)")
            && o.contains("(Bewertung ▸)"))
}

/// Ziel und Aktion direkt (ohne NSApp kein performActionForItem)
@MainActor private func fire(_ i: NSMenuItem) { _ = (i.target as? NSObject)?.perform(i.action, with: i) }

@MainActor @Test func deckMenuActionsFire() {
    var copied: [Int] = [], ejected = 0, rated: [Int] = []
    var a = TrackMenu.Actions()
    a.copy = { copied.append($0) }
    a.eject = { ejected += 1 }
    a.rate = { rated.append($0) }
    let menu = TrackMenu.deckItems(loaded(deck: 2, decks: 4), rip: rip, a).menu()
    #expect(menu.autoenablesItems == false)
    for title in ["Auf Deck A kopieren", "Auf Deck D kopieren", "Auswerfen"] {
        guard let i = menu.items.firstIndex(where: { $0.title == title }) else { Issue.record("\(title) fehlt"); continue }
        fire(menu.items[i])
    }
    if let stars = menu.items.last?.submenu { fire(stars.items[5]) }
    #expect(copied == [0, 3]); #expect(ejected == 1); #expect(rated == [5])
}
