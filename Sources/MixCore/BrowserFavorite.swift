import Foundation

/// Favorit eines Browser-Bereichs (6 Plätze): eine Quelle über eine stabile Kennung oder ein Filter.
/// Quellen: Collection, Preparation, Running Tracks, History, eigene Smartlist (ID, Name), Knoten der Collection
/// (UUID, Namenspfad; Ordner nur Pfad), Musik-Ordner (Pfad). Filter: Tags, Rollen, Suchtext.
public struct BrowserFavorite: Codable, Hashable, Sendable {
    public static let slots = 6

    public enum Kind: String, Sendable {
        case collection, preparation, running, history, smartlist, node, folder, filter
    }

    /// Art als Text: eine unbekannte Art (neuere Version) lässt das Laden der Sitzung nicht scheitern
    public var type: String
    /// Anzeige, umbenennbar
    public var name: String
    /// UUID eines Collection-Knotens bzw. ID einer eigenen Smartlist
    public var id: String?
    /// Knoten: Namen ab der Wurzel · eigene Smartlist: [Name] · Musik-Ordner: [absoluter Pfad]
    public var path: [String]?
    /// Art des Knotens: folder · playlist · smartlist
    public var node: String?
    public var tags: [String]?
    public var roles: [String]?
    public var search: String?

    public init(_ kind: Kind, name: String, id: String? = nil, path: [String]? = nil, node: String? = nil) {
        type = kind.rawValue
        self.name = name
        self.id = id
        self.path = path
        self.node = node
    }

    public var kind: Kind? { Kind(rawValue: type) }
    public var isFilter: Bool { kind == .filter }

    /// Knoten-Art als Text
    public static func nodeKind(_ k: PlaylistNode.Kind) -> String {
        switch k {
        case .folder: "folder"
        case .playlist: "playlist"
        case .smartlist: "smartlist"
        }
    }

    public var nodeKind: PlaylistNode.Kind? {
        switch node {
        case "folder": .folder
        case "playlist": .playlist
        case "smartlist": .smartlist
        default: nil
        }
    }

    /// Knoten unter `root` (Collection-Baum)
    public func resolveNode(in root: PlaylistNode) -> PlaylistNode? {
        guard kind == .node else { return nil }
        return root.find(uuid: id, path: path, kind: nodeKind)
    }

    /// Favorit für einen Knoten unter `root`
    public static func node(_ n: PlaylistNode, in root: PlaylistNode) -> BrowserFavorite? {
        guard let p = root.path(to: n) else { return nil }
        return BrowserFavorite(.node, name: n.name, id: n.uuid.isEmpty ? nil : n.uuid, path: p, node: nodeKind(n.kind))
    }

    /// Filter-Favorit; nil, wenn nichts gefiltert ist
    public static func filter(tags: Set<String>, roles: Set<String>, search: String) -> BrowserFavorite? {
        let s = search.trimmingCharacters(in: .whitespaces)
        guard !tags.isEmpty || !roles.isEmpty || !s.isEmpty else { return nil }
        let r = roles.sorted(), t = tags.sorted()
        var f = BrowserFavorite(.filter, name: (r + t + (s.isEmpty ? [] : ["\"\(s)\""])).joined(separator: " + "))
        f.tags = t.isEmpty ? nil : t
        f.roles = r.isEmpty ? nil : r
        f.search = s.isEmpty ? nil : s
        return f
    }

    /// derselbe Filter wie im Bereich?
    public func matchesFilter(tags: Set<String>, roles: Set<String>, search: String) -> Bool {
        isFilter && Set(self.tags ?? []) == tags && Set(self.roles ?? []) == roles
            && (self.search ?? "") == search.trimmingCharacters(in: .whitespaces)
    }

    /// Plätze aus der Sitzung: immer genau `slots`
    public static func normalized(_ l: [BrowserFavorite?]?) -> [BrowserFavorite?] {
        let l = l ?? []
        return (0..<slots).map { $0 < l.count ? l[$0] : nil }
    }
}
