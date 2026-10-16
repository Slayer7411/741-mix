import Foundation
import Testing
@testable import MixApp

private func tempDir(_ name: String) throws -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

@Test func dataDirCopiesSessionNotCaches() throws {
    let fm = FileManager.default
    let local = try tempDir("local"), coll = try tempDir("traktor")
    defer { try? fm.removeItem(at: local); try? fm.removeItem(at: coll) }
    for f in ["analysis.json", "plugins.json"] { fm.createFile(atPath: local.appendingPathComponent(f).path, contents: Data("{}".utf8)) }
    for d in ["History", "cache", "overviews"] { try fm.createDirectory(at: local.appendingPathComponent(d), withIntermediateDirectories: true) }
    let nml = coll.appendingPathComponent("collection.nml")
    fm.createFile(atPath: nml.path, contents: Data())
    let dir = DataDir.resolve(collection: nml, local: local, selfTest: false)
    #expect(dir == coll.appendingPathComponent("MINOS-741", isDirectory: true))
    #expect(Set(try fm.contentsOfDirectory(atPath: dir.path)) == ["analysis.json", "History"])
    // zweiter Start: vorhandener Ordner bleibt, nichts wird erneut kopiert
    try fm.removeItem(at: dir.appendingPathComponent("analysis.json"))
    #expect(DataDir.resolve(collection: nml, local: local, selfTest: false) == dir)
    #expect(!fm.fileExists(atPath: dir.appendingPathComponent("analysis.json").path))
    // Selbsttest und fehlender Collection-Ordner: lokal
    #expect(DataDir.resolve(collection: nml, local: local, selfTest: true) == local)
    #expect(DataDir.resolve(collection: URL(fileURLWithPath: "/nicht/da/collection.nml"), local: local, selfTest: false) == local)
}

@Test func settingsFileKeepsDeviceKeysAndRoleLocal() throws {
    #expect(SettingsFile.shared("prefs.v1") && SettingsFile.shared("columns.Basis") && SettingsFile.shared("mixerMode"))
    #expect(!SettingsFile.shared("deviceUID") && !SettingsFile.shared("deckPairs") && !SettingsFile.shared("x1.6CB252DB"))
    #expect(!SettingsFile.shared("NSWindow Frame x") && !SettingsFile.shared("migrated.v2") && !SettingsFile.shared(SettingsFile.stampKey))
    let incoming = try JSONSerialization.data(withJSONObject: ["ui": ["pairRole": "Mac 1 · Decks A/C · schreibt", "zoom": 1.2]])
    let local = try JSONSerialization.data(withJSONObject: ["ui": ["pairRole": "Mac 2 · Decks B/D", "zoom": 1.0]])
    let merged = try #require(try JSONSerialization.jsonObject(with: SettingsFile.keepingRole(incoming, local: local)) as? [String: Any])
    let ui = try #require(merged["ui"] as? [String: Any])
    #expect(ui["pairRole"] as? String == "Mac 2 · Decks B/D" && ui["zoom"] as? Double == 1.2)
    let none = try #require(try JSONSerialization.jsonObject(with: SettingsFile.keepingRole(incoming, local: nil)) as? [String: Any])
    #expect((none["ui"] as? [String: Any])?["pairRole"] == nil)
}
