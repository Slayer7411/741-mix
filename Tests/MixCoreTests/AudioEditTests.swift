import Foundation
import Testing
@testable import MixCore

// Audio-Edit-Modus: Auswahl des Import-Laufs, Stand je Eintrag, Speicher für letzten Lauf und erledigt

/// vollständig analysiert: Tempo + Grid, Tonart, Lautheit
private func analysed(_ key: String, imported: Date? = nil) -> Track {
    var t = Track(key: key, path: "/music/\(key).m4a")
    t.bpm = 128
    t.cues = [Cue(name: "AutoGrid", kind: .grid, startMs: 120, lengthMs: 0, hotcue: -1)]
    t.musicalKey = 3
    t.perceivedDb = -1
    t.importDate = imported
    return t
}

/// ohne Werte
private func bare(_ key: String, imported: Date? = nil) -> Track {
    var t = Track(key: key, path: "/music/\(key).m4a")
    t.importDate = imported
    return t
}

@Test func auditPickNotAnalysedAndImportedSinceLastRun() {
    let run = Date(timeIntervalSince1970: 1_000_000)
    let older = run.addingTimeInterval(-86_400), newer = run.addingTimeInterval(86_400)
    let tracks = [
        analysed("done-old", imported: older),        // analysiert, vor dem Lauf importiert -> nicht dabei
        analysed("done-new", imported: newer),        // analysiert, nach dem Lauf importiert -> dabei
        bare("bare-old", imported: older),            // ohne Werte -> dabei
        analysed("own-checked", imported: older),     // eigene Analyse + Rip-Prüfung -> nicht dabei
        analysed("unchecked", imported: older),       // keine Rip-Prüfung -> dabei
    ]
    let own: Set = ["own-checked"]
    let checked: Set = ["done-old", "done-new", "own-checked"]
    let picked = AudioEdit.pick(tracks, lastRun: run, ownAnalysis: { own.contains($0) }, ripChecked: { checked.contains($0) })
    #expect(picked.map(\.key) == ["done-new", "bare-old", "unchecked"])
}

@Test func auditPickWithoutLastRunOnlyNotAnalysed() {
    let tracks = [analysed("new", imported: Date()), bare("bare"), analysed("unchecked")]
    let picked = AudioEdit.pick(tracks, lastRun: nil, ownAnalysis: { $0 == "bare" }, ripChecked: { $0 == "new" || $0 == "bare" })
    // ohne Lauf zählt das Importdatum nicht: „new“ ist geprüft und vollständig, „bare“ hat eine eigene Analyse und Prüfung
    #expect(picked.map(\.key) == ["unchecked"])
}

@Test func auditNotAnalysedNeedsCheckAndValues() {
    #expect(!AudioEdit.notAnalysed(analysed("a"), ownAnalysis: false, ripChecked: true))
    #expect(AudioEdit.notAnalysed(analysed("a"), ownAnalysis: false, ripChecked: false))
    #expect(AudioEdit.notAnalysed(bare("b"), ownAnalysis: false, ripChecked: true))
    #expect(!AudioEdit.notAnalysed(bare("b"), ownAnalysis: true, ripChecked: true))
}

@Test func auditStatusMapping() {
    typealias S = AudioEdit.Status
    // erledigt schlägt alles
    #expect(AudioEdit.status(reviewed: true, analysing: true, queued: true, ripChecked: false, open: 3) == .reviewed)
    #expect(AudioEdit.status(reviewed: false, analysing: true, queued: true, ripChecked: false, open: 0) == .analysing)
    #expect(AudioEdit.status(reviewed: false, analysing: false, queued: true, ripChecked: true, open: 2) == .waiting)
    #expect(AudioEdit.status(reviewed: false, analysing: false, queued: false, ripChecked: false, open: 0) == .unchecked)
    #expect(AudioEdit.status(reviewed: false, analysing: false, queued: false, ripChecked: true, open: 2) == .suggestions(2))
    #expect(AudioEdit.status(reviewed: false, analysing: false, queued: false, ripChecked: true, open: 0) == S.ok)
}

/// Erledigt und letzter Lauf überleben einen Neustart; zurücknehmen und zurücksetzen wirken
@Test func auditStoreRoundTrip() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("audioedit-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let run = Date(timeIntervalSince1970: 1_700_000_000)
    let s = AudioEditStore(url: url)
    #expect(s.lastImport == nil && !s.isReviewed("a"))
    s.setLastImport(run)
    s.markReviewed("a")
    s.markReviewed("b")
    s.unmarkReviewed("b")
    s.flush()
    let t = AudioEditStore(url: url)
    #expect(t.lastImport == run)
    #expect(t.isReviewed("a") && !t.isReviewed("b"))
    #expect(Set(t.reviewed.keys) == ["a"])
    t.reset()
    t.flush()
    let u = AudioEditStore(url: url)
    #expect(u.lastImport == nil && u.reviewed.isEmpty)
}
