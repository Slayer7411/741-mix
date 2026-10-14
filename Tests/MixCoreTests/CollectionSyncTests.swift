import Foundation
import Testing
@testable import MixCore

/// Collection mit Cues aller Arten (Grid als Hotcue 1, Cue, Loop, Memory-Cue, Fade-In), Umlauten, Entities,
/// gesperrtem Eintrag und Playlist-Baum (Ordner, Playlist, Smartlist)
let syncNML = """
<?xml version="1.0" encoding="UTF-8" standalone="no" ?>
<NML VERSION="19"><HEAD COMPANY="www.example.com" PROGRAM="x"></HEAD>
<COLLECTION ENTRIES="3"><ENTRY MODIFIED_DATE="2024/7/30" MODIFIED_TIME="64041" LOCK="0" AUDIO_ID="AIJe///c7t7==" TITLE="Bär &amp; Wolf" ARTIST="Ünal"><LOCATION DIR="/:Music/:Ä &amp; B/:" FILE="a &amp; b.m4a" VOLUME="Macintosh HD" VOLUMEID="Macintosh HD"></LOCATION>
<MODIFICATION_INFO AUTHOR_TYPE="user"></MODIFICATION_INFO>
<INFO BITRATE="614001" GENRE="Techno" COMMENT="1-4 &quot;start&quot;" KEY="11m" PLAYTIME="131" IMPORT_DATE="2024/2/11" FLAGS="12" FILESIZE="9884"></INFO>
<TEMPO BPM="130.000473" BPM_QUALITY="100.000000"></TEMPO>
<MUSICAL_KEY VALUE="19"></MUSICAL_KEY>
<CUE_V2 NAME="AutoGrid" DISPL_ORDER="0" TYPE="4" START="43.963768" LEN="0.000000" REPEATS="-1" HOTCUE="0"></CUE_V2>
<CUE_V2 NAME="n.n." DISPL_ORDER="0" TYPE="0" START="1691.317068" LEN="0.000000" REPEATS="-1" HOTCUE="1"></CUE_V2>
<CUE_V2 NAME="Drop &amp; Ö" DISPL_ORDER="0" TYPE="5" START="6306.054110" LEN="1558.418551" REPEATS="-1" HOTCUE="2"></CUE_V2>
<CUE_V2 NAME="n.n." DISPL_ORDER="0" TYPE="0" START="90000.000000" LEN="0.000000" REPEATS="-1" HOTCUE="-1"></CUE_V2>
</ENTRY>
<ENTRY MODIFIED_DATE="2025/5/30" MODIFIED_TIME="46086" TITLE="Orlok's Symphony" ARTIST="Größe"><LOCATION DIR="/:Music/:" FILE="b.mp3" VOLUME="Macintosh HD" VOLUMEID="Macintosh HD"></LOCATION>
<INFO GENRE="Dub" COMMENT="2-2 dub"></INFO>
<TEMPO BPM="124.000000" BPM_QUALITY="100.000000"></TEMPO>
<CUE_V2 NAME="AutoGrid" DISPL_ORDER="0" TYPE="4" START="12.500000" LEN="0.000000" REPEATS="-1" HOTCUE="-1"></CUE_V2>
<CUE_V2 NAME="n.n." DISPL_ORDER="0" TYPE="1" START="500.000000" LEN="0.000000" REPEATS="-1" HOTCUE="-1"></CUE_V2>
<CUE_V2 NAME="n.n." DISPL_ORDER="0" TYPE="5" START="96865.364423" LEN="1791.045388" REPEATS="-1" HOTCUE="3"></CUE_V2>
</ENTRY>
<ENTRY LOCK="1" TITLE="Locked" ARTIST="X"><LOCATION DIR="/:Music/:" FILE="c.mp3" VOLUME="Macintosh HD" VOLUMEID="Macintosh HD"></LOCATION>
<INFO COMMENT="fix"></INFO>
<TEMPO BPM="128.000000" BPM_QUALITY="100.000000"></TEMPO>
</ENTRY>
</COLLECTION>
<SETS ENTRIES="0"></SETS>
<PLAYLISTS><NODE TYPE="FOLDER" NAME="$ROOT"><SUBNODES COUNT="2"><NODE TYPE="FOLDER" NAME="Sets &amp; Co"><SUBNODES COUNT="2"><NODE TYPE="SMARTLIST" NAME="dub"><SMARTLIST UUID="325d436bc33746d2981e1577805810c5"><SEARCH_EXPRESSION VERSION="1" QUERY="$COMMENT % &quot;dub&quot;"></SEARCH_EXPRESSION>
</SMARTLIST>
</NODE>
<NODE TYPE="PLAYLIST" NAME="Größe"><PLAYLIST ENTRIES="1" TYPE="LIST" UUID="0a1fc2ed97434cc5a49ae14ab9887567"><ENTRY><PRIMARYKEY TYPE="TRACK" KEY="Macintosh HD/:Music/:b.mp3"></PRIMARYKEY>
</ENTRY>
</PLAYLIST>
</NODE>
</SUBNODES>
</NODE>
<NODE TYPE="PLAYLIST" NAME="Preparation"><PLAYLIST ENTRIES="0" TYPE="LIST" UUID="1cf51b36b4fe47969c0bf196df44b188"></PLAYLIST>
</NODE>
</SUBNODES>
</NODE>
</PLAYLISTS>
<INDEXING></INDEXING>
</NML>

"""

