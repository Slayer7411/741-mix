import Foundation
import Testing
@testable import MixCore

@Test func collectionBackupKeepsNewest() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("backup-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    let nml = root.appendingPathComponent("collection.nml")
    fm.createFile(atPath: nml.path, contents: Data("<NML/>".utf8))
    let dir = root.appendingPathComponent("Backup MINOS-741")
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    for i in 0..<(CollectionWriter.keepBackups + 5) {
        #expect(try CollectionWriter.backup(nml, into: dir, now: start.addingTimeInterval(Double(i) * 60), minInterval: 0) != nil)
    }
    let left = try fm.contentsOfDirectory(atPath: dir.path).sorted()
    #expect(left.count == CollectionWriter.keepBackups)
    #expect(left.last == "collection_\(CollectionWriter.backupFormatter.string(from: start.addingTimeInterval(Double(CollectionWriter.keepBackups + 4) * 60))).nml")
}
