import Foundation
import Testing
@testable import MixCore

// Set-Aufnahme: Dateiname mit Konflikt, Tracklist (.txt) und CUE aus der History

private let utc: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
private let t0 = Date(timeIntervalSince1970: 1_791_000_000)   // 2026-10-03 04:00 UTC

@Test func recordingNameAvoidsConflicts() {
    #expect(RecordingName.stem(t0, calendar: utc) == "2026-10-03 04.00 Set")
    #expect(RecordingName.free(t0, ext: "m4a", calendar: utc) { _ in false } == "2026-10-03 04.00 Set")
    let taken: Set = ["2026-10-03 04.00 Set.m4a", "2026-10-03 04.00 Set 2.cue"]   // auch Begleitdateien zählen
    #expect(RecordingName.free(t0, ext: "m4a", calendar: utc) { taken.contains($0) } == "2026-10-03 04.00 Set 3")
}

@Test func tracklistFromHistory() {
    let h: [SetTracklist.Played] = [
        .init(start: t0 - 600, key: "old", artist: "Gone", title: "Before"),          // vor der Aufnahme, lief nicht mehr
        .init(start: t0 - 120, key: "run", artist: "Runner", title: "Already On"),    // lief beim Start -> 0:00
        .init(start: t0 + 754.9, key: "b", artist: "B Artist", title: "Second"),
        .init(start: t0 + 65, key: "a", artist: "", title: "First \"Mix\""),
        .init(start: t0 + 3723, key: "c", artist: "C", title: "Late"),
        .init(start: t0 + 9000, key: "d", artist: "D", title: "After Stop"),
    ]
    let list = SetTracklist(history: h, start: t0, end: t0 + 5000, playingAtStart: ["run"])
    #expect(list.entries.map(\.title) == ["Already On", "First \"Mix\"", "Second", "Late"])
    #expect(list.text == """
    00:00 Runner – Already On
    01:05 First "Mix"
    12:34 B Artist – Second
    1:02:03 C – Late

    """)
    let cue = list.cue(audioFile: "2026-10-03 04.00 Set.m4a", title: "2026-10-03 04.00 Set", date: t0, calendar: utc)
    #expect(cue.hasPrefix("REM DATE 2026-10-03\nTITLE \"2026-10-03 04.00 Set\"\nFILE \"2026-10-03 04.00 Set.m4a\" WAVE\n"))
    #expect(cue.contains("  TRACK 02 AUDIO\n    TITLE \"First 'Mix'\"\n    INDEX 01 01:05:00\n"))   // ohne Artist keine PERFORMER-Zeile
    #expect(cue.contains("  TRACK 03 AUDIO\n    TITLE \"Second\"\n    PERFORMER \"B Artist\"\n    INDEX 01 12:34:67\n"))
    #expect(cue.contains("INDEX 01 62:03:00"))
    #expect(SetTracklist.cueTime(0.5) == "00:00:37")
    #expect(SetTracklist(history: [], start: t0).text.isEmpty)
    #expect(list.cue(audioFile: "x.aif", title: "x").contains("FILE \"x.aif\" AIFF"))
}
