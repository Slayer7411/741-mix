import Foundation
import Testing
@testable import MixCore

private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/DAW")
private func fixture(_ name: String) throws -> Data { try Data(contentsOf: fixtures.appendingPathComponent(name)) }

// MARK: Warp-Marker -> Grid

@Test func warpGridConstantTempo() throws {
    // 128 BPM, Beat 0 bei 0,5 s, Hilfsmarker 1/32 Beat dahinter (wie die DAW ihn setzt)
    let b = 60 / 128.0
    let m = [WarpMarker(sec: 0.5, beat: 0), WarpMarker(sec: 0.5 + 64 * b, beat: 64), WarpMarker(sec: 0.5 + 64.03125 * b, beat: 64.03125)]
    let g = try #require(WarpGrid(markers: m))
    #expect(abs(g.grid.bpm - 128) < 1e-9 && abs(g.grid.anchor - 0.5) < 1e-9)
    #expect(g.constant && g.maxDeviationMs < 1e-6 && g.markers.count == 3)
}

@Test func warpGridAnchorOnFirstDownbeat() throws {
    // Datei beginnt mitten im Takt (Beat 2,625 bei 0 s): Takt-Eins = Beat 4
    let b = 60 / 140.0
    let g = try #require(WarpGrid(markers: [WarpMarker(sec: 0, beat: 2.625), WarpMarker(sec: 10 * b, beat: 12.625)]))
    #expect(abs(g.grid.anchor - 1.375 * b) < 1e-9)
    #expect(abs(g.grid.beatPosition(at: g.grid.anchor)) < 1e-9)
    // Beat 0 nach dem Ende der Datei -> erste Takt-Eins in der Datei
    let late = try #require(WarpGrid(markers: [WarpMarker(sec: 100, beat: 0), WarpMarker(sec: 100 + 8 * b, beat: 8)], duration: 60))
    #expect(late.grid.anchor >= 0 && late.grid.anchor < 4 * b)
}

@Test func warpGridTempoChangeTakesLongestSection() throws {
    // 16 Beats 120 BPM (8 s), dann 64 Beats 128 BPM (30 s): Grid = 128, Anker auf der Linie des langen Abschnitts
    let m = [WarpMarker(sec: 0, beat: 0), WarpMarker(sec: 8, beat: 16), WarpMarker(sec: 38, beat: 80)]
    let g = try #require(WarpGrid(markers: m))
    #expect(abs(g.grid.bpm - 128) < 1e-9 && !g.constant)
    #expect(abs(g.tempoRange.lowerBound - 120) < 1e-9 && abs(g.tempoRange.upperBound - 128) < 1e-9)
    #expect(abs(g.grid.beatPosition(at: 8) - g.grid.beatPosition(at: 8).rounded()) < 1e-9)   // Abschnittsgrenze liegt auf einem Beat
    #expect(g.maxDeviationMs > 400)   // vor dem Abschnitt weicht das konstante Grid ab
}

@Test func warpGridRejectsTooFewOrBroken() {
    #expect(WarpGrid(markers: []) == nil)
    #expect(WarpGrid(markers: [WarpMarker(sec: 1, beat: 0)]) == nil)
    #expect(WarpGrid(markers: [WarpMarker(sec: 1, beat: 0), WarpMarker(sec: 1, beat: 4)]) == nil)   // gleiche Zeit
    #expect(WarpGrid(markers: [WarpMarker(sec: .nan, beat: 0), WarpMarker(sec: 1, beat: 4)]) == nil)
    // rückläufiger Marker fällt weg
    #expect(WarpGrid.clean([WarpMarker(sec: 0, beat: 0), WarpMarker(sec: 2, beat: 4), WarpMarker(sec: 1, beat: 8)]).count == 2)
}

