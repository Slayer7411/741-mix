import AudioToolbox
import Foundation

/// Herkunft eines Plugins
public enum PluginSource: String, Codable, Sendable {
    /// /Library/Audio/Plug-Ins/Components (VST3: …/VST3) und die eingebauten von Apple
    case system
    /// ~/Library/Audio/Plug-Ins/Components (VST3: …/VST3)
    case user
    /// eigener Ordner – nur in MINOS-741 registriert
    case folder
    /// AUv3 aus einer App (Systemregister)
    case appExtension
}

public enum PluginFormat: String, Codable, Sendable { case auv2 = "AUv2", auv3 = "AUv3", vst3 = "VST3" }

/// Eintrag der Plugin-Liste (Einstellungen → PLUGINS)
public struct PluginEntry: Identifiable, Hashable, Sendable {
    /// AU: "aufx:mrev:appl" · VST3: "vst3:<Klassen-ID>" · nicht ladbares Bundle: "bundle:<pfad>"
    public let id: String
    public let name: String
    public let manufacturer: String
    public let version: String
    public let format: PluginFormat
    public let source: PluginSource
    public let path: String?
    /// nil = nicht ladbar (Fehler beim Laden eines Bundles, blockiert)
    public let info: PluginInfo?
    /// Grund, warum ein Bundle aus einem eigenen Ordner nicht ladbar ist
    public let problem: String?

    public var validationKey: String { "\(id)@\(version)" }
    /// AU: auval findet nur installierte (System-Register), nicht die in MINOS-741 registrierten. VST3: Selbsttest
    public var canValidate: Bool { info != nil && (format == .vst3 || source != .folder) }
    /// isoliert laden geht nur für Audio Units im System-Register (Apples Dienst kennt kein VST3)
    public var canIsolate: Bool { info != nil && source != .folder && format != .vst3 }
}

/// ein Eintrag aus dem Feld `AudioComponents` der Info.plist eines .component-Bundles
public struct ComponentDescriptor: Equatable, Sendable {
    public let type: UInt32, subtype: UInt32, manufacturer: UInt32
    public let name: String
    public let version: UInt32
    public let factoryFunction: String
    public var id: String { PluginHost.id(type, subtype, manufacturer) }
    public var isEffect: Bool { type == kAudioUnitType_Effect || type == kAudioUnitType_MusicEffect }
}

/// .component- und .vst3-Bundles auf der Platte (ohne sie zu laden)
public enum PluginBundle {
    /// AudioComponents aus Contents/Info.plist; unvollständige Einträge fallen weg
    public static func components(_ bundle: URL) -> [ComponentDescriptor] {
        guard let plist = infoPlist(bundle), let list = plist["AudioComponents"] as? [[String: Any]] else { return [] }
        return list.compactMap { d in
            guard let t = (d["type"] as? String).flatMap(PluginHost.code), let s = (d["subtype"] as? String).flatMap(PluginHost.code),
                  let m = (d["manufacturer"] as? String).flatMap(PluginHost.code),
                  let f = d["factoryFunction"] as? String, !f.isEmpty else { return nil }
            let name = d["name"] as? String ?? bundle.deletingPathExtension().lastPathComponent
            return ComponentDescriptor(type: t, subtype: s, manufacturer: m, name: name, version: number(d["version"]) ?? 0,
                                       factoryFunction: f)
        }
    }

    /// Name, Hersteller, Version eines VST3-Bundles (Info.plist, sonst moduleinfo.json, sonst Dateiname)
    public static func vst3Info(_ bundle: URL) -> (name: String, vendor: String, version: String) {
        let plist = infoPlist(bundle)
        var name = plist?["CFBundleName"] as? String ?? bundle.deletingPathExtension().lastPathComponent
        var vendor = "", version = plist?["CFBundleShortVersionString"] as? String ?? plist?["CFBundleVersion"] as? String ?? ""
        let mi = bundle.appendingPathComponent("Contents/Resources/moduleinfo.json")
        if let d = try? Data(contentsOf: mi), let j = try? JSONSerialization.jsonObject(with: d, options: [.json5Allowed]) as? [String: Any] {
            if let n = j["Name"] as? String, !n.isEmpty { name = n }
            if version.isEmpty, let v = j["Version"] as? String { version = v }
            if let f = j["Factory Info"] as? [String: Any], let v = f["Vendor"] as? String { vendor = v }
        }
        return (name, vendor, version)
    }

