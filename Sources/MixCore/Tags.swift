import Foundation

/// Tags aus Kommentar 2: zerlegen und vergleichen (ohne Groß-/Kleinschreibung und Akzente)
public enum Tags {
    /// Kommentar 2 an den Trennzeichen zerlegen – jedes Zeichen trennt, leer = Leerzeichen
    public static func split(_ text: String, separators: String) -> [String] {
        let seps = Set(separators.isEmpty ? " " : separators)
        return text.split(whereSeparator: { seps.contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Vergleichsform: klein, ohne Akzente, Leerraum zu einem Leerzeichen
    public static func key(_ tag: String) -> String {
        tag.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// Tag-Filter eines Browser-Bereichs: alle eingeschlossenen Tags müssen vorkommen, kein ausgeschlossener
public struct TagFilter: Hashable, Sendable {
    public enum Mark: Sendable { case none, include, exclude }

    public private(set) var include: Set<String>
    public private(set) var exclude: Set<String>
    private var includeKeys: Set<String>
    private var excludeKeys: Set<String>

    public init(include: Set<String> = [], exclude: Set<String> = []) {
        self.include = include
        self.exclude = exclude
        includeKeys = Set(include.map(Tags.key))
        excludeKeys = Set(exclude.map(Tags.key))
    }

    public var isEmpty: Bool { include.isEmpty && exclude.isEmpty }

    public func mark(key: String) -> Mark {
        includeKeys.contains(key) ? .include : excludeKeys.contains(key) ? .exclude : .none
    }

    public func mark(_ tag: String) -> Mark { isEmpty ? .none : mark(key: Tags.key(tag)) }

    /// `keys`: Vergleichsformen der Tags eines Tracks
    public func matches(keys: [String]) -> Bool {
        includeKeys.allSatisfy(keys.contains) && !keys.contains(where: excludeKeys.contains)
    }

    public func matches(_ text: String, separators: String) -> Bool {
        matches(keys: Tags.split(text, separators: separators).map(Tags.key))
    }

    /// Klick: einschließen bzw. wieder lösen; ⌥-Klick (`exclude`): ausschließen bzw. wieder lösen
    public func toggling(_ tag: String, exclude ex: Bool) -> TagFilter {
        let k = Tags.key(tag), was = mark(key: k)
        var inc = include.filter { Tags.key($0) != k }, exc = exclude.filter { Tags.key($0) != k }
        if ex, was != .exclude { exc.insert(tag) }
        if !ex, was != .include { inc.insert(tag) }
        return TagFilter(include: inc, exclude: exc)
    }

    public func removing(_ tag: String) -> TagFilter {
        let k = Tags.key(tag)
        return TagFilter(include: include.filter { Tags.key($0) != k }, exclude: exclude.filter { Tags.key($0) != k })
    }
}

/// Zerlegte Tags je Kommentar-2-Text, einmal berechnet und gemerkt (viele Tracks teilen denselben Text)
public final class TagIndex {
    public struct Entry: Sendable {
        public let tags: [String]
        public let keys: [String]
        /// Gruppe je Tag (`TagGroups.of`)
        public let groups: [String?]

        /// ohne die Marker selbst (Anzeige: die Gruppe zeigt die Farbe)
        public var withoutMarkers: Entry {
            let keep = tags.indices.filter { groups[$0] != tags[$0] }
            guard keep.count < tags.count else { return self }
            return Entry(tags: keep.map { tags[$0] }, keys: keep.map { keys[$0] }, groups: keep.map { groups[$0] })
        }

        /// Anzeige: mit Gruppen ohne Marker
        public func shown(groups on: Bool) -> Entry { on ? withoutMarkers : self }
    }

    private var separators = ""
    private var cache: [String: Entry] = [:]
    /// zuletzt gesehene Gruppe je Tag (Chips ohne ihren Kommentar-2-Text, z. B. der Filter im Kopf)
    private var groupOf: [String: String] = [:]

    public init() {}

    public func group(of tag: String) -> String? { groupOf[tag] }

    public func entry(_ text: String, separators seps: String) -> Entry {
        if seps != separators { cache.removeAll(keepingCapacity: true); groupOf.removeAll(); separators = seps }
        if let e = cache[text] { return e }
        let tags = Tags.split(text, separators: seps)
        let e = Entry(tags: tags, keys: tags.map(Tags.key), groups: TagGroups.of(tags))
        for (t, g) in zip(tags, e.groups) where g != nil && g != t { groupOf[t] = g }
        cache[text] = e
        return e
    }

    public var count: Int { cache.count }
}

/// Gruppen in Kommentar 2: ein einzelner Großbuchstabe (`K`) beginnt eine Gruppe, die folgenden Tags gehören zu ihr;
/// ein Wort nur aus Großbuchstaben (`BASIS`) ist eine Rolle und beendet die Gruppe.
/// `K tief lang B sub schwer H off DRUMS` -> K: tief lang · B: sub schwer · H: off · Rolle: DRUMS
public enum TagGroups {
    /// Gruppe der Rollen-Tags
    public static let role = "»"

    public static func isMarker(_ tag: String) -> Bool {
        tag.count == 1 && tag.first.map { $0.isLetter && $0.isUppercase } == true
    }

    public static func isRole(_ tag: String) -> Bool {
        tag.count >= 2 && tag.allSatisfy { $0.isLetter && $0.isUppercase }
    }

    /// Gruppe je Tag: Marker = er selbst, Rolle = `role`, vor dem ersten Marker / nach einer Rolle nil
    public static func of(_ tags: [String]) -> [String?] {
        var cur: String?
        return tags.map { t in
            if isMarker(t) { cur = t; return t }
            if isRole(t) { cur = nil; return role }
            return cur
        }
    }
}

/// Gruppen-Profil eines Tracks für „passt zum Master“: erstes Wort je Gruppe (`K tief`, `B sub`, `H off`) und Rollen,
/// alles in Vergleichsform
public struct TagProfile: Hashable, Sendable {
    public var primary: [String: String] = [:]
    public var roles: Set<String> = []

    public init() {}

    public init(tags: [String], groups: [String?]) {
        for (t, g) in zip(tags, groups) {
            guard let g, !TagGroups.isMarker(t) else { continue }
            if g == TagGroups.role { roles.insert(Tags.key(t)) } else if primary[g] == nil { primary[g] = Tags.key(t) }
        }
    }

    public init(_ text: String, separators: String) {
        let tags = Tags.split(text, separators: separators)
        self.init(tags: tags, groups: TagGroups.of(tags))
    }

    public var isEmpty: Bool { primary.isEmpty && roles.isEmpty }
}
