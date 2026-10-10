import Foundation
import Testing
@testable import MixCore

let sampleNML = """
<?xml version="1.0" encoding="UTF-8" standalone="no" ?>
<NML VERSION="19"><COLLECTION ENTRIES="2">
<ENTRY TITLE="Barrier" ARTIST="Marcel Dettmann"><LOCATION DIR="/:Music/:" FILE="a.m4a" VOLUME="Macintosh HD"></LOCATION>
<INFO COMMENT="1-4 groove_ostgut start " RATING="K tief kurz · B sub leicht roll · H off » BASIS" KEY="11m" PLAYTIME_FLOAT="130.08" IMPORT_DATE="2024/2/11" COLOR="1" RANKING="153"></INFO>
<TEMPO BPM="130.000473"></TEMPO><MUSICAL_KEY VALUE="19"></MUSICAL_KEY>
<CUE_V2 NAME="AutoGrid" TYPE="4" START="43.96" LEN="0" HOTCUE="0"></CUE_V2></ENTRY>
<ENTRY TITLE="Other" ARTIST="X"><LOCATION DIR="/:Music/:" FILE="b.mp3" VOLUME="Macintosh HD"></LOCATION>
<INFO COMMENT="2-2 dub"></INFO><TEMPO BPM="124"></TEMPO><MUSICAL_KEY VALUE="0"></MUSICAL_KEY></ENTRY>
</COLLECTION>
<PLAYLISTS><NODE TYPE="FOLDER" NAME="$ROOT"><SUBNODES COUNT="2">
<NODE TYPE="PLAYLIST" NAME="Prep"><PLAYLIST ENTRIES="1" TYPE="LIST"><ENTRY><PRIMARYKEY TYPE="TRACK" KEY="Macintosh HD/:Music/:b.mp3"></PRIMARYKEY></ENTRY></PLAYLIST></NODE>
<NODE TYPE="SMARTLIST" NAME="basis"><SMARTLIST><SEARCH_EXPRESSION VERSION="1" QUERY="$COMMENT2 % &quot;» BASIS&quot; | $COLOR == 4"></SEARCH_EXPRESSION></SMARTLIST></NODE>
</SUBNODES></NODE></PLAYLISTS></NML>
"""

@Test func parsesCollection() throws {
    let c = try NMLParser.parse(data: Data(sampleNML.utf8))
    #expect(c.tracks.count == 2)
    let t = c.tracks[0]
    #expect(t.key == "Macintosh HD/:Music/:a.m4a")
    #expect(t.path == "/Music/a.m4a")
    #expect(t.comment2.hasSuffix("BASIS"))
    #expect(t.openKey == "11m")
    #expect(c.tracks[1].openKey == "1d")
    #expect(t.rating == 3)
    #expect(t.hotcues.count == 1)
    #expect(c.root.name == "$ROOT")
    #expect(c.root.children.map(\.name) == ["Prep", "basis"])
    #expect(c.root.children[0].trackKeys == ["Macintosh HD/:Music/:b.mp3"])
}

@Test func evaluatesQueries() throws {
    let c = try NMLParser.parse(data: Data(sampleNML.utf8))
    let q = try SmartQuery.parse(c.root.children[1].query)
    #expect(c.tracks.filter { q.matches($0) }.map(\.title) == ["Barrier"])
    let now = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2024, month: 6, day: 1).date!
    #expect(try SmartQuery.parse(#"$COMMENT % "ostgut" & $IMPORTDATE >= MONTHS_AGO(12)"#).matches(c.tracks[0], now: now))
    #expect(try !SmartQuery.parse(#"$COMMENT !% "start""#).matches(c.tracks[0]))
    #expect(try SmartQuery.parse(#"$FILEPATH STARTS_WITH "/music" | $BPM > 200"#).matches(c.tracks[0]))
    #expect(try SmartQuery.parse(#"!($BPM >= 125)"#).matches(c.tracks[1]))
}

/// Alle Smartlists der echten Mac-Collection müssen sich parsen lassen (falls vorhanden).
@Test func parsesAllRealSmartlists() throws {
    let url = realCollection()
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    let c = try NMLParser.parse(url: url)
    #expect(c.tracks.count > 10000)
    var smart: [PlaylistNode] = []
    func walk(_ n: PlaylistNode) { if n.kind == .smartlist { smart.append(n) }; n.children.forEach(walk) }
    walk(c.root)
    #expect(smart.count > 50)
    for n in smart { _ = try SmartQuery.parse(n.query) }
}

@Test func beatGridMath() {
    let g = BeatGrid(anchor: 0.5, bpm: 120)   // Beat = 0,5 s
    #expect(g.beat == 0.5)
    #expect(g.beatPosition(at: 2.5) == 4)
    #expect(abs(g.phase(at: 2.625) - 0.25) < 1e-9)
    #expect(g.nearestBeat(to: 2.7) == 2.5)
    #expect(g.beatFloor(2.99) == 2.5)
    #expect(g.barBeat(at: 2.5) == (2, 1))
    #expect(abs(BeatGrid.phaseError(own: 3.9, master: 7.1) - (-0.2)) < 1e-9)
    #expect(BeatSizes.label(0.25) == "1/4")
    #expect(BeatSizes.label(16) == "16")
}

