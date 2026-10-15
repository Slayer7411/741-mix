import Foundation
import Testing
@testable import MixApp

// Gespielt zurücksetzen: nur die gewählten Tracks, Standard beim Start, Mehrfachauswahl im Baum.

/// nur die gewählten Tracks verlieren die Markierung; nichts Gespieltes oder Unbekanntes ändert sich
@Test func playedResetKeysOnlyChosenTracks() {
    let played: Set<String> = ["a", "b", "c"]
    #expect(HistoryStore.playedAfterReset(played, keys: ["b", "x"]) == ["a", "c"])
    #expect(HistoryStore.playedAfterReset(played, keys: []) == played)
    #expect(HistoryStore.playedAfterReset(played, keys: ["x"]) == played)
    #expect(HistoryStore.playedAfterReset(played, keys: played).isEmpty)
}

/// Standard an: beim Start leer; aus: der gespeicherte Stand bleibt; alte Einstellungen ohne Feld -> an
@Test func playedResetOnStartDefault() {
    #expect(UIPrefs().resetPlayedOnStart)
    #expect(AppPrefs.decode(Data(#"{"ui":{"zoom":1}}"#.utf8)).ui.resetPlayedOnStart)
    #expect(HistoryStore.playedAtStart(["a", "b"], ui: UIPrefs()).isEmpty)
    var ui = UIPrefs()
    ui.resetPlayedOnStart = false
    #expect(HistoryStore.playedAtStart(["a", "b"], ui: ui) == ["a", "b"])
}

/// Baum: ein Eintrag = die Quelle; ⌘-Klick nimmt den neuen Eintrag als Quelle; ⇧-Bereich lässt die Quelle stehen
@Test func treeSourceFollowsClick() {
    let a = BrowserSource.folder("/m/a"), b = BrowserSource.preparation, c = BrowserSource.collection
    // Einfacher Klick
    #expect(SourceTree.primary([b], marked: [a], selection: a) == b)
    // ⌘-Klick auf einen zweiten Eintrag: der neue wird Quelle
    #expect(SourceTree.primary([a, b], marked: [a], selection: a) == b)
    // ⌘-Klick auf die Quelle selbst (entfernt): ein anderer bleibt markiert
    #expect(SourceTree.primary([b], marked: [a, b], selection: a) == b)
    // ⇧-Bereich: die Quelle bleibt, wenn sie im Bereich liegt
    #expect(SourceTree.primary([a, b, c], marked: [a], selection: a) == a)
    // leer: keine Quelle
    #expect(SourceTree.primary([], marked: [a], selection: a) == nil)
}
