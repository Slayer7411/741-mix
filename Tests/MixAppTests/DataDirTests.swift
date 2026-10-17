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
    #expect(Set(try fm.contentsOfDirectory(atPath: dir.path)) == ["analysis.json", "plugins.json", "History"])
    // zweiter Start: vorhandene Dateien im Ordner bleiben, fehlende kommen dazu
    try Data("{\"neu\":1}".utf8).write(to: dir.appendingPathComponent("analysis.json"))
    try fm.removeItem(at: dir.appendingPathComponent("plugins.json"))
    #expect(DataDir.resolve(collection: nml, local: local, selfTest: false) == dir)
    #expect(try String(contentsOf: dir.appendingPathComponent("analysis.json"), encoding: .utf8) == "{\"neu\":1}")
    #expect(fm.fileExists(atPath: dir.appendingPathComponent("plugins.json").path))
    // Selbsttest und fehlender Collection-Ordner: lokal
    #expect(DataDir.resolve(collection: nml, local: local, selfTest: true) == local)
    #expect(DataDir.resolve(collection: URL(fileURLWithPath: "/nicht/da/collection.nml"), local: local, selfTest: false) == local)
}

@Test func settingsFileKeepsAudioDeviceAndPairLocal() throws {
    for k in ["prefs.v1", "columns.Basis", "x1.6CB252DB", "NSWindow Frame x", "NSSplitView Subview Frames y", "masterVolume", "quantize"] {
        #expect(SettingsFile.shared(k), "\(k)")
    }
    for k in ["deviceUID", "deckPairs", "sampleRate", "bufferSize", "mixerMode", SettingsFile.stampKey] { #expect(!SettingsFile.shared(k), "\(k)") }
    let incoming = try JSONSerialization.data(withJSONObject: ["ui": ["pair": ["on": true, "writes": true], "zoom": 1.2],
                                                                "record": ["inputUID": "fremd", "format": "wav"]])
    let local = try JSONSerialization.data(withJSONObject: ["ui": ["pair": ["on": true, "writes": false], "zoom": 1.0],
                                                             "record": ["inputUID": "xone", "format": "aiff"]])
    let merged = try #require(try JSONSerialization.jsonObject(with: SettingsFile.keepingLocal(incoming, local: local)) as? [String: Any])
    let ui = try #require(merged["ui"] as? [String: Any]), rec = try #require(merged["record"] as? [String: Any])
    #expect((ui["pair"] as? [String: Any])?["writes"] as? Bool == false && ui["zoom"] as? Double == 1.2)
    #expect(rec["inputUID"] as? String == "xone" && rec["format"] as? String == "wav")
}
