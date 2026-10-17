import AppKit
import CryptoKit
import Foundation
import MixCore
import MixEngine
import Observation
import SwiftUI

/// Manifest `latest.json` (Ordner oder GitHub-Release; scripts/make-dmg.sh --publish, scripts/release.sh)
struct UpdateManifest: Codable, Equatable {
    let version: String
    let build: String
    /// Dateiname der DMG (Ordner) bzw. Name des Release-Assets
    let file: String
    let sha256: String
    let size: Int64
    let date: String
    let minSystem: String
    /// Download-Adresse der DMG (GitHub-Release); im Ordner nicht nötig
    let url: String?

    /// Lesen und prüfen: Pflichtfelder, Dateiname ohne Pfad (.dmg), Hash im Hex-Format, gültiges Datum, erlaubte Adresse
    static func parse(_ data: Data) -> UpdateManifest? {
        guard let m = try? JSONDecoder().decode(UpdateManifest.self, from: data) else { return nil }
        guard !m.version.isEmpty, !m.build.isEmpty, m.size > 0,
              m.file == (m.file as NSString).lastPathComponent, m.file.hasSuffix(".dmg"), !m.file.hasPrefix("."),
              m.sha256.count == 64, m.sha256.allSatisfy(\.isHexDigit),
              UpdateRules.parseDate(m.date) != nil,
              m.url.map(UpdateNet.isAllowed) ?? true else { return nil }
        return UpdateManifest(version: m.version, build: m.build, file: m.file, sha256: m.sha256.lowercased(), size: m.size,
                              date: m.date, minSystem: m.minSystem, url: m.url)
    }
}

/// Update-Kanal (ui.updateChannel): neuester Build (rollendes Release), stabile Versionen, eigener Ordner, aus
enum UpdateChannel: String, CaseIterable, Codable, Identifiable {
    case latestBuild = "latest"
    case stable = "stable"
    case folder = "folder"
    case off = "off"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .latestBuild: String(localized: "Neuester Build")
        case .stable: String(localized: "Stabile Versionen")
        case .folder: String(localized: "Eigener Ordner")
        case .off: String(localized: "Aus")
        }
    }

    /// Manifest-Adresse der Netzkanäle (nil bei Ordner und aus)
    var manifestURL: URL? {
        switch self {
        case .latestBuild: URL(string: "https://github.com/Slayer7411/MINOS-741/releases/download/latest-build/latest.json")
        case .stable: URL(string: "https://github.com/Slayer7411/MINOS-741/releases/latest/download/latest.json")
        case .folder, .off: nil
        }
    }

    /// Abstand der automatischen Prüfung: Ordner 30 min, Netz 6 h
    var checkInterval: TimeInterval { self == .folder ? 30 * 60 : 6 * 3600 }
}

/// Netz-Regeln: nur HTTPS, nur GitHub (Adresse und Weiterleitungen), kein Cookie, kein Cache
enum UpdateNet {
    static let hosts: Set<String> = ["github.com", "objects.githubusercontent.com"]
    static let maxManifestBytes = 64 * 1024

    /// erlaubte Adresse: https, Host github.com oder objects.githubusercontent.com, ohne Benutzer und Port
    static func isAllowed(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.user == nil && url.password == nil
            && (url.port == nil || url.port == 443) && hosts.contains(url.host?.lowercased() ?? "")
    }

    static func isAllowed(_ text: String) -> Bool { URL(string: text).map(isAllowed) ?? false }

    /// Weiterleitung nur auf erlaubte Ziele (GitHub leitet Release-Assets auf objects.githubusercontent.com um)
    static func redirectAllowed(_ url: URL?) -> Bool { url.map(isAllowed) ?? false }

    /// Sitzung ohne Cookies, ohne Cache; 15 s Inaktivität, Download darf länger laufen
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 30 * 60
        return URLSession(configuration: c)
    }()

    /// prüft jede Weiterleitung
    final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(redirectAllowed(request.url) ? request : nil)
        }
    }
    static let guardDelegate = RedirectGuard()

    static func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpShouldHandleCookies = false
        r.setValue("MINOS-741-Update", forHTTPHeaderField: "User-Agent")
        return r
    }

    /// Manifest holen (höchstens 64 KB, nur HTTP 200)
    static func fetchManifest(_ url: URL) async throws -> Data {
        guard isAllowed(url) else { throw UpdateError.notAllowed }
        let (data, resp) = try await session.data(for: request(url), delegate: guardDelegate)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200, redirectAllowed(resp.url) else {
            throw UpdateError.network(String(localized: "latest.json nicht gefunden"))
        }
        guard data.count <= maxManifestBytes else { throw UpdateError.manifestInvalid }
        return data
    }

    /// DMG laden nach `dir/name`; liefert die lokale Datei
    static func download(_ url: URL, named name: String, into dir: URL) async throws -> URL {
        guard isAllowed(url) else { throw UpdateError.notAllowed }
        let (tmp, resp) = try await session.download(for: request(url), delegate: guardDelegate)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200, redirectAllowed(resp.url) else {
            throw UpdateError.network(String(localized: "Download fehlgeschlagen"))
        }
        let dest = dir.appendingPathComponent(name)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }
}