@Test func warpMapBothWays() throws {
    let map = try #require(WarpMap([WarpMarker(sec: 0, beat: 0), WarpMarker(sec: 8, beat: 16), WarpMarker(sec: 38, beat: 80)]))
    #expect(abs(map.sec(atBeat: 8) - 4) < 1e-12 && abs(map.sec(atBeat: 48) - 23) < 1e-12)
    #expect(abs(map.sec(atBeat: -2) + 1) < 1e-12)          // davor: Tempo des ersten Abschnitts
    #expect(abs(map.sec(atBeat: 96) - 45.5) < 1e-12)       // danach: Tempo des letzten
    for s in stride(from: -3.0, through: 50, by: 0.7) { #expect(abs(map.sec(atBeat: map.beat(atSec: s)) - s) < 1e-9) }
    let beats = map.beats(in: 0...8)
    #expect(beats.count == 17 && beats.filter(\.bar).count == 5)
}

// MARK: Clip-Analyse-Datei

@Test func clipAnalysisFixture() throws {
    let info = try ClipAnalysisFile.parse(try fixture("clip.wav.asd"))
    #expect(info.version == 5 && info.isWarped == true && info.beatsPerBar == 4)
    #expect(info.markers.count == 2 && info.markers[0] == WarpMarker(sec: 0, beat: 0))
    #expect(abs(info.markers[1].beat - 0.03125) < 1e-12 && abs(info.markers[1].sec - 0.013297872340425532) < 1e-15)
    #expect(abs((WarpGrid(markers: info.markers)?.grid.bpm ?? 0) - 141) < 1e-6)
}

/// synthetisch: Markerliste der echten Datei durch n Marker ersetzt (gleicher Aufbau, Anzahl + Einträge)
private func asdWith(_ markers: [WarpMarker]) throws -> Data {
    let d = try fixture("clip.wav.asd")
    let tag = Data([0x00, 0x0A]) + Data("WarpMarker".utf8)
    // erster Listeneintrag: nach der Klassenbeschreibung (die mit Feldzahl 2 + „SecTime“ weitergeht)
    var at = d.startIndex, first: Data.Index?
    while let r = d.range(of: tag, in: at..<d.endIndex) {
        let after = r.upperBound
        if d[after..<after + 4] != Data([2, 0, 0, 0]) { first = r.lowerBound; break }
        at = after
    }
    let start = try #require(first), entry = 2 + 10 + 4 + 16
    var out = Data(d[d.startIndex..<start - 4])
    withUnsafeBytes(of: UInt32(markers.count).littleEndian) { out.append(contentsOf: $0) }
    for (i, m) in markers.enumerated() {
        out.append(tag)
        withUnsafeBytes(of: UInt32(i).littleEndian) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: m.sec.bitPattern.littleEndian) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: m.beat.bitPattern.littleEndian) { out.append(contentsOf: $0) }
    }
    out.append(d[(start + 2 * entry)...])
    return out
}

@Test func clipAnalysisManyMarkers() throws {
    let b = 60 / 124.0
    let m = (0..<40).map { WarpMarker(sec: 0.25 + Double($0 * 8) * b, beat: Double($0 * 8)) }
    let info = try ClipAnalysisFile.parse(try asdWith(m))
    #expect(info.markers == m)
    let g = try #require(WarpGrid(markers: info.markers))
    #expect(abs(g.grid.bpm - 124) < 1e-9 && abs(g.grid.anchor - 0.25) < 1e-9 && g.constant)
    #expect(try ClipAnalysisFile.parse(try asdWith([])).markers.isEmpty)
}

