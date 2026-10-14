import Foundation

/// Feld einer Smartlist-Regel. `kind` bestimmt Operatoren und Werteingabe
public enum SmartField: String, Codable, CaseIterable, Sendable {
    case search, artist, title, release, mix, remixer, producer, label, genre, catalog, comment, comment2, tag
    case key, bpm, rating, year, releaseDate, duration, loudness, bitrate, color, playCount
    case fileType, path, importDate, played, lastPlayed, cloud, analyzed, expression

    public enum Kind: Sendable { case search, text, tag, key, number, date, flag, cloud, expression }

    public var kind: Kind {
        switch self {
        case .search: .search
        case .artist, .title, .release, .mix, .remixer, .producer, .label, .genre, .catalog, .comment, .comment2, .fileType, .path: .text
        case .tag: .tag
        case .key: .key
        case .bpm, .rating, .year, .duration, .loudness, .bitrate, .color, .playCount: .number
        case .releaseDate, .importDate, .lastPlayed: .date
        case .played, .analyzed: .flag
        case .cloud: .cloud
        case .expression: .expression
        }
    }

    /// Operatoren in der Reihenfolge des Menüs
    public var ops: [SmartOp] {
        switch kind {
        case .search: [.contains, .notContains]
        case .text: [.contains, .notContains, .equals, .isNot, .startsWith, .endsWith, .isEmpty, .notEmpty]
        case .tag: [.contains, .notContains, .isEmpty, .notEmpty]
        case .key: [.equals, .isNot, .isEmpty, .notEmpty]
        case .number: [.equals, .isNot, .greater, .less, .atLeast, .atMost, .between] + (self == .loudness || self == .year ? [.isEmpty, .notEmpty] : [])
        case .date: [.inLast, .notInLast, .before, .after, .between, .isEmpty, .notEmpty]
        case .flag: [.yes, .no]
        case .cloud: [.equals, .isNot]
        case .expression: [.matches]
        }
    }

    /// Werte aus der Collection als Vorschläge (Text, Tag)
    public var suggests: Bool { kind == .text || kind == .tag }
}

public enum SmartOp: String, Codable, CaseIterable, Sendable {
    case equals = "is", isNot, contains, notContains, startsWith, endsWith, isEmpty, notEmpty
    case less, greater, atLeast, atMost, between
    case before, after, inLast, notInLast
    case yes, no
    case matches

    /// braucht keinen Wert
    public var unary: Bool { [.isEmpty, .notEmpty, .yes, .no].contains(self) }
}

/// Zustand der Datei für die Regel „Cloud-Status“
public enum SmartAvailability: String, Codable, CaseIterable, Sendable { case local, cloud, missing }