private let sA = "Macintosh HD/:Music/:Ä & B/:a & b.m4a"
private let sB = "Macintosh HD/:Music/:b.mp3"
private let sC = "Macintosh HD/:Music/:c.mp3"

private func fixture() throws -> (dir: URL, url: URL) {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("minos-sync-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    let url = d.appendingPathComponent("collection.nml")
    try Data(syncNML.utf8).write(to: url)
    return (d, url)
}

private func tracks(_ url: URL) throws -> [String: Track] {
    Dictionary(uniqueKeysWithValues: try NMLParser.parse(url: url).tracks.map { ($0.key, $0) })
}

private func sameCues(_ a: [Cue], _ b: [Cue]) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { CollectionWriter.sameCue($0, $1) }
}

/// Lesen: Cues aller Arten, Stand des Eintrags
@Test func syncReadsCuesAndStamp() throws {
    let c = try NMLParser.parse(data: Data(syncNML.utf8))
    let a = try #require(c.tracks.first { $0.key == sA })
    #expect(a.entryStamp == "2024/7/30 64041" && a.cues.count == 4)
    #expect(a.hotcues.map(\.hotcue) == [0, 1, 2] && a.hotcues[0].kind == .grid && a.hotcues[2].kind == .loop)
    #expect(a.hotcues[2].name == "Drop & Ö" && a.hotcues[2].lengthMs == 1558.418551)
    #expect(a.cues.contains { $0.hotcue == -1 && $0.kind == .cue && $0.startMs == 90000 })
    #expect(c.tracks.first { $0.key == sC }?.entryStamp == "")
}

/// Rundreise ohne Änderung: Track -> Änderung mit denselben Cues / demselben Grid -> Block Byte für Byte gleich,
/// Datei bleibt unangetastet
@Test func syncRoundTripUnchangedIsByteIdentical() throws {
    let index = NMLEntryIndex(nmlText: syncNML)
    let c = try NMLParser.parse(data: Data(syncNML.utf8))
    var job = CollectionWriter.Job()
    for t in c.tracks {
        var e = TrackEdit(hotcues: t.hotcues)
        if let g = t.gridAnchorMs { e.bpm = t.bpm; e.gridAnchorMs = g }
        let block = try #require(index.raw[t.key])
        #expect(CollectionWriter.patch(entry: block, edit: e) == block)
        job.cues[t.key] = e
    }
    let (dir, url) = try fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let res = try CollectionWriter.write(url: url, job: job, index: index, backupDir: nil)
    #expect(!res.changed && res.missing.isEmpty && res.writtenCues.count == 3)
    #expect(try Data(contentsOf: url) == Data(syncNML.utf8))
}

