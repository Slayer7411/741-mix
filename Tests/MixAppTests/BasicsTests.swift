import AppKit
import Foundation
import Testing
import MixCore
@testable import MixApp

// Grundfunktionen: Über (Angaben und Lizenzdateien), Fehlermeldung, Handbuch-Blöcke, Tastenkürzel-Liste,
// Protokoll-Zeilen, Einstellungen exportieren/importieren. Keine Fenster, kein Öffnen von Adressen.

private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@Test func aboutInfoFromBundleDictionary() {
    let a = AboutInfo.make(["CFBundleShortVersionString": "0.8.2", "CFBundleVersion": "db052b1",
                            "MINOSCodename": "LIMBUS", "MINOSBuildDate": "2026-10-17T10:00:00Z"])
    #expect(a.versionLine == "0.8.2 · LIMBUS")
    #expect(a.buildLine == "build db052b1 · 2026-10-17")
    // ohne Bündel (swift run): Version aus dem Codename-Schema, Build „dev“
    let dev = AboutInfo.make(nil)
    #expect(dev.version == "dev")
    #expect(dev.build == "dev")
    #expect(dev.buildLine == "build dev")
    // Build gleich Version (lokaler Bau ohne Hash): nicht doppelt anzeigen
    #expect(AboutInfo.make(["CFBundleShortVersionString": "1.0", "CFBundleVersion": "1.0"]).build == "dev")
}

@Test func everyLicenceComponentHasItsFile() {
    let fm = FileManager.default
    for c in AboutInfo.components(appVersion: "0.8.2") {
        let url = repo.appendingPathComponent("Sources/MixApp/Resources/\(c.file)")
        #expect(fm.fileExists(atPath: url.path), "Lizenzdatei fehlt: \(c.file)")
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        #expect(text.count > 200, "Lizenztext zu kurz: \(c.file)")
    }
    #expect(AboutInfo.components(appVersion: "0.8.2").first?.version == "0.8.2")
}

@Test func bundledLicenceCopiesMatchTheirSources() throws {
    let pairs = [("LICENSE.md", "Licenses/LICENSE-MINOS-741.md"),
                 ("Sources/LinkKit/LICENSE-Link.md", "Licenses/LICENSE-link.md"),
                 ("Sources/LinkKit/asio/LICENSE_1_0.txt", "Licenses/LICENSE-asio.txt"),
                 ("Sources/VST3SDK/LICENSE.txt", "Licenses/LICENSE-VST3SDK.txt"),
                 ("Sources/MixDSP/vendor/signalsmith-stretch/LICENSE.txt", "Licenses/LICENSE-signalsmith-stretch.txt"),
                 ("Sources/MixDSP/vendor/signalsmith-linear/LICENSE.txt", "Licenses/LICENSE-signalsmith-linear.txt")]
    for (src, copy) in pairs {
        let a = try Data(contentsOf: repo.appendingPathComponent(src))
        let b = try Data(contentsOf: repo.appendingPathComponent("Sources/MixApp/Resources/\(copy)"))
        #expect(a == b, "Kopie weicht ab: \(copy)")
    }
}

@Test func bugReportAddressCarriesOnlyEnvironment() throws {
    let env = BugReport.Environment(version: "0.8.2", build: "db052b1", codename: "LIMBUS", macOS: "26.0.1", model: "Mac15,7")
    let url = BugReport.url(env)
    let s = url.absoluteString
    #expect(s.hasPrefix("https://github.com/Slayer7411/MINOS-741/issues/new?"))
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let title = items.first { $0.name == "title" }?.value ?? ""
    let body = items.first { $0.name == "body" }?.value ?? ""
    #expect(title == "Bug report: 0.8.2 (db052b1)")
    #expect(body.contains("MINOS-741 0.8.2 · LIMBUS · build db052b1"))
    #expect(body.contains("macOS 26.0.1 · Mac15,7"))
    // keine Angaben zur Person oder zum Rechner
    #expect(!body.contains(NSHomeDirectory()))
    #expect(!body.contains(NSUserName()))
    #expect(!body.contains("/Users"))
}

