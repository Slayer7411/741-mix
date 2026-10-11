import CryptoKit
import Darwin
import Foundation
import MixCore

/// Dekodierter Track als Datei (`.mtrk`, Cache des Datei-Dienstes). Unveränderlich: geschrieben wird in `*.tmp…`,
/// dann `rename`; danach nie wieder angefasst. Eingeblendet wird nur lesend; Aufräumen löscht nur (`unlink`, nie
/// kürzen → kein SIGBUS in einer noch eingeblendeten Datei).
///
/// Aufbau (little endian):
/// ```
/// 0      Kopf 4 KB: 'MTRK', Formatversion, Kopfgröße, Dekoderversion, Rate, Frames, Blöcke, Block-Frames,
///        Quelle (Größe, mtime ns), Dateigröße, 7 Abschnitte (Offset, Länge), Pfad, Schlüssel, Prüfsumme (FNV-1a)
/// 16 K   L[frames] Float32          (Abschnitte auf 16 KB ausgerichtet = Seitengröße Apple Silicon)
///        R[frames] Float32
///        peak / low / mid / high [blocks] Float32
///        spectrum [blocks × 8] UInt8
/// ```
public enum TrackFile {
    public static let magic: UInt32 = 0x4B52_544D   // "MTRK"
    public static let formatVersion: UInt32 = 1
    /// Dekodierung + Wellenform-Analyse: bei jeder Änderung daran hochzählen, alte Dateien gelten dann nicht mehr
    public static let decoderVersion: UInt32 = 1
    public static let headerSize = 4096
    public static let alignment = 16384
    public static let fileExtension = "mtrk"

    public enum Section: Int, CaseIterable, Sendable { case left, right, peak, low, mid, high, spectrum }

    public enum FileError: Error, Equatable, Sendable {
        case io(Int32)
        case tooSmall
        case magic
        case version(UInt32)
        case checksum
        case size
        case layout
        case key
    }

    // MARK: Schlüssel

    /// Quelle eines Cache-Eintrags: Pfad + Größe + mtime + Rate + Dekoderversion. Ändert sich die Datei, ein anderer Schlüssel
    public struct SourceKey: Hashable, Codable, Sendable {
        public var path: String
        public var size: Int64
        public var mtimeNs: Int64
        public var sampleRate: Double
        public var decoderVersion: UInt32

        public init(path: String, size: Int64, mtimeNs: Int64, sampleRate: Double, decoderVersion: UInt32 = TrackFile.decoderVersion) {
            self.path = path; self.size = size; self.mtimeNs = mtimeNs; self.sampleRate = sampleRate; self.decoderVersion = decoderVersion
        }

        /// Schlüssel einer Quelldatei per `stat` – auf einem Musikpfad nur im Datei-Dienst aufrufen (kann hängen)
        public static func of(path: String, sampleRate: Double) throws -> SourceKey {
            var st = stat()
            guard stat(path, &st) == 0 else { throw FileError.io(errno) }
            let mtime = Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)
            return SourceKey(path: path, size: Int64(st.st_size), mtimeNs: mtime, sampleRate: sampleRate)
        }

