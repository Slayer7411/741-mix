import Foundation

/// Knoten im Playlist-Baum (Ordner, Playlist, Smartlist).
public final class PlaylistNode: Identifiable, Hashable, @unchecked Sendable {
    public enum Kind: Sendable { case folder, playlist, smartlist }
    public private(set) var id = UUID()
    public var name: String
    public var kind: Kind
    public var children: [PlaylistNode] = []
    /// Track-Schlüssel (nur Playlist)
    public var trackKeys: [String] = []
    /// Smartlist-Regel (nur Smartlist)
    public var query: String = ""
    /// UUID aus der Collection (Playlist, Smartlist; Ordner haben keine)
    public var uuid: String = ""

    public init(name: String, kind: Kind) { self.name = name; self.kind = kind }

    public var childrenOrNil: [PlaylistNode]? { kind == .folder ? children : nil }
    /// Neu geladener Baum: Knoten mit gleichem Pfad (Art + Name) übernehmen die ID des alten Knotens –
    /// Auswahl und Zeilen im Baum bleiben über ein Neu-Laden erhalten (sonst baut die Liste alle Zeilen neu)
    public func adoptIDs(from old: PlaylistNode) {
        guard kind == old.kind, name == old.name else { return }
        id = old.id
        var pool: [String: ArraySlice<PlaylistNode>] = [:]
        for c in old.children { pool["\(c.kind)|\(c.name)", default: []].append(c) }
        for c in children {
            let k = "\(c.kind)|\(c.name)"
            if let o = pool[k]?.first { c.adoptIDs(from: o); pool[k] = pool[k]?.dropFirst() }
        }
    }
    /// gleicher Baum (Namen, Arten, Playlist-Einträge, Regeln)?
    public func sameTree(_ o: PlaylistNode) -> Bool {
        id == o.id && name == o.name && kind == o.kind && trackKeys == o.trackKeys && query == o.query && uuid == o.uuid
            && children.count == o.children.count && zip(children, o.children).allSatisfy { $0.sameTree($1) }
    }
    /// alle Knoten nach ID
    public func index(into d: inout [UUID: PlaylistNode]) {
        d[id] = self
        for c in children { c.index(into: &d) }
    }
    /// Namen von den Kindern dieses Knotens bis `target` (nil = nicht darunter)
    public func path(to target: PlaylistNode) -> [String]? {
        for c in children {
            if c === target || c.id == target.id { return [c.name] }
            if let p = c.path(to: target) { return [c.name] + p }
        }
        return nil
    }
    /// Knoten unter diesem: zuerst über die UUID, sonst über den Namenspfad (gleiche Art, erster Treffer)
    public func find(uuid: String?, path: [String]?, kind: Kind? = nil) -> PlaylistNode? {
        if let uuid, !uuid.isEmpty, let n = first(where: { $0.uuid == uuid }) { return n }
        guard let path, !path.isEmpty else { return nil }
        var n = self
        for (i, name) in path.enumerated() {
            let last = i == path.count - 1
            let want: Kind? = last ? kind : .folder
            guard let c = n.children.first(where: { c in c.name == name && (want == nil || c.kind == want) }) else { return nil }
            n = c
        }
        return n
    }
    /// erster Knoten unter diesem (Tiefensuche), der passt
    public func first(where match: (PlaylistNode) -> Bool) -> PlaylistNode? {
        for c in children {
            if match(c) { return c }
            if let f = c.first(where: match) { return f }
        }
        return nil
    }
    public static func == (a: PlaylistNode, b: PlaylistNode) -> Bool { a.id == b.id }
    public func hash(into h: inout Hasher) { h.combine(id) }
}

public struct Collection: Sendable {
    public var tracks: [Track]
    public var root: PlaylistNode
}

/// Liest eine `collection.nml` (SAX, ~1 s für 15k Tracks).
public final class NMLParser: NSObject, XMLParserDelegate {
    private var tracks: [Track] = []
    private var current: Track?
    private var inCollection = false
    private var root = PlaylistNode(name: "$ROOT", kind: .folder)
    private var stack: [PlaylistNode] = []
    private var pendingNode: PlaylistNode?

    public static func parse(url: URL) throws -> Collection {
        guard let xml = XMLParser(contentsOf: url) else { throw CocoaError(.fileReadUnknown) }
        let d = NMLParser()
        xml.delegate = d
        guard xml.parse() else { throw xml.parserError ?? CocoaError(.fileReadCorruptFile) }
        return Collection(tracks: d.tracks, root: d.root.children.first ?? d.root)
    }

    public static func parse(data: Data) throws -> Collection {
        let xml = XMLParser(data: data)
        let d = NMLParser()
        xml.delegate = d
        guard xml.parse() else { throw xml.parserError ?? CocoaError(.fileReadCorruptFile) }
        return Collection(tracks: d.tracks, root: d.root.children.first ?? d.root)
    }

