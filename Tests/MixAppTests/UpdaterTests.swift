import Foundation
import Testing
@testable import MixApp

/// Updates: Manifest, Kanäle und Quellen, Reihenfolge nach Datum, Prüfsumme, Netz-Regeln, Installationsregel, Helfer
@Suite struct UpdaterTests {
    static let sha = String(repeating: "a", count: 64)
    static let dmgURL = "https://github.com/Slayer7411/MINOS-741/releases/download/latest-build/MINOS-741.dmg"

    static func manifestJSON(build: String = "b2", date: String = "2026-10-16T09:00:00Z", sha: String = sha,
                             file: String = "MINOS-741-0.9-b2.dmg", size: String = "1234", url: String? = nil,
                             codename: String? = nil) -> Data {
        let u = url.map { ", \"url\": \"\($0)\"" } ?? ""
        let c = codename.map { ", \"codename\": \"\($0)\"" } ?? ""
        return Data("""
        {"version": "0.9", "build": "\(build)", "file": "\(file)", "sha256": "\(sha)", "size": \(size),
         "date": "\(date)", "minSystem": "15.0"\(u)\(c)}
        """.utf8)
    }

    static func manifest(build: String = "b2", date: String = "2026-10-16T09:00:00Z", url: String? = nil) -> UpdateManifest {
        UpdateManifest.parse(manifestJSON(build: build, date: date, url: url))!
    }

    static func error(_ r: Result<Void, UpdateError>) -> UpdateError? {
        if case .failure(let e) = r { return e }
        return nil
    }

    static func loadError(_ r: Result<(UpdateManifest, Updater.Candidate.Source), UpdateError>) -> UpdateError? {
        if case .failure(let e) = r { return e }
        return nil
    }

    static func tempDir(_ tag: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("upd-\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: Manifest

    @Test func parsesValidManifest() {
        let m = UpdateManifest.parse(Self.manifestJSON(sha: String(repeating: "A", count: 64)))
        #expect(m?.build == "b2")
        #expect(m?.size == 1234)
        #expect(m?.sha256 == Self.sha)   // Kleinbuchstaben
        #expect(m?.url == nil)           // Ordner-Manifest ohne Adresse
    }

    @Test func manifestCodenameIsOptional() {
        #expect(UpdateManifest.parse(Self.manifestJSON(codename: "LIMBUS"))?.codename == "LIMBUS")
        #expect(UpdateManifest.parse(Self.manifestJSON())?.codename == nil)
    }

    @Test func noticeNamesCodenameWhenKnown() {
        #expect(UpdateRules.noticeText(version: "0.9", codename: "LUXURIA", build: "b2") == "Update verfügbar: 0.9 · LUXURIA (b2)")
        #expect(UpdateRules.noticeText(version: "0.9", codename: nil, build: "b2") == "Update verfügbar: 0.9 (b2)")
        #expect(UpdateRules.noticeText(version: "0.9", codename: "", build: "b2") == "Update verfügbar: 0.9 (b2)")
    }

    @Test func manifestWithDownloadURL() {
        let m = UpdateManifest.parse(Self.manifestJSON(url: Self.dmgURL))
        #expect(m?.url == Self.dmgURL)
        // Adresse außerhalb der erlaubten Hosts: das ganze Manifest ist ungültig
        #expect(UpdateManifest.parse(Self.manifestJSON(url: "https://example.com/MINOS-741.dmg")) == nil)
        #expect(UpdateManifest.parse(Self.manifestJSON(url: "http://github.com/MINOS-741.dmg")) == nil)
    }

    @Test func rejectsBrokenManifests() {
        #expect(UpdateManifest.parse(Data("{}".utf8)) == nil)
        #expect(UpdateManifest.parse(Self.manifestJSON(sha: "xyz")) == nil)                        // Hash-Format
        #expect(UpdateManifest.parse(Self.manifestJSON(file: "../evil.dmg")) == nil)              // Pfad
        #expect(UpdateManifest.parse(Self.manifestJSON(file: "app.zip")) == nil)                  // keine DMG
        #expect(UpdateManifest.parse(Self.manifestJSON(date: "gestern")) == nil)                  // Datum
        #expect(UpdateManifest.parse(Self.manifestJSON(size: "0")) == nil)                        // leer
        #expect(UpdateManifest.parse(Self.manifestJSON(build: "")) == nil)
    }

    // MARK: Netz-Regeln

    @Test func onlyHTTPSGitHubHosts() throws {
        #expect(UpdateNet.isAllowed(Self.dmgURL))
        #expect(UpdateNet.isAllowed("https://objects.githubusercontent.com/x/MINOS-741.dmg"))
        #expect(!UpdateNet.isAllowed("http://github.com/x"))                       // kein HTTP
        #expect(!UpdateNet.isAllowed("https://evil.github.com.example/x"))         // Host-Täuschung
        #expect(!UpdateNet.isAllowed("https://example.com/x"))
        #expect(!UpdateNet.isAllowed("https://user@github.com/x"))                 // Benutzer in der Adresse
        #expect(!UpdateNet.isAllowed("https://github.com:8443/x"))                 // fremder Port
        #expect(!UpdateNet.isAllowed("file:///etc/passwd"))
        #expect(!UpdateNet.isAllowed("nicht eine adresse"))
    }

    @Test func redirectsOnlyToAllowedHosts() throws {
        #expect(UpdateNet.redirectAllowed(URL(string: "https://objects.githubusercontent.com/a")))
        #expect(!UpdateNet.redirectAllowed(URL(string: "https://attacker.example/a")))
        #expect(!UpdateNet.redirectAllowed(URL(string: "http://objects.githubusercontent.com/a")))
        #expect(!UpdateNet.redirectAllowed(nil))
    }

    @Test func channelAddresses() {
        #expect(UpdateChannel.latestBuild.manifestURL?.absoluteString
                == "https://github.com/Slayer7411/MINOS-741/releases/download/latest-build/latest.json")
        #expect(UpdateChannel.stable.manifestURL?.absoluteString
                == "https://github.com/Slayer7411/MINOS-741/releases/latest/download/latest.json")
        #expect(UpdateChannel.folder.manifestURL == nil)
        #expect(UpdateChannel.off.manifestURL == nil)
        for ch in [UpdateChannel.latestBuild, .stable] {
            #expect(ch.manifestURL.map(UpdateNet.isAllowed) == true)
        }
        #expect(UpdateChannel.folder.checkInterval == 30 * 60)
        #expect(UpdateChannel.latestBuild.checkInterval == 6 * 3600)
        #expect(UpdateChannel(rawValue: "latest") == .latestBuild)   // gespeicherte Einstellung bleibt lesbar
    }