@Test func manualBlocksFromTheRealManual() throws {
    let md = try String(contentsOf: repo.appendingPathComponent("docs/MANUAL.md"), encoding: .utf8)
    let blocks = Manual.blocks(md)
    let h2 = blocks.filter { if case .heading(2, _) = $0 { true } else { false } }
    #expect(h2.count >= 10, "Abschnitte im Handbuch: \(h2.count)")
    #expect(blocks.contains { if case .code = $0 { true } else { false } })
    #expect(blocks.contains { if case .table = $0 { true } else { false } })
    #expect(blocks.contains { if case .bullet = $0 { true } else { false } })
    // kein Markdown-Rest in den Überschriften
    for case let .heading(_, t) in blocks { #expect(!t.hasPrefix("#"), "Überschrift mit # : \(t)") }
}

@Test func manualBlockRules() {
    let blocks = Manual.blocks("""
    # Titel
    Ein Satz
    über zwei Zeilen.

    ## ◆ 01 · INSTALL
    - erster **Punkt**
    3. dritter
    ```
    code  mit   Leerraum
    ```
    | a | b |
    |---|---|
    | 1 | 2 |
    ---
    """)
    #expect(blocks[0] == .heading(level: 1, text: "Titel"))
    #expect(blocks[1] == .paragraph("Ein Satz über zwei Zeilen."))
    #expect(blocks[2] == .heading(level: 2, text: "◆ 01 · INSTALL"))
    #expect(blocks[3] == .bullet("erster **Punkt**", number: nil))
    #expect(blocks[4] == .bullet("dritter", number: "3"))
    #expect(blocks[5] == .code("code  mit   Leerraum"))
    #expect(blocks[6] == .table(["| a | b |", "|---|---|", "| 1 | 2 |"]))
    #expect(blocks[7] == .rule)
    #expect(Manual.tableLine("|---|---|") == nil)
    #expect(Manual.tableLine("| 1 | 2 |") == "1   2")
}

@Test func shortcutReferenceGroupsEveryActionOnce() {
    let all = ShortcutReference.sections(keys: ShortcutMap())
    let rows = all.flatMap(\.rows)
    #expect(rows.count == ShortcutID.allCases.count)
    #expect(Set(rows.map(\.action)).count == ShortcutID.allCases.count)
    // Gruppen in der Reihenfolge der Einstellungen, jede Zeile in ihrer Gruppe
    #expect(all.map(\.group) == ShortcutGroup.allCases.filter { g in all.contains { $0.group == g } })
    for s in all { for r in s.rows { #expect(r.action.group == s.group) } }
}

@Test func shortcutReferenceShowsCurrentComboAndFilters() {
    var keys = ShortcutMap()
    keys.set(.play, KeyCombo("k", [.command, .shift]))
    let rows = ShortcutReference.sections(keys: keys).flatMap(\.rows)
    #expect(rows.first { $0.action == .play }?.combo == KeyCombo("k", [.command, .shift]).symbols)
    #expect(ShortcutReference.customCount(keys) == 1)
    // Suche nach Name und nach Belegung, ohne Groß-/Kleinschreibung; ohne Treffer keine Gruppe
    let byName = ShortcutReference.sections(keys: keys, query: "PLAY/PAUSE").flatMap(\.rows)
    #expect(byName.contains { $0.action == .play })
    let byCombo = ShortcutReference.sections(keys: keys, query: "⇧⌘k").flatMap(\.rows)
    #expect(byCombo.map(\.action) == [.play])
    #expect(ShortcutReference.sections(keys: keys, query: "gibt-es-nicht-xyz").isEmpty)
}

@Test func statusLogLinesParseFilterAndDedupe() {
    let file = """
    === Start 0.8.2 (db052b1) 2026-10-17 09:00:00
    2026-10-17 09:12:04 ok Collection geladen · 1240 Tracks
    2026-10-17 09:14:37 warning Datei fehlt
    kein Zeitstempel hier
    """
    let m = StatusMessage(id: 1, level: .error, text: "Audio-Gerät nicht gefunden", now: Date(timeIntervalSince1970: 1_792_000_000))
    let lines = StatusLogReader.lines(fileText: file, recent: [m])
    #expect(lines.count == 5)
    #expect(lines[0].level == nil && lines[0].text.hasPrefix("=== Start"))
    #expect(lines[1] == StatusLogLine(id: 1, time: "2026-10-17 09:12:04", level: .ok, text: "Collection geladen · 1240 Tracks"))
    #expect(StatusLogReader.filter(lines, level: .warning).map(\.text) == ["Datei fehlt"])
    #expect(StatusLogReader.filter(lines, level: nil).count == 5)
    // Meldung schon in der Datei: nicht doppelt
    let again = StatusLogReader.lines(fileText: StatusLogReader.format(m), recent: [m])
    #expect(again.count == 1)
    #expect(again[0].level == .error)
    // nur die letzten Zeilen der Datei
    #expect(StatusLogReader.lines(fileText: "a\nb\nc", recent: [], limit: 2).map(\.text) == ["b", "c"])
}

@Test func settingsExportImportRoundTripKeepsLocalValues() throws {
    let fm = FileManager.default
    let src = "minos.test.src.\(UUID().uuidString)", dst = "minos.test.dst.\(UUID().uuidString)"
    let a = UserDefaults(suiteName: src)!, b = UserDefaults(suiteName: dst)!
    defer { a.removePersistentDomain(forName: src); b.removePersistentDomain(forName: dst) }
    let dir = fm.temporaryDirectory.appendingPathComponent("settings-\(UUID().uuidString)")
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }

    // Quelle: Oberfläche, Tasten, Audio-Gerät, Zwei-Mac-Pairing
    var p = AppPrefs()
    p.ui.compactDecks = true
    p.ui.pair.on = true
    a.set(try JSONEncoder().encode(p), forKey: AppPrefs.key)
    a.set("DEV-SOURCE", forKey: "deviceUID")
    a.set(true, forKey: "settings.imported")
    // Ziel: eigene Werte, die beim Übernehmen bleiben sollen
    var mine = AppPrefs()
    mine.ui.pair.on = false
    b.set(try JSONEncoder().encode(mine), forKey: AppPrefs.key)
    b.set("DEV-LOCAL", forKey: "deviceUID")

    let file = dir.appendingPathComponent("settings.plist")
    try SettingsTransfer.export(to: file, defaults: a, domain: src)
    let read = try SettingsTransfer.dictionary(from: Data(contentsOf: file))
    #expect(read["settings.imported"] == nil, "Import-Stempel gehört nicht in die Datei")

    let n = try SettingsTransfer.importFile(file, defaults: b)
    #expect(n > 0)
    #expect(b.string(forKey: "deviceUID") == "DEV-LOCAL", "Audio-Gerät bleibt auf diesem Mac")
    let got = try JSONDecoder().decode(AppPrefs.self, from: b.data(forKey: AppPrefs.key)!)
    #expect(got.ui.compactDecks == true, "Oberfläche wird übernommen")
    #expect(got.ui.pair.on == false, "Zwei-Mac-Modus bleibt auf diesem Mac")
}

@Test func settingsImportRejectsOtherPropertyLists() throws {
    let plain = try PropertyListSerialization.data(fromPropertyList: ["foo": 1], format: .xml, options: 0)
    #expect(throws: SettingsTransfer.Failure.notSettings) { try SettingsTransfer.dictionary(from: plain) }
    #expect(throws: (any Error).self) { try SettingsTransfer.dictionary(from: Data("kein plist".utf8)) }
}

@Test @MainActor func linksOpenOnlyThroughTheInjectedOpener() {
    var opened: [URL] = []
    let saved = AppLinks.opener
    AppLinks.opener = { opened.append($0) }
    defer { AppLinks.opener = saved }
    AppLinks.open(AppLinks.github)
    AppLinks.open(AppLinks.instagram)
    #expect(opened == [AppLinks.github, AppLinks.instagram])
    #expect(AppLinks.instagram.absoluteString == "https://instagram.com/minos_741")
}

@Test @MainActor func windowsNeverShowInTests() {
    // swift test: Ereignisschleife läuft nicht, also nie ein Fenster; nur gemerkt
    #expect(!BasicWindows.mayShow)
}
