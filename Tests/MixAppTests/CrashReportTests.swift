import Foundation
import Testing
@testable import MixApp

private let names = CrashRedact.Names(home: "/Users/cs.privat", user: "cs.privat", fullName: "Christian Schenk",
                                      computer: "Christians-MacBook-Pro")

private func tempDir(_ name: String) throws -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

private let ipsHeader = #"{"app_name":"MINOS-741","app_version":"9.9.9","build_version":"4242","os_version":"macOS 26.0 (25A100)"}"#
private let ipsBody = #"""
{"procPath":"/Users/cs.privat/Applications/MINOS-741.app/Contents/MacOS/minos741","cpuType":"ARM-64","hardwareModel":"Mac15,7",
 "crashReporterKey":"6F3C2A1B-1111-2222-3333-444455556666","exception":{"type":"EXC_BAD_ACCESS","signal":"SIGSEGV"},
 "osVersion":{"train":"macOS 26.0","build":"25A100"},"faultingThread":0,
 "threads":[{"triggered":true,"frames":[{"imageOffset":4096,"symbol":"mixer_process","symbolLocation":12,"imageIndex":0},
 {"imageOffset":99,"imageIndex":1}]}],
 "usedImages":[{"path":"/Users/cs.privat/x/minos741","name":"minos741"}]}