/// Eigene History-NML muss sich mit dem History-Leser wieder lesen lassen (Rundreise) und Roh-Einträge übernehmen.
@Test func historyRoundTrip() throws {
    let index = NMLEntryIndex(nmlText: sampleNML)
    #expect(index.raw.count == 2)
    #expect(index.raw["Macintosh HD/:Music/:a.m4a"]?.contains("CUE_V2") == true)
    let start = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 10, day: 10, hour: 21, minute: 5, second: 7).date!
    let e = [HistoryEntry(key: "Macintosh HD/:Music/:a.m4a", title: "Barrier", artist: "Marcel Dettmann", bpm: 130, keyText: "11m",
                          deck: 2, start: start, duration: 95.5),
             HistoryEntry(key: "Macintosh HD/:Other/:x & y.mp3", title: "Fremd", artist: "X", bpm: 125, keyText: "1d",
                          deck: 1, start: start.addingTimeInterval(120), duration: 60)]
    let text = HistoryNMLWriter.nml(entries: e, index: index, uuid: "0123456789abcdef0123456789abcdef")
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("hist-\(UUID().uuidString).nml")
    try text.write(to: url, atomically: true, encoding: .utf8)
    let back = HistoryNMLParser.parse(url: url)
    #expect(back.count == 2)
    #expect(back[0].title == "Barrier" && back[0].deck == 2 && abs(back[0].duration - 95.5) < 0.001)
    #expect(back[0].start == start)
    #expect(back[1].key == "Macintosh HD/:Other/:x & y.mp3")
    #expect(HistoryNMLWriter.fileName(for: start) == "history_2026y10m10d_21h05m07s.nml")
    // eigene Sitzungsdatei: Tag + Nummer, Reihenfolge über das Datum, Anzeige „2026-10-10 · 02“
    #expect(HistorySession.sessionFileName(day: start, number: 2) == "history_2026-10-10-02.nml")
    let s2 = HistorySession(url: URL(fileURLWithPath: "/x/history_2026-10-10-02.nml"), date: HistorySession.date(fromFileName: "history_2026-10-10-02.nml")!, source: .live)
    #expect(s2.label == "2026-10-10 · 02")
    #expect(HistorySession.date(fromFileName: "history_2026-10-10-02.nml")! > HistorySession.date(fromFileName: "history_2026-10-10-01.nml")!)
    #expect(HistorySession.date(fromFileName: "history_2026y10m10d_21h05m07s.nml") != nil)
    // echte History-Dateien der Collection lesbar?
    let dir = realCollection().deletingLastPathComponent().appendingPathComponent("History")
    if let f = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter({ $0.pathExtension == "nml" }).sorted(by: { $0.path < $1.path }).last {
        #expect(!HistoryNMLParser.parse(url: f).isEmpty)
    }
}

/// Browser-Suche über die echte Collection: der vorbereitete Suchtext muss alle Treffer der Feldsuche liefern
/// (plus akzent-unabhängige) und deutlich schneller sein – läuft nur mit vorhandener Collection.
@Test func searchTextCoversFieldSearch() throws {
    let url = realCollection()
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    let tracks = try NMLParser.parse(url: url).tracks
    for query in ["dettmann ba", "11m", "groove", "d"] {
        let words = query.split(separator: " ").map(String.init)
        var t0 = Date()
        let old = Set(tracks.filter { t in
            let hay = [t.artist, t.title, t.comment, t.comment2, t.label, t.genre, t.album, t.openKey].joined(separator: " ")
            return words.allSatisfy { hay.localizedCaseInsensitiveContains($0) }
        }.map(\.key))
        let oldMs = Date().timeIntervalSince(t0) * 1000
        let folded = words.map(Track.fold)
        t0 = Date()
        let new = Set(tracks.filter { $0.matches(words: folded) }.map(\.key))
        let newMs = Date().timeIntervalSince(t0) * 1000
        print(String(format: "[bench] search '%@': fields %.1f ms (%d) · searchText %.2f ms (%d)", query, oldMs, old.count, newMs, new.count))
        #expect(old.isSubset(of: new))
        #expect(new.count - old.count < 50)
    }
}

/// echte Collection auf diesem Mac (neuester Versionsordner); Tests überspringen sich ohne sie
private func realCollection() -> URL {
    let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Native Instruments")
    let dirs = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
    return dirs.filter { $0.lastPathComponent.hasPrefix("Traktor") }.map { $0.appendingPathComponent("collection.nml") }
        .filter { FileManager.default.fileExists(atPath: $0.path) }
        .sorted { $0.path.localizedStandardCompare($1.path) == .orderedDescending }.first
        ?? base.appendingPathComponent("none/collection.nml")
}

/// Open Key nach Halbton-Verschiebung: Dur/Moll bleibt, Umlauf bei 12
@Test func openKeyShift() {
    var t = Track(key: "k", path: "/x.mp3")
    t.musicalKey = 16            // Em = 2m
    #expect(t.openKey == "2m")
    #expect(t.openKey(shiftedBy: 1) == "9m")     // Fm
    #expect(t.openKey(shiftedBy: -5) == "3m")    // Bm
    #expect(t.openKey(shiftedBy: 12) == "2m")
    t.musicalKey = 0             // C = 1d
    #expect(t.openKey(shiftedBy: 1) == "8d")     // Db
    #expect(t.openKey(shiftedBy: -1) == "6d")    // B
}