/// Hotcue verschoben, Loop gelöscht, neuer Loop: nur dieser ENTRY ändert sich, Memory-Cue und Grid bleiben;
/// neu gelesen = was `TrackEdit.apply` im Deck zeigt
@Test func syncHotcueChangeTouchesOneEntry() throws {
    let index = NMLEntryIndex(nmlText: syncNML)
    let before = try NMLParser.parse(data: Data(syncNML.utf8))
    let a = try #require(before.tracks.first { $0.key == sA })
    var hot = a.hotcues                                       // Grid (0), Cue (1), Loop (2) – wie das Deck sie speichert
    hot[1].startMs = 1700.25
    hot.remove(at: 2)
    hot.append(Cue(name: "Loop", kind: .loop, startMs: 12_345.678_912_3, lengthMs: 1_845.5, hotcue: 6))
    let e = TrackEdit(hotcues: hot)
    let (dir, url) = try fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    var job = CollectionWriter.Job()
    job.cues[sA] = e
    let res = try CollectionWriter.write(url: url, job: job, index: index, backupDir: dir.appendingPathComponent("Backup MINOS-741"))
    #expect(res.changed && res.writtenCues[sA] == e && res.backup != nil)
    let text = try String(contentsOf: url, encoding: .utf8)
    let oldA = try #require(index.raw[sA]), newA = try #require(res.blocks[sA])
    #expect(text == syncNML.replacingOccurrences(of: oldA, with: newA))
    #expect(newA.contains(#"<CUE_V2 NAME="AutoGrid" DISPL_ORDER="0" TYPE="4" START="43.963768" LEN="0.000000" REPEATS="-1" HOTCUE="0"></CUE_V2>"#))
    #expect(newA.contains(#"HOTCUE="-1"></CUE_V2>"#) && !newA.contains("Drop &amp; Ö"))
    #expect(newA.contains(#"<CUE_V2 NAME="Loop" DISPL_ORDER="0" TYPE="5" START="12345.678912" LEN="1845.500000" REPEATS="-1" HOTCUE="6"></CUE_V2>"#))
    #expect(newA.hasSuffix("</CUE_V2>\n</ENTRY>"))
    let after = try tracks(url)
    let na = try #require(after[sA])
    let shown = e.apply(to: a)
    #expect(sameCues(na.hotcues.filter { $0.kind != .grid }, shown.hotcues.filter { $0.kind != .grid }))
    #expect(na.gridAnchorMs == a.gridAnchorMs && na.cues.filter { $0.hotcue < 0 } == a.cues.filter { $0.hotcue < 0 })
    #expect(after[sB] == before.tracks.first { $0.key == sB })
}

