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

/// Befund -> markierter Bereich: Anfang 0 … time, Ende time … Dauer, Grenzen der Datei, Grid ohne Bereich
@Test func ripFindingRange() {
    let s = RipCheck.Finding(kind: .foreign, edge: .start, time: 7.5, confidence: 0.8, cues: [.key])
    let e = RipCheck.Finding(kind: .silence, edge: .end, time: 182.4, confidence: 0.9, cues: [.silence])
    #expect(RipCheck.range(s, duration: 190) == TrackRange(0, 7.5))
    #expect(RipCheck.range(e, duration: 190) == TrackRange(182.4, 190))
    // Dauer kürzer als der Befund: begrenzt, Ende hinter der Datei -> keiner
    #expect(RipCheck.range(s, duration: 5) == TrackRange(0, 5))
    #expect(RipCheck.range(e, duration: 180) == nil)
    #expect(RipCheck.range(s, duration: 0) == nil)
    #expect(RipCheck.range(RipCheck.Finding(kind: .silence, edge: .start, time: 0.005, confidence: 1, cues: []), duration: 190) == nil)
    #expect(RipCheck.range(RipCheck.Finding(kind: .grid, edge: .start, time: 2, confidence: 0.6, cues: [.phase]), duration: 190) == nil)
}

/// mit Schnittliste: Bereich in Ausgabe-Zeit
@Test func ripFindingRangeWithEditList() {
    let s = RipCheck.Finding(kind: .foreign, edge: .start, time: 7.5, confidence: 0.8, cues: [.key])
    let e = RipCheck.Finding(kind: .silence, edge: .end, time: 182.4, confidence: 0.9, cues: [.silence])
    // unverändert = wie ohne Liste
    #expect(RipCheck.range(s, duration: 190, edl: EditList(duration: 190)) == TrackRange(0, 7.5))
    #expect(RipCheck.range(e, duration: 190, edl: EditList(duration: 190)) == TrackRange(182.4, 190))
    // Mitte entfernt (100–120): Ende rückt um 20 s vor, Anfang bleibt
    var mid = EditList(duration: 190)
    let ok1 = mid.remove(TrackRange(100, 120))
    #expect(ok1)
    #expect(RipCheck.range(s, duration: 190, edl: mid) == TrackRange(0, 7.5))
    let r = RipCheck.range(e, duration: 190, edl: mid)
    #expect(r.map { abs($0.start - 162.4) < 1e-9 && abs($0.end - 170) < 1e-9 } == true)
    // Teil des Anfangs schon entfernt (0–5): Rest 0 … 2,5
    var head = EditList(duration: 190)
    let ok2 = head.remove(TrackRange(0, 5))
    #expect(ok2)
    #expect(RipCheck.range(s, duration: 190, edl: head).map { abs($0.end - 2.5) < 1e-9 && $0.start == 0 } == true)
    // ganz entfernt -> keiner
    var all = EditList(duration: 190)
    let ok3 = all.remove(TrackRange(0, 7.5))
    #expect(ok3)
    #expect(RipCheck.range(s, duration: 190, edl: all) == nil)
    var tail = EditList(duration: 190)
    let ok4 = tail.keep(TrackRange(0, 182.4))
    #expect(ok4)
    #expect(RipCheck.range(e, duration: 190, edl: tail) == nil)
}

/// erledigt: zählt nicht mehr als offen, bleibt beim neuen Ergebnis, solange es den Befund gibt; alte Datei ohne `done`
@Test func ripDoneStaysDone() throws {
    let s = RipCheckStore(url: nil)
    s.put(sample(), for: "a")
    s.markDone(["foreign.start"], for: "a")
    s.markDone(["foreign.start"], for: "a")
    let e = try #require(s.entry(for: "a"))
    #expect(e.done == ["foreign.start"] && e.dismissed.isEmpty)
    #expect(e.open(trim: nil, gridEdited: false).map(\.id) == ["grid.start", "silence.end"])
    s.put(sample(), for: "a")
    #expect(s.entry(for: "a")?.done == ["foreign.start"])
    var r = sample()
    r.findings.removeAll { $0.kind == .foreign }
    s.put(r, for: "a")
    #expect(s.entry(for: "a")?.done == [])
    let json = #"{"result":{"findings":[],"duration":10},"dismissed":["x"]}"#
    let d = try JSONDecoder().decode(RipCheck.Entry.self, from: Data(json.utf8))
    #expect(d.done.isEmpty && d.dismissed == ["x"])
}
