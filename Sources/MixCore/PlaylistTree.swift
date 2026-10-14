import Foundation

/// Eintrag im eigenen Playlist-Baum: Ordner (beliebig tief), Playlist (Track-Schlüssel in Reihenfolge) oder Smartlist
public struct PlaylistItem: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case folder, playlist, smartlist }

    public var id: UUID
    public var name: String
    public var kind: Kind
    /// nur Ordner
    public var children: [PlaylistItem]
    /// nur Playlist: Track-Schlüssel (NML-Schlüssel), Reihenfolge = Playlist-Reihenfolge
    public var tracks: [String]
    /// nur Smartlist
    public var rules: SmartRules

    public init(id: UUID = UUID(), name: String, kind: Kind, children: [PlaylistItem] = [], tracks: [String] = [],
                rules: SmartRules = SmartRules()) {
        self.id = id
        self.name = name
        self.kind = kind
        self.children = children
        self.tracks = tracks
        self.rules = rules
    }

    public static func folder(_ name: String, _ children: [PlaylistItem] = [], id: UUID = UUID()) -> PlaylistItem {
        PlaylistItem(id: id, name: name, kind: .folder, children: children)
    }
    public static func playlist(_ name: String, _ tracks: [String] = [], id: UUID = UUID()) -> PlaylistItem {
        PlaylistItem(id: id, name: name, kind: .playlist, tracks: tracks)
    }
    public static func smartlist(_ name: String, _ rules: SmartRules, id: UUID = UUID()) -> PlaylistItem {
        PlaylistItem(id: id, name: name, kind: .smartlist, rules: rules)
    }

    enum CodingKeys: String, CodingKey { case id, name, kind, children, tracks, rules }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        kind = Kind(rawValue: try c.decodeIfPresent(String.self, forKey: .kind) ?? "") ?? .playlist
        children = try c.decodeIfPresent([PlaylistItem].self, forKey: .children) ?? []
        tracks = try c.decodeIfPresent([String].self, forKey: .tracks) ?? []
        rules = try c.decodeIfPresent(SmartRules.self, forKey: .rules) ?? SmartRules()
    }

    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(kind, forKey: .kind)
        switch kind {
        case .folder: try c.encode(children, forKey: .children)
        case .playlist: try c.encode(tracks, forKey: .tracks)
        case .smartlist: try c.encode(rules, forKey: .rules)
        }
    }

    /// Anzahl Einträge darunter (Ordner: alles, auch verschachtelt)
    public var descendantCount: Int { children.reduce(0) { $0 + 1 + $1.descendantCount } }
}

