import Foundation
import Testing
import MixCore
@testable import MixApp

// Spalten-Anordnung der Track-Tabelle (`columns.<bereich>`): gleiches JSON wie die frühere SwiftUI-Tabelle.

/// gespeichert von der SwiftUI-Tabelle (TableColumnCustomization), ohne „played“, „cloud“, „cover“, „preview“, „mix“
private let swiftUISaved = """
{"columnOrder":[{"base":{"explicit":{"_0":"analyzed"}}},{"base":{"explicit":{"_0":"color"}}},\
{"base":{"explicit":{"_0":"comment"}}},{"base":{"explicit":{"_0":"title"}}},{"base":{"explicit":{"_0":"artist"}}},\
{"base":{"explicit":{"_0":"bpm"}}},{"base":{"explicit":{"_0":"gone"}}}],\
"perColumnState":[{"base":{"explicit":{"_0":"artist"}}},{"visibility":{"automatic":{}},"currentWidth":230},\
{"base":{"explicit":{"_0":"comment"}}},{"visibility":{"hidden":{}},"currentWidth":167.5},\
{"base":{"explicit":{"_0":"bpm"}}},{"visibility":{"visible":{}}}]}
"""

@Test func columnLayoutReadsSwiftUIFormat() throws {
    let s = try #require(ColumnLayout.decode(Data(swiftUISaved.utf8)))
    #expect(s.order == ["analyzed", "color", "comment", "title", "artist", "bpm", "gone"])
    #expect(s.widths == ["artist": 230, "comment": 167.5])
    #expect(s.hidden == ["comment": true, "bpm": false])
}

@Test func columnLayoutPlacesNewColumns() throws {
    let order = ColumnLayout.placed(try #require(ColumnLayout.decode(Data(swiftUISaved.utf8))))
    // unbekannte raus, played vorne, cloud dahinter, cover neben die Farbe, preview hinter den Titel, Rest hinten
    #expect(Array(order.prefix(9)) == ["played", "cloud", "analyzed", "color", "cover", "comment", "title", "preview", "artist"])
    #expect(!order.contains("gone"))
    #expect(Set(order) == Set(TrackColumn.all.map(\.id)))
    #expect(order.count == TrackColumn.all.count)
}

@Test func columnLayoutRoundTrip() throws {
    var s = ColumnLayout.State()
    s.order = TrackColumn.all.map(\.id).reversed()
    s.widths = ["artist": 180, "title": 222.5]
    s.hidden = ["cover": false, "label": true]
    #expect(ColumnLayout.decode(ColumnLayout.encode(s)) == s)
    // leer oder kaputt: Standard-Reihenfolge
    #expect(ColumnLayout.placed(ColumnLayout.State()) == TrackColumn.all.map(\.id))
    #expect(ColumnLayout.decode(Data("nicht json".utf8)) == nil)
}

/// Hintergrund-Liste: gleiche Zeilen wie sofort gefiltert (Rollen, Tags, Suche)
@Test func listFilterMatchesCriteria() {
    func t(_ k: String, _ c2: String, _ title: String) -> Track {
        var x = Track(key: k, path: "/\(k).mp3")
        x.comment2 = c2
        x.title = title
        x.buildSearchText()
        return x
    }
    let base = [t("a", "» BASIS · tief", "Night"), t("b", "» SYNTH · hoch", "Day"), t("c", "» basis · hoch", "Nightfall")]
    var c = BrowserPaneModel.Criteria()
    c.separators = "·"
    c.roles = [.basis]
    #expect(BrowserPaneModel.filtered(base, c, index: .init()).map(\.path) == ["/a.mp3", "/c.mp3"])
    c.words = [Track.fold("nightf")]
    #expect(BrowserPaneModel.filtered(base, c, index: .init()).map(\.path) == ["/c.mp3"])
    c = BrowserPaneModel.Criteria()
    c.separators = "·"
    c.tags = .init(include: ["hoch"], exclude: ["» SYNTH"])
    #expect(BrowserPaneModel.filtered(base, c, index: .init()).map(\.path) == ["/c.mp3"])
}
