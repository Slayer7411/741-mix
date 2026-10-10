import Foundation

/// Smartlist-Regeln (NML-Syntax), z. B. `$COMMENT % "hain" & $IMPORTDATE >= MONTHS_AGO(12)`.
/// `&` bindet stärker als `|`; Klammern und `!` werden zusätzlich unterstützt.
public indirect enum SmartQuery: Sendable {
    case and(SmartQuery, SmartQuery)
    case or(SmartQuery, SmartQuery)
    case not(SmartQuery)
    case compare(field: String, op: Op, value: Value)
    case always

    public enum Op: String, Sendable { case contains = "%", notContains = "!%", eq = "==", ne = "!=",
                                       ge = ">=", le = "<=", gt = ">", lt = "<", startsWith = "STARTS_WITH" }
    public enum Value: Sendable { case text(String), number(Double), bool(Bool), monthsAgo(Int), daysAgo(Int) }

    public struct ParseError: Error, CustomStringConvertible { public let description: String }

    public static func parse(_ s: String) throws -> SmartQuery {
        var p = Parser(tokens: try tokenize(s))
        if p.tokens.isEmpty { return .always }
        let q = try p.parseOr()
        guard p.pos == p.tokens.count else { throw ParseError(description: "Unerwartetes Ende bei \(p.tokens[p.pos])") }
        return q
    }

    public func matches(_ t: Track, now: Date = Date()) -> Bool {
        switch self {
        case .always: return true
        case let .and(a, b): return a.matches(t, now: now) && b.matches(t, now: now)
        case let .or(a, b): return a.matches(t, now: now) || b.matches(t, now: now)
        case let .not(a): return !a.matches(t, now: now)
        case let .compare(field, op, value): return Self.compare(t, field, op, value, now)
        }
    }

    // MARK: - Auswertung

    enum FieldValue { case text(String), number(Double), date(Date?) }

    static func fieldValue(_ t: Track, _ f: String) -> FieldValue {
        switch f {
        case "TITLE": .text(t.title)
        case "ARTIST": .text(t.artist)
        case "ALBUM", "RELEASE": .text(t.album)
        case "LABEL": .text(t.label)
        case "GENRE": .text(t.genre)
        case "REMIXER": .text(t.remixer)
        case "PRODUCER": .text(t.producer)
        case "COMMENT": .text(t.comment)
        case "COMMENT2": .text(t.comment2)
        case "KEY", "KEYTEXT": .text(t.keyText)
        case "FILEPATH": .text(t.path)
        case "FILENAME": .text(t.fileName)
        case "BPM": .number(t.bpm)
        case "RATING", "RANKING": .number(Double(t.rating))
        case "COLOR": .number(Double(t.color))
        case "PLAYCOUNT": .number(Double(t.playCount))
        case "PLAYED": .number(t.playCount > 0 ? 1 : 0)
        case "BITRATE": .number(Double(t.bitrate))
        case "PLAYTIME", "TIME": .number(t.duration)
        case "FILESTATE": .number(t.fileExists ? 1 : 2)
        case "IMPORTDATE": .date(t.importDate)
        case "RELEASEDATE": .date(t.releaseDate)
        case "LASTPLAYED": .date(t.lastPlayed)
        default: .text("")
        }
    }

    static func compare(_ t: Track, _ f: String, _ op: Op, _ v: Value, _ now: Date) -> Bool {
        let cal = Calendar(identifier: .gregorian)
        switch (fieldValue(t, f), v) {
        case let (.text(a), .text(b)):
            switch op {
            case .contains: return a.localizedCaseInsensitiveContains(b)
            case .notContains: return !a.localizedCaseInsensitiveContains(b)
            case .eq: return a.caseInsensitiveCompare(b) == .orderedSame
            case .ne: return a.caseInsensitiveCompare(b) != .orderedSame
            case .startsWith: return a.lowercased().hasPrefix(b.lowercased())
            case .ge: return a >= b
            case .le: return a <= b
            case .gt: return a > b
            case .lt: return a < b
            }
        case let (.number(a), _):
            let b: Double = switch v {
                case let .number(n): n
                case let .bool(x): x ? 1 : 0
                case let .text(s): Double(s) ?? 0
                default: 0
            }
            return cmp(a, b, op)
        case let (.date(a), _):
            let b: Date? = switch v {
                case let .monthsAgo(n): cal.date(byAdding: .month, value: -n, to: now)
                case let .daysAgo(n): cal.date(byAdding: .day, value: -n, to: now)
                case let .text(s): NMLParser.date(s)
                default: nil
            }
            guard let a, let b else { return op == .ne }
            return cmp(a.timeIntervalSince1970, b.timeIntervalSince1970, op)
        default:
            return false
        }
    }

    static func cmp(_ a: Double, _ b: Double, _ op: Op) -> Bool {
        switch op {
        case .eq, .contains, .startsWith: a == b
        case .ne, .notContains: a != b
        case .ge: a >= b
        case .le: a <= b
        case .gt: a > b
        case .lt: a < b
        }
    }

    // MARK: - Lexer/Parser

    enum Token: Equatable, CustomStringConvertible {
        case field(String), op(Op), text(String), number(Double), ident(String), and, or, not, lparen, rparen
        var description: String { "\(self)" }
    }

    static func tokenize(_ s: String) throws -> [Token] {
        var out: [Token] = []
        let c = Array(s)
        var i = 0
        while i < c.count {
            let ch = c[i]
            if ch.isWhitespace { i += 1; continue }
            switch ch {
            case "&": out.append(.and); i += 1
            case "|": out.append(.or); i += 1
            case "(": out.append(.lparen); i += 1
            case ")": out.append(.rparen); i += 1
            case "%": out.append(.op(.contains)); i += 1
            case "\"":
                var j = i + 1, str = ""
                while j < c.count, c[j] != "\"" { str.append(c[j]); j += 1 }
                guard j < c.count else { throw ParseError(description: "Anführungszeichen nicht geschlossen") }
                out.append(.text(str)); i = j + 1
            case "$":
                var j = i + 1, name = ""
                while j < c.count, c[j].isLetter || c[j].isNumber || c[j] == "_" { name.append(c[j]); j += 1 }
                out.append(.field(name.uppercased())); i = j
            case "!", "=", ">", "<":
                let two = i + 1 < c.count ? String(c[i...i + 1]) : String(ch)
                if let op = Op(rawValue: two) { out.append(.op(op)); i += 2 }
                else if ch == "!" { out.append(.not); i += 1 }
                else if ch == "=" { out.append(.op(.eq)); i += 1 }
                else if let op = Op(rawValue: String(ch)) { out.append(.op(op)); i += 1 }
                else { throw ParseError(description: "Unbekanntes Zeichen \(ch)") }
            default:
                if ch.isNumber || ch == "-" || ch == "." {
                    var j = i, num = ""
                    while j < c.count, c[j].isNumber || c[j] == "." || c[j] == "-" { num.append(c[j]); j += 1 }
                    out.append(.number(Double(num) ?? 0)); i = j
                } else if ch.isLetter {
                    var j = i, w = ""
                    while j < c.count, c[j].isLetter || c[j] == "_" { w.append(c[j]); j += 1 }
                    if w.uppercased() == "STARTS_WITH" { out.append(.op(.startsWith)) } else { out.append(.ident(w.uppercased())) }
                    i = j
                } else {
                    throw ParseError(description: "Unbekanntes Zeichen \(ch)")
                }
            }
        }
        return out
    }

    struct Parser {
        let tokens: [Token]
        var pos = 0
        var peek: Token? { pos < tokens.count ? tokens[pos] : nil }
        mutating func next() -> Token? { defer { pos += 1 }; return peek }

        mutating func parseOr() throws -> SmartQuery {
            var l = try parseAnd()
            while peek == .or { pos += 1; l = .or(l, try parseAnd()) }
            return l
        }
        mutating func parseAnd() throws -> SmartQuery {
            var l = try parseUnary()
            while peek == .and { pos += 1; l = .and(l, try parseUnary()) }
            return l
        }
        mutating func parseUnary() throws -> SmartQuery {
            switch next() {
            case .not: return .not(try parseUnary())
            case .lparen:
                let q = try parseOr()
                guard next() == .rparen else { throw ParseError(description: "Klammer fehlt") }
                return q
            case let .field(f):
                guard case let .op(op)? = next() else { throw ParseError(description: "Operator fehlt nach $\(f)") }
                return .compare(field: f, op: op, value: try parseValue())
            case let t: throw ParseError(description: "Unerwartet: \(String(describing: t))")
            }
        }
        mutating func parseValue() throws -> Value {
            switch next() {
            case let .text(s): return .text(s)
            case let .number(n): return .number(n)
            case .ident("TRUE"): return .bool(true)
            case .ident("FALSE"): return .bool(false)
            case let .ident(fn) where fn == "MONTHS_AGO" || fn == "DAYS_AGO":
                guard next() == .lparen, case let .number(n)? = next(), next() == .rparen else {
                    throw ParseError(description: "\(fn)(n) erwartet")
                }
                return fn == "MONTHS_AGO" ? .monthsAgo(Int(n)) : .daysAgo(Int(n))
            case let t: throw ParseError(description: "Wert erwartet, gefunden \(String(describing: t))")
            }
        }
    }
}
