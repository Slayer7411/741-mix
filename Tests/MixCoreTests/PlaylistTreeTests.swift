import Foundation
import Testing
@testable import MixCore

private func names(_ l: [PlaylistItem]) -> [String] { l.map(\.name) }

@Test func treeFoldersInFolders() {
    var t = PlaylistTree()
    let a = PlaylistItem.folder("A"), b = PlaylistItem.folder("B"), c = PlaylistItem.folder("C")
    do { let r = t.insert(a); #expect((r)) }
    do { let r = t.insert(b, into: a.id); #expect((r)) }
    do { let r = t.insert(c, into: b.id); #expect((r)) }
    let p = PlaylistItem.playlist("P", ["k1"]), s = PlaylistItem.smartlist("S", SmartRules(rules: [SmartRule(.genre, .contains, "techno")]))
    do { let r = t.insert(p, into: c.id); #expect((r)) }
    do { let r = t.insert(s, into: c.id, at: 0); #expect((r)) }
    #expect(names(t.item(c.id)!.children) == ["S", "P"])
    #expect(t.parent(of: p.id) == .some(c.id))
    #expect(t.parent(of: a.id) == .some(nil))
    #expect(t.parent(of: UUID()) == nil)
    #expect(t.isDescendant(p.id, of: a.id) && !t.isDescendant(a.id, of: p.id))
    #expect(t.folders.map(\.depth) == [0, 1, 2])
    #expect(t.all.count == 5 && t.item(a.id)!.descendantCount == 4)
    // nicht in eine Playlist, keine doppelte ID
    do { let r = t.insert(.playlist("X"), into: p.id); #expect(!(r)) }
    do { let r = t.insert(p); #expect(!(r)) }
    #expect(t.uniqueName("P", in: c.id) == "P 2" && t.uniqueName("P", in: nil) == "P")
}

@Test func treeMoveRenameDelete() {
    var t = PlaylistTree()
    let f = PlaylistItem.folder("F"), g = PlaylistItem.folder("G")
    let p1 = PlaylistItem.playlist("1"), p2 = PlaylistItem.playlist("2"), p3 = PlaylistItem.playlist("3")
    for i in [f, p1, p2, p3] { t.insert(i) }
    t.insert(g, into: f.id)
    // Reihenfolge auf derselben Ebene: Index vor dem Verschieben
    do { let r = t.move(p1.id, into: nil, at: 4); #expect((r)) }
    #expect(names(t.items) == ["F", "2", "3", "1"])
    do { let r = t.move(p1.id, into: nil, at: 1); #expect((r)) }
    #expect(names(t.items) == ["F", "1", "2", "3"])
    // in Ordner, Ordner in Ordner
    do { let r = t.move(p2.id, into: g.id); #expect((r)) }
    #expect(t.parent(of: p2.id) == .some(g.id))
    // nie in sich selbst oder einen eigenen Unterordner
    do { let r = t.move(f.id, into: g.id); #expect(!(r)) }
    do { let r = t.move(f.id, into: f.id); #expect(!(r)) }
    do { let r = t.move(p3.id, into: p1.id); #expect(!(r)) }
    do { let r = t.move(g.id, into: nil, at: 0); #expect((r)) }
    #expect(names(t.items) == ["G", "F", "1", "3"])
    do { let r = t.rename(p3.id, to: "  Drei "); #expect((r)) }
    #expect(t.item(p3.id)?.name == "Drei")
    do { let r = t.rename(p3.id, to: "   "); #expect(!(r)) }
    // Ordner löschen nimmt den Inhalt mit
    let gone = t.remove(g.id)
    #expect(gone?.children.map(\.name) == ["2"])
    #expect(!t.contains(p2.id) && names(t.items) == ["F", "1", "Drei"])
}

@Test func treeTracks() {
    var t = PlaylistTree()
    let p = PlaylistItem.playlist("P", ["a", "b"])
    t.insert(p)
    do { let r = t.addTracks(["b", "c", "d", "c"], to: p.id); #expect((r == 2)) }
    #expect(t.item(p.id)?.tracks == ["a", "b", "c", "d"])
    do { let r = t.addTracks(["x"], to: p.id, at: 1); #expect((r == 1)) }
    #expect(t.item(p.id)?.tracks == ["a", "x", "b", "c", "d"])
    // d und a vor b (Index von b = 2)
    do { let r = t.moveTracks(["d", "a"], in: p.id, to: 2); #expect((r)) }
    #expect(t.item(p.id)?.tracks == ["x", "a", "d", "b", "c"])
    do { let r = t.moveTracks(["x"], in: p.id, to: 5); #expect((r)) }
    #expect(t.item(p.id)?.tracks == ["a", "d", "b", "c", "x"])
    do { let r = t.moveTracks(["a"], in: p.id, to: 0); #expect(!r) }   // schon dort
    do { let r = t.removeTracks(["d", "zz"], from: p.id); #expect((r == 1)) }
    t.renameTrack("b", to: "b2")
    #expect(t.item(p.id)?.tracks == ["a", "b2", "c", "x"])
    // Smartlist nimmt keine Tracks
    let s = PlaylistItem.smartlist("S", SmartRules())
    t.insert(s)
    do { let r = t.addTracks(["a"], to: s.id); #expect((r == 0)) }
}

@Test func treeValuesAndNML() {
    var t = PlaylistTree()
    t.remember("Hypno", for: .genre)
    t.remember("hypno", for: .genre)
    t.remember("Acid", for: .genre)
    t.remember("x", for: .bpm)   // keine Vorschläge für Zahlen
    #expect(t.values(for: .genre) == ["Acid", "Hypno"] && t.values(for: .bpm).isEmpty)
    t.forget("Acid", for: .genre)
    #expect(t.values(for: .genre) == ["Hypno"])
    let f = PlaylistItem.folder("Sets", [.playlist("Fr", ["k"]), .smartlist("S", SmartRules())])
    t.insert(f)
    #expect(t.nmlNodes == [.folder("Sets", [.playlist("Fr", ["k"])])])
    #expect(t.hasPlaylists)
}

@Test func treeJSONRoundTrip() throws {
    var t = PlaylistTree()
    let f = PlaylistItem.folder("Ordner")
    t.insert(f)
    t.insert(.folder("Unter", [.playlist("Liste", ["v/:a/:b.mp3", "v/:c.mp3"])]), into: f.id)
    t.insert(.smartlist("Neu", SmartRules(match: .any, rules: [SmartRule(.importDate, .inLast, "30", "d"),
                                                             SmartRule(.genre, .contains, "Techno")],
                                         sort: SmartSort(.bpm, ascending: true), limit: 25)))
    t.remember("Eigenes Genre", for: .genre)
    let data = try t.encoded()
    let back = try PlaylistTree.decode(data)
    #expect(back == t)
    #expect(try back.encoded() == data)
    // nur das Nötige je Art in der Datei
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let items = json?["items"] as? [[String: Any]]
    #expect(json?["version"] as? Int == 1)
    #expect(items.map { $0.map { Set($0.keys) } } == [["id", "name", "kind", "children"], ["id", "name", "kind", "rules"]])
    // fehlende Felder / unbekannte Art lesbar
    let odd = try PlaylistTree.decode(Data(#"{"items":[{"name":"X","kind":"future"},{"name":"F","kind":"folder"}]}"#.utf8))
    #expect(odd.items.map(\.kind) == [.playlist, .folder] && odd.version == 1)
}

@Test func treeMigratesLegacySmartlists() {
    let id1 = UUID(), id2 = UUID()
    let t = PlaylistTree.migrated(legacy: [(id1, "Basis", #"$COMMENT2 % "BASIS" & $BPM >= 128"#),
                                           (id2, "Wild", #"!($GENRE % "house")"#)])
    #expect(t.items.map(\.id) == [id1, id2] && t.items.allSatisfy { $0.kind == .smartlist })
    #expect(t.items[0].rules.rules.map(\.field) == [.comment2, .bpm])
    #expect(t.items[1].rules.rules.map(\.field) == [.expression] && t.items[1].rules.rules[0].value == #"!($GENRE % "house")"#)
}

/// eigene Ordner in Ordnern als `$ROOT/MINOS-741/Playlists/…` in die Collection-Datei und wieder gelesen; fremde
/// Knoten bleiben Zeichen für Zeichen
@Test func treeMirrorIntoCollectionFile() throws {
    let foreign = #"<NODE TYPE="PLAYLIST" NAME="Fremd"><PLAYLIST ENTRIES="0" TYPE="LIST" UUID="abc"></PLAYLIST>"# + "\n</NODE>\n"
    let tail = #"<PLAYLISTS><NODE TYPE="FOLDER" NAME="$ROOT"><SUBNODES COUNT="1">"# + foreign + "</SUBNODES>\n</NODE>\n</PLAYLISTS>\n</NML>\n"
    var t = PlaylistTree()
    let sets = PlaylistItem.folder("Sets & Co")
    t.insert(sets)
    t.insert(.folder("2026", [.playlist("Fr", ["v/:a/:x.mp3", "v/:b.mp3"]), .smartlist("S", SmartRules())]), into: sets.id)
    t.insert(.playlist("Warm-up", ["v/:c.mp3"]))
    let own: [NMLOwnNode] = [.playlist("Preparation", []), .folder("Playlists", t.nmlNodes)]
    let out = try #require(CollectionWriter.patch(playlists: tail, own: own))
    #expect(out.contains(foreign))
    let c = try NMLParser.parse(data: Data(("<NML><COLLECTION ENTRIES=\"0\"></COLLECTION>" + out).utf8))
    let mine = try #require(c.root.children.first { $0.name == CollectionWriter.ownFolder })
    let pl = try #require(mine.find(uuid: nil, path: ["Playlists", "Sets & Co", "2026", "Fr"], kind: .playlist))
    #expect(pl.trackKeys == ["v/:a/:x.mp3", "v/:b.mp3"])
    #expect(mine.find(uuid: nil, path: ["Playlists", "Warm-up"], kind: .playlist)?.trackKeys == ["v/:c.mp3"])
    #expect(mine.find(uuid: nil, path: ["Playlists", "Sets & Co", "2026", "S"]) == nil)   // Smartlists nicht
    // zweites Schreiben ändert nichts
    #expect(CollectionWriter.patch(playlists: out, own: own) == out)
}
