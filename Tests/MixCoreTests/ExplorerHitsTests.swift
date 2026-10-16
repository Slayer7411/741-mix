import Foundation
import Testing
@testable import MixCore

@Test func explorerHitsFoldersFirstThenParents() {
    let hits: [(path: String, folder: Bool)] = [
        ("/Volumes/NO NAME/Contents/ALU/a.mp3", false),
        ("/Users/c/Desktop/USB Tracks", true),
        ("/Users/c/Desktop/USB Tracks/b.mp3", false),
        ("/Users/c/Library/Caches/x.mp3", false),
        ("/Users/c/Library/CloudStorage/Drive/Music/Label", true),
        ("/Users/c/.Trash/old.mp3", false),
        ("/System/Library/Sounds/Ping.aiff", false),
    ]
    #expect(ExplorerHits.folders(hits, home: "/Users/c") == ["/Users/c/Library/CloudStorage/Drive/Music/Label", "/Users/c/Desktop/USB Tracks", "/Volumes/NO NAME/Contents/ALU"])
}

@Test func explorerWalkFindsFoldersAndAudio() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("explorer-walk-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Disco Set"), withIntermediateDirectories: true)
    for f in ["Disco Set/a.mp3", "disco inferno.mp3", "disco.txt", "other.wav"] {
        FileManager.default.createFile(atPath: root.appendingPathComponent(f).path, contents: Data())
    }
    let hits = ExplorerHits.walk(root, matching: "disco").map { ($0.path as NSString).lastPathComponent }.sorted()
    #expect(hits == ["Disco Set", "disco inferno.mp3"])
}