    /// Bundle-Version (CFBundleShortVersionString, sonst CFBundleVersion, sonst die erste AudioComponents-Version)
    public static func version(_ bundle: URL) -> String {
        let plist = infoPlist(bundle)
        if let v = plist?["CFBundleShortVersionString"] as? String, !v.isEmpty { return v }
        if let v = plist?["CFBundleVersion"] as? String, !v.isEmpty { return v }
        return components(bundle).first.map { PluginHost.versionString($0.version) } ?? ""
    }

    /// Effekt-Klassen aus Contents/Resources/moduleinfo.json (VST 3.7+, ohne den Code zu laden); nil = keine Datei
    /// oder keine Klassenliste
    public static func vst3Classes(_ bundle: URL) -> [PluginInfo]? {
        let mi = bundle.appendingPathComponent("Contents/Resources/moduleinfo.json")
        guard let d = try? Data(contentsOf: mi),
              let j = try? JSONSerialization.jsonObject(with: d, options: [.json5Allowed]) as? [String: Any],
              let classes = j["Classes"] as? [[String: Any]] else { return nil }
        let vendor = (j["Factory Info"] as? [String: Any])?["Vendor"] as? String ?? ""
        return classes.compactMap { c in
            let subs = c["Sub Categories"] as? [String] ?? []
            guard c["Category"] as? String == "Audio Module Class", subs.contains("Fx"), !subs.contains("Instrument"),
                  let cid = c["CID"] as? String, cid.count == 32, let name = c["Name"] as? String else { return nil }
            let v = c["Vendor"] as? String ?? ""
            return PluginInfo.vst3(classID: cid, name: name, vendor: v.isEmpty ? vendor : v, version: c["Version"] as? String ?? "",
                                   path: bundle.path)
        }
    }

    /// .component und .vst3 unter `folder` (rekursiv bis `depth`, nie in ein Bundle hinein)
    public static func scan(_ folder: URL, depth: Int = 4) -> (components: [URL], vst3: [URL]) {
        var comps: [URL] = [], vst3: [URL] = []
        func walk(_ dir: URL, _ level: Int) {
            // Pfade so, wie der Ordner angegeben ist (kein Auflösen von /var → /private/var)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
            for name in names.sorted() where !name.hasPrefix(".") {
                let u = dir.appendingPathComponent(name)
                switch u.pathExtension.lowercased() {
                case "component": comps.append(u)
                case "vst3": vst3.append(u)
                default:
                    let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    if isDir, level < depth, !["app", "bundle", "framework", "vst", "aaxplugin"].contains(u.pathExtension.lowercased()) {
                        walk(u, level + 1)
                    }
                }
            }
        }
        walk(folder, 0)
        return (comps, vst3)
    }

    static func infoPlist(_ bundle: URL) -> [String: Any]? {
        guard let d = try? Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: d, options: [], format: nil)) as? [String: Any]
    }

    /// Zahl aus der Plist: Integer, "67072" oder "0x10600"
    static func number(_ v: Any?) -> UInt32? {
        if let n = v as? NSNumber { return n.uint32Value }
        guard let s = (v as? String)?.trimmingCharacters(in: .whitespaces) else { return nil }
        if s.lowercased().hasPrefix("0x") { return UInt32(s.dropFirst(2), radix: 16) }
        return UInt32(s)
    }
}

/// Ergebnis von auval für ein Plugin in einer Version
public struct PluginValidation: Codable, Equatable, Sendable {
    public var passed: Bool
    public var date: Date
    /// letzte Zeilen der Ausgabe
    public var log: String
    public init(passed: Bool, date: Date = Date(), log: String) { self.passed = passed; self.date = date; self.log = log }
}