/// Entscheidungen des Updaters ohne Oberfläche (Unit-Tests: MixAppTests/UpdaterTests)
enum UpdateRules {
    /// Gründe, warum jetzt nicht installiert werden darf
    enum Block: Equatable {
        case deckPlaying, live, recording

        var message: String {
            switch self {
            case .deckPlaying: String(localized: "ein Deck spielt")
            case .live: String(localized: "LIVE ist an")
            case .recording: String(localized: "eine Aufnahme läuft")
            }
        }
    }

    /// Automatik: so lange keine Eingabe in der App (Sekunden)
    static let autoIdle: TimeInterval = 120

    /// ISO-8601-Datum (mit Zeitzone) aus dem Manifest oder den Build-Infos
    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// Kandidat: anderer Build und Datum neuer als das Datum dieses Builds (nie Hash-Vergleich)
    static func isCandidate(_ m: UpdateManifest, currentBuild: String, currentDate: String?) -> Bool {
        guard let current = currentDate.flatMap(parseDate), let new = parseDate(m.date) else { return false }
        return m.build != currentBuild && new > current
    }

    /// Grund gegen Installation jetzt (Deck, LIVE, Aufnahme), sonst nil
    static func installBlock(decksPlaying: Bool, live: Bool, recording: Bool) -> Block? {
        if decksPlaying { return .deckPlaying }
        if live { return .live }
        if recording { return .recording }
        return nil
    }

    /// Automatik: an, ein Update liegt bereit, nichts blockiert, nicht übersprungen, und die App war `autoIdle` Sekunden
    /// ohne Eingabe
    static func autoInstallDue(enabled: Bool, pending: Bool, block: Block?, idle: TimeInterval, skipped: Bool) -> Bool {
        enabled && pending && block == nil && !skipped && idle >= autoIdle
    }

    /// Übersprungen (nach Zurückwechseln): genau dieser Build wird nicht automatisch installiert
    static func autoSkipped(build: String, skipBuild: String) -> Bool { !skipBuild.isEmpty && build == skipBuild }

    /// Ein anderer Build, der neuer ist als der übersprungene, hebt das Überspringen auf
    static func clearsSkip(_ m: UpdateManifest, skipBuild: String, skipDate: String) -> Bool {
        guard !skipBuild.isEmpty, m.build != skipBuild, let new = parseDate(m.date), let skip = parseDate(skipDate) else {
            return false
        }
        return new > skip
    }

    /// SHA-256 (Hex, Kleinbuchstaben) und Größe der Datei, blockweise gelesen
    static func sha256(of url: URL) throws -> (hex: String, size: Int64) {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        var size: Int64 = 0
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
            size += Int64(chunk.count)
        }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), size)
    }
}

/// Fehler des Updaters; `message` ist der Text für die Statusleiste
enum UpdateError: Error, Equatable {
    case off, noFolder, folderMissing, noManifest, manifestInvalid, dmgMissing(String), busy, noCandidate, noPrevious
    case blocked(UpdateRules.Block), notABundle, notWritable(String), outsideTestRoot, notAllowed, network(String)
    case io(String), sizeMismatch, checksum, hdiutil(String), noAppInDMG, packageMismatch, signature(String)

