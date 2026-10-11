import Darwin
import Foundation

/// Steuer-Ebene zwischen Prozessen: Unix-Socket (Stream), Nachrichten mit Kopf, optional ein fd je Nachricht
/// (SCM_RIGHTS). Nur für Start, Aufträge, Übergabe von Dateien und Zustand – nie für Audiodaten.
///
/// Kopf (12 Bytes, little endian): 'MIPC', Typ (u16), Version (u16), Länge (u32), danach die Nutzlast.
/// Ein mitgeschickter fd hängt am ersten Byte des Kopfs.
public final class Channel: @unchecked Sendable {
    public static let magic: UInt32 = 0x4350_494D   // "MIPC"
    public static let headerSize = 12
    public static let maxPayload = 1 << 20

    public struct Frame: Sendable {
        public var type: UInt16
        public var version: UInt16
        public var payload: [UInt8]
        /// mitgeschickter fd (gehört dem Empfänger, der ihn schließt)
        public var fd: Int32?

        public func decode<T: Decodable>(_: T.Type) throws -> T {
            try JSONDecoder().decode(T.self, from: Data(payload))
        }
    }

    public enum ChannelError: Error, Equatable, Sendable {
        case closed
        case io(Int32)
        case magic
        case tooLarge(Int)
    }

    public let fd: Int32
    private let sendLock = NSLock()
    private let stateLock = NSLock()
    private var isClosed = false

    public init(fd: Int32) {
        self.fd = fd
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit { close() }

    /// verbundenes Paar: eigener Kanal + fd für das Kind (beide close-on-exec; das Kind bekommt seinen per dup2)
    public static func pair() throws -> (Channel, Int32) {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw ChannelError.io(errno) }
        for f in fds { _ = fcntl(f, F_SETFD, FD_CLOEXEC) }
        return (Channel(fd: fds[0]), fds[1])
    }

    public var closed: Bool { stateLock.withLock { isClosed } }

    public func close() {
        let first: Bool = stateLock.withLock {
            defer { isClosed = true }
            return !isClosed
        }
        if first { Darwin.close(fd) }
    }

    /// beendet ein blockiertes `receive` auf einem anderen Thread (fd bleibt bis `close` gültig)
    public func shutdown() { _ = Darwin.shutdown(fd, SHUT_RDWR) }

    // MARK: Senden

    public func send<T: Encodable>(_ type: UInt16, _ value: T, version: UInt16 = 1, fd pass: Int32? = nil) throws {
        try send(type, version: version, payload: Array(try JSONEncoder().encode(value)), fd: pass)
    }

    public func send(_ type: UInt16, version: UInt16 = 1, payload: [UInt8] = [], fd pass: Int32? = nil) throws {
        guard payload.count <= Self.maxPayload else { throw ChannelError.tooLarge(payload.count) }
        var buf = [UInt8](repeating: 0, count: Self.headerSize + payload.count)
        buf.withUnsafeMutableBytes { p in
            p.storeBytes(of: Self.magic.littleEndian, toByteOffset: 0, as: UInt32.self)
            p.storeBytes(of: type.littleEndian, toByteOffset: 4, as: UInt16.self)
            p.storeBytes(of: version.littleEndian, toByteOffset: 6, as: UInt16.self)
            p.storeBytes(of: UInt32(payload.count).littleEndian, toByteOffset: 8, as: UInt32.self)
        }
        buf.replaceSubrange(Self.headerSize..., with: payload)
        try sendLock.withLock {
            guard !closed else { throw ChannelError.closed }
            var done = try buf.withUnsafeBytes { try sendFirst($0, pass: pass) }
            while done < buf.count {
                let n = buf.withUnsafeBytes { Darwin.send(fd, $0.baseAddress! + done, $0.count - done, 0) }
                if n < 0 {
                    if errno == EINTR { continue }
                    throw errno == EPIPE ? ChannelError.closed : ChannelError.io(errno)
                }
                done += n
            }
        }
    }

    /// erster Teil per sendmsg, mit fd als Kontrollnachricht
    private func sendFirst(_ data: UnsafeRawBufferPointer, pass: Int32?) throws -> Int {
        var iov = iovec(iov_base: UnsafeMutableRawPointer(mutating: data.baseAddress), iov_len: data.count)
        let space = Self.cmsgSpace(1)
        let control = UnsafeMutableRawPointer.allocate(byteCount: space, alignment: 8)
        defer { control.deallocate() }
        if let pass {
            memset(control, 0, space)
            control.storeBytes(of: socklen_t(Self.cmsgLen(1)), toByteOffset: 0, as: socklen_t.self)
            control.storeBytes(of: SOL_SOCKET, toByteOffset: 4, as: Int32.self)
            control.storeBytes(of: SCM_RIGHTS, toByteOffset: 8, as: Int32.self)
            control.storeBytes(of: pass, toByteOffset: Self.cmsgHeader, as: Int32.self)
        }
        while true {
            let n = withUnsafeMutablePointer(to: &iov) { iovp -> Int in
                var msg = msghdr()
                msg.msg_iov = iovp
                msg.msg_iovlen = 1
                if pass != nil {
                    msg.msg_control = control
                    msg.msg_controllen = socklen_t(space)
                }
                return sendmsg(fd, &msg, 0)
            }
            if n >= 0 { return n }
            if errno == EINTR { continue }
            throw errno == EPIPE ? ChannelError.closed : ChannelError.io(errno)
        }
    }

    // MARK: Empfangen