    // MARK: Quelle wählen

    @Test func sourceFollowsChannel() async throws {
        #expect(Self.loadError(await Updater.load(.off, folder: nil)) == .off)
        #expect(Self.loadError(await Updater.load(.folder, folder: nil)) == .noFolder)
        // Ordner ohne latest.json: Fehler, kein Netz
        let empty = try Self.tempDir("empty")
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(Self.loadError(await Updater.load(.folder, folder: empty)) == .noManifest)
    }

    @Test func folderChannelReadsManifestAndDMG() async throws {
        let dir = try Self.tempDir("folder")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.manifestJSON().write(to: dir.appendingPathComponent("latest.json"))
        // DMG fehlt: Fehler mit dem Namen
        #expect(Self.loadError(await Updater.load(.folder, folder: dir)) == .dmgMissing("MINOS-741-0.9-b2.dmg"))
        try Data("dmg".utf8).write(to: dir.appendingPathComponent("MINOS-741-0.9-b2.dmg"))
        switch await Updater.load(.folder, folder: dir) {
        case .success(let (m, source)):
            #expect(m.build == "b2")
            #expect(source == .folder(dir))
        case .failure(let e):
            Issue.record("Ordner-Quelle erwartet, erhalten: \(e)")
        }
    }

    // MARK: Ordnung und Kandidat

    @Test func candidateNeedsNewerDateAndOtherBuild() {
        let m = Self.manifest(build: "b2", date: "2026-10-16T09:00:00Z")
        #expect(UpdateRules.isCandidate(m, currentBuild: "b1", currentDate: "2026-10-01T00:00:00Z"))
        // gleicher Build: nie (keine Anzeige der eigenen Version)
        #expect(!UpdateRules.isCandidate(m, currentBuild: "b2", currentDate: "2026-10-01T00:00:00Z"))
        // Manifest älter als dieser Build: kein Rückschritt
        #expect(!UpdateRules.isCandidate(m, currentBuild: "b3", currentDate: "2026-10-17T00:00:00Z"))
        // gleiches Datum: nicht neuer
        #expect(!UpdateRules.isCandidate(m, currentBuild: "b1", currentDate: "2026-10-16T09:00:00Z"))
        // kein Build-Datum (Entwicklungsbuild): nie
        #expect(!UpdateRules.isCandidate(m, currentBuild: "b1", currentDate: nil))
    }

    @Test func dateOrderingUsesInstantNotText() {
        // gleicher Zeitpunkt, andere Zeitzone: nicht neuer
        let m = Self.manifest(build: "b2", date: "2026-10-16T11:00:00+02:00")
        #expect(!UpdateRules.isCandidate(m, currentBuild: "b1", currentDate: "2026-10-16T09:00:00Z"))
        let later = Self.manifest(build: "b2", date: "2026-10-16T09:00:01Z")
        #expect(UpdateRules.isCandidate(later, currentBuild: "b1", currentDate: "2026-10-16T09:00:00Z"))
    }

    // MARK: Installationsregel

