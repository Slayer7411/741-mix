import Foundation
import Testing
@testable import MixCore

private func tempDir() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("minos-edits-\(UUID().uuidString)")
}

/// `edits.json` von vor dem Schnitt (ohne trimStart / trimEnd) wird weiter gelesen, Grid und Hotcues bleiben
@Test func oldEditsFileWithoutTrimDecodes() throws {
    let old = """
    {"A/B/x.mp3":{"bpm":128.5,"gridAnchorMs":120.5,"hotcues":[{"name":"Cue","kind":0,"startMs":1000,"lengthMs":0,"hotcue":0}],"modified":781000000},
     "A/B/y.mp3":{"gridAnchorMs":-380,"modified":781000001}}
    """
    let e = try JSONDecoder().decode([String: TrackEdit].self, from: Data(old.utf8))
    #expect(e["A/B/x.mp3"]?.bpm == 128.5 && e["A/B/x.mp3"]?.gridAnchorMs == 120.5 && e["A/B/x.mp3"]?.hotcues?.count == 1)
    #expect(e["A/B/x.mp3"]?.trim.isEmpty == true && e["A/B/y.mp3"]?.trim.isEmpty == true)
    #expect(e["A/B/y.mp3"]?.hasGrid == true && e["A/B/y.mp3"]?.bpm == nil)
    // gleiche Datei über den Speicher
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("edits.json")
    try Data(old.utf8).write(to: url)
    let store = TrackEditStore(url: url)
    #expect(store.all.count == 2 && store.edit(for: "A/B/x.mp3")?.hotcues?.first?.startMs == 1000)
}

/// Schnitt dazu: gesammelt im Hintergrund geschrieben, nach dem Neuladen wieder da; leere Änderung fällt heraus
@Test func editStoreWritesTrimDebounced() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("edits.json")
    let store = TrackEditStore(url: url)
    store.saveDelay = 30   // im Test nur über flush()
    var e = TrackEdit(bpm: 124, gridAnchorMs: 50)
    e.trim = TrackTrim(start: 1.5, end: 300.25)
    store.set(e, for: "k")
    store.set(TrackEdit(), for: "empty")
    #expect(!FileManager.default.fileExists(atPath: url.path))   // noch nicht geschrieben
    store.flush()
    let again = TrackEditStore(url: url)
    #expect(again.all.count == 1)
    #expect(again.edit(for: "k")?.trim == TrackTrim(start: 1.5, end: 300.25) && again.edit(for: "k")?.bpm == 124)
    store.set(nil, for: "k")
    store.flush()
    #expect(TrackEditStore(url: url).all.isEmpty)
}

/// nur lesen (Selbsttest, Messung): nie schreiben
@Test func readOnlyEditStoreNeverWrites() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("edits.json")
    let store = TrackEditStore(url: url, writes: false)
    store.set(TrackEdit(bpm: 120), for: "k")
    store.flush()
    #expect(store.edit(for: "k")?.bpm == 120)
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

/// Schnitt prüfen: Ränder fallen weg, zu kurz = ungültig
@Test func trimNormalized() {
    #expect(TrackTrim(start: 0, end: 300).normalized(duration: 300) == TrackTrim())
    #expect(TrackTrim(start: 2, end: 400).normalized(duration: 300) == TrackTrim(start: 2))
    #expect(TrackTrim(start: -1, end: 250).normalized(duration: 300) == TrackTrim(end: 250))
    #expect(TrackTrim(start: 10, end: 10.5).normalized(duration: 300) == nil)
    #expect(TrackTrim(start: 299.5).normalized(duration: 300) == nil)
    #expect(TrackTrim(start: 2, end: 250).range(duration: 300) == 2...250)
    #expect(TrackTrim().range(duration: 300) == 0...300)
    #expect(TrackEdit(trim: TrackTrim(start: 2)).same(as: TrackEdit(trim: TrackTrim(start: 2))))
    #expect(TrackEdit().same(as: nil) && !TrackEdit(bpm: 1).same(as: nil))
}
