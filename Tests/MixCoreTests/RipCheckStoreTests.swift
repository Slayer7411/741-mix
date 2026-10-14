import Foundation
import Testing
@testable import MixCore

private func sample() -> RipCheck.Result {
    var f = RipCheck.Finding(kind: .foreign, edge: .start, time: 7.5, confidence: 0.8, cues: [.key, .loop])
    f.keyForeign = 0; f.keyTrack = 6; f.bars = 4
    var g = RipCheck.Finding(kind: .grid, edge: .start, time: 2, confidence: 0.6, cues: [.phase])
    g.offsetMs = 31
    let e = RipCheck.Finding(kind: .silence, edge: .end, time: 182.4, confidence: 0.95, cues: [.silence])
    return RipCheck.Result(findings: [f, g, e], duration: 190)
}

/// Datei-Rundreise: Befunde und verworfene bleiben, verworfene ohne Befund fallen beim neuen Ergebnis weg
@Test func ripStoreRoundTrip() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ripcheck-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let s = RipCheckStore(url: url)
    s.put(sample(), for: "a")
    s.dismiss(["grid.start"], for: "a")
    s.flush()
    let t = RipCheckStore(url: url)
    let e = try #require(t.entry(for: "a"))
    #expect(e.result == sample())
    #expect(e.dismissed == ["grid.start"])
    var r = sample()
    r.findings.removeAll { $0.kind == .grid }
    t.put(r, for: "a")
    #expect(t.entry(for: "a")?.dismissed == [])
    t.rename(from: "a", to: "b")
    #expect(t.entry(for: "a") == nil && t.entry(for: "b") != nil)
}

/// offen: nicht verworfen, ohne Schnitt auf der Seite, Grid ohne eigenes Grid; Spaltentext
@Test func ripOpenFindingsAndColumn() {
    var e = RipCheck.Entry(result: sample())
    #expect(e.open(trim: nil, gridEdited: false).count == 3)
    #expect(RipCheck.columnText(e.open(trim: nil, gridEdited: false)) == "▸ 7,5 s ◂ 3:02 GRID")
    #expect(e.open(trim: TrackTrim(start: 7.5), gridEdited: false).map(\.id) == ["grid.start", "silence.end"])
    #expect(e.open(trim: TrackTrim(start: 7.5, end: 182), gridEdited: true).isEmpty)
    e.dismissed = ["silence.end"]
    #expect(RipCheck.columnText(e.open(trim: nil, gridEdited: true)) == "▸ 7,5 s")
    #expect(RipCheck.shortTime(59.96) == "60,0 s" || RipCheck.shortTime(59.96) == "1:00")
}

/// ältere Datei ohne optionale Felder lädt
@Test func ripEntryDecodesMinimal() throws {
    let json = #"{"a":{"result":{"findings":[{"kind":"silence","edge":"start","time":3.1,"confidence":0.9,"cues":["silence"]}],"duration":100},"dismissed":[],"checked":0,"version":1}}"#
    let d = try JSONDecoder().decode([String: RipCheck.Entry].self, from: Data(json.utf8))
    #expect(d["a"]?.result.start?.time == 3.1)
}
