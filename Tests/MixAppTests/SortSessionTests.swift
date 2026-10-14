import Foundation
import Testing
import MixCore
@testable import MixApp

/// Sitzung: alle Sortierspalten als `sorts` (`bpm:desc`), ältere Stände nur `sort` / `ascending`
@Test func sessionPaneKeepsAllSortKeys() throws {
    var p = Session.Pane(source: "collection", sort: "bpm", ascending: false)
    p.sorts = ["bpm:desc", "comment:desc", "artist:asc"]
    let data = try JSONEncoder().encode(p)
    let back = try JSONDecoder().decode(Session.Pane.self, from: data)
    #expect(back.sorts == ["bpm:desc", "comment:desc", "artist:asc"] && back.sort == "bpm" && back.ascending == false)
    // ohne `sorts` (alte Datei) bleibt die eine Spalte
    let old = try JSONDecoder().decode(Session.Pane.self, from: Data(#"{"source":"collection","sort":"title","ascending":true}"#.utf8))
    #expect(old.sorts == nil && old.sort == "title")
    let c = try #require(Session.comparator("comment", ascending: false))
    #expect(Session.sortName(c) == "comment" && c.order == .reverse)
}
