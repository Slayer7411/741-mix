import Foundation
import Testing
@testable import MixCore

/// Speicher: ablegen, Felder dazu (Analysieren) oder ersetzen (Neu analysieren), neu laden, geschrieben markieren
@Test func analysisStoreRoundTrip() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("minos-ana-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("analysis.json")
    let store = AnalysisStore(url: url)
    final class Seen: @unchecked Sendable { var keys: [String] = []; let lock = NSLock() }
    let seen = Seen()
    store.onChange = { k in seen.lock.lock(); seen.keys.append(k); seen.lock.unlock() }
    store.put(TrackAnalysis(musicalKey: 5), for: "a", replace: false)
    store.put(TrackAnalysis(bpm: 128, gridAnchorMs: 250), for: "a", replace: false)
    #expect(store.entry(for: "a")?.fields == [.tempo, .key] && store.entry(for: "a")?.bpm == 128)
    store.put(TrackAnalysis(perceivedDb: 2), for: "a", replace: true)
    #expect(store.entry(for: "a")?.fields == .loudness && store.entry(for: "a")?.musicalKey == nil)
    store.put(TrackAnalysis(bpm: 120, gridAnchorMs: 0, musicalKey: 0, perceivedDb: 0, peakDb: -1), for: "b", replace: false)
    store.markWritten(["b"])
    #expect(store.unwritten.keys.sorted() == ["a"])
    store.put(TrackAnalysis(musicalKey: 3), for: "b", replace: false)   // neue Felder -> wieder ungeschrieben
    #expect(store.unwritten.count == 2)
    store.flush()
    let again = AnalysisStore(url: url)
    #expect(again.count == 2 && again.entry(for: "b")?.musicalKey == 3 && again.entry(for: "b")?.bpm == 120)
    again.remove(["a"])
    again.flush()
    #expect(AnalysisStore(url: url).count == 1)
    #expect(seen.keys == ["a", "a", "a", "b", "b"])
    // leer -> Eintrag weg
    store.put(TrackAnalysis(), for: "c", replace: true)
    #expect(store.entry(for: "c") == nil)
}

/// Zurückschreiben der Analyse: TEMPO geändert, LOUDNESS + MUSICAL_KEY ergänzt / gesetzt, Grid-Marker ersetzt oder neu
@Test func analysisWriteBack() throws {
    let index = NMLEntryIndex(nmlText: editNML)
    let keyA = "Macintosh HD/:Music/:a & b.m4a", keyB = "Macintosh HD/:Music/:b.mp3"
    let oldA = try #require(index.raw[keyA]), oldB = try #require(index.raw[keyB])
    let a = TrackAnalysis(bpm: 130.5, gridAnchorMs: 44.5, musicalKey: 7, perceivedDb: -1.25, peakDb: 0.1)
    let newA = CollectionWriter.patch(entry: oldA, analysis: a)
    #expect(newA.contains("<TEMPO BPM=\"130.500000\" BPM_QUALITY=\"100.000000\"></TEMPO>"))
    #expect(newA.contains("<MUSICAL_KEY VALUE=\"7\"></MUSICAL_KEY>"))
    #expect(newA.contains("</TEMPO>\n<LOUDNESS PEAK_DB=\"0.100000\" PERCEIVED_DB=\"-1.250000\" ANALYZED_DB=\"-1.250000\"></LOUDNESS>"))
    #expect(newA.contains("<CUE_V2 NAME=\"AutoGrid\" DISPL_ORDER=\"0\" TYPE=\"4\" START=\"44.500000\" LEN=\"0.000000\" REPEATS=\"-1\" HOTCUE=\"0\"></CUE_V2>"))
    #expect(!newA.contains("START=\"43.963768\""))
    // nur die Tonart: alles andere bleibt Byte für Byte
    let keyOnly = CollectionWriter.patch(entry: oldA, analysis: TrackAnalysis(musicalKey: 19))
    #expect(keyOnly == oldA)
    let keyB2 = CollectionWriter.patch(entry: oldB, analysis: TrackAnalysis(gridAnchorMs: 12.25, musicalKey: 2, perceivedDb: 3))
    #expect(keyB2.contains("</TEMPO>\n<LOUDNESS PERCEIVED_DB=\"3.000000\" ANALYZED_DB=\"3.000000\"></LOUDNESS>\n<MUSICAL_KEY VALUE=\"2\"></MUSICAL_KEY>"))
    #expect(keyB2.hasSuffix("<CUE_V2 NAME=\"AutoGrid\" DISPL_ORDER=\"0\" TYPE=\"4\" START=\"12.250000\" LEN=\"0.000000\" REPEATS=\"-1\" HOTCUE=\"-1\"></CUE_V2>\n</ENTRY>"))
    // Datei: Metadaten und Analyse zusammen, wieder lesbar
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("minos-anaw-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("collection.nml")
    try Data(editNML.utf8).write(to: url)
    let res = try CollectionWriter.write(url: url, changes: [keyB: [.genre: "Dub & Bass"]], analyses: [keyA: a, keyB: TrackAnalysis(musicalKey: 2)],
                                         index: index, backupDir: nil)
    #expect(res.changed && res.writtenAnalyses.sorted() == [keyA, keyB] && res.written.count == 1)
    let c = try NMLParser.parse(url: url)
    let ta = try #require(c.tracks.first { $0.key == keyA }), tb = try #require(c.tracks.first { $0.key == keyB })
    #expect(abs(ta.bpm - 130.5) < 1e-6 && ta.musicalKey == 7 && ta.perceivedDb == -1.25 && ta.peakDb == 0.1 && ta.gridAnchorMs == 44.5)
    #expect(tb.musicalKey == 2 && tb.genre == "Dub & Bass" && tb.bpm == 124)
}
