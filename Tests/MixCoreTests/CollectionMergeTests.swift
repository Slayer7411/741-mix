import Foundation
import Testing
@testable import MixCore

private func track(_ key: String, artist: String = "Artist", title: String = "Title", path: String? = nil, size: Int = 9000,
                   duration: Double = 300, bitrate: Int = 320, cues: [Cue] = [], rating: Int = 0, plays: Int = 0,
                   comment: String = "", comment2: String = "", color: Int = 0) -> Track {
    var t = Track(key: key, path: path ?? "/Music/" + key)
    t.artist = artist; t.title = title; t.fileSizeKB = size; t.duration = duration; t.bitrate = bitrate
    t.cues = cues; t.rating = rating; t.playCount = plays; t.comment = comment; t.comment2 = comment2; t.color = color
    return t
}

private func hot(_ slot: Int, _ ms: Double) -> Cue { Cue(name: "", kind: .cue, startMs: ms, lengthMs: 0, hotcue: slot) }
private func memory(_ ms: Double) -> Cue { Cue(name: "", kind: .cue, startMs: ms, lengthMs: 0, hotcue: -1) }
private func loop(_ ms: Double, _ len: Double, slot: Int = -1) -> Cue { Cue(name: "", kind: .loop, startMs: ms, lengthMs: len, hotcue: slot) }

@Test func mergeTagsUnionKeepsOrderAndSeparator() {
    let k = track("k", comment2: "dark  groove mellow")
    let o = track("o", comment2: "Groove driving dark")
    let p = CollectionMerge.plan(keeper: k, others: [o], separators: " ")
    #expect(p.changes[.comment2] == "dark groove mellow driving")
    #expect(p.result.comment2 == "dark groove mellow driving")
    // Trennzeichen aus den Einstellungen: erstes Zeichen verbindet
    let q = CollectionMerge.plan(keeper: track("k", comment2: "a, b"), others: [track("o", comment2: "c")], separators: ", ")
    #expect(q.changes[.comment2] == "a,b,c")
    // nichts Neues: keine Änderung
    let same = CollectionMerge.plan(keeper: k, others: [track("o", comment2: "dark")], separators: " ")
    #expect(same.changes[.comment2] == nil)
}

@Test func mergeHotcueConflictBecomesMemoryCue() {
    let k = track("k", cues: [hot(0, 1000), hot(1, 2000)])
    // Slot 0 ist schon mit anderer Stelle belegt -> Memory-Cue; Slot 3 ist frei -> bleibt Hotcue 3
    let o = track("o", cues: [hot(0, 5000), hot(3, 8000)])
    let p = CollectionMerge.plan(keeper: k, others: [o], separators: " ")
    #expect(p.hotcues?.map(\.hotcue) == [0, 1, 3])
    #expect(p.hotcues?.first { $0.hotcue == 0 }?.startMs == 1000)
    #expect(p.memoryCues.map(\.startMs) == [5000])
    #expect(p.memoryCues.allSatisfy { $0.hotcue == -1 })
    #expect(p.result.cues.filter { $0.hotcue < 0 }.map(\.startMs) == [5000])
}

@Test func mergeHotcueSamePositionIsSkipped() {
    let k = track("k", cues: [hot(0, 1000)])
    // gleiche Stelle (±5 ms) in anderem Slot: nur einmal
    let o = track("o", cues: [hot(2, 1003), memory(1000)])
    let p = CollectionMerge.plan(keeper: k, others: [o], separators: " ")
    #expect(p.hotcues == nil)
    #expect(p.memoryCues.isEmpty)
}

@Test func mergeLoopsDedupe() {
    let k = track("k", cues: [loop(2000, 4000)])
    // gleicher Loop (±5 ms): weg; anderer Länge: dazu, als Memory-Loop
    let o = track("o", cues: [loop(2003, 4002), loop(2000, 8000)])
    let p = CollectionMerge.plan(keeper: k, others: [o], separators: " ")
    #expect(p.memoryCues.count == 1)
    #expect(p.memoryCues.first?.kind == .loop)
    #expect(p.memoryCues.first?.lengthMs == 8000)
    #expect(p.result.cues.filter { $0.kind == .loop }.count == 2)
}