/// Grid von Hand: BPM und erster Grid-Marker; gesperrter Eintrag bleibt
@Test func syncGridEditRespectsLock() throws {
    let index = NMLEntryIndex(nmlText: syncNML)
    var e = TrackEdit(bpm: 125.5, gridAnchorMs: 30.25)
    let newB = CollectionWriter.patch(entry: try #require(index.raw[sB]), edit: e)
    #expect(newB.contains(#"<TEMPO BPM="125.500000""#) && newB.contains(#"TYPE="4" START="30.250000""#))
    let blockC = try #require(index.raw[sC])
    #expect(CollectionWriter.patch(entry: blockC, edit: e) == blockC)
    e.hotcues = [Cue(name: "Cue", kind: .cue, startMs: 1000, lengthMs: 0, hotcue: 0)]
    let newC = CollectionWriter.patch(entry: blockC, edit: e)
    #expect(newC.contains("<TEMPO BPM=\"128.000000\"") && newC.hasSuffix("</TEMPO>\n<CUE_V2 NAME=\"Cue\" DISPL_ORDER=\"0\" TYPE=\"0\" START=\"1000.000000\" LEN=\"0.000000\" REPEATS=\"-1\" HOTCUE=\"0\"></CUE_V2>\n</ENTRY>"))
}

/// neuer Eintrag (Tool-Loop-Datei): ENTRY vor </COLLECTION>, ENTRIES mitgezählt, ohne AUDIO_ID, alles wieder lesbar
@Test func syncNewEntryForCut() throws {
    let index = NMLEntryIndex(nmlText: syncNML)
    var t = Track(key: "Macintosh HD/:Music/:Ä & B/:a & b [tool-loop 1].m4a", path: "/Music/Ä & B/a & b [tool-loop 1].m4a")
    t.title = "Bär & Wolf [tool-loop 1]"; t.artist = "Ünal"; t.bpm = 130.000473; t.musicalKey = 19; t.keyText = "11m"
    t.duration = 14.77; t.fileSizeKB = 812; t.bitrate = 440; t.comment2 = "loop » BASIS"; t.perceivedDb = 1.2; t.peakDb = 0.25
    t.cues = [Cue(name: "AutoGrid", kind: .grid, startMs: 0, lengthMs: 0, hotcue: -1),
              Cue(name: "Loop", kind: .loop, startMs: 0, lengthMs: 14_769.2, hotcue: 0),
              Cue(name: "Load", kind: .load, startMs: 0, lengthMs: 0, hotcue: -1)]
    let (dir, url) = try fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    var job = CollectionWriter.Job()
    job.newEntries = [t, t, Track(key: sB, path: "/Music/b.mp3")]     // doppelt und schon vorhanden -> einmal bzw. gar nicht
    let res = try CollectionWriter.write(url: url, job: job, index: index, backupDir: nil)
    #expect(res.changed && res.added == [t.key])
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.contains("<COLLECTION ENTRIES=\"4\">") && text.contains("</ENTRY>\n</COLLECTION>"))
    let block = try #require(res.blocks[t.key])
    #expect(!block.contains("AUDIO_ID") && block.contains(#"<LOCATION DIR="/:Music/:Ä &amp; B/:" FILE="a &amp; b [tool-loop 1].m4a" VOLUME="Macintosh HD" VOLUMEID="Macintosh HD"></LOCATION>"#))
    #expect(text == syncNML.replacingOccurrences(of: "<COLLECTION ENTRIES=\"3\">", with: "<COLLECTION ENTRIES=\"4\">")
        .replacingOccurrences(of: "</ENTRY>\n</COLLECTION>", with: "</ENTRY>\n" + block + "\n</COLLECTION>"))
    let n = try #require(try tracks(url)[t.key])
    #expect(n.title == t.title && n.artist == "Ünal" && abs(n.bpm - t.bpm) < 1e-6 && n.musicalKey == 19 && n.comment2 == t.comment2)
    #expect(n.cues.count == 2 && n.gridAnchorMs == 0 && n.hotcues.first?.kind == .loop && abs(n.duration - 14.77) < 1e-6)
    #expect(n.bitrate == 440 && n.fileSizeKB == 812 && n.perceivedDb == 1.2)
    // zweiter Lauf mit neuem Index: nichts mehr anzulegen
    let res2 = try CollectionWriter.write(url: url, job: job, index: NMLEntryIndex(nmlText: text), backupDir: nil)
    #expect(!res2.changed && res2.added.isEmpty)
}

