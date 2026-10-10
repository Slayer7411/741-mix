import Foundation
import Testing
@testable import MixCore

private func tempDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("minos-ov-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func sample(_ seed: UInt8 = 0) -> TrackOverview {
    TrackOverview(duration: 312.5, bytes: (0..<(TrackOverview.points * 4)).map { UInt8(truncatingIfNeeded: $0 &+ Int(seed)) })
}

/// Blöcke -> Punkte: Spitze = Maximum, Bänder = Mittelwert
@Test func overviewReducesBlocks() {
    let n = 3200
    let peak = (0..<n).map { $0 < n / 2 ? Float(0.8) : Float(0.2) }
    let low = (0..<n).map { $0 < n / 2 ? Float(1) : Float(0) }
    let high = (0..<n).map { $0 < n / 2 ? Float(0) : Float(1) }
    let mid = [Float](repeating: 0, count: n)
    let o = TrackOverview(peak: peak, low: low, mid: mid, high: high, duration: 10.7)
    #expect(o.count == TrackOverview.points)
    #expect(o.bytes.count == TrackOverview.points * 4)
    #expect(o.duration == 10.7)
    #expect(abs(o.peak(10) - 0.8) < 0.01 && abs(o.peak(300) - 0.2) < 0.01)
    #expect(o.low(10) > 0.99 && o.high(10) < 0.01)
    #expect(o.high(300) > 0.99 && o.low(300) < 0.01)
    // einzelne Spitze bleibt erhalten
    var p2 = peak; p2[1234] = 1
    #expect(TrackOverview(peak: p2, low: low, mid: mid, high: high, duration: 1).bytes.contains(255))
    #expect(TrackOverview(peak: [], low: [], mid: [], high: [], duration: 0).count == 0)
}

/// speichern, neu laden: gleiche Übersicht; späterer Eintrag ersetzt früheren; abgeschnittenes Ende schadet nicht
@Test func overviewStoreRoundTrip() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let audio = dir.appendingPathComponent("a.mp3")
    try Data(repeating: 7, count: 1000).write(to: audio)
    let s = OverviewStore(directory: dir)
    s.put("Macintosh HD/:Music/:a.mp3", path: audio.path, overview: sample(1))
    s.put("Macintosh HD/:Music/:a.mp3", path: audio.path, overview: sample(2))
    s.put("Macintosh HD/:Music/:ü ß.mp3", path: audio.path, overview: sample(3))
    s.flush()
    let r = OverviewStore(directory: dir)
    r.load()
    #expect(r.count == 2)
    #expect(r.overview("Macintosh HD/:Music/:a.mp3", path: audio.path) == sample(2))
    #expect(r.overview("Macintosh HD/:Music/:ü ß.mp3", path: audio.path) == sample(3))
    #expect(r.info("Macintosh HD/:Music/:a.mp3")?.duration == 312.5)
    // Absturz mitten im Schreiben: halber Eintrag am Ende
    let h = try FileHandle(forWritingTo: dir.appendingPathComponent("overviews.bin"))
    try h.seekToEnd(); try h.write(contentsOf: Data([200, 0, 0, 0, 5, 0, 65])); try h.close()
    let t = OverviewStore(directory: dir)
    t.load()
    #expect(t.count == 2)
}

/// Audiodatei geändert (Größe/Zeit) -> Übersicht ungültig, Eintrag weg
@Test func overviewStoreInvalidatesOnFileChange() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let audio = dir.appendingPathComponent("b.wav")
    try Data(repeating: 1, count: 500).write(to: audio)
    let s = OverviewStore(directory: dir)
    s.put("k", path: audio.path, overview: sample())
    s.flush()
    #expect(s.isValid("k", path: audio.path))
    // neu getaggt: andere Größe, neue Änderungszeit
    try Data(repeating: 2, count: 640).write(to: audio)
    let r = OverviewStore(directory: dir)
    r.load()
    #expect(r.contains("k"))
    #expect(r.overview("k", path: audio.path) == nil)
    #expect(!r.contains("k"))
    // gleiche Größe, nur Änderungszeit
    s.put("m", path: audio.path, overview: sample())
    s.flush()
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: audio.path)
    let q = OverviewStore(directory: dir)
    q.load()
    #expect(q.overview("m", path: audio.path) == nil)
}

/// viele überholte Einträge -> beim Laden neu geschrieben
@Test func overviewStoreCompacts() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let audio = dir.appendingPathComponent("c.wav")
    try Data(repeating: 1, count: 10).write(to: audio)
    let s = OverviewStore(directory: dir)
    for i in 0..<300 { s.put("k\(i % 5)", path: audio.path, overview: sample(UInt8(i % 200))) }
    s.flush()
    let file = dir.appendingPathComponent("overviews.bin")
    let before = try Data(contentsOf: file).count
    let r = OverviewStore(directory: dir)
    r.load()
    r.flush()
    let after = try Data(contentsOf: file).count
    #expect(after < before / 10)
    let q = OverviewStore(directory: dir)
    q.load()
    #expect(q.count == 5)
    #expect(q.overview("k4", path: audio.path) == sample(UInt8(299 % 200)))
}