        /// Dateiname ohne Endung (32 Hex-Zeichen)
        public var name: String {
            let s = "v\(decoderVersion)|\(Int(sampleRate.rounded()))|\(size)|\(mtimeNs)|\(path)"
            return SHA256.hash(data: Data(s.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        }
        public var fileName: String { "\(name).\(TrackFile.fileExtension)" }
    }

    // MARK: Kopf

    public struct Header: Equatable, Sendable {
        public var key: SourceKey
        public var frames: Int
        public var blocks: Int
        public var blockFrames: Int
        public var fileSize: Int
        /// je `Section` (Offset, Länge) in Bytes
        public var offsets: [Int]
        public var lengths: [Int]

        public func range(_ s: Section) -> (offset: Int, length: Int) { (offsets[s.rawValue], lengths[s.rawValue]) }
    }

    static func aligned(_ v: Int) -> Int { (v + alignment - 1) / alignment * alignment }

    /// Abschnitte für einen Track dieser Größe
    static func layout(frames: Int, blocks: Int) -> (offsets: [Int], lengths: [Int], fileSize: Int) {
        let lengths = [frames * 4, frames * 4, blocks * 4, blocks * 4, blocks * 4, blocks * 4, blocks * WaveSpectrum.stride]
        var offsets: [Int] = []
        var at = alignment
        for l in lengths {
            offsets.append(at)
            at = aligned(at + l)
        }
        let end = offsets[lengths.count - 1] + lengths[lengths.count - 1]
        return (offsets, lengths, end)
    }

    private enum Off {
        static let magic = 0, version = 4, headerSize = 8, decoder = 12, rate = 16, frames = 24, blocks = 32
        static let blockFrames = 40, srcSize = 48, srcMtime = 56, fileSize = 64, sectionCount = 72, sections = 80
        static let pathLength = 192, path = 196, pathMax = 3800, keyName = 4000, checksum = 4088
    }

    static func fnv1a(_ p: UnsafeRawBufferPointer) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in p { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return h
    }

    static func encode(_ h: Header) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: headerSize)
        b.withUnsafeMutableBytes { p in
            func put<T>(_ v: T, _ o: Int) { p.storeBytes(of: v, toByteOffset: o, as: T.self) }
            put(magic.littleEndian, Off.magic)
            put(formatVersion.littleEndian, Off.version)
            put(UInt32(headerSize).littleEndian, Off.headerSize)
            put(h.key.decoderVersion.littleEndian, Off.decoder)
            put(h.key.sampleRate.bitPattern.littleEndian, Off.rate)
            put(Int64(h.frames).littleEndian, Off.frames)
            put(Int64(h.blocks).littleEndian, Off.blocks)
            put(Int64(h.blockFrames).littleEndian, Off.blockFrames)
            put(h.key.size.littleEndian, Off.srcSize)
            put(h.key.mtimeNs.littleEndian, Off.srcMtime)
            put(Int64(h.fileSize).littleEndian, Off.fileSize)
            put(UInt32(Section.allCases.count).littleEndian, Off.sectionCount)
            for s in Section.allCases {
                put(Int64(h.offsets[s.rawValue]).littleEndian, Off.sections + s.rawValue * 16)
                put(Int64(h.lengths[s.rawValue]).littleEndian, Off.sections + s.rawValue * 16 + 8)
            }
            let path = Array(h.key.path.utf8)
            put(UInt32(path.count).littleEndian, Off.pathLength)
            for (i, c) in path.prefix(Off.pathMax).enumerated() { p[Off.path + i] = c }
            for (i, c) in Array(h.key.name.utf8).prefix(32).enumerated() { p[Off.keyName + i] = c }
            put(fnv1a(UnsafeRawBufferPointer(rebasing: p[0..<Off.checksum])).littleEndian, Off.checksum)
        }
        return b
    }

    /// Kopf prüfen und lesen; `fileSize` = tatsächliche Dateigröße (fstat)
    static func decode(_ b: UnsafeRawBufferPointer, fileSize: Int) throws -> Header {
        guard b.count >= headerSize, fileSize >= headerSize else { throw FileError.tooSmall }
        func get<T: FixedWidthInteger>(_ o: Int, _: T.Type) -> T { T(littleEndian: b.loadUnaligned(fromByteOffset: o, as: T.self)) }
        guard get(Off.magic, UInt32.self) == magic else { throw FileError.magic }
        let v = get(Off.version, UInt32.self)
        guard v == formatVersion, get(Off.headerSize, UInt32.self) == UInt32(headerSize) else { throw FileError.version(v) }
        guard get(Off.checksum, UInt64.self) == fnv1a(UnsafeRawBufferPointer(rebasing: b[0..<Off.checksum])) else { throw FileError.checksum }
        let rate = Double(bitPattern: get(Off.rate, UInt64.self))
        let frames = Int(get(Off.frames, Int64.self)), blocks = Int(get(Off.blocks, Int64.self))
        let blockFrames = Int(get(Off.blockFrames, Int64.self))
        let size = Int(get(Off.fileSize, Int64.self))
        guard size == fileSize else { throw FileError.size }
        guard rate > 0, rate.isFinite, frames >= 0, blocks >= 1, blockFrames == TrackAudio.blockFrames(sampleRate: rate),
              blocks == frames / blockFrames + 1, get(Off.sectionCount, UInt32.self) == UInt32(Section.allCases.count) else {
            throw FileError.layout
        }
        var offsets: [Int] = [], lengths: [Int] = []
        for s in Section.allCases {
            offsets.append(Int(get(Off.sections + s.rawValue * 16, Int64.self)))
            lengths.append(Int(get(Off.sections + s.rawValue * 16 + 8, Int64.self)))
        }
        // Abschnitte müssen genau dem erwarteten Aufbau entsprechen (ausgerichtet, ohne Überlappung, in der Datei)
        let want = layout(frames: frames, blocks: blocks)
        guard offsets == want.offsets, lengths == want.lengths, want.fileSize == size else { throw FileError.layout }
        let n = Int(get(Off.pathLength, UInt32.self))
        let path = String(decoding: UnsafeRawBufferPointer(rebasing: b[Off.path..<(Off.path + min(n, Off.pathMax))]), as: UTF8.self)
        let key = SourceKey(path: path, size: get(Off.srcSize, Int64.self), mtimeNs: get(Off.srcMtime, Int64.self),
                            sampleRate: rate, decoderVersion: get(Off.decoder, UInt32.self))
        let stored = String(decoding: UnsafeRawBufferPointer(rebasing: b[Off.keyName..<(Off.keyName + 32)]), as: UTF8.self)
        // gekürzter Pfad (sehr lang): Schlüssel aus dem Kopf zählt, Pfad nur zur Anzeige
        if n <= Off.pathMax, stored != key.name { throw FileError.key }
        return Header(key: key, frames: frames, blocks: blocks, blockFrames: blockFrames, fileSize: size, offsets: offsets, lengths: lengths)
    }

    // MARK: Schreiben

    /// Track als `.mtrk` schreiben: erst `<ziel>.tmp-<pid>-<zufall>`, Barriere, dann `rename` auf das Ziel.
    /// Liefert die Dateigröße. Bei einem Fehler bleibt nichts liegen
    @discardableResult
    public static func write(_ a: TrackAudio, key: SourceKey, to url: URL) throws -> Int {
        let blocks = a.peak.count
        precondition(a.low.count == blocks && a.mid.count == blocks && a.high.count == blocks)
        let l = layout(frames: a.frames, blocks: blocks)
        let header = Header(key: key, frames: a.frames, blocks: blocks, blockFrames: TrackAudio.blockFrames(sampleRate: a.sampleRate),
                            fileSize: l.fileSize, offsets: l.offsets, lengths: l.lengths)
        guard header.blocks == a.frames / header.blockFrames + 1, key.sampleRate == a.sampleRate else { throw FileError.layout }
        let tmp = url.path + ".tmp-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
        let fd = open(tmp, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw FileError.io(errno) }
        var ok = false
        defer {
            close(fd)
            if !ok { unlink(tmp) }
        }
        guard ftruncate(fd, off_t(l.fileSize)) == 0 else { throw FileError.io(errno) }
        func put(_ p: UnsafeRawPointer, _ count: Int, at offset: Int) throws {
            var done = 0
            while done < count {
                let n = pwrite(fd, p + done, min(count - done, 1 << 26), off_t(offset + done))
                if n < 0 { if errno == EINTR { continue }; throw FileError.io(errno) }
                done += n
            }
        }
        try put(a.left, l.lengths[0], at: l.offsets[0])
        try put(a.right, l.lengths[1], at: l.offsets[1])
        for (k, band) in [a.peak, a.low, a.mid, a.high].enumerated() where blocks > 0 {
            try put(band.baseAddress!, l.lengths[2 + k], at: l.offsets[2 + k])
        }
        // Spektrum fehlt (sehr kurzer Track) -> Nullen (Datei ist schon so groß angelegt)
        if a.spectrum.data.count == l.lengths[6] {
            try a.spectrum.data.withUnsafeBytes { try put($0.baseAddress!, $0.count, at: l.offsets[6]) }
        }
        try encode(header).withUnsafeBytes { try put($0.baseAddress!, $0.count, at: 0) }
        // Reihenfolge sichern: Daten vor dem rename auf der Platte (billiger als F_FULLFSYNC, reicht für einen Cache)
        if fcntl(fd, F_BARRIERFSYNC) != 0 { fsync(fd) }
        guard rename(tmp, url.path) == 0 else { throw FileError.io(errno) }
        ok = true
        return l.fileSize
    }

    /// nur den Kopf lesen und prüfen (Index-Aufbau, Treffer-Prüfung) – blendet nichts ein
    public static func readHeader(_ url: URL) throws -> Header {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw FileError.io(errno) }
        defer { close(fd) }
        return try readHeader(fd: fd)
    }

    static func readHeader(fd: Int32) throws -> Header {
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw FileError.io(errno) }
        var b = [UInt8](repeating: 0, count: headerSize)
        let n = b.withUnsafeMutableBytes { pread(fd, $0.baseAddress, headerSize, 0) }
        guard n == headerSize else { throw n < 0 ? FileError.io(errno) : FileError.tooSmall }
        return try b.withUnsafeBytes { try decode($0, fileSize: Int(st.st_size)) }
    }

    // MARK: Einblenden

    /// Datei nur lesend eingeblendet. Ausgeblendet wird im deinit – also erst, wenn niemand mehr die `TrackAudio`
    /// hält (der Steuerkern hält sie, bis der Audio-Thread den Puffer nicht mehr liest)
    public final class Mapping: @unchecked Sendable {
        public let header: Header
        public let base: UnsafeRawPointer
        public let length: Int
        private let lockState = NSLock()
        private var isLocked = false

        init(header: Header, base: UnsafeRawPointer, length: Int) {
            self.header = header; self.base = base; self.length = length
        }

        deinit { munmap(UnsafeMutableRawPointer(mutating: base), length) }

        public var locked: Bool { lockState.withLock { isLocked } }

        /// Audiodaten (L + R + Wellenform) im Speicher festhalten, bevor der Kern sie bekommt: der Audio-Thread darf
        /// nie auf eine Seite von der Platte warten. Läuft auf einem Hintergrund-Thread (liest die Datei einmal ganz).
        /// Geht `mlock` nicht (Grenze für festen Speicher), werden die Seiten wenigstens einmal gelesen. Liefert, ob fest
        @discardableResult
        public func lock() -> Bool {
            if locked { return true }
            let start = header.offsets[Section.left.rawValue]
            let p = base + start, n = length - start
            if mlock(p, n) == 0 {
                lockState.withLock { isLocked = true }
                return true
            }
            madvise(UnsafeMutableRawPointer(mutating: p), n, MADV_WILLNEED)
            var sum: UInt8 = 0
            for o in stride(from: 0, to: n, by: 4096) { sum &+= p.load(fromByteOffset: o, as: UInt8.self) }
            withExtendedLifetime(sum) {}
            return false
        }
    }

    /// Datei einblenden (Pfad); `expect` = erwarteter Schlüssel (sonst `.key`)
    public static func map(_ url: URL, expect: SourceKey? = nil) throws -> Mapping {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw FileError.io(errno) }
        defer { close(fd) }
        return try map(fd: fd, expect: expect)
    }

    /// geöffnete Datei einblenden (z. B. per SCM_RIGHTS bekommen); der Aufrufer schließt `fd`, die Abbildung bleibt
    public static func map(fd: Int32, expect: SourceKey? = nil) throws -> Mapping {
        let h = try readHeader(fd: fd)
        if let expect, expect.name != h.key.name { throw FileError.key }
        guard let p = mmap(nil, h.fileSize, PROT_READ, MAP_SHARED, fd, 0), p != MAP_FAILED else { throw FileError.io(errno) }
        return Mapping(header: h, base: UnsafeRawPointer(p), length: h.fileSize)
    }

    /// `TrackAudio` als Sicht auf die Abbildung (kein Kopieren der Audiodaten; nur das Spektrum, ~1 MB, wird kopiert)
    public static func audio(_ m: Mapping) -> TrackAudio {
        let h = m.header
        func floats(_ s: Section) -> UnsafeBufferPointer<Float> {
            let r = h.range(s)
            return UnsafeBufferPointer(start: (m.base + r.offset).assumingMemoryBound(to: Float.self), count: r.length / 4)
        }
        let sr = h.range(.spectrum)
        let spectrum = WaveSpectrum(data: Array(UnsafeRawBufferPointer(start: m.base + sr.offset, count: sr.length)))
        return TrackAudio(left: floats(.left).baseAddress!, right: floats(.right).baseAddress!, frames: h.frames,
                          sampleRate: h.key.sampleRate, peak: floats(.peak), low: floats(.low), mid: floats(.mid),
                          high: floats(.high), spectrum: spectrum, owner: m)
    }
}
