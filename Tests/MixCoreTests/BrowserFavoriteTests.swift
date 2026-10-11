import Foundation
import Testing
@testable import MixCore

private func tree(playlist: String = "Peak", uuid: String = "aa11", folder: String = "Sets") -> String {
    let p = uuid.isEmpty ? "" : " UUID=\"\(uuid)\""
    return """
    <?xml version="1.0" encoding="UTF-8" standalone="no" ?>
    <NML VERSION="19"><COLLECTION ENTRIES="0"></COLLECTION>
    <PLAYLISTS><NODE TYPE="FOLDER" NAME="$ROOT"><SUBNODES COUNT="2">
    <NODE TYPE="FOLDER" NAME="\(folder)"><SUBNODES COUNT="2">
    <NODE TYPE="PLAYLIST" NAME="\(playlist)"><PLAYLIST ENTRIES="0" TYPE="LIST"\(p)></PLAYLIST></NODE>
    <NODE TYPE="SMARTLIST" NAME="Peak"><SMARTLIST UUID="bb22"><SEARCH_EXPRESSION VERSION="1" QUERY="$BPM > 130"></SEARCH_EXPRESSION></SMARTLIST></NODE>
    </SUBNODES></NODE>
    <NODE TYPE="PLAYLIST" NAME="Peak"><PLAYLIST ENTRIES="0" TYPE="LIST" UUID="cc33"></PLAYLIST></NODE>
    </SUBNODES></NODE></PLAYLISTS></NML>
    """
}

/// Favoriten finden ihren Knoten über die UUID (auch nach Umbenennen), sonst über den Namenspfad mit Art
@Test func favoriteResolvesNodes() throws {
    let root = try NMLParser.parse(data: Data(tree().utf8)).root
    let sets = root.children[0], peak = sets.children[0], smart = sets.children[1]
    #expect(peak.uuid == "aa11" && smart.uuid == "bb22" && root.children[1].uuid == "cc33" && sets.uuid.isEmpty)
    #expect(root.path(to: smart) == ["Sets", "Peak"])
    #expect(root.path(to: PlaylistNode(name: "x", kind: .playlist)) == nil)

    let fav = try #require(BrowserFavorite.node(peak, in: root))
    #expect(fav.id == "aa11" && fav.path == ["Sets", "Peak"] && fav.node == "playlist" && fav.name == "Peak")
    let favSmart = try #require(BrowserFavorite.node(smart, in: root))
    let favFolder = try #require(BrowserFavorite.node(sets, in: root))
    #expect(favFolder.id == nil && favFolder.path == ["Sets"])

    // neu geladen, umbenannt: gleiche UUID
    let renamed = try NMLParser.parse(data: Data(tree(playlist: "Peak Time").utf8)).root
    #expect(fav.resolveNode(in: renamed)?.name == "Peak Time")
    #expect(favSmart.resolveNode(in: renamed)?.kind == .smartlist)
    // ohne UUID: Pfad, Art entscheidet bei gleichem Namen
    let noUUID = try NMLParser.parse(data: Data(tree(uuid: "").utf8)).root
    #expect(fav.resolveNode(in: noUUID)?.kind == .playlist)
    #expect(noUUID.path(to: fav.resolveNode(in: noUUID)!) == ["Sets", "Peak"])
    // Ordner umbenannt und Playlist ohne UUID: nicht mehr da
    let gone = try NMLParser.parse(data: Data(tree(uuid: "", folder: "Old").utf8)).root
    #expect(fav.resolveNode(in: gone) == nil)
    #expect(favFolder.resolveNode(in: gone) == nil)
    #expect(favFolder.resolveNode(in: noUUID)?.kind == .folder)
    // andere Art findet keinen Knoten
    #expect(BrowserFavorite(.folder, name: "x", path: ["/x"]).resolveNode(in: root) == nil)
}

@Test func favoriteFilterAndCoding() throws {
    #expect(BrowserFavorite.filter(tags: [], roles: [], search: "  ") == nil)
    let f = try #require(BrowserFavorite.filter(tags: ["H off", "B sub"], roles: ["BASIS"], search: " dub "))
    #expect(f.isFilter && f.name == "BASIS + B sub + H off + \"dub\"")
    #expect(f.tags == ["B sub", "H off"] && f.roles == ["BASIS"] && f.search == "dub")
    #expect(f.matchesFilter(tags: ["B sub", "H off"], roles: ["BASIS"], search: "dub"))
    #expect(!f.matchesFilter(tags: ["B sub"], roles: ["BASIS"], search: "dub"))
    #expect(!BrowserFavorite(.collection, name: "c").matchesFilter(tags: [], roles: [], search: ""))

    // Sitzung: leere Plätze, unbekannte Art einer neueren Version, immer 6 Plätze
    let slots = BrowserFavorite.normalized([BrowserFavorite(.collection, name: "Track Collection"), nil, f])
    #expect(slots.count == BrowserFavorite.slots && slots[1] == nil && slots[2] == f && slots[5] == nil)
    let data = try JSONEncoder().encode(slots)
    #expect(try JSONDecoder().decode([BrowserFavorite?].self, from: data) == slots)
    let future = try JSONDecoder().decode([BrowserFavorite?].self, from: Data(#"[{"type":"cloud","name":"x"},null]"#.utf8))
    #expect(future[0]?.kind == nil && future[1] == nil)
    #expect(BrowserFavorite.normalized(Array(repeating: f, count: 9)).count == 6)
}
