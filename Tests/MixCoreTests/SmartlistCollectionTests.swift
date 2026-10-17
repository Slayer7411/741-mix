import Foundation
import Testing
@testable import MixCore

private let smartNow = SmartRules.day("2026-10-17")!

private let smartLib: [Track] = [
    {
        var t = Track(key: "a", path: "/Users/me/Music/a.mp3")
        t.title = "Ende"; t.artist = "Kühl Sounds"; t.genre = "Techno"; t.comment = "ende groove"; t.comment2 = "» VOLL"
        t.bpm = 131; t.color = 3; t.rating = 4; t.locked = true; t.playCount = 0; t.importDate = SmartRules.day("2026-10-01")
        return t
    }(),
    {
        var t = Track(key: "b", path: "/Users/me/Music/b.mp3")
        t.title = "Böse"; t.artist = "Basic"; t.genre = "dub"; t.comment = "Böse Nacht archive"; t.bpm = 122; t.color = 1
        t.playCount = 2; t.importDate = SmartRules.day("2024-02-11")
        return t
    }(),
    {
        var t = Track(key: "c", path: "/Users/me/Music/c.mp3")
        t.title = "Silence"; t.artist = "Other"; t.genre = "Techno"; t.bpm = 140
        return t
    }(),
]

private func smartHits(_ q: String, played: Set<String> = [], now: Date = smartNow) throws -> [String] {
    let parsed = try SmartQuery.parse(q)
    return smartLib.filter { parsed.matches($0, now: now, played: played) }.map(\.key)
}

/// Text ohne Groß/Klein und ohne Akzente, wie in der Suche
@Test func smartQueryTextIgnoresCaseAndAccents() throws {
    #expect(try smartHits(#"$COMMENT % "BÖSE""#) == ["b"])
    #expect(try smartHits(#"$COMMENT % "bose""#) == ["b"])
    #expect(try smartHits(#"$ARTIST == "KUHL SOUNDS""#) == ["a"])
    #expect(try smartHits(#"$TITLE STARTS_WITH "bose""#) == ["b"])
    #expect(try smartHits(#"$TITLE ENDS_WITH "NDE""#) == ["a"])
    #expect(try smartHits(#"$COMMENT2 % "voll""#) == ["a"])
    #expect(try smartHits(#"$COMMENT !% "archive""#) == ["a", "c"])
    #expect(try smartHits(#"$COMMENT !% "ARCHIVE" & $GENRE == "techno""#) == ["a", "c"])
}

@Test func smartQueryBooleanOperators() throws {
    #expect(try smartHits(#"$COMMENT % "ende" | $TITLE % "silence""#) == ["a", "c"])
    #expect(try smartHits(#"$GENRE == "techno" & $BPM >= 135"#) == ["c"])
    #expect(try smartHits(#"!($GENRE == "techno")"#) == ["b"])
    #expect(try smartHits(#"$GENRE == "techno" & ($BPM < 132 | $COLOR == 1)"#) == ["a"])
    // „&“ bindet stärker als „|“
    #expect(try smartHits(#"$TITLE % "silence" | $TITLE % "ende" & $BPM > 200"#) == ["c"])
}

/// PLAYED = PLAYCOUNT > 0 oder in der History (wie „gespielt“ im Rest der App)
@Test func smartQueryPlayedUsesHistory() throws {
    #expect(try smartHits(#"$PLAYED == TRUE"#) == ["b"])
    #expect(try smartHits(#"$PLAYED == TRUE"#, played: ["c"]) == ["b", "c"])
    #expect(try smartHits(#"$PLAYED == FALSE"#, played: ["c"]) == ["a"])
}

@Test func smartQueryLockField() throws {
    #expect(try smartHits(#"$LOCK == 1"#) == ["a"])
    #expect(try smartHits(#"$LOCK == TRUE"#) == ["a"])
    #expect(try smartHits(#"$LOCK == 0"#) == ["b", "c"])
}

/// `$IMPORT_DATE` und `$IMPORTDATE` sind dasselbe Feld; Datum gleich = gleicher Tag
@Test func smartQueryFieldNamesAndDays() throws {
    #expect(try smartHits(#"$IMPORT_DATE >= MONTHS_AGO(12)"#) == ["a"])
    #expect(try smartHits(#"$IMPORTDATE >= MONTHS_AGO(12)"#) == ["a"])
    #expect(try smartHits(#"$IMPORTDATE == "2026/10/1""#) == ["a"])
    #expect(try smartHits(#"$IMPORTDATE == "2024-02-11""#) == ["b"])
    #expect(try smartHits(#"$IMPORTDATE != "2026/10/1""#) == ["b", "c"])   // ohne Datum: ungleich
    #expect(try smartHits(#"$IMPORTDATE > DAYS_AGO(30)"#) == ["a"])
}

@Test func smartQueryNumbersAndColor() throws {
    #expect(try smartHits(#"$COLOR == 3"#) == ["a"])
    #expect(try smartHits(#"$BPM >= 130 & $BPM < 135"#) == ["a"])
    #expect(try smartHits(#"$RATING >= 4"#) == ["a"])
}

/// Fehler im Regel-Text melden, nicht abstürzen (die Fehlermeldung nennt das Zeichen)
@Test func smartQueryParseErrorsReport() {
    #expect(throws: SmartQuery.ParseError.self) { try SmartQuery.parse("$BPM > 5 6") }
    #expect(throws: SmartQuery.ParseError.self) { try SmartQuery.parse("$GENRE % \"x\" )") }
    #expect(throws: SmartQuery.ParseError.self) { try SmartQuery.parse("($BPM > 5") }
    #expect(SmartRule(.expression, .matches, "$BPM > 5 6").problem != nil)
    #expect(SmartQuery.Token.field("BPM").description == "$BPM")
    #expect(SmartQuery.Token.text("x").description == "\"x\"")
    #expect(SmartQuery.Token.number(6).description == "6.0")
    #expect(SmartQuery.Token.and.description == "&")
}

