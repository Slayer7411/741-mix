import Foundation
import Darwin

/// UDP-Empfänger der DAW-Brücke: BSD-Socket auf 127.0.0.1, liest auf einer eigenen Queue, parst und meldet jedes
/// Paket über `onMessage` (auf dieser Queue). Nie Haupt- oder Audio-Thread. Port 0 = vom System gewählt (Tests).
public final class DAWBridgeReceiver: @unchecked Sendable {
    public enum StartError: Error, Equatable { case socket(Int32), bind(Int32) }

    private let queue = DispatchQueue(label: "minos741.dawbridge", qos: .userInitiated)
    private var source: DispatchSourceRead?
    /// tatsächlich gebundener Port
    public private(set) var port: UInt16 = 0
    public var onMessage: (@Sendable (DAWBridge.Message) -> Void)?
    /// unlesbare Pakete (Zähler, für Tests und Diagnose)
    public private(set) var rejected = 0

    public init() {}
    deinit { stop() }

    public var running: Bool { source != nil }

    public func start(port want: UInt16) throws {
        stop()
        let s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard s >= 0 else { throw StartError.socket(errno) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = want.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard ok == 0 else { let e = errno; close(s); throw StartError.bind(e) }
        var bound = sockaddr_in(), len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) } }
        port = UInt16(bigEndian: bound.sin_port)
        _ = fcntl(s, F_SETFL, fcntl(s, F_GETFL) | O_NONBLOCK)
        let src = DispatchSource.makeReadSource(fileDescriptor: s, queue: queue)
        src.setEventHandler { [weak self] in self?.drain(s) }
        src.setCancelHandler { close(s) }
        source = src
        src.resume()
    }

    public func stop() {
        source?.cancel()
        source = nil
        port = 0
    }

    /// auf `queue`: alle wartenden Pakete lesen (der Abbruch schließt den Socket erst nach diesem Handler)
    private func drain(_ s: Int32) {
        var buf = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = buf.withUnsafeMutableBytes { recv(s, $0.baseAddress, $0.count, 0) }
            guard n > 0 else { return }
            do { onMessage?(try DAWBridge.parse(Data(buf[0..<n]))) } catch { rejected += 1 }
        }
    }

    /// ein Paket an einen lokalen Port schicken (Selbsttest, Tests)
    @discardableResult
    public static func send(_ data: Data, port: UInt16) -> Bool {
        let s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard s >= 0 else { return false }
        defer { close(s) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let n = data.withUnsafeBytes { d in
            withUnsafePointer(to: &addr) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(s, d.baseAddress, d.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
        return n == data.count
    }
}