    var message: String {
        switch self {
        case .off: String(localized: "Updates sind aus")
        case .noFolder: String(localized: "Kein Update-Ordner gewählt")
        case .folderMissing: String(localized: "Update-Ordner nicht erreichbar")
        case .noManifest: String(localized: "latest.json fehlt im Update-Ordner")
        case .manifestInvalid: String(localized: "latest.json ist ungültig")
        case .dmgMissing(let f): String(format: String(localized: "DMG fehlt im Update-Ordner: %@"), f)
        case .busy: String(localized: "Prüfung oder Installation läuft schon")
        case .noCandidate: String(localized: "Kein Update bereit")
        case .noPrevious: String(localized: "Keine vorherige Version vorhanden")
        case .blocked(let b): String(format: String(localized: "Installation nicht möglich: %@"), b.message)
        case .notABundle: String(localized: "Diese App liegt nicht als .app-Paket vor: kein Update")
        case .notWritable(let d): String(format: String(localized: "Kein Schreibzugriff auf %@: MINOS-741 von Hand aus dem DMG ersetzen"), d)
        case .outsideTestRoot: String(localized: "E2E: Ziel liegt außerhalb des Testordners")
        case .notAllowed: String(localized: "Adresse nicht erlaubt")
        case .network(let t): String(format: String(localized: "Update-Server: %@"), t)
        case .io(let t): String(format: String(localized: "Datei-Fehler: %@"), t)
        case .sizeMismatch: String(localized: "DMG: Größe stimmt nicht mit dem Manifest")
        case .checksum: String(localized: "DMG: Prüfsumme stimmt nicht")
        case .hdiutil(let t): String(format: String(localized: "DMG öffnen fehlgeschlagen: %@"), t)
        case .noAppInDMG: String(localized: "Das DMG enthält keine MINOS-741.app")
        case .packageMismatch: String(localized: "Das Paket passt nicht zum Manifest")
        case .signature(let t): String(format: String(localized: "Signatur ungültig: %@"), t)
        }
    }
}

/// Automatische Updates (ui.updateChannel): Manifest vom Netz (GitHub) oder aus einem Ordner. Prüfen im Hintergrund;
/// Installation: DMG holen und prüfen, App daneben bereitstellen, beenden, Helfer tauscht die Bundles und startet neu.
/// Das Audio sieht nichts davon.
@MainActor @Observable
final class Updater {
    static let shared = Updater()

    /// Quelle eines Kandidaten: DMG im Ordner oder Download-Adresse
    struct Candidate: Equatable {
        enum Source: Equatable {
            case folder(URL)
            case download(URL)
        }
        let manifest: UpdateManifest
        let source: Source
    }

    /// neuere Version (nil = keine oder schon aktuell)
    private(set) var candidate: Candidate?
    private(set) var lastChecked: Date?
    /// letzter Fehler der Prüfung (Anzeige in den Einstellungen)
    private(set) var lastError: String?
    private(set) var checking = false
    private(set) var installing = false
    /// Helfer ist gestartet, die App beendet sich gerade
    private(set) var relaunching = false

    @ObservationIgnored private weak var mix: MixModel?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var lastActivity = Date()
    @ObservationIgnored private var startedAt: Date?
    @ObservationIgnored private var lastAutoCheck: Date?
    @ObservationIgnored private var announced: String?
    /// Build, bei dem die Automatik gescheitert ist: bis zum nächsten Kandidaten nicht erneut versuchen
    @ObservationIgnored private var autoFailedBuild: String?

    /// erste automatische Prüfung 30 s nach dem Start, Takt 5 s
    static let firstCheckDelay: TimeInterval = 30
    static let tickInterval: TimeInterval = 5

    private init() {}

    // MARK: Einstellungen und Pfade

    var channel: UpdateChannel { mix?.prefs.ui.updateChannel ?? .latestBuild }

