import Foundation
import Testing
@testable import MixCore

/// Schnittliste: Bearbeitungen in Ausgabe-Zeit, Frames sample-genau, Grid und Cues, Tool-Loop-Rechnung
struct EditListTests {
    let g = BeatGrid(anchor: 0, bpm: 120)   // Beat 0,5 s, Takt 2 s

    @Test func plainAndMarks() {
        var e = EditList(duration: 60)
        #expect(e.isPlain && e.duration == 60)
        let ok1 = e.split(at: 10)
        #expect(ok1)
        #expect(e.segments.count == 2 && e.isPlain && !e.isCut(joint: 0))
        let ok2 = e.split(at: 10)
        #expect(!ok2)   // schon eine Naht
        let ok3 = e.removeMark(0)
        #expect(ok3 && e.segments.count == 1)
    }

    @Test func removeKeepDuplicateMute() {
        var e = EditList(duration: 60)
        let ok4 = e.remove(TrackRange(10, 20))
        #expect(ok4)
        #expect(e.duration == 50 && e.segments == [EditSegment(0, 10), EditSegment(20, 60)])
        #expect(e.isCut(joint: 0) && !e.isPlain)
        #expect(e.sourceTime(10) == 20 && e.outputTime(25) == 15 && e.outputTime(15) == nil)

        var k = EditList(duration: 60)
        let ok5 = k.keep(TrackRange(8, 16))
        #expect(ok5)
        #expect(k.segments == [EditSegment(8, 16)] && k.duration == 8)
        let ok6 = k.keep(TrackRange(0, 0.5))
        #expect(!ok6)   // kürzer als 1 s

        var d = EditList(duration: 60)
        let copy = d.duplicate(TrackRange(4, 6))
        #expect(copy == TrackRange(6, 8))
        #expect(d.segments == [EditSegment(0, 4), EditSegment(4, 6), EditSegment(4, 6), EditSegment(6, 60)])
        #expect(d.duration == 62)

        var m = EditList(duration: 60)
        let ok7 = m.mute(TrackRange(2, 4))
        #expect(ok7)
        #expect(m.segments[1].muted && m.duration == 60 && !m.isPlain)
        let ok8 = m.mute(TrackRange(2, 4))
        #expect(ok8 && m.isPlain)   // noch einmal = hörbar
    }

    @Test func moveSegments() {
        var e = EditList(duration: 12)
        e.split(at: 4)
        e.split(at: 8)
        // mittleres Stück nach links: [4-8][0-4][8-12]
        let r = e.move(TrackRange(4, 8), by: -1)
        #expect(r == TrackRange(0, 4))
        #expect(e.segments.map(\.start) == [4, 0, 8])
        let none = e.move(TrackRange(0, 4), by: -1)
        #expect(none == nil)   // ganz links
        let r2 = e.move(TrackRange(0, 4), by: 1)
        #expect(r2 == TrackRange(4, 8) && e.segments.map(\.start) == [0, 4, 8])
    }

    @Test func moveJointRolls() {
        var e = EditList(duration: 60)
        e.remove(TrackRange(10, 20))
        let ok9 = e.moveJoint(0, to: 12)
        #expect(ok9)   // links 2 s länger, rechts beginnt 2 s später
        #expect(e.segments == [EditSegment(0, 12), EditSegment(22, 60)] && e.duration == 50)
        let ok10 = e.moveJoint(0, to: 100)
        #expect(ok10)
        #expect(e.segments[1].length >= EditList.minSegment - 1e-9)
    }

    /// Frames: Ränder gerundet, Länge = Summe der Stücke, sample-genau
    @Test func framesSampleExact() {
        var e = EditList(duration: 10)
        e.remove(TrackRange(1.25, 2.5))
        e.mute(TrackRange(3, 4))
        let f = e.frames(rate: 44_100, sourceFrames: 441_000)
        #expect(f.pieces == [0..<55_125, 110_250..<187_425, 187_425..<231_525, 231_525..<441_000])   // stumm 3–4 s Ausgabe = 4,25–5,25 s Quelle
        #expect(f.muted == [false, false, true, false])
        #expect(f.pieces.reduce(0) { $0 + $1.count } == 441_000 - 55_125)
        // Marken ohne Schnitt verschwinden in den Frames
        var p = EditList(duration: 10)
        p.split(at: 5)
        #expect(p.frames(rate: 48_000, sourceFrames: 480_000).pieces == [0..<480_000])
    }