    @Test func installBlockRule() {
        #expect(UpdateRules.installBlock(decksPlaying: true, live: true, recording: true) == .deckPlaying)
        #expect(UpdateRules.installBlock(decksPlaying: false, live: true, recording: false) == .live)
        #expect(UpdateRules.installBlock(decksPlaying: false, live: false, recording: true) == .recording)
        #expect(UpdateRules.installBlock(decksPlaying: false, live: false, recording: false) == nil)
    }

    @Test func autoInstallOnlyWhenIdleAndFree() {
        let idle = UpdateRules.autoIdle
        #expect(UpdateRules.autoInstallDue(enabled: true, pending: true, block: nil, idle: idle, skipped: false))
        #expect(!UpdateRules.autoInstallDue(enabled: true, pending: true, block: nil, idle: idle - 1, skipped: false))
        #expect(!UpdateRules.autoInstallDue(enabled: false, pending: true, block: nil, idle: idle + 600, skipped: false))
        #expect(!UpdateRules.autoInstallDue(enabled: true, pending: false, block: nil, idle: idle + 600, skipped: false))
        #expect(!UpdateRules.autoInstallDue(enabled: true, pending: true, block: .deckPlaying, idle: idle + 600, skipped: false))
        #expect(!UpdateRules.autoInstallDue(enabled: true, pending: true, block: .live, idle: idle + 600, skipped: false))
    }

    @Test func skippedBuildIsNeverAutoInstalled() {
        let idle = UpdateRules.autoIdle + 600
        #expect(!UpdateRules.autoInstallDue(enabled: true, pending: true, block: nil, idle: idle, skipped: true))
        #expect(UpdateRules.autoSkipped(build: "b2", skipBuild: "b2"))
        #expect(!UpdateRules.autoSkipped(build: "b3", skipBuild: "b2"))
        #expect(!UpdateRules.autoSkipped(build: "b2", skipBuild: ""))
    }

    /// Überspringen fällt, sobald ein anderer, neuerer Build erscheint; der übersprungene selbst hebt es nicht auf
    @Test func newerBuildClearsSkip() {
        let skipDate = "2026-10-16T09:00:00Z"
        #expect(UpdateRules.clearsSkip(Self.manifest(build: "b3", date: "2026-10-16T10:00:00Z"), skipBuild: "b2", skipDate: skipDate))
        #expect(!UpdateRules.clearsSkip(Self.manifest(build: "b2", date: "2026-10-16T10:00:00Z"), skipBuild: "b2", skipDate: skipDate))
        #expect(!UpdateRules.clearsSkip(Self.manifest(build: "b3", date: "2026-10-16T08:00:00Z"), skipBuild: "b2", skipDate: skipDate))
        #expect(!UpdateRules.clearsSkip(Self.manifest(build: "b3", date: "2026-10-16T10:00:00Z"), skipBuild: "", skipDate: skipDate))
        #expect(!UpdateRules.clearsSkip(Self.manifest(build: "b3", date: "2026-10-16T10:00:00Z"), skipBuild: "b2", skipDate: ""))
    }

    // MARK: Prüfsumme und Bereitstellung

    @Test func sha256OfKnownContent() throws {
        let dir = try Self.tempDir("sha")
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("abc.bin")
        try Data("abc".utf8).write(to: f)
        let r = try UpdateRules.sha256(of: f)
        #expect(r.hex == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(r.size == 3)
    }

    /// falsche Größe oder Prüfsumme: vor dem Einhängen abbrechen, keine App bereitstellen, Arbeitsordner weg
    @Test func wrongChecksumStopsBeforeMount() throws {
        let work = try Self.tempDir("work")
        let dmg = work.appendingPathComponent("MINOS-741-0.9-b2.dmg")
        try Data("kein dmg".utf8).write(to: dmg)
        let newApp = work.appendingPathComponent(".MINOS-741-update.app")
        // Größe 1234 passt nicht
        #expect(Self.error(Updater.stage(Self.manifest(), dmg: dmg, work: work, newApp: newApp)) == .sizeMismatch)

        let work2 = try Self.tempDir("work2")
        let dmg2 = work2.appendingPathComponent("MINOS-741-0.9-b2.dmg")
        try Data("kein dmg".utf8).write(to: dmg2)
        let m2 = UpdateManifest.parse(Self.manifestJSON(sha: String(repeating: "0", count: 64), size: "8"))!
        #expect(Self.error(Updater.stage(m2, dmg: dmg2, work: work2, newApp: work2.appendingPathComponent("x.app"))) == .checksum)
        #expect(!FileManager.default.fileExists(atPath: work2.path))   // Arbeitsordner immer weg
    }

    @Test func helperScriptHasValidSyntax() throws {
        let dir = try Self.tempDir("helper")
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("helfer.sh")
        try Updater.helperScript.write(to: f, atomically: true, encoding: .utf8)
        let r = Updater.run("/bin/bash", ["-n", f.path])
        #expect(r.status == 0, Comment(rawValue: r.out))
    }
}