    /// Update-Ordner aus den Einstellungen (nur für den Kanal „Eigener Ordner“)
    var folder: URL? {
        let p = mix?.prefs.ui.updateFolder ?? ""
        return p.isEmpty ? nil : URL(fileURLWithPath: (p as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Netzprüfung im Testlauf aus: Ende-zu-Ende nutzt nur den Ordner (kein Zugriff auf GitHub aus Tests)
    var networkAllowed: Bool { !E2E.isActive && !Session.isSelfTest }

    /// aktuelle Version und Build-Datum aus Info.plist (MINOSBuildDate, make-app.sh)
    var currentBuild: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "" }
    var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "" }
    var currentDate: String? { Bundle.main.infoDictionary?["MINOSBuildDate"] as? String }

    /// Bundle, das ersetzt wird. Im Ende-zu-Ende-Lauf die Kopie aus MIX741_E2E_APP (nur unter dem Testordner)
    var installTarget: URL {
        if E2E.isActive, let p = ProcessInfo.processInfo.environment["MIX741_E2E_APP"], !p.isEmpty {
            return URL(fileURLWithPath: p, isDirectory: true)
        }
        return Bundle.main.bundleURL
    }

    /// Rückstand für Rollback: `.MINOS-741-previous.app` neben der App
    var previousURL: URL { installTarget.deletingLastPathComponent().appendingPathComponent(".MINOS-741-previous.app") }
    var hasPrevious: Bool { FileManager.default.fileExists(atPath: previousURL.path) }

    /// Protokoll der Installation (eigene Datei, nicht im Datenordner)
    private var logURL: URL {
        if E2E.isActive, let root = E2E.root { return root.appendingPathComponent("logs/update.log") }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/MINOS-741/update.log")
    }

    private var decksPlaying: Bool { mix.map { m in (0..<MixEngine.deckCount).contains { m.deck($0).playing } } ?? false }

    /// Grund gegen Installation jetzt (Deck, LIVE, Aufnahme), sonst nil
    var block: UpdateRules.Block? {
        UpdateRules.installBlock(decksPlaying: decksPlaying, live: mix?.live ?? false, recording: mix?.recorder.recording ?? false)
    }

    // MARK: Start

    /// einmal beim Start der Hauptansicht (startControllers)
    func start(mix: MixModel) {
        guard self.mix == nil else { return }
        self.mix = mix
        // Selbsttest: kein Takt und keine Beobachtung der Tastatur und Maus (Netz: `networkAllowed`)
        guard !Session.isSelfTest else { return }
        startedAt = Date()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) { event in
            MainActor.assumeIsolated { Updater.shared.lastActivity = Date() }
            return event
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { _ in
            MainActor.assumeIsolated { Updater.shared.tick() }
        }
    }

    /// Kanal gewechselt: Kandidat vergessen, bald neu prüfen
    func channelChanged() {
        candidate = nil
        lastError = nil
        lastAutoCheck = nil
    }

    /// Takt: Prüfung nach 30 s und danach im Kanal-Abstand; Automatik-Installation bei Ruhe
    private func tick() {
        guard let mix, let started = startedAt else { return }
        let now = Date()
        let ch = channel
        if ch == .off || (ch == .folder && folder == nil) { candidate = nil }
        if ch != .off, !checking, ch == .folder || networkAllowed {
            let due = lastAutoCheck.map { now.timeIntervalSince($0) >= ch.checkInterval }
                ?? (now.timeIntervalSince(started) >= Self.firstCheckDelay)
            if due { lastAutoCheck = now; check() }
        }
        if mix.prefs.ui.autoUpdate, let c = candidate, c.manifest.build != autoFailedBuild, !installing, !relaunching,
           UpdateRules.autoInstallDue(enabled: true, pending: true, block: block, idle: now.timeIntervalSince(lastActivity),
                                      skipped: UpdateRules.autoSkipped(build: c.manifest.build,
                                                                       skipBuild: mix.prefs.ui.updateSkipBuild)) {
            install { result in
                if case .failure = result { Updater.shared.autoFailedBuild = c.manifest.build }
            }
        }
    }

    // MARK: Prüfen

    /// Manifest des gewählten Kanals laden und prüfen (Hintergrund); Ergebnis über `completion` und die Statusleiste
    func check(completion: (@MainActor (Result<Candidate?, UpdateError>) -> Void)? = nil) {
        let ch = channel
        guard ch != .off else { completion?(.failure(.off)); return }
        guard !checking, !installing, !relaunching else { completion?(.failure(.busy)); return }
        if ch != .folder && !networkAllowed {
            completion?(.failure(.network(String(localized: "im Testlauf aus"))))
            return
        }
        checking = true
        let build = currentBuild, date = currentDate, folder = folder
        Task {
            let loaded = await Updater.load(ch, folder: folder)
            Updater.shared.finishCheck(loaded.map { m, source in
                UpdateRules.isCandidate(m, currentBuild: build, currentDate: date) ? Candidate(manifest: m, source: source) : nil
            }, completion: completion)
        }
    }

    /// Manifest holen: Ordner (Datei lesen) oder Netz (GitHub); mit der Quelle des DMG
    nonisolated static func load(_ ch: UpdateChannel, folder: URL?) async -> Result<(UpdateManifest, Candidate.Source), UpdateError> {
        switch ch {
        case .off:
            return .failure(.off)
        case .folder:
            guard let folder else { return .failure(.noFolder) }
            return await onQueue { readManifest(folder).map { ($0, Candidate.Source.folder(folder)) } }
        case .latestBuild, .stable:
            guard let url = ch.manifestURL else { return .failure(.notAllowed) }
            do {
                let m = try await UpdateNet.fetchManifest(url)
                guard let parsed = UpdateManifest.parse(m), let dmg = parsed.url, let dmgURL = URL(string: dmg) else {
                    return .failure(.manifestInvalid)
                }
                return .success((parsed, .download(dmgURL)))
            } catch let e as UpdateError {
                return .failure(e)
            } catch {
                return .failure(.network(error.localizedDescription))
            }
        }
    }

    /// Manifest im Ordner lesen und prüfen (nicht auf dem Hauptthread)
    nonisolated static func readManifest(_ folder: URL) -> Result<UpdateManifest, UpdateError> {
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder.path) else { return .failure(.folderMissing) }
        let url = folder.appendingPathComponent("latest.json")
        guard fm.fileExists(atPath: url.path) else { return .failure(.noManifest) }
        guard let data = try? Data(contentsOf: url), let m = UpdateManifest.parse(data) else { return .failure(.manifestInvalid) }
        guard fm.fileExists(atPath: folder.appendingPathComponent(m.file).path) else { return .failure(.dmgMissing(m.file)) }
        return .success(m)
    }