    @Test func gridAndCues() {
        var e = EditList(duration: 60)
        e.remove(TrackRange(0, 3))   // anderthalb Takte weg
        let ng = e.grid(BeatGrid(anchor: 0.5, bpm: 120))
        #expect(abs(ng.anchor - 1.5) < 1e-9 && ng.bpm == 120)   // 0,5 - 3 = -2,5 -> um ganze Takte nach vorn
        let cues = [Cue(name: "a", kind: .cue, startMs: 1000, lengthMs: 0, hotcue: 0),
                    Cue(name: "b", kind: .cue, startMs: 10_000, lengthMs: 0, hotcue: 1),
                    Cue(name: "l", kind: .loop, startMs: 2000, lengthMs: 2000, hotcue: 2)]
        let m = e.cues(cues)
        #expect(m.count == 1 && m[0].hotcue == 1 && abs(m[0].startMs - 7000) < 1e-6)
    }

    @Test func snapToRaster() {
        #expect(TrackRange.snap(4.9, grid: g, step: 4, free: false, duration: 60) == 4)   // Takt
        #expect(TrackRange.snap(5.1, grid: g, step: 4, free: false, duration: 60) == 6)
        #expect(TrackRange.snap(5.1, grid: g, step: 1, free: false, duration: 60) == 5)
        #expect(TrackRange.snap(5.1, grid: g, step: 4, free: true, duration: 60) == 5.1)
        #expect(EditSnap.bar.next == .bars2 && EditSnap.beat.previous == .bars8)
    }

    @Test func toolLoopRangeAndFrames() {
        // ohne Loop: nächster Taktanfang zur Position
        #expect(ToolLoop.range(beats: 8, grid: g, position: 4.6, loopStart: nil, duration: 60) == TrackRange(4, 8))
        #expect(ToolLoop.range(beats: 8, grid: g, position: 5.2, loopStart: nil, duration: 60) == TrackRange(6, 10))
        // aktiver Loop: ab seinem Anfang
        #expect(ToolLoop.range(beats: 4, grid: g, position: 30, loopStart: 7.5, duration: 60) == TrackRange(7.5, 9.5))
        #expect(ToolLoop.range(beats: 16, grid: g, position: 58, loopStart: nil, duration: 60) == nil)
        // Länge exakt beats · 60 / bpm · rate
        #expect(ToolLoop.frames(beats: 8, bpm: 128, rate: 44_100) == 165_375)
        #expect(ToolLoop.frames(beats: 2, bpm: 174, rate: 48_000) == Int((2.0 * 60 / 174 * 48_000).rounded()))
    }

    @Test func toolLoopLabels() {
        #expect(ToolLoop.title("Song [cut]", beats: 8) == "Song [tool-loop 8]")
        #expect(ToolLoop.fileName("A - B.flac", beats: 4) { _ in false } == "A - B [tool-loop 4].m4a")
        #expect(ToolLoop.fileName("A.wav", beats: 4) { $0 == "A [tool-loop 4].m4a" } == "A [tool-loop 4 #2].m4a")
        #expect(ToolLoop.comment(beats: 8, bpm: 128, from: "Song") == "tool-loop 8 beats · 128 BPM · from Song")
        #expect(ToolLoop.tags("", separators: " ") == "tool-loop")
        #expect(ToolLoop.tags("peak dark", separators: " ") == "peak dark tool-loop")
        #expect(ToolLoop.tags("peak; tool-loop", separators: ";") == "peak; tool-loop")
        var t = Track(key: "k", path: "/m/Song.wav")
        t.title = "Song"; t.musicalKey = 7; t.comment2 = "peak"
        let n = ToolLoop.track(from: t, key: "n", path: "/m/Song [tool-loop 8].m4a", beats: 8, bpm: 128, duration: 3.75, separators: " ")
        #expect(n.title == "Song [tool-loop 8]" && n.musicalKey == 7 && n.bpm == 128)
        #expect(ToolLoop.isToolLoop(n, separators: " ") && n.comment.hasPrefix("tool-loop 8 beats"))
        #expect(BeatGrid(track: n)?.anchor == 0)
    }

    /// edits.json: Schnittliste gespeichert, ältere Einträge ohne sie lesbar
    @Test func trackEditCodable() throws {
        var e = TrackEdit()
        var l = EditList(duration: 30)
        l.remove(TrackRange(2, 4))
        e.edl = l
        #expect(!e.isEmpty)
        let back = try JSONDecoder().decode(TrackEdit.self, from: JSONEncoder().encode(e))
        #expect(back.edl == l)
        let old = try JSONDecoder().decode(TrackEdit.self, from: Data(#"{"bpm":128,"modified":0}"#.utf8))
        #expect(old.edl == nil && old.bpm == 128)
    }
}
