import Foundation
import Testing
@testable import MixCore

// Sicherungen der Collection: Auflistung, Prüfung, Wiederherstellung (nur temporäre Ordner)

private func nml(_ n: Int) -> Data {
    var s = #"<?xml version="1.0" encoding="UTF-8" standalone="no" ?><NML VERSION="19"><COLLECTION ENTRIES="\#(n)">"#
    for i in 0..<n {
        s += #"<ENTRY TITLE="Track \#(i)" ARTIST="Test"><LOCATION DIR="/:music/:" FILE="t\#(i).wav" VOLUME="Macintosh HD" VOLUMEID="Macintosh HD"/></ENTRY>"#
    }
    s += "</COLLECTION></NML>"
    return Data(s.utf8)
}

private func tempRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("restore-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Test func backupListingNewestFirstAndIgnoresOtherFiles() throws {
    let root = try tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let dir = root.appendingPathComponent(CollectionBackups.folderName)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for name in ["collection_2026-10-01_100000.nml", "collection_2026-10-03_090000.nml", "collection_kaputt.nml",
                 "notes.txt", "collection_2026-10-02_100000.bak"] {
        try nml(2).write(to: dir.appendingPathComponent(name))
    }
    let entries = CollectionBackups.list(in: dir)
    #expect(entries.map(\.id) == ["collection_2026-10-03_090000.nml", "collection_2026-10-01_100000.nml"])
    #expect((entries.first?.bytes ?? 0) > 0)
    #expect(CollectionBackups.list(in: root.appendingPathComponent("gibt-es-nicht")).isEmpty)
}

@Test func validateCountsTracksAndRejectsBrokenFiles() throws {
    #expect(try CollectionBackups.validate(nml(4)) == 4)
    #expect(try CollectionBackups.validate(nml(0)) == 0)
    #expect(throws: CollectionBackups.Failure.self) { try CollectionBackups.validate(Data("<html></html>".utf8)) }
    #expect(throws: CollectionBackups.Failure.self) { try CollectionBackups.validate(Data("<NML><COLLECTION ENTRIES=\"2\">".utf8)) }
    #expect(throws: CollectionBackups.Failure.self) { try CollectionBackups.validate(Data([0xff, 0xfe, 0x00])) }
}

@Test func restoreReplacesCollectionAndKeepsPreviousState() throws {
    let root = try tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let collection = root.appendingPathComponent("collection.nml")
    try nml(3).write(to: collection)
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let backup = try #require(try CollectionBackups.backupNow(collection, now: t0))
    try nml(5).write(to: collection)   // der Stand wird geändert, danach zurückgespielt

    let r = try CollectionBackups.restore(backup, over: collection, now: t0.addingTimeInterval(60))
    #expect(r.tracks == 3)
    #expect(try Data(contentsOf: collection) == nml(3))
    // der Stand vor der Wiederherstellung (5 Tracks) liegt als Sicherung daneben
    let previous = try #require(r.previous)
    #expect(CollectionBackups.trackCount(previous) == 5)
    #expect(CollectionBackups.list(in: CollectionBackups.folder(for: collection)).count == 2)
}

@Test func restoreRefusesInvalidBackupAndLeavesCollectionAlone() throws {
    let root = try tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let collection = root.appendingPathComponent("collection.nml")
    try nml(3).write(to: collection)
    let broken = root.appendingPathComponent("collection_2026-10-01_100000.nml")
    try Data("<NML><COLLECTION".utf8).write(to: broken)

    #expect(throws: CollectionBackups.Failure.self) { try CollectionBackups.restore(broken, over: collection) }
    #expect(try Data(contentsOf: collection) == nml(3))
    #expect(!FileManager.default.fileExists(atPath: CollectionBackups.folder(for: collection).path))
}

@Test func restoreStopsWhenPreviousStateCannotBeBackedUp() throws {
    let root = try tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let collection = root.appendingPathComponent("collection.nml")
    try nml(3).write(to: collection)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let backup = try #require(try CollectionBackups.backupNow(collection, now: now))
    try nml(4).write(to: collection)
    // gleiche Sekunde wie die Sicherung: der bisherige Stand hätte keinen eigenen Namen -> nichts ersetzen
    #expect(throws: CollectionBackups.Failure.previousNotBacked) { try CollectionBackups.restore(backup, over: collection, now: now) }
    #expect(try Data(contentsOf: collection) == nml(4))
}

@Test func restoreInSameSecondAcceptsIdenticalPreviousState() throws {
    let root = try tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let collection = root.appendingPathComponent("collection.nml")
    try nml(3).write(to: collection)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let backup = try #require(try CollectionBackups.backupNow(collection, now: now))
    try nml(6).write(to: collection)
    // der bisherige Stand ist unverändert gleich der Sicherung in derselben Sekunde: kein Fehler, kein Doppel
    try nml(3).write(to: collection)
    let r = try CollectionBackups.restore(backup, over: collection, now: now)
    #expect(r.tracks == 3)
    #expect(r.previous == backup)
    #expect(CollectionBackups.list(in: CollectionBackups.folder(for: collection)).count == 1)
}