    private func finishCheck(_ result: Result<Candidate?, UpdateError>, completion: (@MainActor (Result<Candidate?, UpdateError>) -> Void)?) {
        checking = false
        lastChecked = Date()
        switch result {
        case .failure(let e):
            lastError = e.message
            candidate = nil
            completion?(.failure(e))
        case .success(let c):
            lastError = nil
            candidate = c
            if let c, let mix, UpdateRules.clearsSkip(c.manifest, skipBuild: mix.prefs.ui.updateSkipBuild,
                                                      skipDate: mix.prefs.ui.updateSkipDate) {
                mix.prefs.ui.updateSkipBuild = ""
                mix.prefs.ui.updateSkipDate = ""
            }
            if let c, announced != c.manifest.build {
                // einmal je Build melden; bleibt stehen bis Klick oder ✕, Menü und Einstellungen zeigen es weiter
                announced = c.manifest.build
                let text = String(format: String(localized: "Update verfügbar: %@ (%@)"), c.manifest.version, c.manifest.build)
                StatusCenter.post(.info, text, key: "update", sticky: true,
                                  action: (String(localized: "Installieren"), { Updater.shared.install() }))
            }
            completion?(.success(c))
        }
    }

    // MARK: Installieren

    /// Installation: DMG holen und prüfen, dann Beenden und Neustart über den Helfer. `completion` bekommt das
    /// Ergebnis vor dem Beenden (Ende-zu-Ende-Antwort); bei Erfolg beendet sich die App selbst.
    func install(completion: (@MainActor (Result<[String: Any], UpdateError>) -> Void)? = nil) {
        func fail(_ e: UpdateError) {
            StatusCenter.post(.warning, String(localized: "Update nicht installiert"), detail: e.message, key: "update")
            completion?(.failure(e))
        }
        guard !installing, !relaunching else { return fail(.busy) }
        guard let c = candidate else { return fail(.noCandidate) }
        if let b = block { return fail(.blocked(b)) }
        let target = installTarget
        guard target.pathExtension == "app",
              FileManager.default.fileExists(atPath: target.appendingPathComponent("Contents/Info.plist").path) else {
            return fail(.notABundle)
        }
        if E2E.isActive {
            guard let root = E2E.root, target.path.hasPrefix(root.path + "/") else { return fail(.outsideTestRoot) }
        }
        let dir = target.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: dir.path) else { return fail(.notWritable(dir.path)) }
        let newApp = dir.appendingPathComponent(".MINOS-741-update.app")
        let work = Self.workDir()
        installing = true
        StatusCenter.dismiss(key: "update")
        StatusCenter.post(.info, String(localized: "Update wird geladen …"), detail: c.manifest.version, key: "update", job: true)
        Task {
            let got = await Updater.acquire(c, work: work)
            let result: Result<Void, UpdateError>
            switch got {
            case .failure(let e): result = .failure(e)
            case .success(let dmg):
                result = await Updater.onQueue { Updater.stage(c.manifest, dmg: dmg, work: work, newApp: newApp) }
            }
            Updater.shared.finishStage(result, c: c, target: target, newApp: newApp, completion: completion)
        }
    }

    private func finishStage(_ r: Result<Void, UpdateError>, c: Candidate, target: URL, newApp: URL,
                             completion: (@MainActor (Result<[String: Any], UpdateError>) -> Void)?) {
        installing = false
        StatusCenter.dismiss(key: "update")
        func abort(_ e: UpdateError) {
            try? FileManager.default.removeItem(at: newApp)
            StatusCenter.post(.warning, String(localized: "Update nicht installiert"), detail: e.message, key: "update")
            completion?(.failure(e))
        }
        if case .failure(let e) = r { return abort(e) }
        // zwischen Bereitstellung und Beenden kann ein Deck angefangen haben
        if let b = block { return abort(.blocked(b)) }
        guard Self.spawnHelper(mode: "install", app: target, source: newApp, log: logURL, direct: E2E.isActive) else {
            return abort(.io(String(localized: "Helfer nicht gestartet")))
        }
        relaunching = true
        StatusCenter.post(.info, String(localized: "Neue Version wird gestartet …"), detail: c.manifest.version, key: "update")
        completion?(.success(["relaunch": true, "build": c.manifest.build, "version": c.manifest.version, "to": target.path]))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
    }

    /// Zurück zur vorherigen Version (`.MINOS-741-previous.app`); danach Neustart über den Helfer
    func rollback(completion: (@MainActor (Result<[String: Any], UpdateError>) -> Void)? = nil) {
        func fail(_ e: UpdateError) {
            StatusCenter.post(.warning, String(localized: "Zurückwechseln nicht möglich"), detail: e.message, key: "update")
            completion?(.failure(e))
        }
        guard !installing, !relaunching else { return fail(.busy) }
        guard hasPrevious else { return fail(.noPrevious) }
        let prev = previousURL
        let target = installTarget
        if let b = block { return fail(.blocked(b)) }
        guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            return fail(.notWritable(target.deletingLastPathComponent().path))
        }
        guard Self.spawnHelper(mode: "rollback", app: target, source: prev, log: logURL, direct: E2E.isActive) else {
            return fail(.io(String(localized: "Helfer nicht gestartet")))
        }
        relaunching = true
        // der verlassene Build wird nicht automatisch wieder installiert (Einstellung bleibt nach dem Neustart)
        mix?.prefs.ui.updateSkipBuild = currentBuild
        mix?.prefs.ui.updateSkipDate = currentDate ?? ""
        completion?(.success(["relaunch": true, "rollback": true, "to": target.path]))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
    }

    /// Arbeitsordner: im Ende-zu-Ende-Lauf unter dem Testordner, sonst im temporären Ordner
    nonisolated static func workDir() -> URL {
        let base = E2E.root.map { $0.appendingPathComponent("tmp", isDirectory: true) } ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("minos-update-\(UUID().uuidString)", isDirectory: true)
    }

    /// Arbeit auf der Hintergrund-Queue (kein Hauptthread)
    nonisolated static func onQueue<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { c in DispatchQueue.global(qos: .utility).async { c.resume(returning: body()) } }
    }

    /// DMG an einen Ort im Arbeitsordner bringen: Ordner kopieren, Netz laden. Bei Fehler ist `work` entfernt.
    nonisolated static func acquire(_ c: Candidate, work: URL) async -> Result<URL, UpdateError> {
        let fm = FileManager.default
        do { try fm.createDirectory(at: work, withIntermediateDirectories: true) } catch {
            return .failure(.io(error.localizedDescription))
        }
        let result: Result<URL, UpdateError>
        switch c.source {
        case .folder(let folder):
            let src = folder.appendingPathComponent(c.manifest.file), dst = work.appendingPathComponent(c.manifest.file)
            result = await onQueue {
                do { try FileManager.default.copyItem(at: src, to: dst); return .success(dst) } catch {
                    return .failure(.io(error.localizedDescription))
                }
            }
        case .download(let url):
            do { result = .success(try await UpdateNet.download(url, named: c.manifest.file, into: work)) } catch let e as UpdateError {
                result = .failure(e)
            } catch {
                result = .failure(.network(error.localizedDescription))
            }
        }
        if case .failure = result { try? fm.removeItem(at: work) }
        return result
    }

    /// Sitzt die geladene DMG-Datei im Arbeitsordner: Größe und SHA-256 prüfen, einhängen, App daneben bereitstellen,
    /// aushängen, Signatur prüfen. Bei jedem Fehler bleibt die alte App unberührt; `work` wird immer entfernt.
    nonisolated static func stage(_ m: UpdateManifest, dmg: URL, work: URL, newApp: URL) -> Result<Void, UpdateError> {
        let fm = FileManager.default
        defer { try? fm.removeItem(at: work) }
        // geprüft wird die Datei, die auch eingehängt wird
        let sum: (hex: String, size: Int64)
        do { sum = try UpdateRules.sha256(of: dmg) } catch { return .failure(.io(error.localizedDescription)) }
        guard sum.size == m.size else { return .failure(.sizeMismatch) }
        guard sum.hex == m.sha256 else { return .failure(.checksum) }

        let mnt = work.appendingPathComponent("mnt", isDirectory: true)
        do { try fm.createDirectory(at: mnt, withIntermediateDirectories: true) } catch { return .failure(.io(error.localizedDescription)) }
        let attach = run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mnt.path, dmg.path])
        guard attach.status == 0 else { return .failure(.hdiutil(attach.out)) }
        let result = copyApp(from: mnt, manifest: m, to: newApp)
        var detach = run("/usr/bin/hdiutil", ["detach", mnt.path])
        if detach.status != 0 { detach = run("/usr/bin/hdiutil", ["detach", "-force", mnt.path]) }
        return result
    }

    /// App aus dem eingehängten DMG nach `newApp` kopieren, Quarantäne entfernen, Paket und Signatur prüfen
    nonisolated private static func copyApp(from mnt: URL, manifest m: UpdateManifest, to newApp: URL) -> Result<Void, UpdateError> {
        let fm = FileManager.default
        let app = mnt.appendingPathComponent("MINOS-741.app")
        guard fm.fileExists(atPath: app.path) else { return .failure(.noAppInDMG) }
        try? fm.removeItem(at: newApp)   // Rest eines früheren Versuchs
        let copy = run("/usr/bin/ditto", [app.path, newApp.path])
        guard copy.status == 0 else { return .failure(.io(copy.out)) }
        _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])
        let info = Bundle(url: newApp)?.infoDictionary
        guard info?["CFBundleVersion"] as? String == m.build, info?["CFBundleShortVersionString"] as? String == m.version else {
            try? fm.removeItem(at: newApp)
            return .failure(.packageMismatch)
        }
        let sig = run("/usr/bin/codesign", ["--verify", "--strict", newApp.path])
        guard sig.status == 0 else {
            try? fm.removeItem(at: newApp)
            return .failure(.signature(sig.out))
        }
        return .success(())
    }

    /// Programm mit Ausgabe (stdout + stderr) ausführen und auf das Ende warten
    @discardableResult
    nonisolated static func run(_ exe: String, _ args: [String]) -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: Helfer

    /// Kleiner Helfer (bash, im temporären Ordner): wartet auf das Ende dieser App, tauscht die Bundles, startet neu.
    /// install: App -> .MINOS-741-previous.app, neue App an ihre Stelle. rollback: die vorherige App wird wieder die
    /// aktive, die jetzige wird .MINOS-741-previous.app. Ende-zu-Ende: direkter Start des Programms (Umgebung bleibt).
    nonisolated static let helperScript = """
    #!/bin/bash
    # MINOS-741 Update-Helfer (Argumente: pid app quelle log modus programm|-)
    PID="$1"; APP="$2"; SRC="$3"; LOG="$4"; MODE="$5"; BIN="$6"
    mkdir -p "$(dirname "$LOG")"
    exec >>"$LOG" 2>&1
    trap 'rm -f "$0"' EXIT
    echo "[helfer] $(date) pid=$PID modus=$MODE"
    DIR=$(dirname "$APP")
    PREV="$DIR/.MINOS-741-previous.app"
    n=0
    while kill -0 "$PID" 2>/dev/null; do
      n=$((n+1)); [ "$n" -gt 900 ] && { echo "[helfer] App beendet nicht, Abbruch"; exit 1; }
      sleep 0.2
    done
    if [ "$MODE" = "install" ]; then
      rm -rf "$PREV"
      mv "$APP" "$PREV" || { echo "[helfer] alte App nicht verschoben"; exit 1; }
      if ! mv "$SRC" "$APP"; then
        echo "[helfer] neue App nicht eingesetzt, alte zurück"; mv "$PREV" "$APP"; exit 1
      fi
    else
      TMP="$DIR/.MINOS-741-swap.app"
      rm -rf "$TMP"
      mv "$APP" "$TMP" || { echo "[helfer] aktuelle App nicht verschoben"; exit 1; }
      if ! mv "$SRC" "$APP"; then
        echo "[helfer] vorherige App nicht eingesetzt, aktuelle zurück"; mv "$TMP" "$APP"; exit 1
      fi
      mv "$TMP" "$PREV"
    fi
    echo "[helfer] getauscht, starte"
    if [ "$BIN" = "-" ]; then /usr/bin/open "$APP"; else "$BIN" & fi
    exit 0
    """

    /// Helfer starten (läuft weiter, wenn diese App beendet ist); false, wenn er nicht startet
    static func spawnHelper(mode: String, app: URL, source: URL, log: URL, direct: Bool) -> Bool {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("minos-helfer-\(UUID().uuidString).sh")
        do { try helperScript.write(to: script, atomically: true, encoding: .utf8) } catch { return false }
        let bin = direct ? app.appendingPathComponent("Contents/MacOS/MINOS-741").path : "-"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path, "\(ProcessInfo.processInfo.processIdentifier)", app.path, source.path, log.path, mode, bin]
        do { try p.run() } catch { return false }
        return true
    }
}

