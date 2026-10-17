import AppKit
import Foundation
import MixCore

/// Adressen aus den Grundfunktionen (GitHub, Instagram, Handbuch im Netz, Fehlermeldung). Geöffnet wird nur über
/// `opener`. Im Selbsttest und im Ende-zu-Ende-Lauf wird die Adresse nur gemerkt (`recorded`), nie im Browser.
/// Tests setzen `opener` selbst (kein Öffnen beim Testen).
@MainActor
enum AppLinks {
    static let github = URL(string: "https://github.com/Slayer7411/MINOS-741")!
    static let instagram = URL(string: "https://instagram.com/minos_741")!
    static let manualOnline = URL(string: "https://github.com/Slayer7411/MINOS-741/blob/main/docs/MANUAL.md")!

    nonisolated(unsafe) static var recorded: [String] = []
    nonisolated(unsafe) static var opener: (URL) -> Void = { url in
        if Session.isSelfTest || E2E.isActive { recorded.append(url.absoluteString) } else { NSWorkspace.shared.open(url) }
    }

    static func open(_ url: URL) { opener(url) }
}

/// Fehlermeldung ohne Absturz: GitHub-Issue mit Version, Build, Codename, macOS und Rechnermodell vorausgefüllt.
/// Keine Angaben zu Person, Rechnername, Pfaden oder Collection.
enum BugReport {
    struct Environment: Equatable {
        var version: String
        var build: String
        var codename: String
        var macOS: String
        var model: String
    }

    /// `issues/new`-Adresse mit Titel und Text (englisch, öffentlich)
    static func url(_ e: Environment) -> URL {
        let title = "Bug report: \(e.version) (\(e.build))"
        let body = """
        <!-- What happened, what you expected, and the steps to reproduce it. -->


        ---
        MINOS-741 \(e.version) · \(e.codename) · build \(e.build)
        macOS \(e.macOS) · \(e.model)
        """
        return URL(string: "\(CrashRedact.issueBase)?title=\(CrashRedact.enc(title))&body=\(CrashRedact.enc(body))")!
    }

    /// Angaben des laufenden Programms; Rechnermodell aus `hw.model` (z. B. „Mac15,7“), sonst „?“
    static func current() -> Environment {
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "dev"
        let build = (info?["CFBundleVersion"] as? String) ?? "dev"
        let codename = (info?["MINOSCodename"] as? String) ?? Codename.forVersion(version) ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return Environment(version: version, build: build, codename: codename,
                           macOS: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)", model: hardwareModel())
    }

    private static func hardwareModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "?" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buf, &size, nil, 0) == 0 else { return "?" }
        return String(cString: buf)
    }
}