    /// Stand eines ENTRY aus MODIFIED_DATE + MODIFIED_TIME (leer, wenn beide fehlen)
    public static func stamp(_ a: [String: String]) -> String {
        let d = a["MODIFIED_DATE"] ?? "", t = a["MODIFIED_TIME"] ?? ""
        return d.isEmpty && t.isEmpty ? "" : d + " " + t
    }

    /// NML-Pfad "/:Users/:x/:" → "/Users/x/"
    public static func plainDir(_ dir: String) -> String { dir.replacingOccurrences(of: "/:", with: "/") }

    static func date(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let p = s.split(separator: "/").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return DateComponents(calendar: Calendar(identifier: .gregorian), year: p[0], month: p[1], day: p[2]).date
    }

    public func parser(_ parser: XMLParser, didStartElement el: String, namespaceURI: String?,
                       qualifiedName: String?, attributes a: [String: String] = [:]) {
        switch el {
        case "COLLECTION": inCollection = true
        case "ENTRY" where inCollection:
            current = Track(key: "", path: "")
            current?.title = a["TITLE"] ?? ""
            current?.artist = a["ARTIST"] ?? ""
            current?.locked = a["LOCK"] == "1"
            current?.entryStamp = Self.stamp(a)
        case "LOCATION" where current != nil:
            let vol = a["VOLUME"] ?? "", dir = a["DIR"] ?? "", file = a["FILE"] ?? ""
            current?.key = vol + dir + file
            current?.path = Self.plainDir(dir) + file
        case "ALBUM" where current != nil:
            current?.album = a["TITLE"] ?? ""
            current?.trackNumber = Int(a["TRACK"] ?? "") ?? 0
        case "INFO" where current != nil:
            guard var t = current else { return }
            t.genre = a["GENRE"] ?? ""
            t.label = a["LABEL"] ?? ""
            t.comment = a["COMMENT"] ?? ""
            t.comment2 = a["RATING"] ?? ""
            t.keyText = a["KEY"] ?? ""
            t.remixer = a["REMIXER"] ?? ""
            t.producer = a["PRODUCER"] ?? ""
            t.mix = a["MIX"] ?? ""
            t.catalogNo = a["CATALOG_NO"] ?? ""
            t.fileSizeKB = Int(a["FILESIZE"] ?? "") ?? 0
            t.duration = Double(a["PLAYTIME_FLOAT"] ?? a["PLAYTIME"] ?? "") ?? 0
            t.bitrate = (Int(a["BITRATE"] ?? "") ?? 0) / 1000
            t.rating = (Int(a["RANKING"] ?? "") ?? 0) / 51
            t.color = Int(a["COLOR"] ?? "") ?? 0
            t.playCount = Int(a["PLAYCOUNT"] ?? "") ?? 0
            t.importDate = Self.date(a["IMPORT_DATE"])
            t.releaseDate = Self.date(a["RELEASE_DATE"])
            t.lastPlayed = Self.date(a["LAST_PLAYED"])
            current = t
        case "TEMPO" where current != nil:
            current?.bpm = Double(a["BPM"] ?? "") ?? 0
        case "LOUDNESS" where current != nil:
            current?.peakDb = Double(a["PEAK_DB"] ?? "")
            current?.perceivedDb = Double(a["PERCEIVED_DB"] ?? "")
        case "MUSICAL_KEY" where current != nil:
            current?.musicalKey = Int(a["VALUE"] ?? "") ?? -1
        case "CUE_V2" where current != nil:
            let cue = Cue(name: a["NAME"] ?? "",
                          kind: Cue.Kind(rawValue: Int(a["TYPE"] ?? "") ?? 0) ?? .cue,
                          startMs: Double(a["START"] ?? "") ?? 0,
                          lengthMs: Double(a["LEN"] ?? "") ?? 0,
                          hotcue: Int(a["HOTCUE"] ?? "") ?? -1)
            current?.cues.append(cue)
        case "NODE":
            let kind: PlaylistNode.Kind = switch a["TYPE"] {
                case "PLAYLIST": .playlist
                case "SMARTLIST": .smartlist
                default: .folder
            }
            let node = PlaylistNode(name: a["NAME"] ?? "", kind: kind)
            (stack.last ?? root).children.append(node)
            stack.append(node)
        case "PLAYLIST", "SMARTLIST":
            if let u = a["UUID"], let n = stack.last, n.uuid.isEmpty { n.uuid = u }
        case "PRIMARYKEY":
            if let k = a["KEY"], let n = stack.last, n.kind == .playlist { n.trackKeys.append(k) }
        case "SEARCH_EXPRESSION":
            stack.last?.query = a["QUERY"] ?? ""
        default: break
        }
    }

    public func parser(_ parser: XMLParser, didEndElement el: String, namespaceURI: String?, qualifiedName: String?) {
        switch el {
        case "COLLECTION": inCollection = false
        case "ENTRY" where inCollection:
            if var t = current, !t.key.isEmpty { t.buildSearchText(); tracks.append(t) }
            current = nil
        case "NODE": _ = stack.popLast()
        default: break
        }
    }
}