/// gespeicherte Plugin-Einstellungen (plugins.json)
public struct PluginSettings: Codable, Equatable, Sendable {
    /// für MINOS-741 abgeschaltete Plugins (stehen nicht im FX-Menü)
    public var disabled: Set<String> = []
    /// Plugins anderer Hersteller isoliert laden (Standard an); Apple immer im Prozess
    public var isolateThirdParty = true
    /// Einstellung je Plugin (fehlt = Standard)
    public var isolation: [String: Bool] = [:]
    /// eigene Plugin-Ordner
    public var folders: [String] = []
    /// gesperrt nach einem Absturz: Schlüssel (Plugin-ID oder "bundle:<pfad>") → Grund
    public var blocked: [String: String] = [:]
    /// auval-Ergebnisse je "id@version"
    public var validation: [String: PluginValidation] = [:]

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        disabled = try c.decodeIfPresent(Set<String>.self, forKey: .disabled) ?? []
        isolateThirdParty = try c.decodeIfPresent(Bool.self, forKey: .isolateThirdParty) ?? true
        isolation = try c.decodeIfPresent([String: Bool].self, forKey: .isolation) ?? [:]
        folders = try c.decodeIfPresent([String].self, forKey: .folders) ?? []
        blocked = try c.decodeIfPresent([String: String].self, forKey: .blocked) ?? [:]
        validation = try c.decodeIfPresent([String: PluginValidation].self, forKey: .validation) ?? [:]
    }
}

/// Plugin-Verwaltung: Liste (System-Register + eigene Ordner + VST3), Einstellungen, Absturz-Markierung.
/// Thread-sicher; Einlesen und Registrieren auf dem aufrufenden Thread (nie auf dem Audio-Thread).
public final class PluginCatalog: @unchecked Sendable {
    public static let home = FileManager.default.homeDirectoryForCurrentUser
    /// Standard-Ordner der Audio Units (immer eingelesen; AUv3 kommen über das System-Register)
    public static let defaultFolders: [(URL, PluginSource)] = [
        (URL(fileURLWithPath: "/Library/Audio/Plug-Ins/Components"), .system),
        (home.appendingPathComponent("Library/Audio/Plug-Ins/Components"), .user),
    ]
    public static let defaultVST3Folders = [URL(fileURLWithPath: "/Library/Audio/Plug-Ins/VST3"),
                                            home.appendingPathComponent("Library/Audio/Plug-Ins/VST3")]
    static let markerName = "plugin-opening.json"

    /// Ablage (plugins.json, Absturz-Markierung); nil = nur im Speicher
    public let directory: URL?
    /// nichts schreiben (Selbsttest)
    public let readOnly: Bool
    public let folders: [(URL, PluginSource)]
    public let vst3Folders: [URL]
    /// beim Start gefundene Markierung: dieses Plugin war beim Öffnen, als MINOS-741 zuletzt beendet wurde → blockiert
    public private(set) var crashedLastRun: (key: String, name: String)?

    private let lock = NSLock()
    private var _settings: PluginSettings
    private var _entries: [PluginEntry]?

    public init(directory: URL?, readOnly: Bool = false, folders: [(URL, PluginSource)] = PluginCatalog.defaultFolders,
                vst3Folders: [URL] = PluginCatalog.defaultVST3Folders) {
        self.directory = directory
        self.readOnly = readOnly
        self.folders = folders
        self.vst3Folders = vst3Folders
        var s = PluginSettings()
        if let u = directory?.appendingPathComponent("plugins.json"), let d = try? Data(contentsOf: u),
           let decoded = try? JSONDecoder().decode(PluginSettings.self, from: d) { s = decoded }
        _settings = s
        checkCrashMarker()
    }

    // MARK: Einstellungen

    public var settings: PluginSettings { lock.withLock { _settings } }

