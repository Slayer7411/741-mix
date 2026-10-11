import Darwin
import Foundation
import Testing
@testable import MixIPC

private struct Ping: Codable, Equatable { var n: Int; var text: String }

@Test func framesRoundTrip() throws {
    let (a, bfd) = try Channel.pair()
    let b = Channel(fd: bfd)
    try a.send(7, Ping(n: 42, text: "grüße"), version: 3)
    let f = try b.receive()
    #expect(f.type == 7 && f.version == 3 && f.fd == nil)
    #expect(try f.decode(Ping.self) == Ping(n: 42, text: "grüße"))
    // leere Nachricht, dann große (über den Socket-Puffer, wird in Teilen gelesen)
    try b.send(1)
    #expect(try a.receive().payload.isEmpty)
    let big = (0..<(600 * 1024)).map { UInt8($0 & 0xff) }
    let t = Thread { try? a.send(2, payload: big) }
    t.start()
    let g = try b.receive()
    #expect(g.type == 2 && g.payload == big)
}

/// fd über den Kanal: der Empfänger liest dieselbe Datei, auch nachdem der Sender seinen fd geschlossen hat
@Test func passesFileDescriptor() throws {
    let (a, bfd) = try Channel.pair()
    let b = Channel(fd: bfd)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("minos-ipc-\(UUID().uuidString)")
    try Data("mtrk inhalt".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let fd = open(url.path, O_RDONLY)
    try a.send(5, payload: [1, 2, 3], fd: fd)
    close(fd)
    let f = try b.receive()
    #expect(f.payload == [1, 2, 3])
    let got = try #require(f.fd)
    #expect(fcntl(got, F_GETFD) & FD_CLOEXEC != 0)
    var buf = [UInt8](repeating: 0, count: 64)
    let n = pread(got, &buf, 64, 0)
    #expect(String(decoding: buf[0..<max(0, n)], as: UTF8.self) == "mtrk inhalt")
    close(got)
    // nächste Nachricht ohne fd
    try a.send(6)
    #expect(try b.receive().fd == nil)
}

@Test func closedPeerAndBadMagic() throws {
    let (a, bfd) = try Channel.pair()
    let b = Channel(fd: bfd)
    a.close()
    #expect(throws: Channel.ChannelError.closed) { try b.receive() }
    #expect(throws: Channel.ChannelError.closed) { try a.send(1) }
    #expect(throws: Channel.ChannelError.closed) { try b.send(1) }

    let (c, dfd) = try Channel.pair()
    let d = Channel(fd: dfd)
    _ = "XXXXXXXXXXXX".withCString { Darwin.send(c.fd, $0, 12, 0) }
    #expect(throws: Channel.ChannelError.magic) { try d.receive() }
}

@Test func shutdownWakesBlockedReceive() async throws {
    let (a, _) = try Channel.pair()
    let t0 = Date()
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { a.shutdown() }
    #expect(throws: Channel.ChannelError.closed) { try a.receive() }
    #expect(Date().timeIntervalSince(t0) < 2)
}

/// Kind erbt nur 0–3: ein offener fd des Elternprozesses ist im Kind nicht sichtbar
@Test func helperInheritsOnlyChannel() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("minos-ipc-\(UUID().uuidString)")
    FileManager.default.createFile(atPath: url.path, contents: Data())
    defer { try? FileManager.default.removeItem(at: url) }
    let leak = open(url.path, O_RDONLY)   // ohne CLOEXEC
    defer { close(leak) }
    let h = try Helper.spawn(executable: URL(fileURLWithPath: "/bin/sh"),
                             arguments: ["-c", "ls /dev/fd >&3; echo \"$\(Helper.fdVariable)\" >&3"])
    var out = [UInt8]()
    var buf = [UInt8](repeating: 0, count: 256)
    while true {
        let n = recv(h.channel.fd, &buf, 256, 0)
        if n <= 0 { break }
        out += buf[0..<n]
    }
    #expect(h.wait(timeout: 5))
    let lines = String(decoding: out, as: UTF8.self).split(separator: "\n").map(String.init)
    let fds = Set(lines.dropLast().compactMap(Int32.init))
    #expect(fds.isSuperset(of: [0, 1, 2, 3]))
    #expect(!fds.contains(leak))
    #expect(lines.last == "3")
    #expect(Helper.describe(h.exitStatus ?? -1) == "exit 0")
}

@Test func helperKillAndExitStatus() throws {
    let h = try Helper.spawn(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"])
    #expect(h.running)
    let exited = DispatchSemaphore(value: 0)
    final class Box: @unchecked Sendable { var status: Int32? }
    let box = Box()
    h.onExit { box.status = $0; exited.signal() }
    let t0 = Date()
    h.kill()
    #expect(exited.wait(timeout: .now() + 5) == .success)
    #expect(Date().timeIntervalSince(t0) < 1)
    #expect(Helper.describe(box.status ?? 0) == "signal 9")
    #expect(!h.running && h.wait(timeout: 0))
    // Kanal ist nach dem Ende zu
    #expect(throws: Channel.ChannelError.closed) { try h.channel.receive() }
    // schon beendet: onExit kommt sofort
    var late: Int32?
    h.onExit { late = $0 }
    #expect(late != nil)

    let quick = try Helper.spawn(executable: URL(fileURLWithPath: "/usr/bin/false"))
    #expect(quick.wait(timeout: 5))
    #expect(Helper.describe(quick.exitStatus ?? 0) == "exit 1")
    #expect(throws: Helper.SpawnError.notFound("/nonexistent/minos-files")) {
        try Helper.spawn(executable: URL(fileURLWithPath: "/nonexistent/minos-files"))
    }
}
