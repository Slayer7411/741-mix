import Foundation

/// Clip-Analyse-Datei einer DAW (`<audiodatei>.asd`), nur lesen. Aufbau (an echten Dateien geprüft):
/// Kopf mit Tabelle, dann ein Block mit Kennung `AB 1E 56 78`, Version (1 Byte), Länge (u32), Wurzel-Klasse
/// (`00`, Länge u8, ASCII `SampleData`), Zahl der Klassen (u32) und je Klasse: `00`, Name (u8 + ASCII), Feldzahl (i32,
/// negativ = Liste / Feld variabler Länge), je Feld Name (u32 Zeichen + UTF-16LE) und Typ (1 Byte; `00` + Name = Klasse).
/// Danach die Daten der Wurzel in Feldreihenfolge, Klassen-Felder eingebettet. Liste: Anzahl (u32), je Eintrag
/// `00` + Klassenname, Kennung (u32), Felder. `WarpMarker` = SecTime, BeatTime (je f64).
public enum ClipAnalysisFile {
    public struct Info: Equatable, Sendable {
        public var version: Int
        public var markers: [WarpMarker]
        public var isWarped: Bool?
        /// Taktart (Zähler), nil = nicht gelesen
        public var beatsPerBar: Double?
    }

    public enum ParseError: Error, Equatable {
        /// keine Clip-Analyse-Datei (Kennung oder Wurzel fehlt)
        case notClipAnalysis
        /// Aufbau unerwartet (abgeschnitten, Feldtypen unbekannt)
        case malformed(String)
    }

    static let magic: [UInt8] = [0xAB, 0x1E, 0x56, 0x78]
    static let root = "SampleData"

    /// Datei neben der Audiodatei (`/a/b.wav` -> `/a/b.wav.asd`)
    public static func sidecar(for audioPath: String) -> URL { URL(fileURLWithPath: audioPath + ".asd") }

    public static func parse(url: URL) throws -> Info { try parse(Data(contentsOf: url, options: .mappedIfSafe)) }

    public static func parse(_ data: Data) throws -> Info {
        try data.withUnsafeBytes { raw in
            var r = Reader(b: raw.bindMemory(to: UInt8.self))
            return try parse(&r)
        }
    }

    // MARK: intern

    enum FieldType: Equatable {
        case f64, bool, i32, f32
        case other(UInt8)
        case object(String)
        var size: Int? {
            switch self {
            case .f64: 8
            case .bool: 1
            case .i32, .f32: 4
            default: nil
            }
        }
    }
    struct Field { var name: String; var type: FieldType }
    struct Class { var count: Int; var fields: [Field] }

