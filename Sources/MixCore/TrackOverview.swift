import Foundation

/// Kleine Übersicht eines Tracks für die Browser-Vorschau: je Punkt Spitze + Bass-/Mitten-/Höhenanteil (je 1 Byte).
/// 320 Punkte = 1,25 KB je Track, 14k Tracks ≈ 18 MB.
public struct TrackOverview: Equatable, Sendable {
    public static let points = 320

    /// Länge der dekodierten Datei in Sekunden (x-Achse der Übersicht)
    public var duration: Double
    /// je Punkt 4 Bytes: Spitze (0–255 = 0 dBFS), Bass-, Mitten-, Höhenanteil (0–255, Summe ≈ 255)
    public var bytes: [UInt8]

    public init(duration: Double, bytes: [UInt8]) {
        self.duration = duration
        self.bytes = bytes
    }

    public var count: Int { bytes.count / 4 }
    public func peak(_ i: Int) -> Float { Float(bytes[i * 4]) / 255 }
    public func low(_ i: Int) -> Float { Float(bytes[i * 4 + 1]) / 255 }
    public func mid(_ i: Int) -> Float { Float(bytes[i * 4 + 2]) / 255 }
    public func high(_ i: Int) -> Float { Float(bytes[i * 4 + 3]) / 255 }

    /// aus Wellenform-Blöcken (Spitze 0–1, Bandanteile mit Summe 1) – dieselben Blöcke wie die Deck-Wellenform.
    /// Spitze = Maximum der Blöcke eines Punkts, Bänder = Mittelwert.
    public init(peak: [Float], low: [Float], mid: [Float], high: [Float], duration: Double, points: Int = TrackOverview.points) {
        self.duration = duration
        let n = min(peak.count, low.count, mid.count, high.count)
        guard n > 0, points > 0 else { bytes = []; return }
        let q = { (v: Float) -> UInt8 in UInt8(max(0, min(255, (v * 255).rounded()))) }
        var out = [UInt8](repeating: 0, count: points * 4)
        let per = Double(n) / Double(points)
        for p in 0..<points {
            let s = min(n - 1, Int(Double(p) * per)), e = max(s + 1, min(n, Int(Double(p + 1) * per)))
            var pk: Float = 0, lo: Float = 0, mi: Float = 0, hi: Float = 0
            for i in s..<e { pk = max(pk, peak[i]); lo += low[i]; mi += mid[i]; hi += high[i] }
            let c = Float(e - s)
            out[p * 4] = q(pk); out[p * 4 + 1] = q(lo / c); out[p * 4 + 2] = q(mi / c); out[p * 4 + 3] = q(hi / c)
        }
        bytes = out
    }
}

/// Speicher der Übersichten: eine Datei `overviews.bin` (nur angehängt), Schlüssel = Track-Schlüssel, gültig solange
/// Größe und Änderungszeit der Audiodatei gleich sind. Thread-sicher; Lesen/Prüfen läuft nie auf dem Hauptthread.
public final class OverviewStore: @unchecked Sendable {
    /// Größe + Änderungszeit der Audiodatei
    public struct Stamp: Equatable, Sendable {
        public var size: Int64
        public var mtime: Double
        public init(size: Int64, mtime: Double) { self.size = size; self.mtime = mtime }

        public static func of(path: String) -> Stamp? {
            var st = stat()
            guard stat(path, &st) == 0 else { return nil }
            return Stamp(size: Int64(st.st_size), mtime: Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9)
        }
    }

    private struct Entry { var stamp: Stamp; var overview: TrackOverview; var gen: Int }

