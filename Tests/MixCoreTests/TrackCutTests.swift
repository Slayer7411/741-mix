import Foundation
import Testing
@testable import MixCore

/// Schneiden: Grid, Cues, Länge, Dateiname, Eintrag in cuts.json
struct TrackCutTests {
    // 120 BPM: Beat 0,5 s, Takt 2 s
    let g = BeatGrid(anchor: 0.25, bpm: 120)

    @Test func snapOnBeatAndClamp() {
        #expect(abs(TrackRange.snap(10.3, grid: g, free: false, duration: 100) - 10.25) < 1e-9)
        #expect(TrackRange.snap(10.3, grid: g, free: true, duration: 100) == 10.3)
        #expect(TrackRange.snap(10.3, grid: nil, free: false, duration: 100) == 10.3)
        #expect(TrackRange.snap(100.2, grid: g, free: false, duration: 100) == 100)
        #expect(TrackRange.snap(-1, grid: g, free: true, duration: 100) == 0)
        let r = TrackRange(20.25, 4.25)
        #expect(r.start == 4.25 && r.end == 20.25)
        #expect(r.beatsText(grid: g) == "32")
        #expect(TrackRange.barBeat(4.25, grid: g) == "3.1")
        #expect(TrackRange.barBeat(4.75, grid: g) == "3.2")
    }

    @Test func gridRemove() {
        // Anker vor dem Bereich bleibt
        let r = TrackRange(10.25, 26.25)
        #expect(TrackCut.grid(g, mode: .remove, range: r) == g)
        // Anker dahinter: um die Länge nach vorn
        let late = BeatGrid(anchor: 30.25, bpm: 120)
        #expect(abs(TrackCut.grid(late, mode: .remove, range: r).anchor - 14.25) < 1e-9)
        // Anker im Bereich: ganze Takte dahinter, nie negativ
        let inside = BeatGrid(anchor: 10.25, bpm: 120)
        let n = TrackCut.grid(inside, mode: .remove, range: TrackRange(4.25, 30.25))
        #expect(n.anchor >= 0 && n.anchor < 2)
        #expect(abs((n.anchor - (10.25 - 26)).truncatingRemainder(dividingBy: 2)) < 1e-9)
    }

    @Test func gridKeep() {
        // Bereich ab Takt 3, Beat 2 (5,75 s): Anker davor -> ganze Takte, Taktlage bleibt (Beat 1 bei 1,5 s)
        let n = TrackCut.grid(g, mode: .keep, range: TrackRange(4.75, 36.75))
        #expect(abs(n.anchor - 1.5) < 1e-9)
        #expect(n.bpm == 120)
        // Anker im Bereich: relativ zum neuen Anfang
        let late = BeatGrid(anchor: 8.25, bpm: 120)
        #expect(abs(TrackCut.grid(late, mode: .keep, range: TrackRange(4.25, 36.25)).anchor - 4) < 1e-9)
    }

    @Test func cuesShiftAndDrop() {
        let r = TrackRange(10, 20)
        let cues = [
            Cue(name: "a", kind: .cue, startMs: 5_000, lengthMs: 0, hotcue: 0),
            Cue(name: "b", kind: .cue, startMs: 12_000, lengthMs: 0, hotcue: 1),
            Cue(name: "c", kind: .cue, startMs: 20_000, lengthMs: 0, hotcue: 2),
            Cue(name: "l", kind: .loop, startMs: 8_000, lengthMs: 4_000, hotcue: 3),   // läuft in den Bereich
            Cue(name: "m", kind: .loop, startMs: 30_000, lengthMs: 4_000, hotcue: -1),
            Cue(name: "g", kind: .grid, startMs: 250, lengthMs: 0, hotcue: -1),
        ]
        let removed = TrackCut.cues(cues, mode: .remove, range: r)
        #expect(removed.map(\.name) == ["a", "c", "m"])
        #expect(removed.map(\.startMs) == [5_000, 10_000, 20_000])
        let kept = TrackCut.cues(cues, mode: .keep, range: r)
        #expect(kept.map(\.name) == ["b"])
        #expect(kept[0].startMs == 2_000)
        #expect(TrackCut.duration(300, mode: .remove, range: r) == 290)
        #expect(TrackCut.duration(300, mode: .keep, range: r) == 10)
    }

    @Test func trackAndEntry() {
        var t = Track(key: "HD/:m/:a.mp3", path: "/m/a.mp3")
        t.artist = "Artist"; t.title = "Title"; t.comment = "c1"; t.comment2 = "PEAK BASIS"; t.bpm = 120; t.musicalKey = 9
        t.keyText = "8m"; t.playCount = 7
        t.cues = [Cue(name: "Grid", kind: .grid, startMs: 250, lengthMs: 0, hotcue: -1),
                  Cue(name: "m", kind: .cue, startMs: 40_000, lengthMs: 0, hotcue: -1)]
        let hot = [Cue(name: "h", kind: .cue, startMs: 50_000, lengthMs: 0, hotcue: 0),
                   Cue(name: "AutoGrid", kind: .grid, startMs: 250, lengthMs: 0, hotcue: 1)]
        let n = TrackCut.track(from: t, key: "HD/:m/:a [cut].m4a", path: "/m/a [cut].m4a", grid: BeatGrid(anchor: 0.25, bpm: 120.0123),
                               hotcues: hot, mode: .remove, range: TrackRange(10.25, 26.25), duration: 284)
        #expect(n.title == "Title [cut]" && n.artist == "Artist" && n.comment2 == "PEAK BASIS" && n.musicalKey == 9)
        #expect(n.playCount == 0 && n.duration == 284 && !n.loose)
        #expect(n.gridAnchorMs == 250 && n.bpm == 120.0123)
        #expect(n.cues.filter { $0.kind != .grid }.map(\.startMs) == [24_000, 34_000])
        // Grid-Marker auf Hotcue 2 bleibt dort (auf dem Anker)
        #expect(n.hotcues.map(\.hotcue) == [0, 1] && n.hotcues[1].kind == .grid && n.hotcues[1].startMs == 250)
        let back = CutEntry(track: n, source: t.key).track
        #expect(back.title == n.title && back.bpm == n.bpm && back.cues == n.cues && back.keyText == "8m" && back.comment == "c1")
        let data = try! JSONEncoder().encode(CutEntry(track: n, source: t.key))
        #expect(try! JSONDecoder().decode(CutEntry.self, from: data).track.key == n.key)
        #expect(TrackCut.title("Title [cut]") == "Title [cut]")
    }

    @Test func fileNames() {
        #expect(TrackCut.fileName("Song.mp3") { _ in false } == "Song [cut].m4a")
        let taken: Set = ["Song [cut].m4a", "Song [cut 2].m4a"]
        #expect(TrackCut.fileName("Song.mp3") { taken.contains($0) } == "Song [cut 3].m4a")
        #expect(TrackCut.fileName("Song [cut].m4a") { taken.contains($0) } == "Song [cut 3].m4a")
        #expect(TrackCut.fileName("Song [cut 2].m4a") { _ in false } == "Song [cut].m4a")
    }
}