    public func update(_ f: (inout PluginSettings) -> Void) {
        let s: PluginSettings = lock.withLock { f(&_settings); return _settings }
        save(s)
    }

    private func save(_ s: PluginSettings) {
        guard !readOnly, let dir = directory else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        if let d = try? enc.encode(s) { try? d.write(to: dir.appendingPathComponent("plugins.json"), options: .atomic) }
    }

    public func setEnabled(_ id: String, _ on: Bool) { update { if on { $0.disabled.remove(id) } else { $0.disabled.insert(id) } } }
    public func isEnabled(_ id: String) -> Bool { !settings.disabled.contains(id) }
    public func block(_ key: String, reason: String) { update { $0.blocked[key] = reason } }
    public func unblock(_ key: String) { update { $0.blocked[key] = nil } }
    public func blockReason(_ key: String) -> String? { settings.blocked[key] }

    /// im FX-Menü wählbar und ladbar? nil = ja, sonst der Grund
    public func unusableReason(_ id: String) -> String? {
        let s = settings
        if let r = s.blocked[id] { return String(format: String(localized: "blockiert: %@"), r) }
        if s.disabled.contains(id) { return String(localized: "in den Einstellungen abgeschaltet") }
        return nil
    }

    /// isoliert laden? Apple im Prozess, andere nach Einstellung; Plugins aus eigenen Ordnern immer im Prozess
    public func isolated(_ id: String) -> Bool {
        let s = settings
        guard let e = entries().first(where: { $0.id == id }), e.canIsolate, let info = e.info else { return false }
        return s.isolation[id] ?? (!info.isApple && s.isolateThirdParty)
    }

    public func setIsolation(_ id: String, _ on: Bool?) { update { $0.isolation[id] = on } }

    public func validation(_ e: PluginEntry) -> PluginValidation? { settings.validation[e.validationKey] }
    public func storeValidation(_ e: PluginEntry, _ v: PluginValidation) { update { $0.validation[e.validationKey] = v } }

    // MARK: Absturz-Markierung
    // vor dem Öffnen (oder Laden eines Bundles) "öffne X" schreiben, danach löschen. Steht sie beim nächsten Start
    // noch da, ist MINOS-741 dabei abgestürzt → X wird blockiert.

    private struct Marker: Codable { var key: String; var name: String; var date: Date }

    private var markerURL: URL? { directory?.appendingPathComponent(Self.markerName) }

    public func beginOpen(key: String, name: String) {
        guard !readOnly, let u = markerURL, let dir = directory else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(Marker(key: key, name: name, date: Date())) { try? d.write(to: u, options: .atomic) }
    }

    public func endOpen() {
        guard !readOnly, let u = markerURL else { return }
        try? FileManager.default.removeItem(at: u)
    }

    private func checkCrashMarker() {
        guard !readOnly, let u = markerURL, let d = try? Data(contentsOf: u) else { return }
        try? FileManager.default.removeItem(at: u)
        guard let m = try? JSONDecoder().decode(Marker.self, from: d) else { return }
        let when = DateFormatter.localizedString(from: m.date, dateStyle: .short, timeStyle: .short)
        crashedLastRun = (m.key, m.name)
        _settings.blocked[m.key] = String(format: String(localized: "abgestürzt beim Öffnen (%@)"), when)
        save(_settings)
    }

    // MARK: Liste

    /// alle Einträge (einmal eingelesen, `refresh` liest neu)
    public func entries(refresh: Bool = false) -> [PluginEntry] {
        if !refresh, let e = lock.withLock({ _entries }) { return e }
        let e = scan()
        lock.withLock { _entries = e }
        return e
    }

    /// für das FX-Menü: ladbar, eingeschaltet, nicht blockiert
    public func menuList(refresh: Bool = false) -> [PluginInfo] {
        let s = settings
        return entries(refresh: refresh).compactMap { e in
            guard let i = e.info, !s.disabled.contains(e.id), s.blocked[e.id] == nil else { return nil }
            return i
        }
    }