/// eigener Playlist-Ordner: angehängt (COUNT + 1), fremde Knoten Zeichen für Zeichen gleich, ersetzt statt verdoppelt,
/// unbekannte Tracks fallen weg, gleicher Inhalt = keine Änderung
@Test func syncPlaylistsOwnFolder() throws {
    let index = NMLEntryIndex(nmlText: syncNML)
    let (dir, url) = try fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    var job = CollectionWriter.Job()
    job.playlists = [.playlist("Preparation", [sB, sA, "Macintosh HD/:nicht/:da.mp3"]),
                     .folder("History", [.playlist("History 2026-10-10 · 01", [sA, sB, sA])])]
    let res = try CollectionWriter.write(url: url, job: job, index: index, backupDir: nil)
    #expect(res.changed && res.playlistsChanged)
    let text = try String(contentsOf: url, encoding: .utf8)
    let head = syncNML.components(separatedBy: "<PLAYLISTS>")[0]
    #expect(text.hasPrefix(head))
    #expect(text.contains("<PLAYLISTS><NODE TYPE=\"FOLDER\" NAME=\"$ROOT\"><SUBNODES COUNT=\"3\">"))
    let foreign = syncNML.components(separatedBy: "<SUBNODES COUNT=\"2\"><NODE TYPE=\"FOLDER\" NAME=\"Sets")[1].components(separatedBy: "</SUBNODES>\n</NODE>\n</PLAYLISTS>")[0]
    #expect(text.contains(foreign + "<NODE TYPE=\"FOLDER\" NAME=\"MINOS-741\"><SUBNODES COUNT=\"2\">"))
    let c = try NMLParser.parse(url: url)
    #expect(c.root.children.map(\.name) == ["Sets & Co", "Preparation", "MINOS-741"])
    let own = try #require(c.root.children.last)
    #expect(own.children.map(\.name) == ["Preparation", "History"])
    #expect(own.children[0].trackKeys == [sB, sA] && own.children[1].children[0].trackKeys == [sA, sB, sA])
    #expect(own.children[0].uuid.count == 32 && c.root.children[1].trackKeys.isEmpty)
    // nochmal gleich -> nichts geschrieben
    let res2 = try CollectionWriter.write(url: url, job: job, index: index, backupDir: nil)
    #expect(!res2.changed)
    // anderer Inhalt -> ersetzt, nicht verdoppelt
    job.playlists = [.playlist("Preparation", [sA])]
    let res3 = try CollectionWriter.write(url: url, job: job, index: index, backupDir: nil)
    #expect(res3.changed)
    let c3 = try NMLParser.parse(url: url)
    #expect(c3.root.children.map(\.name) == ["Sets & Co", "Preparation", "MINOS-741"] && c3.root.children[2].children.count == 1)
    #expect(try String(contentsOf: url, encoding: .utf8).contains("<SUBNODES COUNT=\"3\">"))
    // gleiche UUID für denselben Pfad
    #expect(c3.root.children[2].children[0].uuid == own.children[0].uuid)
}

/// Datei umbenannt (Endung nach dem Schneiden): LOCATION geändert, neuer Schlüssel, Rest gleich
@Test func syncLocationMove() throws {
    let index = NMLEntryIndex(nmlText: syncNML)
    let (dir, url) = try fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let loc = CollectionWriter.pathChanged(old: "/Music/b.mp3", new: "/Music/b.m4a", oldBlock: index.raw[sB])
    #expect(loc.file == "b.m4a" && loc.dir == "/:Music/:")
    var job = CollectionWriter.Job()
    job.moves[sB] = NMLLocation(volume: "Macintosh HD", volumeID: "Macintosh HD", dir: "/:Music/:", file: "b.m4a")
    job.playlists = [.playlist("Preparation", [sB])]
    let res = try CollectionWriter.write(url: url, job: job, index: index, backupDir: nil)
    let nk = "Macintosh HD/:Music/:b.m4a"
    #expect(res.changed && res.moved == [sB: nk])
    let t = try tracks(url)
    #expect(t[sB] == nil && t[nk]?.title == "Orlok's Symphony" && t[nk]?.cues.count == 3)
    #expect(try NMLParser.parse(url: url).root.children.last?.children.first?.trackKeys == [nk])
}