/// Einstellungen -> ANZEIGE -> Updates: Kanal, Ordner, Automatik, Stand
struct UpdateSettingsSection: View {
    @Environment(MixModel.self) private var mix

    private var up: Updater { Updater.shared }

    private var folderText: String {
        let p = mix.prefs.ui.updateFolder
        return p.isEmpty ? String(localized: "aus") : (p as NSString).abbreviatingWithTildeInPath
    }

    private var status: String {
        if up.channel == .off { return String(localized: "Aus: keine Updates") }
        if up.checking { return String(localized: "Prüfe …") }
        if let e = up.lastError { return e }
        if let c = up.candidate {
            let text = String(format: String(localized: "Neuere Version: %@ (%@)"), c.manifest.version, c.manifest.build)
            return UpdateRules.autoSkipped(build: c.manifest.build, skipBuild: mix.prefs.ui.updateSkipBuild)
                ? text + " · " + String(localized: "nicht automatisch (nach Zurückwechseln)") : text
        }
        if let d = up.lastChecked {
            return String(format: String(localized: "Aktuell: %@ (%@) · geprüft %@"), up.currentVersion, up.currentBuild,
                          d.formatted(date: .omitted, time: .shortened))
        }
        return String(localized: "Noch nicht geprüft")
    }

    var body: some View {
        @Bindable var mix = mix
        Picker("Update-Kanal", selection: $mix.prefs.ui.updateChannel) {
            ForEach(UpdateChannel.allCases) { Text(verbatim: $0.title).tag($0) }
        }
        .settingsAnchor("display.update.channel")
        .onChange(of: mix.prefs.ui.updateChannel) { Updater.shared.channelChanged() }
        HStack {
            Text("Ordner")
            Spacer()
            Text(verbatim: folderText).font(Theme.mono(10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Button("Ordner wählen …") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.canCreateDirectories = true
                panel.message = String(localized: "Ordner mit latest.json und den DMGs (scripts/make-dmg.sh --publish)")
                if panel.runModal() == .OK, let u = panel.url {
                    mix.prefs.ui.updateFolder = u.path
                    mix.prefs.ui.updateChannel = .folder
                    Updater.shared.channelChanged()
                }
            }
            .disabled(up.channel != .folder)
            if !mix.prefs.ui.updateFolder.isEmpty {
                Button("Aus") {
                    mix.prefs.ui.updateFolder = ""
                    Updater.shared.channelChanged()
                }
            }
        }
        .settingsAnchor("display.update.folder")
        Toggle("Updates automatisch installieren", isOn: $mix.prefs.ui.autoUpdate)
            .disabled(up.channel == .off)
            .settingsAnchor("display.update.auto")
        HStack {
            Text(verbatim: status).font(Theme.mono(11)).foregroundStyle(.secondary).lineLimit(2)
            Spacer()
            if up.candidate != nil, !up.installing {
                Button("Installieren") { up.install() }
            }
            if up.hasPrevious, !up.installing {
                Button("Vorherige Version wiederherstellen") { up.rollback() }
            }
            Button("Jetzt prüfen") { up.check() }
                .disabled(up.channel == .off || up.checking)
        }
        .settingsAnchor("display.update.check")
        Text("Ohne Automatik meldet MINOS-741 ein Update in der Statusleiste. Die Installation startet nur, wenn kein Deck spielt und LIVE aus ist; die App wird dafür beendet und neu gestartet.")
            .settingsHint()
    }
}
