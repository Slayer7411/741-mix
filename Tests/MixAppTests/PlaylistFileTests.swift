import Foundation
import Testing
import MixCore
@testable import MixApp

// playlists.json: erster Start übernimmt die alten Smartlists, danach wird nur gelesen; unlesbar -> beiseitegelegt

private func tempDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("minos-playlists-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

@MainActor @Test func playlistFileMigratesLegacySmartlistsOnce() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("playlists.json")
    let id = UUID()
    let legacy = [(id: id, name: "Basis 128", query: #"$COMMENT2 % "BASIS" & $BPM >= 128"#)]
    let first = PlaylistFile.load(url: url, legacy: legacy)
    #expect(first.items.count == 1 && first.items[0].id == id && first.items[0].kind == .smartlist)
    #expect(first.items[0].rules.rules.map(\.field) == [.comment2, .bpm])
    PlaylistFile.flush()
    #expect(FileManager.default.fileExists(atPath: url.path))
    // zweiter Start: Datei gilt, alte Liste wird nicht noch einmal übernommen
    var changed = first
    changed.rename(id, to: "Umbenannt")
    PlaylistFile.write(changed, to: url)
    PlaylistFile.flush()
    let second = PlaylistFile.load(url: url, legacy: legacy)
    #expect(second == changed)
}

@MainActor @Test func playlistFileSetsUnreadableAside() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("playlists.json")
    try Data("{ kaputt".utf8).write(to: url)
    let t = PlaylistFile.load(url: url, legacy: [(UUID(), "x", "$BPM > 1")])
    #expect(t.items.isEmpty)
    let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    #expect(files.contains { $0.hasPrefix("playlists-unlesbar-") } && !files.contains("playlists.json"))
    #expect(PlaylistFile.loadNote != nil)
}

@MainActor @Test func ownSourceTitleFollowsRename() {
    let it = PlaylistItem.playlist("A")
    var r = OwnRef(it)
    let a = BrowserSource.own(r)
    r.name = "B"
    #expect(a == .own(r) && BrowserSource.own(r).title == "B")
    #expect(Session.sourceID(a) == "own:\(it.id.uuidString)")
}
