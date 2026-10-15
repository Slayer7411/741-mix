import Foundation
import Testing
import MixCore
@testable import MixApp

@Test func trackPartsNormalizeAndLines() {
    #expect(TrackParts.normalized(TrackParts.standard.map(\.rawValue)) == TrackParts.standard)
    // unbekannte und doppelte raus, Zeilenwechsel ergänzt
    #expect(TrackParts.normalized(["title", "x", "title", "artist"]) == [.title, .artist, .lineBreak])
    #expect(TrackParts.normalized([]) == TrackParts.standard)
    #expect(TrackParts.normalized(["br"]) == TrackParts.standard)
    let (a, b) = TrackParts.lines(TrackParts.standard)
    #expect(a == [.title, .artist] && b == [.comment, .tags, .label])
    let (c, d) = TrackParts.lines(TrackParts.commentFirst)
    #expect(c == [.comment, .title] && d == [.artist, .tags])
    #expect(TrackParts.fields(TrackParts.standard) == [.title, .artist, .comment, .comment2, .label])
    #expect(TrackParts.moved(TrackParts.standard, .artist, by: -1).prefix(2) == [.artist, .title])
    #expect(TrackParts.moved(TrackParts.standard, .title, by: -1) == TrackParts.standard)
    #expect(TrackParts.moved(TrackParts.standard, .label, by: 1) == TrackParts.standard)
}

@Test func columnLayoutTwoLineReplacesParts() {
    var s = ColumnLayout.State()
    s.order = ["played", "info", "color", "artist", "title", "bpm", "comment", "comment2", "label", "plays"]
    s.widths = ["artist": 222, "title": 296, "comment": 224, "comment2": 314, "label": 162]
    let parts = Set(TrackParts.standard.compactMap(\.column))
    let two = ColumnLayout.twoLine(from: s, replacing: parts)
    #expect(two.order.firstIndex(of: "track") == ColumnLayout.placed(s).firstIndex(of: "artist"), "\(two.order)")
    #expect(two.order.filter { $0 == "track" }.count == 1)
    #expect(two.widths["track"] == CGFloat(222 + 296 + 224 + 314 + 162), "\(two.widths)")
    #expect(parts.allSatisfy { two.hidden[$0] == true } && two.hidden["track"] == false)
    // Rundreise im gespeicherten Format
    #expect(ColumnLayout.decode(ColumnLayout.encode(two)) == two)
}

@Test func sessionPaneKeepsRowsAndDetail() throws {
    var p = Session.Pane(source: "collection")
    p.rows = 2
    p.detailBar = true
    let back = try JSONDecoder().decode(Session.Pane.self, from: JSONEncoder().encode(p))
    #expect(back.rows == 2 && back.detailBar == true)
    let old = try JSONDecoder().decode(Session.Pane.self, from: Data(#"{"source":"collection"}"#.utf8))
    #expect(old.rows == nil && old.detailBar == nil)
}

@MainActor @Test func paneRowsFollowPrefsUnlessSet() {
    var ui = UIPrefs()
    let pane = BrowserPaneModel(name: "T")
    #expect(!pane.twoText(ui) && !pane.showsDetail(ui))
    ui.browserRows = .double
    #expect(pane.twoText(ui) && pane.showsDetail(ui))
    pane.detailBar = false
    #expect(!pane.showsDetail(ui))
    pane.twoLine = false
    ui.detailBar = .on
    #expect(!pane.twoText(ui))
    pane.detailBar = nil
    #expect(pane.showsDetail(ui))
}

@MainActor @Test func prefsOldAndNewRowFields() throws {
    // vor den Zeilen-Einstellungen gespeichert: Standard (einzeilig, automatisch, kürzen an)
    let old = AppPrefs.decode(Data(#"{"ui": {"browserRowPadding": 7}}"#.utf8))
    #expect(old.ui.browserRows == .single && old.ui.detailBar == .auto && old.ui.shortValues && old.ui.browserRowPadding == 7)
    #expect(TrackParts.normalized(old.ui.trackParts) == TrackParts.standard)
    var p = old
    p.ui.browserRows = .double
    p.ui.trackParts = TrackParts.commentFirst.map(\.rawValue)
    p.ui.shortValues = false
    p.ui.detailBar = .off
    let back = AppPrefs.decode(try JSONEncoder().encode(p))
    #expect(back == p)
}