    /// PluginInfo zu einer ID (auch abgeschaltete)
    public func info(_ id: String) -> PluginInfo? { entries().first { $0.id == id }?.info }

    private func scan() -> [PluginEntry] {
        let s = settings
        var out: [PluginEntry] = []
        // 1. eigene Ordner: Bundles registrieren (einmal je Prozess)
        var own: [String: String] = [:]   // Plugin-ID → Bundle-Pfad
        var vst3 = vst3Folders.flatMap { PluginBundle.scan($0).vst3 }
        for f in s.folders {
            let found = PluginBundle.scan(URL(fileURLWithPath: f))
            vst3 += found.vst3
            for b in found.components {
                let key = "bundle:" + b.path
                let r: PluginRegistry.Result
                if s.blocked[key] != nil {
                    r = .init(ids: [], error: nil)
                } else {
                    r = PluginRegistry.register(b, before: { self.beginOpen(key: key, name: b.lastPathComponent) },
                                                after: { self.endOpen() })
                }
                if s.blocked[key] != nil || r.error != nil {
                    out.append(PluginEntry(id: key, name: b.deletingPathExtension().lastPathComponent, manufacturer: "",
                                           version: PluginBundle.version(b), format: .auv2, source: .folder, path: b.path,
                                           info: nil, problem: r.error))
                }
                for id in r.ids where own[id] == nil { own[id] = b.path }
            }
        }
        // 2. Standard-Ordner: welche ID liegt in welchem Bundle
        var where_: [String: (String, PluginSource)] = [:]
        for (dir, src) in folders {
            for b in PluginBundle.scan(dir, depth: 1).components {
                for c in PluginBundle.components(b) where where_[c.id] == nil { where_[c.id] = (b.path, src) }
            }
        }
        // 3. System-Register (enthält die eben registrierten)
        let registeredElsewhere = PluginRegistry.registeredIDs()
        for i in PluginHost.installed() {
            let src: PluginSource, path: String?
            if let p = own[i.id] {
                src = .folder; path = p
            } else if let w = where_[i.id] {
                src = w.1; path = w.0
            } else if registeredElsewhere.contains(i.id) {
                continue   // aus einem inzwischen entfernten Ordner (bleibt bis zum Neustart registriert)
            } else {
                src = i.isV3 ? .appExtension : .system; path = nil
            }
            out.append(PluginEntry(id: i.id, name: i.name, manufacturer: i.manufacturer, version: i.versionString,
                                   format: i.isV3 ? .auv3 : .auv2, source: src, path: path, info: i, problem: nil))
        }
        // 4. VST3: Effekt-Klassen je Bundle – aus moduleinfo.json, sonst Bundle laden (Absturz-Markierung "bundle:<pfad>")
        var seen = Set<String>(), seenIDs = Set<String>()
        for b in vst3 where seen.insert(b.standardizedFileURL.path).inserted {
            let v = PluginBundle.vst3Info(b)
            let src: PluginSource = b.path.hasPrefix(Self.home.path + "/Library/Audio") ? .user
                : (b.path.hasPrefix("/Library/Audio") ? .system : .folder)
            let key = "bundle:" + b.path
            var classes: [PluginInfo] = [], problem: String?
            if s.blocked[key] == nil {
                if let c = PluginBundle.vst3Classes(b) {
                    classes = c
                } else {
                    beginOpen(key: key, name: b.lastPathComponent)
                    let r = PluginHost.vst3Classes(b)
                    endOpen()
                    classes = r.classes
                    problem = r.error.map { String(format: String(localized: "Code nicht ladbar: %@"), $0) }
                }
                if classes.isEmpty && problem == nil { problem = String(localized: "keine Effekt-Klasse (Fx) im Bundle") }
            }
            let fresh = classes.filter { seenIDs.insert($0.id).inserted }
            if fresh.isEmpty {
                if !classes.isEmpty { continue }   // dieselben Klassen liegen schon in einem anderen Ordner
                out.append(PluginEntry(id: key, name: v.name, manufacturer: v.vendor, version: v.version, format: .vst3,
                                       source: src, path: b.path, info: nil, problem: problem))
            }
            for c in fresh {
                out.append(PluginEntry(id: c.id, name: c.name, manufacturer: c.manufacturer, version: c.versionString, format: .vst3,
                                       source: src, path: b.path, info: c, problem: nil))
            }
        }
        return out.sorted { ($0.manufacturer.lowercased(), $0.name.lowercased()) < ($1.manufacturer.lowercased(), $1.name.lowercased()) }
    }
}