/// Eine Regelzeile: Feld · Operator · Wert (`value2`: zweiter Wert bei „zwischen“, Einheit bei „in den letzten“)
public struct SmartRule: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var field: SmartField
    public var op: SmartOp
    public var value: String
    public var value2: String

    public init(_ field: SmartField, _ op: SmartOp, _ value: String = "", _ value2: String = "") {
        self.field = field
        self.op = op
        self.value = value
        self.value2 = value2
    }

    enum CodingKeys: String, CodingKey { case id, field, op, value, value2 }

    /// unbekannte Felder / Operatoren (neuere Version): Regel bleibt als Ausdruck ohne Treffer stehen
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        let f = SmartField(rawValue: try c.decodeIfPresent(String.self, forKey: .field) ?? "")
        let o = SmartOp(rawValue: try c.decodeIfPresent(String.self, forKey: .op) ?? "")
        value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
        value2 = try c.decodeIfPresent(String.self, forKey: .value2) ?? ""
        if let f, let o, f.ops.contains(o) {
            field = f
            op = o
        } else {
            field = .expression
            op = .matches
            value = "$TITLE == \"\u{0}\""
        }
    }

    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(field, forKey: .field)
        try c.encode(op, forKey: .op)
        if !value.isEmpty { try c.encode(value, forKey: .value) }
        if !value2.isEmpty { try c.encode(value2, forKey: .value2) }
    }

    /// Feld wechseln: Operator bleibt, wenn das neue Feld ihn kennt, sonst der erste; Wert passend leeren
    public mutating func setField(_ f: SmartField) {
        guard f != field else { return }
        let kindChanged = f.kind != field.kind
        field = f
        if !f.ops.contains(op) { op = f.ops[0] }
        if kindChanged {
            value = ""
            value2 = ""
            if f.kind == .cloud { value = SmartAvailability.local.rawValue }
            if f.kind == .key { value = "0" }
        }
        if op == .inLast || op == .notInLast, value2.isEmpty { value2 = "d" }
    }

    public mutating func setOp(_ o: SmartOp) {
        op = o
        if o == .inLast || o == .notInLast {
            if Int(value) == nil { value = "30" }
            if !["d", "w", "m", "y"].contains(value2) { value2 = "d" }
        } else if field.kind == .date, o != .between, ["d", "w", "m", "y"].contains(value2) {
            value2 = ""
        }
        if (o == .before || o == .after || o == .between), field.kind == .date, SmartRules.day(value) == nil { value = "" }
    }

    /// Fehler der Eingabe (nil = gültig)
    public var problem: String? {
        if op.unary { return nil }
        switch field.kind {
        case .search, .text, .tag: return nil
        case .key: return Int(value).map { (0...23).contains($0) } == true ? nil : "Key wählen"
        case .cloud: return SmartAvailability(rawValue: value) == nil ? "Status wählen" : nil
        case .flag: return nil
        case .expression:
            do { _ = try SmartQuery.parse(value); return nil } catch { return String(describing: error) }
        case .number:
            guard SmartRules.number(value, field) != nil else { return SmartRules.numberHint(field) }
            if op == .between, SmartRules.number(value2, field) == nil { return SmartRules.numberHint(field) }
            return nil
        case .date:
            switch op {
            case .inLast, .notInLast: return Int(value).map { $0 >= 0 } == true ? nil : "Anzahl (ganze Zahl)"
            case .between: return SmartRules.day(value) != nil && SmartRules.day(value2) != nil ? nil : "Datum JJJJ-MM-TT"
            default: return SmartRules.day(value) != nil ? nil : "Datum JJJJ-MM-TT"
            }
        }
    }
}

/// Sortierung vor dem Limit (die Liste im Browser sortiert danach wie eingestellt)
public struct SmartSort: Codable, Hashable, Sendable {
    public var field: SmartField
    public var ascending: Bool
    public init(_ field: SmartField, ascending: Bool) { self.field = field; self.ascending = ascending }
}

/// Umgebung der Auswertung: Zeit, Tag-Trennzeichen, gespielte Tracks, Dateizustand
public struct SmartContext: Sendable {
    public var now: Date
    public var separators: String
    /// in dieser History gespielt (zählt zu „Gespielt“ wie PLAYCOUNT > 0)
    public var played: Set<String>
    /// Dateizustand; nil = aus `fileExists` (lokal / fehlt)
    public var availability: (@Sendable (Track) -> SmartAvailability)?

    public init(now: Date = Date(), separators: String = " ", played: Set<String> = [],
                availability: (@Sendable (Track) -> SmartAvailability)? = nil) {
        self.now = now
        self.separators = separators
        self.played = played
        self.availability = availability
    }
}

/// Smartlist aus Regelzeilen: alle / eine der Regeln, optional Sortierung und Limit.
/// Alte Smartlists (Regel-Text) laufen als Zeile `expression` oder werden beim Übernehmen in Zeilen zerlegt (`from(query:)`)
public struct SmartRules: Codable, Hashable, Sendable {
    public enum Match: String, Codable, CaseIterable, Sendable { case all, any }
    public var match: Match
    public var rules: [SmartRule]
    public var sort: SmartSort?
    public var limit: Int?

    public init(match: Match = .all, rules: [SmartRule] = [], sort: SmartSort? = nil, limit: Int? = nil) {
        self.match = match
        self.rules = rules
        self.sort = sort
        self.limit = limit
    }

