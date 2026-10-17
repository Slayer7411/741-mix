import Foundation
import Network

/// Ende-zu-Ende-Modus: `MIX741_E2E_ROOT=<ordner>` (Tests/E2E/README.md). Eine Instanz benutzt nur Dateien unter diesem
/// Ordner (Collection, Datenordner, Cache), eine eigene UserDefaults-Suite, eine eigene Bonjour-Art und keine Audio-
/// Hardware (Kern rendert auf einen Zwischenpuffer, `CoreAudioOutput`). Ohne die Variable ändert sich nichts.
public enum E2E {
    /// Ordner der Instanz (absolut); nil = normaler Betrieb
    public static let root: URL? = {
        guard let p = ProcessInfo.processInfo.environment["MIX741_E2E_ROOT"], !p.isEmpty else { return nil }
        return URL(fileURLWithPath: p, isDirectory: true)
    }()
    public static var isActive: Bool { root != nil }

    /// Name der Instanz: Rechnername beim Pairing, Teil der Suite; Standard: Ordnername
    public static let name: String = {
        let n = ProcessInfo.processInfo.environment["MIX741_E2E_NAME"] ?? ""
        return n.isEmpty ? (root?.lastPathComponent ?? "E2E") : n
    }()

    /// Bonjour-Art (`_name._tcp`, Name höchstens 15 Zeichen): eigene Art, damit kein echter MINOS-Mac antwortet
    public static let service: String = {
        let s = ProcessInfo.processInfo.environment["MIX741_E2E_SERVICE"] ?? ""
        return s.isEmpty ? "_m741-e2e._tcp" : s
    }()

    /// UserDefaults-Suite dieser Instanz (eigene Datei unter ~/Library/Preferences, nie die Domäne der Hauptapp)
    public static var suite: String {
        let safe = String(name.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" })
        return "com.github.slayer7411.minos741.e2e." + safe
    }

    /// Einstellungen dieser Instanz (ohne Suite: die normalen Standardeinstellungen)
    public nonisolated(unsafe) static let defaults: UserDefaults = {
        guard isActive else { return .standard }
        // nie stillschweigend die Standard-Domäne (Christians Einstellungen) nehmen
        guard let d = UserDefaults(suiteName: suite) else { fatalError("E2E: UserDefaults-Suite \(suite) fehlt") }
        return d
    }()

    /// Application-Support-Ordner (E2E: `<root>/appsupport`)
    public static var applicationSupport: URL {
        root?.appendingPathComponent("appsupport", isDirectory: true)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    /// Caches (E2E: `<root>/caches`)
    public static var caches: URL {
        root?.appendingPathComponent("caches", isDirectory: true)
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    /// Collection-Datei der Instanz (E2E: `<root>/collection/collection.nml`), sonst nil
    public static var collection: URL? { root?.appendingPathComponent("collection/collection.nml") }

    /// Musikordner der Instanz (E2E: `<root>/music`), sonst nil
    public static var music: URL? { root?.appendingPathComponent("music", isDirectory: true) }

    /// Postfach der Steuerung (E2E: `<root>/control/{outbox,inbox}`), sonst nil
    public static var control: URL? { root?.appendingPathComponent("control", isDirectory: true) }

    /// Ordner, den alle Instanzen eines Laufs teilen (Portmeldungen der Verbindung); nil = keiner
    public static var shared: URL? {
        ProcessInfo.processInfo.environment["MIX741_E2E_SHARED"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Ausgabe ohne Gerät: Name und Kennung des Scheingeräts
    public static let nullDeviceName = "E2E (kein Gerät)"
    public static let nullDeviceUID = "e2e-null-output"
}

/// Portmeldungen der Zwei-Mac-Verbindung im Ende-zu-Ende-Lauf: jede Instanz schreibt ihren Listener-Port als
/// `<Name>.port` in den gemeinsamen Ordner (`E2E.shared`), der Partner liest ihn (Verbindung über Loopback).
public enum E2EPeers {
    public static func publish(_ port: UInt16) {
        guard let dir = E2E.shared else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(E2E.name + ".port")
        try? "\(port)".write(to: url, atomically: true, encoding: .utf8)
    }

    public static func port(of name: String) -> NWEndpoint.Port? {
        guard let dir = E2E.shared,
              let text = try? String(contentsOf: dir.appendingPathComponent(name + ".port"), encoding: .utf8),
              let n = UInt16(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return NWEndpoint.Port(rawValue: n)
    }
}