@Test func mergeRatingPlaysColorComment() {
    let k = track("k", rating: 3, plays: 12, comment: "")
    let o1 = track("o1", rating: 5, plays: 7, comment: "keep me", color: 4)
    let o2 = track("o2", rating: 1, plays: 2, comment: "other", color: 2)
    let p = CollectionMerge.plan(keeper: k, others: [o1, o2], separators: " ")
    #expect(p.changes[.rating] == "5")
    #expect(p.plays == 21)
    #expect(p.changes[.comment] == "keep me")
    #expect(p.color == 4)
    // Behalter mit Kommentar und Farbe behält sie
    let k2 = track("k2", comment: "mine", color: 1)
    let p2 = CollectionMerge.plan(keeper: k2, others: [o1], separators: " ")
    #expect(p2.changes[.comment] == nil)
    #expect(p2.color == nil)
    #expect(p2.result.color == 1)
}

@Test func mergeGridKeptOrTaken() {
    let grid = Cue(name: "AutoGrid", kind: .grid, startMs: 500, lengthMs: 0, hotcue: -1)
    var o = track("o", cues: [grid])
    o.bpm = 128
    let k = track("k")
    let p = CollectionMerge.plan(keeper: k, others: [o], separators: " ")
    #expect(p.grid?.gridAnchorMs == 500)
    #expect(p.grid?.bpm == 128)
    #expect(p.result.gridAnchorMs == 500)
    // Behalter hat schon ein Grid: bleibt
    let own = Cue(name: "AutoGrid", kind: .grid, startMs: 100, lengthMs: 0, hotcue: -1)
    let p2 = CollectionMerge.plan(keeper: track("k", cues: [own]), others: [o], separators: " ")
    #expect(p2.grid == nil)
    #expect(p2.result.gridAnchorMs == 100)
}

@Test func mergeKeeperChoice() {
    var missing = track("missing", bitrate: 320)
    missing.fileMissing = true
    let local = track("local", bitrate: 192)
    // lokal vorhanden schlägt höhere Bitrate
    #expect(CollectionMerge.keeper([missing, local])?.key == "local")
    // gleiche Datei-Lage: höhere Bitrate
    let low = track("low", bitrate: 128), high = track("high", bitrate: 320)
    #expect(CollectionMerge.keeper([low, high])?.key == "high")
    // gleiche Bitrate: analysiert
    var analysed = track("analysed", bitrate: 320)
    analysed.bpm = 124; analysed.perceivedDb = -9
    #expect(CollectionMerge.keeper([high, analysed])?.key == "analysed")
    // Gleichstand: kleinerer Schlüssel
    #expect(CollectionMerge.keeper([track("b"), track("a")])?.key == "a")
    #expect(CollectionMerge.keeper([]) == nil)
}

@Test func mergeGroupsFindSameTrack() {
    let a = track("a", artist: "Ben Klock", title: "Subzero (Original Mix)", path: "/Music/Ben Klock - Subzero.mp3", size: 9000, duration: 400)
    // gleiche Datei, andere Schreibweise des Pfads
    let b = track("b", artist: "Other", title: "Other", path: "/music/ben klock - subzero.MP3", size: 1, duration: 10)
    // gleicher Artist + Titel, Länge ±1 s, gleiche Größe, andere Datei
    let c = track("c", artist: "ben klock", title: "Subzero", path: "/Volumes/x/subzero.flac", size: 9000, duration: 400.6)
    // gleicher Titel, aber andere Größe: keine Gruppe
    let d = track("d", artist: "Ben Klock", title: "Subzero", path: "/Volumes/y/s.flac", size: 9100, duration: 400)
    let groups = CollectionMerge.groups([a, b, c, d])
    #expect(groups.count == 1)
    #expect(groups.first?.keys == ["a", "b", "c"])
    #expect(groups.first?.reason == "same file path")
    // nur Namensgleichheit
    let g2 = CollectionMerge.groups([a, c])
    #expect(g2.first?.reason == "same artist + title, length ±1 s, same size")
    #expect(CollectionMerge.groups([a, d]).isEmpty)
}

@Test func mergeJobCarriesRemovalsRedirectsAndFields() {
    let k = track("k", cues: [hot(0, 1000)], rating: 2, plays: 1)
    let o = track("o", cues: [hot(0, 2000)], rating: 4, plays: 3)
    let p = CollectionMerge.plan(keeper: k, others: [o], separators: " ")
    let job = CollectionMerge.job(for: [p])
    #expect(job.remove == ["o"])
    #expect(job.redirects == ["o": "k"])
    #expect(job.changes["k"]?[.rating] == "4")
    #expect(job.info["k"]?["PLAYCOUNT"] == "4")
    #expect(job.info["k"]?["COLOR"] == nil)
    #expect(job.cues["k"] == nil)
    #expect(job.cueAdds["k"]?.map { $0.startMs } == [2000])
    #expect(CollectionMerge.removalJob(keys: ["x"]).remove == ["x"])
}
