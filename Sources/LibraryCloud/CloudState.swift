import Foundation

/// Lage einer Track-Datei in einem Cloud-Ordner (File Provider, z. B. Google Drive)
public enum CloudState: UInt8, Sendable, Hashable, CaseIterable {
    /// noch nicht geprüft oder Prüfung über der Zeitgrenze
    case unknown
    /// Inhalt liegt auf der Platte
    case local
    /// nur online: Platzhalter ohne Inhalt („dataless“)
    case cloud
    /// Datei fehlt
    case missing
}

/// Ergebnis einer Prüfung: Zustand und Dateigröße (Bytes, auch für Platzhalter bekannt)
public struct FileProbe: Sendable, Hashable {
    public var state: CloudState
    public var size: Int64

    public init(_ state: CloudState, size: Int64 = 0) {
        self.state = state
        self.size = size
    }
}

/// stat-Ergebnis -> Zustand. Einziges Merkmal: SF_DATALESS in st_flags (sofort gültig, ohne Anbieter-Abfrage).
/// URL-Schlüssel (ubiquitousItemDownloadingStatus) gehen per XPC an den Anbieter (~1 ms je Datei) und hinken
/// nach einem Download Sekunden hinterher.
public enum CloudClassifier {
    /// SF_DATALESS (sys/stat.h)
    public static let datalessFlag: UInt32 = 0x4000_0000

    /// `err` = errno von stat (0 = ok), `mode` = st_mode
    public static func classify(err: Int32, flags: UInt32, mode: UInt16) -> CloudState {
        if err != 0 { return err == ENOENT || err == ENOTDIR ? .missing : .unknown }
        guard mode & S_IFMT == S_IFREG else { return .missing }
        return flags & datalessFlag != 0 ? .cloud : .local
    }
}

/// Pfade in Cloud-Ordnern erkennen und gruppieren
public enum CloudPaths {
    /// liegt im Ordner eines Dateianbieters (~/Library/CloudStorage/…, iCloud Drive)
    public static func isCloudBacked(_ path: String) -> Bool {
        path.contains("/Library/CloudStorage/") || path.contains("/Library/Mobile Documents/")
    }

    /// Wurzel des Anbieters, z. B. `/Users/x/Library/CloudStorage/GoogleDrive-a@b.c`
    public static func providerRoot(_ path: String) -> String? {
        for marker in ["/Library/CloudStorage/", "/Library/Mobile Documents/"] {
            guard let r = path.range(of: marker) else { continue }
            let rest = path[r.upperBound...]
            let name = rest.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
            guard !name.isEmpty else { return nil }
            return String(path[..<r.upperBound]) + name
        }
        return nil
    }

    /// lesbarer Name des Anbieters: `GoogleDrive-a@b.c` -> `Google Drive`
    public static func providerName(_ root: String) -> String {
        let name = (root as NSString).lastPathComponent
        if name.hasPrefix("GoogleDrive") { return "Google Drive" }
        if name.hasPrefix("OneDrive") { return "OneDrive" }
        if name.hasPrefix("Dropbox") { return "Dropbox" }
        if root.contains("/Library/Mobile Documents") || name.hasPrefix("iCloud") { return "iCloud Drive" }
        return name.split(separator: "-").first.map(String.init) ?? name
    }

    /// tiefster gemeinsamer Ordner aller Pfade (nil bei leerer Liste)
    public static func commonFolder(_ paths: [String]) -> String? {
        guard var common = paths.first.map({ ($0 as NSString).deletingLastPathComponent.split(separator: "/", omittingEmptySubsequences: true) })
        else { return nil }
        for p in paths.dropFirst() {
            let parts = (p as NSString).deletingLastPathComponent.split(separator: "/", omittingEmptySubsequences: true)
            var n = 0
            while n < common.count, n < parts.count, common[n] == parts[n] { n += 1 }
            common = Array(common.prefix(n))
            if common.isEmpty { break }
        }
        return "/" + common.joined(separator: "/")
    }

    /// Library-Ordner: tiefster Ordner, der mindestens `share` der Cloud-Pfade enthält (Ausreißer wie
    /// Papierkorb oder Temp-Ordner des Anbieters zählen nicht)
    public static func libraryFolder(_ paths: [String], share: Double = 0.9) -> String? {
        let cloud = paths.filter(isCloudBacked)
        guard !cloud.isEmpty else { return nil }
        var counts: [String: Int] = [:]
        for p in cloud {
            var dir = (p as NSString).deletingLastPathComponent
            while dir.count > 1 {
                counts[dir, default: 0] += 1
                dir = (dir as NSString).deletingLastPathComponent
            }
        }
        let need = Int((Double(cloud.count) * share).rounded(.up))
        return counts.filter { $0.value >= need }.max { $0.key.count < $1.key.count }?.key
    }

    /// zu beobachtende Ordner: je Anbieter der gemeinsame Ordner seiner Pfade (ohne versteckte Ordner wie
    /// `.Trash` / `.tmp` des Anbieters – sonst wäre es der ganze Anbieter)
    public static func watchRoots(_ paths: [String]) -> [String] {
        var groups: [String: [String]] = [:]
        for p in paths where isCloudBacked(p) && !p.contains("/.") {
            if let root = providerRoot(p) { groups[root, default: []].append(p) }
        }
        return groups.values.compactMap(commonFolder).sorted()
    }
}