/// Bundles aus eigenen Ordnern im Prozess registrieren (AudioComponentRegister). Gilt für den ganzen Prozess und lässt
/// sich nicht zurücknehmen – darum je Bundle-Pfad genau einmal.
public enum PluginRegistry {
    public struct Result: Sendable { public var ids: [String]; public var error: String? }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var done: [String: Result] = [:]
    /// geladene Bundles bleiben geladen (die Fabrik-Funktionen liegen darin)
    nonisolated(unsafe) private static var bundles: [CFBundle] = []

    /// alle in diesem Prozess registrierten IDs
    public static func registeredIDs() -> Set<String> { lock.withLock { Set(done.values.flatMap(\.ids)) } }

    /// Effekte eines .component-Bundles registrieren. `before`/`after` umschließen das Laden des Codes (Absturz-Markierung).
    /// Schon im System vorhandene IDs werden nicht doppelt registriert (nimmt dann die installierte).
    public static func register(_ bundle: URL, before: () -> Void = {}, after: () -> Void = {}) -> Result {
        let path = bundle.standardizedFileURL.path
        lock.lock(); defer { lock.unlock() }
        if let r = done[path] { return r }
        let r = load(bundle, before: before, after: after)
        done[path] = r
        return r
    }

    private static func load(_ bundle: URL, before: () -> Void, after: () -> Void) -> Result {
        let all = PluginBundle.components(bundle)
        guard !all.isEmpty else { return Result(ids: [], error: String(localized: "kein AudioComponents-Eintrag in der Info.plist")) }
        let fx = all.filter(\.isEffect)
        guard !fx.isEmpty else { return Result(ids: [], error: String(localized: "kein Effekt-Plugin (aufx/aumf)")) }
        let fresh = fx.filter { c in
            var d = AudioComponentDescription(componentType: c.type, componentSubType: c.subtype, componentManufacturer: c.manufacturer,
                                              componentFlags: 0, componentFlagsMask: 0)
            return AudioComponentFindNext(nil, &d) == nil
        }
        if fresh.isEmpty { return Result(ids: [], error: nil) }   // schon installiert
        guard let cf = CFBundleCreate(kCFAllocatorDefault, bundle as CFURL) else {
            return Result(ids: [], error: String(localized: "Bundle nicht lesbar"))
        }
        var e: Unmanaged<CFError>?
        before()
        let ok = CFBundleLoadExecutableAndReturnError(cf, &e)
        after()
        guard ok else {
            let why = e.map { CFErrorCopyDescription($0.takeRetainedValue()) as String } ?? "?"
            return Result(ids: [], error: String(format: String(localized: "Code nicht ladbar: %@"), why))
        }
        bundles.append(cf)
        var ids: [String] = [], missing: [String] = []
        for c in fresh {
            guard let fp = CFBundleGetFunctionPointerForName(cf, c.factoryFunction as CFString) else { missing.append(c.factoryFunction); continue }
            let factory = unsafeBitCast(fp, to: AudioComponentFactoryFunction.self)
            var d = AudioComponentDescription(componentType: c.type, componentSubType: c.subtype, componentManufacturer: c.manufacturer,
                                              componentFlags: 0, componentFlagsMask: 0)
            _ = AudioComponentRegister(&d, c.name as CFString, c.version, factory)
            ids.append(c.id)
        }
        let err = ids.isEmpty ? String(format: String(localized: "Fabrik-Funktion fehlt: %@"), missing.joined(separator: ", ")) : nil
        return Result(ids: ids, error: err)
    }
}