/// Eigener Playlist-Baum (`playlists.json`): Ordner, Playlists, Smartlists gemischt, dazu eigene Werte für die
/// Regel-Vorschläge. Alle Änderungen als Wertoperationen (Rückgängig = alten Baum zurück).
public struct PlaylistTree: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version = PlaylistTree.currentVersion
    public var items: [PlaylistItem]
    /// eigene Werte je Feld (`SmartField.rawValue`), bleiben in den Vorschlägen auch ohne Track
    public var values: [String: [String]]

    public init(items: [PlaylistItem] = [], values: [String: [String]] = [:]) {
        self.items = items
        self.values = values
    }

    enum CodingKeys: String, CodingKey { case version, items, values }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        items = try c.decodeIfPresent([PlaylistItem].self, forKey: .items) ?? []
        values = try c.decodeIfPresent([String: [String]].self, forKey: .values) ?? [:]
    }

    // MARK: - Lesen

    public func item(_ id: UUID) -> PlaylistItem? {
        func find(_ l: [PlaylistItem]) -> PlaylistItem? {
            for i in l {
                if i.id == id { return i }
                if let f = find(i.children) { return f }
            }
            return nil
        }
        return find(items)
    }

    public func contains(_ id: UUID) -> Bool { item(id) != nil }

    /// Eltern-Ordner (nil = oberste Ebene); nil, wenn es den Eintrag nicht gibt
    public func parent(of id: UUID) -> UUID?? {
        func find(_ l: [PlaylistItem], _ p: UUID?) -> UUID?? {
            for i in l {
                if i.id == id { return .some(p) }
                if let f = find(i.children, i.id) { return f }
            }
            return nil
        }
        return find(items, nil)
    }

    /// `id` liegt (auch tiefer) unter `ancestor`
    public func isDescendant(_ id: UUID, of ancestor: UUID) -> Bool {
        item(ancestor).map { a in Self.flatten(a.children).contains { $0.id == id } } ?? false
    }

    static func flatten(_ l: [PlaylistItem]) -> [PlaylistItem] { l.flatMap { [$0] + flatten($0.children) } }

    /// alle Einträge, Tiefensuche in Baum-Reihenfolge
    public var all: [PlaylistItem] { Self.flatten(items) }

    /// Ordner mit Tiefe (Menü „Verschieben nach“)
    public var folders: [(item: PlaylistItem, depth: Int)] {
        func walk(_ l: [PlaylistItem], _ d: Int) -> [(item: PlaylistItem, depth: Int)] {
            l.filter { $0.kind == .folder }.flatMap { [($0, d)] + walk($0.children, d + 1) }
        }
        return walk(items, 0)
    }

    /// Name aus den Namen der Ebene: „Neue Playlist“, „Neue Playlist 2“ …
    public func uniqueName(_ base: String, in parent: UUID?) -> String {
        let names = Set(siblings(parent).map(\.name))
        if !names.contains(base) { return base }
        var n = 2
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    func siblings(_ parent: UUID?) -> [PlaylistItem] { parent.flatMap { item($0)?.children } ?? (parent == nil ? items : []) }

    // MARK: - Ändern

    /// Liste der Ebene `parent` (nil = oben) ändern; false = kein Ordner
    @discardableResult
    mutating func withList(_ parent: UUID?, _ f: (inout [PlaylistItem]) -> Void) -> Bool {
        guard let parent else { f(&items); return true }
        return Self.mutate(parent, in: &items) { i in
            guard i.kind == .folder else { return false }
            f(&i.children)
            return true
        }
    }

    static func mutate(_ id: UUID, in l: inout [PlaylistItem], _ f: (inout PlaylistItem) -> Bool) -> Bool {
        for k in l.indices {
            if l[k].id == id { return f(&l[k]) }
            if mutate(id, in: &l[k].children, f) { return true }
        }
        return false
    }

    /// Eintrag einfügen (Ordner `parent`, nil = oben), `index` nil = ans Ende. false = Ziel kein Ordner oder ID vergeben
    @discardableResult
    public mutating func insert(_ item: PlaylistItem, into parent: UUID? = nil, at index: Int? = nil) -> Bool {
        guard !contains(item.id), Self.flatten(item.children).allSatisfy({ !contains($0.id) }) else { return false }
        return withList(parent) { l in l.insert(item, at: max(0, min(l.count, index ?? l.count))) }
    }

    @discardableResult
    public mutating func remove(_ id: UUID) -> PlaylistItem? {
        func take(_ l: inout [PlaylistItem]) -> PlaylistItem? {
            if let k = l.firstIndex(where: { $0.id == id }) { return l.remove(at: k) }
            for k in l.indices { if let t = take(&l[k].children) { return t } }
            return nil
        }
        return take(&items)
    }

    /// Verschieben in Ordner `parent` an `index` (Position vor dem Verschieben, nil = ans Ende). Nicht in sich selbst
    /// oder einen eigenen Unterordner
    @discardableResult
    public mutating func move(_ id: UUID, into parent: UUID?, at index: Int? = nil) -> Bool {
        guard case let .some(old) = self.parent(of: id) else { return false }
        if let parent {
            guard parent != id, !isDescendant(parent, of: id), item(parent)?.kind == .folder else { return false }
        }
        var at = index
        if old == parent, let i = at, let from = siblings(parent).firstIndex(where: { $0.id == id }), from < i { at = i - 1 }
        var copy = self
        guard let it = copy.remove(id), copy.insert(it, into: parent, at: at) else { return false }
        self = copy
        return true
    }

    @discardableResult
    public mutating func update(_ id: UUID, _ f: (inout PlaylistItem) -> Void) -> Bool {
        Self.mutate(id, in: &items) { i in f(&i); return true }
    }

    @discardableResult
    public mutating func rename(_ id: UUID, to name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return false }
        return update(id) { $0.name = n }
    }

    /// Tracks an eine Playlist (ohne doppelte), `index` nil = ans Ende. Ergebnis: Anzahl neu
    @discardableResult
    public mutating func addTracks(_ keys: [String], to id: UUID, at index: Int? = nil) -> Int {
        var added = 0
        update(id) { i in
            guard i.kind == .playlist else { return }
            var have = Set(i.tracks)
            let new = keys.filter { have.insert($0).inserted }
            i.tracks.insert(contentsOf: new, at: max(0, min(i.tracks.count, index ?? i.tracks.count)))
            added = new.count
        }
        return added
    }

    @discardableResult
    public mutating func removeTracks(_ keys: Set<String>, from id: UUID) -> Int {
        var n = 0
        update(id) { i in
            let before = i.tracks.count
            i.tracks.removeAll { keys.contains($0) }
            n = before - i.tracks.count
        }
        return n
    }

    /// Reihenfolge: `keys` (in ihrer Reihenfolge in der Playlist) vor den Track an `index` (Index vor dem Verschieben,
    /// `tracks.count` = ans Ende)
    @discardableResult
    public mutating func moveTracks(_ keys: [String], in id: UUID, to index: Int) -> Bool {
        var ok = false
        update(id) { i in
            let set = Set(keys)
            let moving = i.tracks.filter { set.contains($0) }
            guard !moving.isEmpty else { return }
            let target = max(0, min(i.tracks.count, index))
            let before = i.tracks[..<target].filter { set.contains($0) }.count
            var rest = i.tracks.filter { !set.contains($0) }
            rest.insert(contentsOf: moving, at: max(0, min(rest.count, target - before)))
            ok = rest != i.tracks
            i.tracks = rest
        }
        return ok
    }

    /// Track-Schlüssel geändert (Datei umbenannt): in allen Playlists
    public mutating func renameTrack(_ old: String, to new: String) {
        func walk(_ l: inout [PlaylistItem]) {
            for k in l.indices {
                if l[k].kind == .playlist, l[k].tracks.contains(old) {
                    l[k].tracks = l[k].tracks.map { $0 == old ? new : $0 }
                }
                walk(&l[k].children)
            }
        }
        walk(&items)
    }

    // MARK: - Eigene Werte

    public func values(for f: SmartField) -> [String] { values[f.rawValue] ?? [] }

    /// eigener Wert für die Vorschläge (ohne Groß-/Kleinschreibung doppelt nur einmal)
    public mutating func remember(_ value: String, for f: SmartField) {
        let v = value.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty, f.suggests else { return }
        var l = values[f.rawValue] ?? []
        guard !l.contains(where: { $0.caseInsensitiveCompare(v) == .orderedSame }) else { return }
        l.append(v)
        l.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        values[f.rawValue] = l
    }

    public mutating func forget(_ value: String, for f: SmartField) {
        values[f.rawValue]?.removeAll { $0 == value }
        if values[f.rawValue]?.isEmpty == true { values[f.rawValue] = nil }
    }

    // MARK: - Collection-Datei

    /// Ordner und Playlists als Knoten für `$ROOT/MINOS-741/Playlists` (Smartlists bleiben in MINOS-741)
    public var nmlNodes: [NMLOwnNode] {
        func conv(_ l: [PlaylistItem]) -> [NMLOwnNode] {
            l.compactMap { i in
                switch i.kind {
                case .folder: .folder(i.name, conv(i.children))
                case .playlist: .playlist(i.name, i.tracks)
                case .smartlist: nil
                }
            }
        }
        return conv(items)
    }

    public var hasPlaylists: Bool { all.contains { $0.kind == .playlist } }

    // MARK: - Datei

    public static func decode(_ data: Data) throws -> PlaylistTree { try JSONDecoder().decode(PlaylistTree.self, from: data) }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }

    /// erster Start: eigene Smartlists der früheren Liste (ID, Name, Regel-Text) oben im Baum, IDs bleiben
    /// (Sitzung und Favoriten finden sie wieder)
    public static func migrated(legacy: [(id: UUID, name: String, query: String)]) -> PlaylistTree {
        PlaylistTree(items: legacy.map { .smartlist($0.name, SmartRules.from(query: $0.query), id: $0.id) })
    }
}