"""#

@Test func newReportsPicksOnlyMinosReportsAfterTheLastOne() {
    let files: [(name: String, date: Date)] = [
        ("MINOS-741_a.ips", Date(timeIntervalSince1970: 100)),
        ("minos741-x.ips", Date(timeIntervalSince1970: 200)),
        ("minos-files_x.ips", Date(timeIntervalSince1970: 300)),
        ("Other.ips", Date(timeIntervalSince1970: 400)),
        ("MINOS-741_b.txt", Date(timeIntervalSince1970: 500)),
        ("MINOS-741_c.ips", Date(timeIntervalSince1970: 50)),
    ]
    let all = CrashReports.newReports(files, after: Date(timeIntervalSince1970: 60))
    #expect(all.map(\.name) == ["MINOS-741_a.ips", "minos741-x.ips", "minos-files_x.ips"])
    let later = CrashReports.newReports(files, after: Date(timeIntervalSince1970: 250))
    #expect(later.map(\.name) == ["minos-files_x.ips"])
    #expect(CrashReports.newReports(files, after: Date(timeIntervalSince1970: 300)).isEmpty)
}

@Test func fileNameHasDateComputerAndBuild() throws {
    let date = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 9, minute: 5, second: 3)))
    #expect(CrashReports.fileName(date: date, computer: "Christians MacBook Pro", build: "4242") == "2026-10-17_090503_Christians-MacBook-Pro_4242.txt")
    #expect(CrashReports.fileName(date: date, computer: "Büro/Mac (2)", build: "1.0") == "2026-10-17_090503_BroMac-2_1-0.txt")
    #expect(CrashReports.fileName(date: date, computer: "", build: "") == "2026-10-17_090503_unbekannt_unbekannt.txt")
}

@Test func settingsDropDeviceIdsAndUnpackPrefs() throws {
    let prefs = try JSONSerialization.data(withJSONObject: ["ui": ["zoom": 1.2, "deviceUID": "BuiltIn-UID", "pair": ["on": true]]])
    let domain: [String: Any] = ["deviceUID": "usb-123", "mixerMode": "Intern", "prefs.v1": prefs,
                                 "record": ["inputUID": "xone-9", "format": "wav"]]
    let json = CrashReports.settingsJSON(domain)
    #expect(!json.contains("UID"), "\(json)")
    #expect(!json.contains("usb-123") && !json.contains("xone-9") && !json.contains("BuiltIn-UID"))
    #expect(json.contains("\"mixerMode\"") && json.contains("\"zoom\"") && json.contains("\"pair\""))
    #expect(CrashRedact.isDeviceKey("outputDeviceID") && CrashRedact.isDeviceKey("deviceUID") && !CrashRedact.isDeviceKey("zoom"))
}

@Test func textRedactionRemovesPathsNamesAddressesAndIds() {
    let s = "Datei /Users/cs.privat/Music/track.wav in ~/Library, cs.privat auf Christians-MacBook-Pro, IP 192.168.1.20, "
        + "MAC 3c:22:fb:12:34:56, id 6F3C2A1B-1111-2222-3333-444455556666, Deck 1/2, 10:00:00, v2:12 fertig"
    let r = CrashRedact.text(s, names: names)
    #expect(r.contains("<datei>"))
    for bad in ["cs.privat", "Christians", "192.168", "3c:22", "6F3C2A1B", "/Users/", "Library"] {
        #expect(!r.contains(bad), "\(bad) in \(r)")
    }
    #expect(r.contains("Deck 1/2") && r.contains("10:00:00"))
    #expect(CrashRedact.text("Heimordner ~", names: names) == "Heimordner ~")
}

@Test func logLinesWithTracksOrPathsAreDropped() {
    let lines = [
        "Collection wird geladen: collection.nml",
        "Artist – Title wird gespielt",
        "Datei /Users/cs.privat/x fehlt",
        "Lade track01.wav",
        "Ausgabe gestoppt",
        "Gerät cs.privat vorhanden",
    ]
    #expect(CrashRedact.logTail(lines, names: names) == ["Collection wird geladen: collection.nml", "Ausgabe gestoppt"])
    let many = (1...30).map { "Zeile \($0)" }
    #expect(CrashRedact.logTail(many, names: names, limit: 20).count == 20)
    #expect(CrashRedact.logTail(many, names: names, limit: 20).last == "Zeile 30")
}

@Test func parseIPSReadsHeaderAndBody() throws {
    let text = ipsHeader + "\n" + ipsBody
    let (h, b) = try #require(CrashRedact.parseIPS(text))
    #expect(h["build_version"] as? String == "4242")
    #expect(b["cpuType"] as? String == "ARM-64")
    #expect(CrashRedact.parseIPS("kein json") == nil)
    #expect(CrashRedact.parseIPS(ipsBody)?.body["hardwareModel"] as? String == "Mac15,7")
}

@Test func publicReportKeepsWhatIsNeededAndLeaksNothing() throws {
    let logs = ["Collection wird geladen: collection.nml", "Artist – Title wird gespielt"]
    let report = try #require(CrashRedact.publicReport(ips: ipsHeader + "\n" + ipsBody, status: logs, names: names))
    for want in ["MINOS-741 crash report (redacted)", "App:       9.9.9 (build 4242)", "macOS:     macOS 26.0 (25A100)",
                 "CPU:       ARM-64", "Model:     Mac15,7", "Exception: EXC_BAD_ACCESS (SIGSEGV)", "  0  mixer_process+12",
                 "Collection wird geladen: collection.nml"] {
        #expect(report.contains(want), "fehlt: \(want)")
    }
    for bad in ["cs.privat", "Christians", "6F3C2A1B", "/Users", "Artist", "usedImages", "procPath", "minos741\n", "<nutzer>.app"] {
        #expect(!report.contains(bad), "\(bad) in\n\(report)")
    }
}

@Test func issueURLIsEncodedAndTruncatesWithClipboardNote() throws {
    let short = CrashRedact.issueURL(title: "MINOS-741 crash", body: "a&b=c #1 ü")
    #expect(!short.truncated)
    let s = short.url.absoluteString
    #expect(s.hasPrefix("https://github.com/Slayer7411/MINOS-741/issues/new?title="))
    #expect(s.hasSuffix("&labels=crash"))
    #expect(s.contains("a%26b%3Dc%20%231%20%C3%BC"))
    let long = CrashRedact.issueURL(title: "t", body: String(repeating: "x", count: 20_000))
    #expect(long.truncated)
    #expect(long.url.absoluteString.count <= CrashRedact.issueMaxLength)
    let decoded = try #require(long.url.absoluteString.removingPercentEncoding)
    #expect(decoded.contains("vollständiger Bericht in der Zwischenablage"))
}

@Test func scanCopiesNewReportsOnceAndPromptsForTheNewest() throws {
    let fm = FileManager.default
    let reports = try tempDir("reports"), folder = try tempDir("folder")
    defer { try? fm.removeItem(at: reports); try? fm.removeItem(at: folder) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func put(_ name: String, _ text: String, ago: TimeInterval) throws {
        let u = reports.appendingPathComponent(name)
        try text.write(to: u, atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-ago)], ofItemAtPath: u.path)
    }
    try put("MINOS-741_old.ips", ipsHeader + "\n" + ipsBody, ago: 7200)
    try put("minos-files_new.ips", ipsHeader + "\n" + ipsBody, ago: 3600)
    try put("Safari_1.ips", "x", ago: 60)
    let context = CrashReports.Context(appVersion: "9.9.9", build: "4242", computer: "Christians-MacBook-Pro", macOS: "26.0",
                                       copiedAt: now)
    let first = CrashReports.scan(now: now, reportsDir: reports, folder: folder, copyAfter: nil, promptAfter: nil, askPrompt: true,
                                  status: ["Collection wird geladen: collection.nml"], settings: "{}", context: context, names: names)
    #expect(first.copiedNewest == now.addingTimeInterval(-3600))
    #expect(try fm.contentsOfDirectory(atPath: folder.path).count == 2)
    #expect(first.prompt?.fileName == "minos-files_new.ips")
    #expect(first.prompt?.count == 2)
    #expect(first.prompt?.text.contains("mixer_process+12") == true)
    // zweiter Lauf: nichts Neues, weder kopiert noch gefragt
    let second = CrashReports.scan(now: now, reportsDir: reports, folder: folder, copyAfter: now.addingTimeInterval(-3600),
                                   promptAfter: now.addingTimeInterval(-3600), askPrompt: true, status: [], settings: "{}",
                                   context: context, names: names)
    #expect(second.copiedNewest == nil && second.prompt == nil)
    // ohne Ordner und ohne Frage: nur die Suche, nichts geschrieben
    let off = CrashReports.scan(now: now, reportsDir: reports, folder: nil, copyAfter: nil, promptAfter: nil, askPrompt: false,
                                status: [], settings: "{}", context: context, names: names)
    #expect(off.copiedNewest == nil && off.prompt == nil)
}

@Test func writeAddsSuffixInsteadOfOverwriting() throws {
    let fm = FileManager.default
    let dir = try tempDir("write")
    let src = dir.appendingPathComponent("MINOS-741_a.ips")
    try (ipsHeader + "\n" + ipsBody).write(to: src, atomically: true, encoding: .utf8)
    defer { try? fm.removeItem(at: dir) }
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    let ctx = CrashReports.Context(appVersion: "9.9.9", build: "4242", computer: "Mac", macOS: "26", copiedAt: date)
    let out = dir.appendingPathComponent("out")
    let a = try CrashReports.write([(src, date)], into: out, status: [], settings: "{}", context: ctx, fm: fm)
    let b = try CrashReports.write([(src, date)], into: out, status: [], settings: "{}", context: ctx, fm: fm)
    #expect(a.count == 1 && b.count == 1 && a[0] != b[0])
    #expect(b[0].lastPathComponent.hasSuffix("-2.txt"))
    #expect(try String(contentsOf: a[0], encoding: .utf8).contains("===== ips ====="))
    #expect(try fm.contentsOfDirectory(atPath: out.path).allSatisfy { !$0.hasSuffix(".part") })
}

@Test func previousRunTailSkipsTheCurrentRun() {
    let lines = ["=== Start 1 (1) 2026-10-16 09:00:00", "a", "b", "=== Start 1 (2) 2026-10-17 09:00:00", "c"]
    #expect(CrashReports.previousRunTail(lines) == ["a", "b"])
    #expect(CrashReports.previousRunTail(["x"]) == ["x"])
}

@Test func issueTitleNamesVersionBuildAndExceptionOrFallsBack() {
    #expect(CrashRedact.issueTitle(ips: ipsHeader + "\n" + ipsBody, names: names) == "Crash: 9.9.9 (4242) · EXC_BAD_ACCESS")
    #expect(CrashRedact.issueTitle(ips: "{}", names: names) == "Crash report")
    #expect(CrashRedact.issueTitle(ips: "kein json", names: names) == "Crash report")
    let partial = #"{"app_version":"?"}"# + "\n" + #"{"exception":{"type":"EXC_CRASH"}}"#
    #expect(CrashRedact.issueTitle(ips: partial, names: names) == "Crash: EXC_CRASH")
    #expect(!CrashRedact.issueTitle(ips: partial, names: names).contains("?"))
}

@Test @MainActor func openingAnIssueNeverLeavesTheAppInTests() throws {
    var opened: [URL] = []
    let saved = CrashLinks.opener
    CrashLinks.opener = { opened.append($0) }
    defer { CrashLinks.opener = saved }
    let p = CrashReports.Prompt(fileName: "x.ips", title: "Crash: 1 (2) · EXC_X", text: "bericht\n", count: 1, newest: Date())
    CrashPrompt.shared.present(p, mix: nil)
    CrashPrompt.shared.openIssue()
    #expect(opened.count == 1)
    #expect(opened.first?.absoluteString.hasPrefix("https://github.com/Slayer7411/MINOS-741/issues/new?title=Crash%3A") == true)
    #expect(CrashPrompt.shared.shown == false)
}

@Test func lastSeenTimestampFromPrefsDoesNotRepeatTheReport() {
    // der gespeicherte Zeitpunkt (Sekunden seit 1970) darf den Bericht nicht noch einmal „neu“ machen
    let mtime = Date(timeIntervalSinceReferenceDate: 813_000_000.123456789)
    let stored = mtime.timeIntervalSince1970
    let files: [(name: String, date: Date)] = [("MINOS-741_x.ips", mtime)]
    #expect(CrashReports.newReports(files, after: Date(timeIntervalSince1970: stored)).isEmpty)
    #expect(CrashReports.newReports(files, after: Date(timeIntervalSince1970: stored - 1)).count == 1)
}
