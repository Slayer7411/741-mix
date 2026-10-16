import Foundation

/// Daten einer Session im Ordner `MINOS-741` neben der Collection-Datei: Einstellungen (`settings.plist`), Analysen,
/// Edits, Cuts, Playlists, History, Preparation, Sitzung. Zieht mit der Collection um – dieselbe Collection samt Ordner
/// ergibt auf jedem Mac dieselbe Session. Zwischenspeicher und Rechner-Gebundenes bleiben in Application Support.
enum DataDir {
    static let local = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MINOS-741")
    /// bleibt lokal: Wellenform-Cache, Vorschauen, Lasttests, Plugin-Liste (Pfade dieses Macs)
    static let localOnly: Set<String> = ["cache", "overviews", "loadtest", "plugins.json", ".DS_Store"]
    static let name = "MINOS-741"

    /// beim ersten Zugriff festgelegt (Start): Ordner neben der Collection, beim ersten Mal aus Application Support befüllt.
    /// Selbsttest und fehlende/schreibgeschützte Collection-Ordner: Application Support
    static let shared: URL = resolve(collection: LibraryStore.defaultNML, local: local, selfTest: Session.isSelfTest)

    static func resolve(collection: URL, local: URL, selfTest: Bool) -> URL {
        guard !selfTest else { return local }
        let fm = FileManager.default
        let parent = collection.deletingLastPathComponent()
        guard fm.fileExists(atPath: parent.path) else { return local }
        let dir = parent.appendingPathComponent(name, isDirectory: true)
        if fm.fileExists(atPath: dir.path) { return dir }
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for item in (try? fm.contentsOfDirectory(atPath: local.path)) ?? [] where !localOnly.contains(item) {
                try fm.copyItem(at: local.appendingPathComponent(item), to: dir.appendingPathComponent(item))
            }
            return dir
        } catch {
            try? fm.removeItem(at: dir)
            return local
        }
    }
}

/// Einstellungen als Datei im Datenordner (`settings.plist`): beim Start übernommen, wenn sie seit dem letzten Mal
/// geändert wurde (anderer Mac, zurückgespielt), nach dem Speichern und beim Beenden geschrieben. Geräte-gebundene
/// Werte (Audio-Interface, Kanalpaare, Controller-Seriennummern) und die Zwei-Mac-Rolle bleiben auf dem Mac
enum SettingsFile {
    static var url: URL { DataDir.shared.appendingPathComponent("settings.plist") }
    static let stampKey = "settings.imported"
    static let localKeys: Set<String> = ["deviceUID", "sampleRate", "bufferSize", "internalPair", "previewPair", "deckPairs", stampKey]
    static let localPrefixes = ["NS", "Apple", "com_apple", "com.apple", "migrated.", "donate", "x1."]

    static func shared(_ key: String) -> Bool {
        !localKeys.contains(key) && !localPrefixes.contains { key.hasPrefix($0) }
    }

    /// `prefs.v1` aus der Datei mit der eigenen Zwei-Mac-Rolle
    static func keepingRole(_ incoming: Data, local: Data?) -> Data {
        guard var inc = (try? JSONSerialization.jsonObject(with: incoming)) as? [String: Any] else { return incoming }
        var ui = inc["ui"] as? [String: Any] ?? [:]
        let own = local.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }?["ui"] as? [String: Any]
        if let r = own?["pairRole"] { ui["pairRole"] = r } else { ui.removeValue(forKey: "pairRole") }
        inc["ui"] = ui
        return (try? JSONSerialization.data(withJSONObject: inc)) ?? incoming
    }

    static func stamp(_ u: URL) -> String? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: u.path),
              let d = a[.modificationDate] as? Date, let s = a[.size] as? Int else { return nil }
        return "\(Int(d.timeIntervalSince1970 * 1000))-\(s)"
    }

    /// Start, vor dem ersten Lesen der Einstellungen
    static func importIfChanged(_ d: UserDefaults = .standard) {
        guard !Session.isSelfTest, let s = stamp(url), d.string(forKey: stampKey) != s,
              let data = try? Data(contentsOf: url),
              let dict = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return }
        for (k, v) in dict where shared(k) {
            if k == AppPrefs.key, let p = v as? Data { d.set(keepingRole(p, local: d.data(forKey: k)), forKey: k) } else { d.set(v, forKey: k) }
        }
        d.set(s, forKey: stampKey)
    }

    /// alle geteilten Werte in die Datei (atomar)
    static func export(_ d: UserDefaults = .standard) {
        guard !Session.isSelfTest else { return }
        let dict = d.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? d.dictionaryRepresentation()
        let out = dict.filter { shared($0.key) }
        guard !out.isEmpty, let data = try? PropertyListSerialization.data(fromPropertyList: out, format: .xml, options: 0) else { return }
        guard (try? data.write(to: url, options: .atomic)) != nil, let s = stamp(url) else { return }
        d.set(s, forKey: stampKey)
    }

    nonisolated(unsafe) private static var pending: DispatchWorkItem?
    /// nach dem Speichern der Einstellungen: gesammelt nach 2 s
    static func scheduleExport() {
        DispatchQueue.main.async {
            pending?.cancel()
            let w = DispatchWorkItem { export() }
            pending = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: w)
        }
    }
}