/// Schutz: Datei seit dem Lesen geändert -> nicht schreiben; Selbsttest schreibt nur im Temp-Ordner
@Test func syncWriteGuards() throws {
    let index = NMLEntryIndex(nmlText: syncNML)
    let (dir, url) = try fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    var job = CollectionWriter.Job(changes: [sA: [.title: "Neu"]])
    job.expected = FileStamp(size: 1, mtime: 0)
    #expect(throws: CollectionWriter.Refusal.self) { try CollectionWriter.write(url: url, job: job, index: index, backupDir: nil) }
    #expect(try Data(contentsOf: url) == Data(syncNML.utf8))
    job.expected = FileStamp(url: url)
    let res = try CollectionWriter.write(url: url, job: job, index: index, backupDir: nil)
    #expect(res.changed && res.stamp == FileStamp(url: url))
    let selftest = ["MIX741_SELFTEST": "1"]
    #expect(CollectionWriter.writeAllowed(url, environment: selftest))
    #expect(!CollectionWriter.writeAllowed(realCollection(), environment: selftest))
    #expect(CollectionWriter.writeAllowed(realCollection(), environment: [:]))
}

/// Konfliktregel: Eintrag in der Datei seit der eigenen Änderung geändert -> Datei gewinnt, eigener Stand in die Sicherung;
/// unverändert -> eigener Stand bleibt; Schnitt / Active Loops bleiben immer
@Test func syncConflictRule() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("minos-conflict-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let c = try NMLParser.parse(data: Data(syncNML.utf8))
    let base = Dictionary(uniqueKeysWithValues: c.tracks.map { ($0.key, $0) })
    let stamps = base.mapValues(\.entryStamp)
    let meta = MetadataStore(url: nil)
    meta.merge([sA: [.title: "MINOS A"], sB: [.title: "MINOS B"]], base: base, stamps: stamps)
    meta.merge([sA: [.genre: "House"]], base: base, stamps: [sA: "später"])          // erster offener Stand gilt
    #expect(meta.edit(for: sA)?.stamp == "2024/7/30 64041")
    let edits = TrackEditStore(url: nil, writes: false)
    var e = TrackEdit(hotcues: [Cue(name: "Cue", kind: .cue, startMs: 1, lengthMs: 0, hotcue: 1)], trim: TrackTrim(start: 2))
    e.activeLoops = [1]
    e.stamp = stamps[sA]
    edits.set(e, for: sA)
    var eb = TrackEdit(bpm: 125, gridAnchorMs: 10)
    eb.stamp = stamps[sB]
    edits.set(eb, for: sB)
    // A wurde in der Bibliothekssoftware geändert, B nicht
    var now = stamps
    now[sA] = "2026/10/14 3600"
    let mc = meta.takeConflicts(current: now)
    let ec = edits.takeConflicts(current: now)
    #expect(Set(mc.keys) == [sA] && mc[sA]?.values == [.title: "MINOS A", .genre: "House"])
    #expect(meta.edit(for: sA) == nil && meta.edit(for: sB)?.values == [.title: "MINOS B"])
    #expect(Set(ec.keys) == [sA] && ec[sA]?.hotcues?.count == 1)
    let rest = try #require(edits.edit(for: sA))
    #expect(rest.hotcues == nil && rest.trim.start == 2 && rest.activeLoops == [1] && rest.stamp == nil)
    #expect(edits.edit(for: sB)?.hasGrid == true)
    // ohne Stand (ältere Datei) kein Konflikt
    var old = TrackEdit(hotcues: [])
    old.stamp = nil
    edits.set(old, for: sC)
    #expect(edits.takeConflicts(current: [sC: "2026/1/1 1"]).isEmpty)
    // Sicherung: neue Einträge kommen dazu, gleiche Schlüssel werden ersetzt
    let file = dir.appendingPathComponent("metadata-konflikt.json")
    try ConflictBackup.save(mc, to: file)
    try ConflictBackup.save([sB: MetadataEdit(fields: [.title: "x"])], to: file)
    let back = try JSONDecoder().decode([String: MetadataEdit].self, from: Data(contentsOf: file))
    #expect(Set(back.keys) == [sA, sB])
    // nach dem Schreiben: Hotcues / Grid verlassen edits.json, Schnitt bleibt; Grid bleibt bei eigener Analyse
    edits.set(e, for: sA)
    edits.clearWritten([sA: e, sB: eb], keepGrid: [sB])
    #expect(edits.edit(for: sA)?.hotcues == nil && edits.edit(for: sA)?.trim.start == 2 && edits.edit(for: sB)?.hasGrid == true)
    edits.clearWritten([sB: eb])
    #expect(edits.edit(for: sB) == nil)
}