/// Smartlist aus einer `collection.nml`: Ordner, Smartlist mit Ausdruck (XML-Entities), leere Smartlist, Playlist
private let smartNML = """
<?xml version="1.0" encoding="UTF-8" standalone="no" ?>
<NML VERSION="19"><COLLECTION ENTRIES="2">
<ENTRY TITLE="Ende" ARTIST="Kühl Sounds"><LOCATION DIR="/:Users/:me/:Music/:" FILE="a.mp3" VOLUME="Macintosh HD"></LOCATION>
<INFO COMMENT="ende groove" RATING="» VOLL" COLOR="3" RANKING="204" IMPORT_DATE="2026/10/1"></INFO>
<TEMPO BPM="131"></TEMPO></ENTRY>
<ENTRY TITLE="Other" ARTIST="X"><LOCATION DIR="/:Users/:me/:Music/:" FILE="b.mp3" VOLUME="Macintosh HD"></LOCATION>
<INFO COMMENT="dub"></INFO><TEMPO BPM="124"></TEMPO></ENTRY>
</COLLECTION>
<PLAYLISTS><NODE TYPE="FOLDER" NAME="$ROOT"><SUBNODES COUNT="2">
<NODE TYPE="FOLDER" NAME="1_LIVE"><SUBNODES COUNT="2">
<NODE TYPE="SMARTLIST" NAME="ende"><SMARTLIST UUID="u1"><SEARCH_EXPRESSION VERSION="1" QUERY="$COMMENT % &quot;ende&quot; | $COMMENT2 % &quot;ende&quot; &amp; $COLOR == 3"></SEARCH_EXPRESSION></SMARTLIST></NODE>
<NODE TYPE="SMARTLIST" NAME="leer"><SMARTLIST UUID="u2"></SMARTLIST></NODE>
</SUBNODES></NODE>
<NODE TYPE="PLAYLIST" NAME="liste"><PLAYLIST ENTRIES="1" TYPE="LIST" UUID="u3"><ENTRY><PRIMARYKEY TYPE="TRACK" KEY="Macintosh HD/:Users/:me/:Music/:b.mp3"></PRIMARYKEY></ENTRY></PLAYLIST></NODE>
</SUBNODES></NODE></PLAYLISTS></NML>
"""

@Test func smartlistFromNMLKeepsKindRuleAndTracks() throws {
    let c = try NMLParser.parse(data: Data(smartNML.utf8))
    let folder = try #require(c.root.children.first { $0.name == "1_LIVE" })
    #expect(folder.kind == .folder)
    let ende = try #require(folder.children.first { $0.name == "ende" })
    #expect(ende.kind == .smartlist && ende.uuid == "u1")
    #expect(ende.query == #"$COMMENT % "ende" | $COMMENT2 % "ende" & $COLOR == 3"#)
    let leer = try #require(folder.children.first { $0.name == "leer" })
    #expect(leer.kind == .smartlist && leer.uuid == "u2" && leer.query.isEmpty)
    let liste = try #require(c.root.children.first { $0.name == "liste" })
    #expect(liste.kind == .playlist && liste.trackKeys == ["Macintosh HD/:Users/:me/:Music/:b.mp3"])
    // „ende“ im Kommentar oder (Tag „ende“ und Farbe 3): nur der erste Track
    let parsed = try SmartQuery.parse(ende.query)
    #expect(c.tracks.filter { parsed.matches($0) }.map(\.title) == ["Ende"])
}

/// MIX741_SMART_NML=<collection.nml>: alle Smartlists der Datei mit Regel, Trefferzahl und Baum-Art drucken (nur lesen)
@Test func smartlistsAgainstCollection() throws {
    guard let nml = ProcessInfo.processInfo.environment["MIX741_SMART_NML"] else { return }
    var c = try NMLParser.parse(url: URL(fileURLWithPath: nml))
    // Dateizustand wie beim Laden der App (fehlende Datei = FILESTATE 2)
    for i in c.tracks.indices { c.tracks[i].fileMissing = !FileManager.default.fileExists(atPath: c.tracks[i].path) }
    var lists: [(String, PlaylistNode)] = []
    func walk(_ n: PlaylistNode, _ path: String) {
        for ch in n.children {
            let p = path.isEmpty ? ch.name : path + "/" + ch.name
            if ch.kind == .smartlist { lists.append((p, ch)) }
            walk(ch, p)
        }
    }
    walk(c.root, "")
    let now = Date()
    var ok = 0, failed = 0, empty = 0
    print("[smart] \(c.tracks.count) tracks, \(lists.count) smartlists")
    for (path, n) in lists {
        var status = "ok"
        var hits = -1
        let t0 = Date()
        do {
            let parsed = try SmartQuery.parse(n.query)
            hits = c.tracks.filter { parsed.matches($0, now: now) }.count
            if hits == 0 { empty += 1 }
            ok += 1
        } catch {
            status = "FAIL \(error)"
            failed += 1
        }
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        print("[smart] \(path) | kind=\(n.kind) uuid=\(n.uuid.isEmpty ? "-" : "set") | \(status) | hits=\(hits) | \(ms) ms | \(n.query)")
    }
    print("[smart] parsed ok \(ok), failed \(failed), zero hits \(empty), missing files \(c.tracks.filter { !$0.fileExists }.count)")
    #expect(failed == 0)
}