    public var problem: String? { rules.lazy.compactMap(\.problem).first }
    public var isValid: Bool { problem == nil }

    /// hängt am Dateizustand bzw. an den gespielten Tracks (Zwischenspeicher)
    public var usesAvailability: Bool { rules.contains { $0.field == .cloud } }
    public var usesPlayed: Bool { rules.contains { $0.field == .played } }

    // MARK: - Werte

    static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Tag als „JJJJ-MM-TT“ (Anfang des Tages, lokale Zeit)
    public static func day(_ s: String) -> Date? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.count == 10 else { return nil }
        return dayFormat.date(from: t)
    }

    public static func dayText(_ d: Date) -> String { dayFormat.string(from: d) }

    /// Zahl eines Felds: Spielzeit auch als „m:ss“, Komma als Dezimaltrenner
    public static func number(_ s: String, _ f: SmartField) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !t.isEmpty else { return nil }
        if f == .duration, t.contains(":") {
            let p = t.split(separator: ":", omittingEmptySubsequences: false)
            guard p.count == 2, let m = Double(p[0]), let s = Double(p[1]), m >= 0, s >= 0, s < 60 else { return nil }
            return m * 60 + s
        }
        guard let v = Double(t), v.isFinite else { return nil }
        if f == .rating, !(0...5).contains(v) { return nil }
        if f == .bpm || f == .year || f == .bitrate || f == .playCount || f == .duration || f == .color, v < 0 { return nil }
        return v
    }

    public static func numberHint(_ f: SmartField) -> String {
        switch f {
        case .duration: "Zeit m:ss oder Sekunden"
        case .rating: "Sterne 0–5"
        case .loudness: "dB, z. B. -2.5"
        case .year: "Jahr, z. B. 2024"
        case .bitrate: "kbit/s"
        default: "Zahl"
        }
    }

    // MARK: - Auswertung

    public func compile(_ ctx: SmartContext) -> Compiled {
        Compiled(match: match, tests: rules.map { Self.test($0, ctx) }, sort: sort, limit: limit, now: ctx.now)
    }

    /// vorbereitete Regeln (Werte gefaltet, Daten berechnet, Ausdrücke geparst)
    public struct Compiled: Sendable {
        let match: Match
        let tests: [@Sendable (Track) -> Bool]
        let sort: SmartSort?
        let limit: Int?
        let now: Date

        public func matches(_ t: Track) -> Bool {
            if tests.isEmpty { return true }
            return match == .all ? tests.allSatisfy { $0(t) } : tests.contains { $0(t) }
        }

        /// Treffer, sortiert und gekürzt, wenn Sortierung / Limit gesetzt sind
        public func apply(_ tracks: [Track]) -> [Track] {
            var out = tracks.filter(matches)
            if let s = sort {
                let keyed = out.map { (SmartRules.sortValue($0, s.field, now), $0) }
                out = keyed.enumerated().sorted { a, b in
                    let r = a.element.0.compare(b.element.0)
                    if r == .orderedSame { return a.offset < b.offset }
                    return s.ascending ? r == .orderedAscending : r == .orderedDescending
                }.map(\.element.1)
            }
            if let n = limit, n >= 0, out.count > n { out = Array(out.prefix(n)) }
            return out
        }
    }

    enum SortValue {
        case number(Double), text(String)
        func compare(_ o: SortValue) -> ComparisonResult {
            switch (self, o) {
            case let (.number(a), .number(b)): a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
            case let (.text(a), .text(b)): a.localizedStandardCompare(b)
            case (.number, .text): .orderedAscending
            case (.text, .number): .orderedDescending
            }
        }
    }

    static func sortValue(_ t: Track, _ f: SmartField, _ now: Date) -> SortValue {
        switch f.kind {
        case .number: .number(numberValue(t, f) ?? -.greatestFiniteMagnitude)
        case .date: .number(dateValue(t, f)?.timeIntervalSince1970 ?? -.greatestFiniteMagnitude)
        case .key: .number(Double(keyCode(t) ?? -1))
        default: .text(text(t, f))
        }
    }

    /// Text eines Felds
    public static func text(_ t: Track, _ f: SmartField) -> String {
        switch f {
        case .artist: t.artist
        case .title: t.title
        case .release: t.album
        case .mix: t.mix
        case .remixer: t.remixer
        case .producer: t.producer
        case .label: t.label
        case .genre: t.genre
        case .catalog: t.catalogNo
        case .comment: t.comment
        case .comment2, .tag: t.comment2
        case .fileType: (t.path as NSString).pathExtension.lowercased()
        case .path: t.path
        default: ""
        }
    }

    static func numberValue(_ t: Track, _ f: SmartField) -> Double? {
        switch f {
        case .bpm: t.bpm
        case .rating: Double(t.rating)
        case .year: t.releaseDate.map { Double(Calendar(identifier: .gregorian).component(.year, from: $0)) }
        case .duration: t.duration
        case .loudness: t.perceivedDb
        case .bitrate: Double(t.bitrate)
        case .color: Double(t.color)
        case .playCount: Double(t.playCount)
        default: nil
        }
    }

    static func dateValue(_ t: Track, _ f: SmartField) -> Date? {
        switch f {
        case .releaseDate: t.releaseDate
        case .importDate: t.importDate
        case .lastPlayed: t.lastPlayed
        default: nil
        }
    }

    /// Key 0–23 (MUSICAL_KEY, sonst aus dem Key-Text)
    static func keyCode(_ t: Track) -> Int? {
        if (0...23).contains(t.musicalKey) { return t.musicalKey }
        return t.keyText.isEmpty ? nil : Harmony.code(text: t.keyText)
    }

    public static func contains(_ h: [UInt8], _ n: [UInt8]) -> Bool {
        if n.isEmpty { return true }
        return h.withUnsafeBufferPointer { hp in
            n.withUnsafeBufferPointer { np in hp.count >= np.count && memmem(hp.baseAddress, hp.count, np.baseAddress, np.count) != nil }
        }
    }

    static func test(_ r: SmartRule, _ ctx: SmartContext) -> @Sendable (Track) -> Bool {
        let never: @Sendable (Track) -> Bool = { _ in false }
        guard r.problem == nil, r.field.ops.contains(r.op) else { return never }
        let f = r.field
        switch f.kind {
        case .search:
            let words = r.value.split(separator: " ").map { Track.fold(String($0)) }
            let neg = r.op != .contains
            return { $0.matches(words: words) != neg }
        case .text:
            let v = Track.fold(r.value.trimmingCharacters(in: .whitespaces))
            let op = r.op
            let check: @Sendable (String) -> Bool
            switch op {
            case .contains: check = { contains(Track.fold($0), v) }
            case .notContains: check = { !contains(Track.fold($0), v) }
            case .equals: check = { Track.fold($0) == v }
            case .isNot: check = { Track.fold($0) != v }
            case .startsWith: check = { Track.fold($0).starts(with: v) }
            case .endsWith: check = { Track.fold($0).reversed().starts(with: v.reversed()) }
            case .isEmpty: check = { $0.trimmingCharacters(in: .whitespaces).isEmpty }
            case .notEmpty: check = { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            default: return never
            }
            // viele Tracks teilen denselben Text (Genre, Label, Artist): Ergebnis je Text einmal
            let memo = Memo()
            return { t in memo.value(text(t, f), check) }
        case .tag:
            let seps = ctx.separators, want = Tags.key(r.value.trimmingCharacters(in: .whitespaces))
            let keys: @Sendable (Track) -> [String] = { Tags.split($0.comment2, separators: seps).map(Tags.key) }
            switch r.op {
            case .contains: return { keys($0).contains(want) }
            case .notContains: return { !keys($0).contains(want) }
            case .isEmpty: return { Tags.split($0.comment2, separators: seps).isEmpty }
            case .notEmpty: return { !Tags.split($0.comment2, separators: seps).isEmpty }
            default: return never
            }
        case .key:
            let code = Int(r.value) ?? -1
            switch r.op {
            case .equals: return { keyCode($0) == code }
            case .isNot: return { keyCode($0) != code }
            case .isEmpty: return { keyCode($0) == nil }
            case .notEmpty: return { keyCode($0) != nil }
            default: return never
            }
        case .number:
            if r.op == .isEmpty { return { numberValue($0, f) == nil } }
            if r.op == .notEmpty { return { numberValue($0, f) != nil } }
            guard let a = number(r.value, f) else { return never }
            let b = number(r.value2, f) ?? a
            // „ist“ / „ist nicht“: Tempo, Zeit, Lautheit auf die Anzeige gerundet, sonst genau
            let eps: Double = switch f {
                case .bpm: 0.05
                case .duration: 0.5
                case .loudness: 0.05
                default: 1e-9
            }
            let lo = min(a, b), hi = max(a, b)
            return { t in
                guard let x = numberValue(t, f) else { return false }
                switch r.op {
                case .equals: return abs(x - a) < eps
                case .isNot: return abs(x - a) >= eps
                case .greater: return x > a
                case .less: return x < a
                case .atLeast: return x >= a
                case .atMost: return x <= a
                case .between: return x >= lo && x <= hi
                default: return false
                }
            }
        case .date:
            let cal = Calendar(identifier: .gregorian)
            switch r.op {
            case .isEmpty: return { dateValue($0, f) == nil }
            case .notEmpty: return { dateValue($0, f) != nil }
            case .inLast, .notInLast:
                let n = Int(r.value) ?? 0
                let unit: Calendar.Component = switch r.value2 {
                    case "w": .weekOfYear
                    case "m": .month
                    case "y": .year
                    default: .day
                }
                guard let from = cal.date(byAdding: unit, value: -n, to: ctx.now) else { return never }
                let within: @Sendable (Track) -> Bool = { t in dateValue(t, f).map { $0 >= from } ?? false }
                let neg = r.op == .notInLast
                return { within($0) != neg }
            case .before:
                guard let d = day(r.value) else { return never }
                return { t in dateValue(t, f).map { $0 < d } ?? false }
            case .after:
                guard let d = day(r.value), let end = cal.date(byAdding: .day, value: 1, to: d) else { return never }
                return { t in dateValue(t, f).map { $0 >= end } ?? false }
            case .between:
                guard let a = day(r.value), let b = day(r.value2) else { return never }
                let lo = min(a, b)
                guard let hi = cal.date(byAdding: .day, value: 1, to: max(a, b)) else { return never }
                return { t in dateValue(t, f).map { $0 >= lo && $0 < hi } ?? false }
            default: return never
            }
        case .flag:
            let yes = r.op == .yes
            if f == .played {
                let played = ctx.played
                return { t in (t.playCount > 0 || played.contains(t.key)) == yes }
            }
            return { $0.analyzed == yes }
        case .cloud:
            guard let want = SmartAvailability(rawValue: r.value) else { return never }
            let state: @Sendable (Track) -> SmartAvailability = ctx.availability ?? { $0.fileExists ? .local : .missing }
            let neg = r.op != .equals
            return { (state($0) == want) != neg }
        case .expression:
            guard let q = try? SmartQuery.parse(r.value) else { return never }
            let now = ctx.now
            return { q.matches($0, now: now) }
        }
    }

    // MARK: - Alte Smartlists (Regel-Text)

    /// Regel-Text in Zeilen: eine Kette nur aus `&` oder nur aus `|` mit bekannten Vergleichen; sonst eine Zeile
    /// `expression` mit dem ganzen Text (wertet genau wie vorher aus)
    public static func from(query: String) -> SmartRules {
        let raw = SmartRules(rules: [SmartRule(.expression, .matches, query)])
        guard let q = try? SmartQuery.parse(query) else { return raw }
        if case .always = q { return SmartRules() }
        func chain(_ q: SmartQuery, and: Bool) -> [SmartQuery] {
            switch q {
            case let .and(a, b) where and: chain(a, and: true) + chain(b, and: true)
            case let .or(a, b) where !and: chain(a, and: false) + chain(b, and: false)
            default: [q]
            }
        }
        let ands = chain(q, and: true), ors = chain(q, and: false)
        let (parts, match): ([SmartQuery], Match) = ands.count >= ors.count ? (ands, .all) : (ors, .any)
        var rules: [SmartRule] = []
        for p in parts {
            guard let r = rule(p) else { return raw }
            rules.append(r)
        }
        return SmartRules(match: match, rules: rules)
    }

    static func rule(_ q: SmartQuery) -> SmartRule? {
        guard case let .compare(name, op, value) = q else { return nil }
        let textFields: [String: SmartField] = [
            "TITLE": .title, "ARTIST": .artist, "ALBUM": .release, "RELEASE": .release, "LABEL": .label, "GENRE": .genre,
            "REMIXER": .remixer, "PRODUCER": .producer, "MIX": .mix, "CATALOG": .catalog, "COMMENT": .comment,
            "COMMENT2": .comment2, "FILEPATH": .path,
        ]
        let numberFields: [String: SmartField] = [
            "BPM": .bpm, "RATING": .rating, "RANKING": .rating, "COLOR": .color, "PLAYCOUNT": .playCount,
            "BITRATE": .bitrate, "PLAYTIME": .duration, "TIME": .duration,
        ]
        let dateFields: [String: SmartField] = ["IMPORTDATE": .importDate, "RELEASEDATE": .releaseDate, "LASTPLAYED": .lastPlayed]
        func num(_ d: Double) -> String { d == d.rounded() ? String(Int(d)) : String(d) }
        if let f = textFields[name] {
            let v: String
            switch value {
            case let .text(s): v = s
            case let .number(n): v = num(n)
            default: return nil
            }
            let o: SmartOp? = switch op {
                case .contains: .contains
                case .notContains: .notContains
                case .eq: .equals
                case .ne: .isNot
                case .startsWith: .startsWith
                case .endsWith: .endsWith
                default: nil
            }
            return o.map { SmartRule(f, $0, v) }
        }
        if let f = numberFields[name] {
            let v: Double
            switch value {
            case let .number(n): v = n
            case let .text(s): guard let n = Double(s) else { return nil }; v = n
            default: return nil
            }
            let o: SmartOp? = switch op {
                case .eq: .equals
                case .ne: .isNot
                case .gt: .greater
                case .lt: .less
                case .ge: .atLeast
                case .le: .atMost
                default: nil
            }
            // „ist“ / „ist nicht“ vergleicht Tempo und Zeit gerundet, die alte Regel exakt: bleibt Ausdruck
            guard let o, !((f == .bpm || f == .duration) && (o == .equals || o == .isNot)) else { return nil }
            return SmartRule(f, o, num(v))
        }
        if name == "PLAYED" {
            let b: Bool
            switch value {
            case let .bool(x): b = x
            case let .number(n): b = n != 0
            default: return nil
            }
            switch op {
            case .eq: return SmartRule(.played, b ? .yes : .no)
            case .ne: return SmartRule(.played, b ? .no : .yes)
            default: return nil
            }
        }
        if let f = dateFields[name], op == .ge {
            switch value {
            case let .monthsAgo(n): return SmartRule(f, .inLast, String(n), "m")
            case let .daysAgo(n): return SmartRule(f, .inLast, String(n), "d")
            default: return nil
            }
        }
        return nil
    }
}

/// Ergebnis je Text gemerkt (eine Regel, auch über Threads)
final class Memo: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String: Bool] = [:]

    func value(_ s: String, _ f: (String) -> Bool) -> Bool {
        lock.lock()
        if let v = seen[s] { lock.unlock(); return v }
        lock.unlock()
        let v = f(s)
        lock.lock()
        if seen.count < 200_000 { seen[s] = v }
        lock.unlock()
        return v
    }
}