@Test func clipAnalysisRejectsForeignAndTruncated() throws {
    #expect(throws: ClipAnalysisFile.ParseError.notClipAnalysis) { try ClipAnalysisFile.parse(Data("RIFF....WAVE".utf8)) }
    #expect(throws: ClipAnalysisFile.ParseError.notClipAnalysis) { try ClipAnalysisFile.parse(Data()) }
    let d = try fixture("clip.wav.asd")
    // jede abgeschnittene Fassung: Fehler, kein Absturz
    for n in stride(from: 0, to: 3070, by: 7) { #expect(throws: (any Error).self) { try ClipAnalysisFile.parse(d.prefix(n)) } }
    #expect(ClipAnalysisFile.sidecar(for: "/a/b c.wav").path == "/a/b c.wav.asd")
}

// MARK: Brücken-Protokoll

@Test func bridgeParsesScriptPackets() throws {
    guard case let .song(s) = try DAWBridge.parse(try fixture("bridge-song.json")) else { Issue.record("kein song"); return }
    #expect(s.tempo == 128 && s.playing && s.beat == 12 && s.beatsPerBar == 4 && s.seq == 7)
    #expect(s.clipIDs == ["c101", "c103"] && s.positions["c101"] == .init(playing: true, value: 4.5))
    guard case let .clip(c) = try DAWBridge.parse(try fixture("bridge-clip.json")) else { Issue.record("kein clip"); return }
    #expect(c.id == "c101" && c.track == 0 && c.trackName == "Drums" && c.name == "Loop 128" && c.file == "/tmp/minos-daw/loop.wav")
    #expect(c.markers == [WarpMarker(sec: 0.5, beat: 0), WarpMarker(sec: 15.5, beat: 32), WarpMarker(sec: 15.514648, beat: 32.03125)])
    #expect(c.loop == 0...16 && c.looping && c.selected && !c.arrangement && c.warping)
    let g = try #require(c.grid())
    #expect(abs(g.grid.bpm - 128) < 0.01 && abs(g.grid.anchor - 0.5) < 1e-9)
    guard case let .clip(a) = try DAWBridge.parse(try fixture("bridge-clip-arrangement.json")) else { Issue.record("kein clip"); return }
    #expect(a.arrangement && a.markers.first == WarpMarker(sec: 0, beat: -4))
    // Beat 0 bei 1,875 s
    #expect(abs((a.grid()?.grid.anchor ?? 0) - 1.875) < 1e-9)
}

@Test func bridgeRejectsBadPackets() {
    #expect(throws: DAWBridge.ParseError.notJSON) { try DAWBridge.parse(Data("hallo".utf8)) }
    #expect(throws: DAWBridge.ParseError.wrongVersion(2)) { try DAWBridge.parse(Data(#"{"v":2,"t":"song"}"#.utf8)) }
    #expect(throws: DAWBridge.ParseError.unknownType("x")) { try DAWBridge.parse(Data(#"{"v":1,"t":"x"}"#.utf8)) }
    #expect(throws: DAWBridge.ParseError.missing("id")) { try DAWBridge.parse(Data(#"{"v":1,"t":"clip"}"#.utf8)) }
    // Wahrheitswert statt Zahl, kaputte Marker: übergangen
    guard case let .clip(c)? = try? DAWBridge.parse(Data(#"{"v":1,"t":"clip","id":"a","start":true,"markers":[[1],[0,"x"],[4,2]]}"#.utf8))
    else { Issue.record("clip"); return }
    #expect(c.start == 0 && c.markers == [WarpMarker(sec: 2, beat: 4)])
}

@Test func bridgeSessionState() throws {
    var s = DAWSession()
    let clip = DAWBridge.Clip(id: "a", track: 1, name: "x", warping: true, markers: [WarpMarker(sec: 0, beat: 0), WarpMarker(sec: 2, beat: 4)])
    let first = s.apply(.clip(clip), now: 1), again = s.apply(.clip(clip), now: 1.1)
    #expect(first && !again)   // gleich -> keine Listenänderung
    var song = DAWBridge.Song()
    song.tempo = 120; song.playing = true; song.clipIDs = ["a"]; song.positions = ["a": .init(playing: true, value: 8)]
    s.apply(.song(song), now: 2)
    #expect(s.clips["a"]?.playing == true && s.trackCount == 1 && s.alive(now: 3) && !s.alive(now: 4.1))
    // 0,25 s später bei 120 BPM: +0,5 Beats; mehr als 0,5 s wird nicht weitergerechnet
    #expect(abs((s.position(of: "a", now: 2.25) ?? 0) - 8.5) < 1e-9)
    #expect(abs((s.position(of: "a", now: 9) ?? 0) - 9) < 1e-9)
    song.clipIDs = []; song.positions = [:]
    let gone = s.apply(.song(song), now: 3)
    #expect(gone && s.clips.isEmpty)   // Clip weg
    s.apply(.clip(clip), now: 3.1)
    let bye = s.apply(.bye, now: 4)
    #expect(bye && s.clips.isEmpty && !s.connected)
}

@Test func bridgeReceiverGetsLocalPackets() async throws {
    let r = DAWBridgeReceiver()
    try r.start(port: 0)
    defer { r.stop() }
    #expect(r.port > 0 && r.running)
    final class Box: @unchecked Sendable {
        private var list: [DAWBridge.Message] = []; private let lock = NSLock()
        func add(_ m: DAWBridge.Message) { lock.withLock { list.append(m) } }
        var got: [DAWBridge.Message] { lock.withLock { list } }
    }
    let box = Box()
    r.onMessage = { m in box.add(m) }
    #expect(DAWBridgeReceiver.send(try fixture("bridge-clip.json"), port: r.port))
    #expect(DAWBridgeReceiver.send(Data("kaputt".utf8), port: r.port))
    #expect(DAWBridgeReceiver.send(try fixture("bridge-song.json"), port: r.port))
    for _ in 0..<100 {
        if box.got.count >= 2 { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(box.got.count == 2 && r.rejected == 1)
    var s = DAWSession()
    for m in box.got { s.apply(m, now: 1) }
    #expect(s.clips["c101"]?.markers.count == 3 && s.song.tempo == 128)
    // zweiter Empfänger auf demselben Port: Fehler statt stiller Doppelbelegung
    let other = DAWBridgeReceiver()
    #expect(throws: DAWBridgeReceiver.StartError.self) { try other.start(port: r.port) }
}

@Test func gridSourceOrder() {
    var t = Track(key: "k", path: "/x")
    #expect(GridSource.of(t, edit: nil, analysis: nil) == nil)
    t.bpm = 120; t.cues = [Cue(name: "Grid", kind: .grid, startMs: 0, lengthMs: 0, hotcue: -1)]
    #expect(GridSource.of(t, edit: nil, analysis: nil) == .collection)
    #expect(GridSource.of(t, edit: nil, analysis: TrackAnalysis(bpm: 121, gridAnchorMs: 3)) == .analysis)
    var e = TrackEdit(bpm: 122, gridAnchorMs: 4)
    #expect(GridSource.of(t, edit: e, analysis: TrackAnalysis(bpm: 121)) == .manual)
    e.gridSource = .daw
    #expect(GridSource.of(t, edit: e, analysis: nil) == .daw)
    // Herkunft zählt beim Vergleich, alte Dateien ohne Feld lesen sich
    #expect(!e.same(as: TrackEdit(bpm: 122, gridAnchorMs: 4)))
    let old = #"{"bpm":120,"gridAnchorMs":5,"modified":0}"#
    #expect((try? JSONDecoder().decode(TrackEdit.self, from: Data(old.utf8)))?.gridSource == nil)
}
