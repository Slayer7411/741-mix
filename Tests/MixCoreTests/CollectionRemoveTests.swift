import Foundation
import Testing
@testable import MixCore

/// Entfernen aus der Collection: ENTRY-Block weg, Verweise in den Playlists weg oder auf den Behalter umgebogen
/// (ohne Dublette). Geschrieben wird eine Kopie im Temp-Ordner, nie eine echte Collection.
private let removeKeyA = "Macintosh HD/:Music/:a & b.m4a"
private let removeKeyB = "Macintosh HD/:Music/:b.mp3"

private func removeTempFile(_ text: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("minos-remove-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("collection.nml")
    try text.write(to: url, atomically: true, encoding: .utf8)
    return url
}

/// Playlist „Prep & Co“ mit beiden Tracks (a und b): Dublette nach dem Umbiegen
private let bothInPlaylist = editNML.replacingOccurrences(
    of: "<PLAYLIST ENTRIES=\"1\" TYPE=\"LIST\"><ENTRY><PRIMARYKEY TYPE=\"TRACK\" KEY=\"Macintosh HD/:Music/:b.mp3\"></PRIMARYKEY></ENTRY></PLAYLIST>",
    with: "<PLAYLIST ENTRIES=\"2\" TYPE=\"LIST\"><ENTRY><PRIMARYKEY TYPE=\"TRACK\" KEY=\"Macintosh HD/:Music/:b.mp3\"></PRIMARYKEY></ENTRY>\n"
        + "<ENTRY><PRIMARYKEY TYPE=\"TRACK\" KEY=\"Macintosh HD/:Music/:a &amp; b.m4a\"></PRIMARYKEY></ENTRY></PLAYLIST>")

@Test func removeEntryAndItsPlaylistReferences() throws {
    let url = try removeTempFile(editNML)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    var job = CollectionWriter.Job()
    job.remove = [removeKeyB]
    let r = try CollectionWriter.write(url: url, job: job, index: NMLEntryIndex(nmlText: editNML), backupDir: nil)
    #expect(r.removed == [removeKeyB])
    #expect(r.removedRefs == 1)
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(!text.contains("b.mp3"))
    #expect(text.contains("<COLLECTION ENTRIES=\"2\">"))
    #expect(text.contains("<PLAYLIST ENTRIES=\"0\" TYPE=\"LIST\">"))
    let parsed = try NMLParser.parse(url: url)
    #expect(parsed.tracks.map(\.key) == [removeKeyA, "Macintosh HD/:Music/:c.mp3"])
    #expect(ConsistencyCheck.lists(in: parsed.root).allSatisfy { $0.keys.isEmpty })
}

@Test func removeRedirectsPlaylistReferenceToKeeper() throws {
    let url = try removeTempFile(editNML)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    var job = CollectionWriter.Job()
    job.remove = [removeKeyB]
    job.redirects = [removeKeyB: removeKeyA]
    let r = try CollectionWriter.write(url: url, job: job, index: NMLEntryIndex(nmlText: editNML), backupDir: nil)
    #expect(r.removed == [removeKeyB])
    #expect(r.removedRefs == 1)
    let parsed = try NMLParser.parse(url: url)
    #expect(parsed.tracks.count == 2)
    #expect(ConsistencyCheck.lists(in: parsed.root).flatMap(\.keys) == [removeKeyA])
}

@Test func redirectWithoutDuplicateInPlaylist() throws {
    let url = try removeTempFile(bothInPlaylist)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    var job = CollectionWriter.Job()
    job.remove = [removeKeyB]
    job.redirects = [removeKeyB: removeKeyA]
    let r = try CollectionWriter.write(url: url, job: job, index: NMLEntryIndex(nmlText: bothInPlaylist), backupDir: nil)
    #expect(r.removedRefs == 1)
    let parsed = try NMLParser.parse(url: url)
    // der Behalter steht schon drin: der umgebogene Eintrag fällt weg, die Playlist hat ihn nur einmal
    #expect(ConsistencyCheck.lists(in: parsed.root).flatMap(\.keys) == [removeKeyA])
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.contains("<PLAYLIST ENTRIES=\"1\" TYPE=\"LIST\">"))
}

@Test func removalRefusedWhenTargetStillInFile() throws {
    // Schlüssel, der nicht in der Datei steht: wird gemeldet, nichts geschrieben
    let url = try removeTempFile(editNML)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    var job = CollectionWriter.Job()
    job.remove = ["Macintosh HD/:Music/:gibt-es-nicht.mp3"]
    let r = try CollectionWriter.write(url: url, job: job, index: NMLEntryIndex(nmlText: editNML), backupDir: nil)
    #expect(!r.changed)
    #expect(r.removed.isEmpty)
    #expect(r.missing == ["Macintosh HD/:Music/:gibt-es-nicht.mp3"])
}