    struct Reader {
        let b: UnsafeBufferPointer<UInt8>
        var p = 0
        mutating func need(_ n: Int) throws {
            guard n >= 0, p + n <= b.count else { throw ParseError.malformed("abgeschnitten bei \(p)") }
        }
        mutating func u8() throws -> UInt8 { try need(1); defer { p += 1 }; return b[p] }
        mutating func u32() throws -> UInt32 {
            try need(4); defer { p += 4 }
            return UInt32(b[p]) | UInt32(b[p + 1]) << 8 | UInt32(b[p + 2]) << 16 | UInt32(b[p + 3]) << 24
        }
        mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }
        mutating func f64() throws -> Double {
            try need(8); defer { p += 8 }
            var v: UInt64 = 0
            for i in 0..<8 { v |= UInt64(b[p + i]) << (8 * i) }
            return Double(bitPattern: v)
        }
        mutating func f32() throws -> Float { Float(bitPattern: try u32()) }
        mutating func ascii(_ n: Int) throws -> String {
            try need(n); defer { p += n }
            return String(decoding: UnsafeBufferPointer(rebasing: b[p..<(p + n)]), as: UTF8.self)
        }
        mutating func utf16(_ chars: Int) throws -> String {
            guard chars <= 1024 else { throw ParseError.malformed("Feldname zu lang bei \(p)") }
            try need(2 * chars); defer { p += 2 * chars }
            var u: [UInt16] = []
            u.reserveCapacity(chars)
            for i in 0..<chars { u.append(UInt16(b[p + 2 * i]) | UInt16(b[p + 2 * i + 1]) << 8) }
            return String(decoding: u, as: UTF16.self)
        }
        /// `00` + Länge (u8) + ASCII
        mutating func className() throws -> String {
            guard try u8() == 0 else { throw ParseError.malformed("Klassenname erwartet bei \(p - 1)") }
            return try ascii(Int(try u8()))
        }
        /// erste Stelle der Kennung + Wurzel ab `from`
        func findBlock() -> Int? {
            let m = ClipAnalysisFile.magic, rootBytes = Array(ClipAnalysisFile.root.utf8)
            guard b.count >= 16 else { return nil }
            var i = 0
            while i + 11 + rootBytes.count <= b.count {
                if b[i] == m[0], b[i + 1] == m[1], b[i + 2] == m[2], b[i + 3] == m[3],
                   b[i + 9] == 0, Int(b[i + 10]) == rootBytes.count,
                   rootBytes.indices.allSatisfy({ b[i + 11 + $0] == rootBytes[$0] }) { return i }
                i += 1
            }
            return nil
        }
    }

    static func parse(_ r: inout Reader) throws -> Info {
        guard let start = r.findBlock() else { throw ParseError.notClipAnalysis }
        r.p = start + 4
        let version = Int(try r.u8())
        _ = try r.u32()
        let rootName = try r.className()
        let n = Int(try r.u32())
        guard rootName == root, n > 0, n <= 4096 else { throw ParseError.malformed("Klassenzahl \(n)") }
        var classes: [String: Class] = [:]
        for _ in 0..<n {
            let name = try r.className()
            let count = Int(try r.i32())
            guard count <= 4096 else { throw ParseError.malformed("Feldzahl \(count) in \(name)") }
            var fields: [Field] = []
            for _ in 0..<max(0, count) {
                let fname = try r.utf16(Int(try r.u32()))
                let t = try r.u8()
                let type: FieldType = switch t {
                    case 0x00: .object(try r.ascii(Int(try r.u8())))
                    case 0x17: .f64
                    case 0x10: .bool
                    case 0x11: .i32
                    case 0x12: .f32
                    default: .other(t)
                }
                fields.append(Field(name: fname, type: type))
            }
            classes[name] = Class(count: count, fields: fields)
        }
        guard let sample = classes[root], sample.fields.contains(where: { $0.name == "WarpMarkers" }) else {
            throw ParseError.malformed("\(root) ohne WarpMarkers")
        }
        if let wm = classes["WarpMarker"] {
            let names = wm.fields.map(\.name), types = wm.fields.map(\.type)
            guard names.starts(with: ["SecTime", "BeatTime"]), types.starts(with: [.f64, .f64]) else {
                throw ParseError.malformed("WarpMarker-Felder \(names)")
            }
        }
        // Daten der Wurzel bis einschließlich WarpMarkers (alles davor hat feste Länge)
        var info = Info(version: version, markers: [])
        var values: [String: Double] = [:]
        func walk(_ cls: Class, path: String, depth: Int) throws -> Bool {
            guard depth < 16 else { throw ParseError.malformed("zu tief verschachtelt") }
            for f in cls.fields {
                let key = path.isEmpty ? f.name : path + "." + f.name
                if path.isEmpty, f.name == "WarpMarkers" {
                    info.markers = try markers(&r, classes)
                    return true
                }
                switch f.type {
                case .f64: values[key] = try r.f64()
                case .bool: values[key] = Double(try r.u8())
                case .i32: values[key] = Double(try r.i32())
                case .f32: values[key] = Double(try r.f32())
                case .other: throw ParseError.malformed("Feld \(key) mit variabler Länge vor WarpMarkers")
                case let .object(c):
                    guard let sub = classes[c], sub.count >= 0 else { throw ParseError.malformed("Klasse \(c) für \(key)") }
                    if try walk(sub, path: key, depth: depth + 1) { return true }
                }
            }
            return false
        }
        guard try walk(sample, path: "", depth: 0) else { throw ParseError.malformed("WarpMarkers nicht erreicht") }
        info.isWarped = values["IsWarped.Value"].map { $0 != 0 }
        info.beatsPerBar = values["TimeSignature.Numerator.Value"].flatMap { $0 >= 1 && $0 <= 32 ? $0 : nil }
        return info
    }

    static func markers(_ r: inout Reader, _ classes: [String: Class]) throws -> [WarpMarker] {
        let n = Int(try r.u32())
        guard n <= 100_000 else { throw ParseError.malformed("\(n) Warp-Marker") }
        guard n > 0 else { return [] }
        guard let cls = classes["WarpMarker"] else { throw ParseError.malformed("WarpMarker nicht beschrieben") }
        var out: [WarpMarker] = []
        out.reserveCapacity(n)
        for _ in 0..<n {
            guard try r.className() == "WarpMarker" else { throw ParseError.malformed("Listeneintrag ist kein WarpMarker") }
            _ = try r.u32()   // Kennung
            let sec = try r.f64(), beat = try r.f64()
            for f in cls.fields.dropFirst(2) {   // spätere Versionen: weitere Felder fester Länge
                guard let s = f.type.size else { throw ParseError.malformed("WarpMarker-Feld \(f.name)") }
                try r.need(s); r.p += s
            }
            out.append(WarpMarker(sec: sec, beat: beat))
        }
        return out
    }
}