/// alte edits.json / metadata.json ohne Stand lesen sich weiter
@Test func syncDecodesOldStores() throws {
    let e = try JSONDecoder().decode(TrackEdit.self, from: Data(#"{"bpm":128,"modified":0}"#.utf8))
    #expect(e.bpm == 128 && e.stamp == nil)
    let m = try JSONDecoder().decode(MetadataEdit.self, from: Data(#"{"fields":{"title":"x"},"modified":0}"#.utf8))
    #expect(m.values == [.title: "x"] && m.stamp == nil)
}

/// echte Collection (nur gelesen, Kopie im Temp-Ordner): Hotcues eines Eintrags, Playlist-Ordner, neuer Eintrag –
/// außerhalb der geänderten Stellen Byte für Byte gleich
@Test func syncOnRealCopy() throws {
    let real = realCollection()
    guard FileManager.default.fileExists(atPath: real.path) else { return }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("minos-sync-real-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("collection.nml")
    try FileManager.default.copyItem(at: real, to: url)
    let text = try String(contentsOf: url, encoding: .utf8)
    let index = NMLEntryIndex(nmlText: text)
    let c = try NMLParser.parse(url: url)
    // unverändert: alle Einträge mit ihren eigenen Cues -> Datei gleich
    var same = CollectionWriter.Job()
    for t in c.tracks where !t.hotcues.isEmpty { same.cues[t.key] = TrackEdit(hotcues: t.hotcues) }
    #expect(try !CollectionWriter.write(url: url, job: same, index: index, backupDir: nil).changed)
    let t = try #require(c.tracks.first { $0.hotcues.contains { $0.kind != .grid } })
    var hot = t.hotcues
    hot.append(Cue(name: "MINOS", kind: .loop, startMs: 1000, lengthMs: 2000, hotcue: 7))
    var job = CollectionWriter.Job()
    job.cues[t.key] = TrackEdit(hotcues: hot.filter { $0.hotcue != 7 || $0.name == "MINOS" })
    job.playlists = [.playlist("Preparation", Array(c.tracks.prefix(5).map(\.key)))]
    var cut = c.tracks[0]
    cut.key = String(cut.key.dropLast(4)) + " [tool-loop 1].m4a"
    job.newEntries = [cut]
    let res = try CollectionWriter.write(url: url, job: job, index: index, backupDir: nil)
    #expect(res.changed && res.added == [cut.key] && res.missing.isEmpty)
    let after = try NMLParser.parse(url: url)
    #expect(after.tracks.count == c.tracks.count + 1)
    #expect(after.root.children.last?.name == "MINOS-741" && after.root.children.dropLast().map(\.name) == c.root.children.map(\.name))
    let out = try String(contentsOf: url, encoding: .utf8)
    let entryEnd = text.range(of: "</COLLECTION>")!.lowerBound
    #expect(out.hasPrefix(String(text[..<entryEnd]).replacingOccurrences(of: index.raw[t.key]!, with: res.blocks[t.key]!)
        .replacingOccurrences(of: "<COLLECTION ENTRIES=\"\(c.tracks.count)\">", with: "<COLLECTION ENTRIES=\"\(c.tracks.count + 1)\">")))
}
