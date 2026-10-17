import Foundation
import Testing
import MixCore
@testable import MixApp

// Live-Lesbarkeit der Track-Liste: Spalten-Override ohne Änderung der gespeicherten Anordnung, Zeilenhöhe,
// Breiten, Schalter (von Hand / bei LIVE), Standardwerte

@Test @MainActor func liveListWritesNothingToTheNormalLayout() {
    let normal = ColumnLayout.State(order: ["played", "title", "artist", "genre"], widths: ["title": 240], hidden: ["genre": false])
    let suite = "live-list-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: suite)!
    defer { d.removePersistentDomain(forName: suite) }
    let key = LiveList.storageKey(name: "Browser A", twoText: false, live: false)
    #expect(key == "columns.Browser A")
    d.set(ColumnLayout.encode(normal), forKey: key!)
    // Live-Modus: kein Schlüssel, also weder lesen noch schreiben
    #expect(LiveList.storageKey(name: "Browser A", twoText: false, live: true) == nil)
    // Ende des Live-Modus: die normale Anordnung ist unverändert da
    #expect(d.data(forKey: key!).flatMap(ColumnLayout.decode) == normal)
    // zweizeilig hat eine eigene Anordnung
    #expect(LiveList.storageKey(name: "Browser A", twoText: true, live: false) == "columns.Browser A.2")
    #expect(LiveList.storageKey(name: "Browser A", twoText: true, live: true) == nil)
}

@Test @MainActor func liveColumnSetIsArtistTitleBpmKeyTime() {
    #expect(LiveList.columns == ["played", "artist", "title", "bpm", "key", "time"])
    #expect(LiveList.columns.allSatisfy { TrackColumn.byID[$0] != nil })
}

@Test @MainActor func liveRowHeightGrowsWithText() {
    #expect(LiveList.rowHeight(14) == 22)
    let hs = (11...18).map { LiveList.rowHeight(CGFloat($0)) }
    #expect(zip(hs, hs.dropFirst()).allSatisfy { $0 < $1 })
    // Luft über der Schrift: Zeile mindestens 1,5 × Schrift
    #expect((11...18).allSatisfy { CGFloat($0) * 1.5 <= LiveList.rowHeight(CGFloat($0)) })
}

@Test @MainActor func liveTextSizeIsClampedToRange() {
    #expect(LiveList.clampSize(5) == 11)
    #expect(LiveList.clampSize(40) == 18)
    #expect(LiveList.clampSize(14) == 14)
}

@Test @MainActor func liveWidthsFitTheText() {
    let s: CGFloat = 14
    let bpm = LiveList.width("bpm", size: s), time = LiveList.width("time", size: s)
    // feste Spalten, Platz für „128.00“ (fett) und „12:34“
    #expect(bpm.min == bpm.max && time.min == time.max)
    #expect(bpm.ideal >= 6 * LiveList.advance(s + 1))
    #expect(time.ideal >= 5 * LiveList.advance(s))
    // Artist nach oben begrenzt, Title füllt den Rest der Tabelle
    let artist = LiveList.width("artist", size: s), title = LiveList.width("title", size: s)
    #expect(artist.min < artist.ideal && artist.ideal <= artist.max && artist.max < .greatestFiniteMagnitude)
    #expect(title.min < title.ideal && title.max == .greatestFiniteMagnitude)
}

@Test func liveWeightsMapToBundledFaces() {
    #expect(LiveListWeight.allCases.map(\.fontName) == ["IBMPlexMono-Regular", "IBMPlexMono-Medium", "IBMPlexMono-SemiBold"])
}

@Test @MainActor func liveListFollowsLiveAndManualSwitch() {
    var p = UIPrefs()
    #expect(p.liveListOn(live: false) == false)
    // Standard: bei LIVE automatisch
    #expect(p.liveListOn(live: true) == true)
    p.liveListAuto = false
    #expect(p.liveListOn(live: true) == false)
    // von Hand an, auch ohne LIVE
    p.liveList = true
    #expect(p.liveListOn(live: false) == true)
}

@Test @MainActor func liveDefaultsAreReadable() {
    let p = UIPrefs()
    #expect(p.liveList == false && p.liveListAuto == true && p.liveListStripes == true)
    #expect(p.liveListTextSize == 14 && p.liveListWeight == .medium)
    // alte Einstellungen ohne die Felder bekommen die Standardwerte
    let old = AppPrefs.decode(Data(#"{"ui":{"zoom":1}}"#.utf8))
    #expect(old.ui.liveListAuto == true && old.ui.liveListWeight == .medium && old.ui.liveListTextSize == 14)
}