    /// blockiert bis zur nächsten ganzen Nachricht; `.closed` = Gegenseite weg
    public func receive() throws -> Frame {
        var head = [UInt8](repeating: 0, count: Self.headerSize)
        var fds: [Int32] = []
        var got = 0
        do {
            while got < Self.headerSize {
                let n = try head.withUnsafeMutableBytes { try receivePart($0.baseAddress! + got, $0.count - got, &fds) }
                if n == 0 { throw ChannelError.closed }
                got += n
            }
        } catch {
            fds.forEach { Darwin.close($0) }
            throw error
        }
        let (magic, type, version, length) = head.withUnsafeBytes { p in
            (UInt32(littleEndian: p.loadUnaligned(fromByteOffset: 0, as: UInt32.self)),
             UInt16(littleEndian: p.loadUnaligned(fromByteOffset: 4, as: UInt16.self)),
             UInt16(littleEndian: p.loadUnaligned(fromByteOffset: 6, as: UInt16.self)),
             Int(UInt32(littleEndian: p.loadUnaligned(fromByteOffset: 8, as: UInt32.self))))
        }
        guard magic == Self.magic else { fds.forEach { Darwin.close($0) }; throw ChannelError.magic }
        guard length <= Self.maxPayload else { fds.forEach { Darwin.close($0) }; throw ChannelError.tooLarge(length) }
        var payload = [UInt8](repeating: 0, count: length)
        got = 0
        while got < length {
            let n = payload.withUnsafeMutableBytes { recv(fd, $0.baseAddress! + got, length - got, 0) }
            if n < 0, errno == EINTR { continue }
            if n <= 0 { fds.forEach { Darwin.close($0) }; throw n == 0 ? ChannelError.closed : ChannelError.io(errno) }
            got += n
        }
        // mehr als ein fd je Nachricht ist kein gültiger Aufbau: überzählige schließen
        for extra in fds.dropFirst() { Darwin.close(extra) }
        return Frame(type: type, version: version, payload: payload, fd: fds.first)
    }

    private func receivePart(_ p: UnsafeMutableRawPointer, _ count: Int, _ fds: inout [Int32]) throws -> Int {
        let space = Self.cmsgSpace(4)
        let control = UnsafeMutableRawPointer.allocate(byteCount: space, alignment: 8)
        defer { control.deallocate() }
        var iov = iovec(iov_base: p, iov_len: count)
        while true {
            memset(control, 0, space)
            var controlLength = 0
            let n = withUnsafeMutablePointer(to: &iov) { iovp -> Int in
                var msg = msghdr()
                msg.msg_iov = iovp
                msg.msg_iovlen = 1
                msg.msg_control = control
                msg.msg_controllen = socklen_t(space)
                let n = recvmsg(fd, &msg, 0)
                controlLength = Int(msg.msg_controllen)
                return n
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw errno == ECONNRESET ? ChannelError.closed : ChannelError.io(errno)
            }
            // Kontrollnachrichten durchgehen (eine SCM_RIGHTS mit bis zu 4 fds)
            var off = 0
            let total = controlLength
            while off + Self.cmsgHeader <= total {
                let len = Int(control.load(fromByteOffset: off, as: socklen_t.self))
                let level = control.load(fromByteOffset: off + 4, as: Int32.self)
                let type = control.load(fromByteOffset: off + 8, as: Int32.self)
                guard len >= Self.cmsgHeader, off + len <= total else { break }
                if level == SOL_SOCKET, type == SCM_RIGHTS {
                    let count = (len - Self.cmsgHeader) / 4
                    for i in 0..<count {
                        let f = control.load(fromByteOffset: off + Self.cmsgHeader + i * 4, as: Int32.self)
                        _ = fcntl(f, F_SETFD, FD_CLOEXEC)
                        fds.append(f)
                    }
                }
                off += Self.align(len)
            }
            return n
        }
    }

    // MARK: cmsg (Darwin: Kopf 12 Bytes, Ausrichtung 4)

    static let cmsgHeader = align(MemoryLayout<socklen_t>.size + 2 * MemoryLayout<Int32>.size)
    static func align(_ n: Int) -> Int { (n + 3) & ~3 }
    static func cmsgLen(_ fds: Int) -> Int { cmsgHeader + fds * 4 }
    static func cmsgSpace(_ fds: Int) -> Int { cmsgHeader + align(fds * 4) }
}

extension Channel {
    /// im Kind: vom Elternprozess geerbter Kanal (`Helper.fdVariable`)
    public static func inherited() -> Channel? {
        guard let s = ProcessInfo.processInfo.environment[Helper.fdVariable], let fd = Int32(s),
              fcntl(fd, F_GETFD) != -1 else { return nil }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        return Channel(fd: fd)
    }
}

/// erste Nachricht jeder Seite: Dienst, Protokollversion, Build. Andere Hauptversion -> Verbindung abgelehnt
public struct Handshake: Codable, Equatable, Sendable {
    public static let type: UInt16 = 1
    public var service: String
    public var major: Int
    public var minor: Int
    public var build: String
    public var pid: Int32

    public init(service: String, major: Int, minor: Int, build: String = Handshake.currentBuild) {
        self.service = service; self.major = major; self.minor = minor; self.build = build; pid = getpid()
    }

    /// Größe + Änderungszeit der eigenen Datei: Helfer und App aus verschiedenen Builds fallen im Protokoll auf
    public static let currentBuild: String = {
        var st = stat()
        guard let p = Bundle.main.executablePath, stat(p, &st) == 0 else { return "?" }
        return "\(st.st_size)-\(st.st_mtimespec.tv_sec)"
    }()
}
