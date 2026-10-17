import AppKit
import Foundation
import MixCore
import UniformTypeIdentifiers

/// Einstellungen als Datei exportieren und importieren. Gleiches Format wie `settings.plist` im Datenordner
/// (Property List, alle Schlüssel der Domäne). Beim Übernehmen bleiben Audio-Gerät, Zwei-Mac-Modus, Collection-Ordner
/// und Ordner der Absturzberichte auf diesem Mac (`SettingsFile.localKeys`, `localPrefs`)
enum SettingsTransfer {
    enum Failure: Error, Equatable {
        /// Datei ist keine Einstellungsdatei von MINOS-741
        case notSettings
    }

    /// Inhalt der Datei aus den Werten der Domäne (ohne den Import-Stempel)
    static func data(from domain: [String: Any]) throws -> Data {
        let out = domain.filter { $0.key != SettingsFile.stampKey }
        return try PropertyListSerialization.data(fromPropertyList: out, format: .binary, options: 0)
    }

    /// Werte einer Einstellungsdatei; nur gültig, wenn die Oberflächen-Einstellungen (`prefs.v1`) darin stehen
    static func dictionary(from data: Data) throws -> [String: Any] {
        guard let d = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              d[AppPrefs.key] is Data else { throw Failure.notSettings }
        return d
    }

    /// Übernehmen wie beim Start (`SettingsFile.importIfChanged`): geteilte Werte setzen, eigene Werte aus `localPrefs`
    /// bleiben. Gibt die Zahl der übernommenen Schlüssel zurück
    @discardableResult
    static func apply(_ dict: [String: Any], to d: UserDefaults) -> Int {
        var n = 0
        for (k, v) in dict where SettingsFile.shared(k) {
            if k == AppPrefs.key, let p = v as? Data {
                d.set(SettingsFile.keepingLocal(p, local: d.data(forKey: k)), forKey: k)
            } else {
                d.set(v, forKey: k)
            }
            n += 1
        }
        return n
    }

    /// Domäne `domain` (Standard: die Einstellungen dieses Programms) in die Datei schreiben, atomar
    static func export(to url: URL, defaults d: UserDefaults = E2E.defaults, domain: String? = nil) throws {
        let name = domain ?? (E2E.isActive ? E2E.suite : Bundle.main.bundleIdentifier) ?? ""
        let values = d.persistentDomain(forName: name) ?? [:]
        try data(from: values).write(to: url, options: .atomic)
    }

    /// Datei lesen und übernehmen; gibt die Zahl der übernommenen Schlüssel zurück
    @discardableResult
    static func importFile(_ url: URL, defaults d: UserDefaults = E2E.defaults) throws -> Int {
        apply(try dictionary(from: Data(contentsOf: url)), to: d)
    }

    static let fileName = "MINOS-741-Einstellungen.plist"

    /// Dialog: Datei wählen und schreiben
    @MainActor
    static func exportAsking() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName
        panel.allowedContentTypes = [.propertyList]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try export(to: url)
            StatusCenter.post(.ok, String(localized: "Einstellungen exportiert"), detail: url.lastPathComponent, key: "settings.transfer")
        } catch {
            StatusCenter.post(.error, String(localized: "Einstellungen nicht exportiert"), detail: error.localizedDescription, key: "settings.transfer")
        }
    }

    /// Dialog: Datei wählen, Rückfrage, übernehmen. Danach gilt das Neue sofort, soweit es ohne Neustart geht
    @MainActor
    static func importAsking(mix: MixModel) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.propertyList]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let dict: [String: Any]
        do {
            dict = try dictionary(from: Data(contentsOf: url))
        } catch {
            StatusCenter.post(.error, String(localized: "Keine Einstellungsdatei von MINOS-741"), detail: url.lastPathComponent, key: "settings.transfer")
            return
        }
        let a = NSAlert()
        a.messageText = String(localized: "Einstellungen aus der Datei übernehmen?")
        a.informativeText = String(localized: "Die Einstellungen der Datei ersetzen die jetzigen. Audio-Gerät, Zwei-Mac-Modus, Collection-Ordner und Ordner der Absturzberichte bleiben auf diesem Mac.")
        a.addButton(withTitle: String(localized: "Übernehmen"))
        a.addButton(withTitle: String(localized: "Abbrechen"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let n = apply(dict, to: E2E.defaults)
        mix.prefs = AppPrefs.load()   // wirkt sofort: Oberfläche, Engine, Tasten
        StatusCenter.post(.ok, String(localized: "Einstellungen übernommen"), detail: String(localized: "\(n) Werte"), key: "settings.transfer")
    }
}