    public let url: URL?
    private var entries: [String: Entry] = [:]
    /// in dieser Sitzung gegen die Datei geprüft
    private var checked: Set<String> = []
    private var nextGen = 1
    private var records = 0
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "minos741.overviews", qos: .utility)
    /// nach jeder Änderung (neue Übersicht, verworfen) mit dem Track-Schlüssel – beliebiger Thread
    public var onChange: (@Sendable (String) -> Void)?

    static let magic: [UInt8] = Array("MOV1".utf8)

    /// `directory` nil = nur im Speicher
    public init(directory: URL?) {
        url = directory?.appendingPathComponent("overviews.bin")
    }

    /// Datei einlesen (Hintergrund); viele überholte Einträge -> neu geschrieben
    public func load() {
        guard let url, let data = try? Data(contentsOf: url) else { return }
        var loaded: [String: Entry] = [:]
        var n = 0
        Self.parse(data) { key, stamp, ov in
            loaded[key] = Entry(stamp: stamp, overview: ov, gen: 0)
            n += 1
        }
        lock.lock()
        for (k, e) in loaded where entries[k] == nil {
            entries[k] = Entry(stamp: e.stamp, overview: e.overview, gen: nextGen)
            nextGen += 1
        }
        records = n
        let compact = n > 200 && n > entries.count * 2
        lock.unlock()
        if compact { rewrite() }
    }

    public var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }

    /// Stand eines Eintrags ohne Dateiprüfung (für die Zeichen-Schlüssel der Zeilen): Generation + Länge
    public func info(_ key: String) -> (gen: Int, duration: Double)? {
        lock.lock(); defer { lock.unlock() }
        return entries[key].map { ($0.gen, $0.overview.duration) }
    }

    public func contains(_ key: String) -> Bool { lock.lock(); defer { lock.unlock() }; return entries[key] != nil }

    /// Übersicht, wenn die Audiodatei unverändert ist (einmal je Sitzung geprüft); geänderte Datei -> verworfen
    public func overview(_ key: String, path: String) -> TrackOverview? {
        lock.lock()
        guard let e = entries[key] else { lock.unlock(); return nil }
        if checked.contains(key) { lock.unlock(); return e.overview }
        lock.unlock()
        let now = Stamp.of(path: path)
        lock.lock()
        checked.insert(key)
        guard let cur = entries[key] else { lock.unlock(); return nil }
        // Datei fehlt nur gerade (Laufwerk nicht da): behalten
        if now == nil || now == cur.stamp { lock.unlock(); return cur.overview }
        entries[key] = nil
        lock.unlock()
        onChange?(key)
        return nil
    }

    /// gültige Übersicht vorhanden (prüft die Datei)
    public func isValid(_ key: String, path: String) -> Bool { overview(key, path: path) != nil }

    /// neue Übersicht speichern (Stempel der Datei jetzt, falls nicht übergeben)
    public func put(_ key: String, path: String, overview: TrackOverview, stamp: Stamp? = nil) {
        guard let stamp = stamp ?? Stamp.of(path: path), !overview.bytes.isEmpty else { return }
        lock.lock()
        entries[key] = Entry(stamp: stamp, overview: overview, gen: nextGen)
        nextGen += 1
        checked.insert(key)
        records += 1
        lock.unlock()
        onChange?(key)
        guard let url else { return }
        let rec = Self.record(key, stamp, overview)
        queue.async {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) { try? Data(Self.magic).write(to: url) }
            guard let h = try? FileHandle(forWritingTo: url) else { return }
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: rec)
        }
    }

    /// wartet, bis alle Schreibvorgänge durch sind (Tests, Beenden)
    public func flush() { queue.sync {} }

    /// alle gültigen Einträge neu schreiben (atomar)
    private func rewrite() {
        guard let url else { return }
        lock.lock()
        var data = Data(Self.magic)
        for (k, e) in entries { data.append(Self.record(k, e.stamp, e.overview)) }
        records = entries.count
        lock.unlock()
        queue.async { try? data.write(to: url, options: .atomic) }
    }

    // MARK: Dateiformat
    // "MOV1", dann Einträge: u32 Länge des Rests · u16 Schlüssel-Bytes · Schlüssel (UTF-8) · i64 Größe · f64 Änderungszeit ·
    // f64 Dauer · u16 Punkte · Punkte × 4 Bytes. Alles little endian; spätere Einträge ersetzen frühere.

    static func record(_ key: String, _ s: Stamp, _ o: TrackOverview) -> Data {
        let k = Array(key.utf8.prefix(Int(UInt16.max)))
        var body = Data()
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { body.append(contentsOf: $0) } }
        put(UInt16(k.count)); body.append(contentsOf: k)
        put(s.size); put(s.mtime.bitPattern); put(o.duration.bitPattern)
        put(UInt16(o.count)); body.append(contentsOf: o.bytes.prefix(o.count * 4))
        var out = Data()
        withUnsafeBytes(of: UInt32(body.count).littleEndian) { out.append(contentsOf: $0) }
        out.append(body)
        return out
    }

    static func parse(_ data: Data, _ each: (String, Stamp, TrackOverview) -> Void) {
        let b = [UInt8](data)
        guard b.count >= 4, Array(b[0..<4]) == magic else { return }
        var i = 4
        func int<T: FixedWidthInteger>(_ t: T.Type, _ at: inout Int) -> T {
            var v: T = 0
            for j in 0..<MemoryLayout<T>.size { v |= T(b[at + j]) << (8 * j) }
            at += MemoryLayout<T>.size
            return v
        }
        while i + 4 <= b.count {
            var p = i
            let len = Int(int(UInt32.self, &p))
            guard len >= 2, p + len <= b.count else { return }   // abgeschnittener Rest (Absturz beim Schreiben)
            let end = p + len
            let kl = Int(int(UInt16.self, &p))
            guard p + kl + 8 + 8 + 8 + 2 <= end else { return }
            let key = String(decoding: b[p..<(p + kl)], as: UTF8.self)
            p += kl
            let size = int(Int64.self, &p)
            let mtime = Double(bitPattern: int(UInt64.self, &p))
            let dur = Double(bitPattern: int(UInt64.self, &p))
            let n = Int(int(UInt16.self, &p))
            guard p + n * 4 <= end else { return }
            each(key, Stamp(size: size, mtime: mtime), TrackOverview(duration: dur, bytes: Array(b[p..<(p + n * 4)])))
            i = end
        }
    }
}
