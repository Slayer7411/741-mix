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
    }

    private var separators = ""
    private var cache: [String: Entry] = [:]

    public init() {}

    public func entry(_ text: String, separators seps: String) -> Entry {
        if seps != separators { cache.removeAll(keepingCapacity: true); separators = seps }
        if let e = cache[text] { return e }
        let tags = Tags.split(text, separators: seps)
        let e = Entry(tags: tags, keys: tags.map(Tags.key))
        cache[text] = e
        return e
    }

    public var count: Int { cache.count }
}
