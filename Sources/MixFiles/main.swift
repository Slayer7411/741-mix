import Darwin
import Foundation
import MixIPC
import MixMedia
import MixProtocol

// minos-files: Datei-Dienst. Jeder Systemaufruf auf einem Musikpfad (stat, open, Dekoder) läuft hier, nie im
// Audio- oder Oberflächen-Prozess. Ein Auftrag zur Zeit; hängt der Cloud-Anbieter, schießt der Engine-Prozess
// diesen Prozess ab. Ergebnis = `.mtrk` im Cache, der fd geht per SCM_RIGHTS zurück.

setvbuf(stdout, nil, _IOLBF, 0)
guard let channel = Channel.inherited() else {
    FileHandle.standardError.write(Data("minos-files: ohne Kanal (\(Helper.fdVariable)) nicht startbar\n".utf8))
    exit(64)
}
let faults = Faults(ProcessInfo.processInfo.environment["MIX741_FAULT"] ?? "")
if faults.crashStart { raise(SIGKILL) }   // Absturz ohne Crash-Report

do {
    try channel.send(FileProtocol.Kind.handshake.rawValue,
                     Handshake(service: FileProtocol.service, major: FileProtocol.major, minor: FileProtocol.minor))
} catch { exit(65) }

let worker = Worker(channel: channel, faults: faults)
while true {
    let f: Channel.Frame
    do { f = try channel.receive() } catch { _exit(0) }   // Engine weg -> sofort beenden (auch wenn ein Auftrag hängt)
    switch FileProtocol.Kind(rawValue: f.type) {
    case .decode?:
        guard let r = try? f.decode(DecodeRequest.self) else { continue }
        worker.start(r)
    case .stat?:
        guard let r = try? f.decode(StatRequest.self) else { continue }
        worker.startStat(r)
    case .quit?:
        _exit(0)
    default:
        continue   // unbekannt: ignorieren (neuere Engine)
    }
}

/// Fehler-Einspeisung für Tests: `MIX741_FAULT=hang-open:<glob>,freeze-open:<glob>,crash-after:<bytes>,slow:<kB/s>,crash-start`
struct Faults {
    var hangOpen: String?
    var freezeOpen: String?
    var crashAfter: Int?
    var slowKBps: Double?
    var crashStart = false

    init(_ spec: String) {
        for item in spec.split(separator: ",") {
            let parts = item.split(separator: ":", maxSplits: 1).map(String.init)
            let arg = parts.count > 1 ? parts[1] : ""
            switch parts[0] {
            case "hang-open": hangOpen = arg
            case "freeze-open": freezeOpen = arg
            case "crash-after": crashAfter = Int(arg)
            case "slow": slowKBps = Double(arg)
            case "crash-start": crashStart = true
            default: break
            }
        }
    }

    static func matches(_ glob: String?, _ path: String) -> Bool {
        guard let glob else { return false }
        return fnmatch(glob, path, 0) == 0
    }
}

/// ein Auftrag zur Zeit auf eigenem Thread; der Haupt-Thread liest weiter den Kanal (EOF = beenden)
final class Worker: @unchecked Sendable {
    let channel: Channel
    let faults: Faults
    private let lock = NSLock()
    private var current: DecodeProgress?

    init(channel: Channel, faults: Faults) {
        self.channel = channel; self.faults = faults
        let beat = Thread { [self] in
            while true {
                Thread.sleep(forTimeInterval: FileProtocol.beatInterval)
                if let p = lock.withLock({ current }) { try? channel.send(FileProtocol.Kind.progress.rawValue, p) }
            }
        }
        beat.qualityOfService = .userInitiated
        beat.start()
    }

    private func set(_ id: UInt64, _ stage: DecodeStage, _ frames: Int = 0) {
        lock.withLock { current = DecodeProgress(id: id, stage: stage, frames: frames) }
    }

    func start(_ r: DecodeRequest) {
        guard lock.withLock({ current == nil }) else {
            try? channel.send(FileProtocol.Kind.failed.rawValue, DecodeFailed(id: r.id, code: .invalid, detail: "busy"))
            return
        }
        set(r.id, .opening)
        let t = Thread { [self] in
            let reply = run(r)
            lock.withLock { current = nil }
            switch reply {
            case let .done(d, fd):
                try? channel.send(FileProtocol.Kind.done.rawValue, d, fd: fd)
                close(fd)
            case let .failed(e):
                try? channel.send(FileProtocol.Kind.failed.rawValue, e)
            }
        }
        t.qualityOfService = .userInitiated
        t.stackSize = 1 << 22
        t.start()
    }

    enum Reply { case done(DecodeDone, Int32), failed(DecodeFailed) }

    /// Pfade parallel prüfen (stat mit abgeschalteter Materialisierung); Fortschritt = geprüfte Pfade
    func startStat(_ r: StatRequest) {
        guard lock.withLock({ current == nil }) else {
            try? channel.send(FileProtocol.Kind.failed.rawValue, DecodeFailed(id: r.id, code: .invalid, detail: "busy"))
            return
        }
        set(r.id, .checking)
        let t = Thread { [self] in
            if let g = faults.hangOpen, r.paths.contains(where: { Faults.matches(g, $0) }) { while true { sleep(60) } }
            let n = r.paths.count
            let out = UnsafeMutableBufferPointer<PathState>.allocate(capacity: max(1, n))
            defer { out.deallocate() }
            let done = UnsafeMutablePointer<Int>.allocate(capacity: 1)
            done.initialize(to: 0)
            defer { done.deallocate() }
            let counter = NSLock()
            DispatchQueue.concurrentPerform(iterations: n) { i in
                out[i] = Self.state(r.paths[i])
                let c = counter.withLock { done.pointee += 1; return done.pointee }
                if c % 64 == 0 { set(r.id, .checking, c) }
            }
            lock.withLock { current = nil }
            try? channel.send(FileProtocol.Kind.statResult.rawValue, StatResult(id: r.id, states: Array(out.prefix(n))))
        }
        t.qualityOfService = .userInitiated
        t.start()
    }

    static func state(_ path: String) -> PathState {
        let old = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        defer { if old >= 0 { _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, old) } }
        var st = stat()
        if stat(path, &st) != 0 { return errno == ENOENT || errno == ENOTDIR ? .missing : .error }
        return st.st_flags & UInt32(SF_DATALESS) != 0 ? .online : .local
    }

    private func run(_ r: DecodeRequest) -> Reply {
        let fail = { (code: FileErrorCode, detail: String) in Reply.failed(DecodeFailed(id: r.id, code: code, detail: detail)) }
        if Faults.matches(faults.hangOpen, r.path) { while true { sleep(60) } }
        if Faults.matches(faults.freezeOpen, r.path) { raise(SIGSTOP) }
        let t0 = Date()
        let key: TrackFile.SourceKey
        do { key = try TrackFile.SourceKey.of(path: r.path, sampleRate: r.sampleRate) } catch let TrackFile.FileError.io(e) {
            return fail(e == ENOENT || e == ENOTDIR ? .missing : .read, String(cString: strerror(e)))
        } catch { return fail(.read, "\(error)") }

        // Treffer im Cache: Kopf prüfen, Zeitstempel für das Aufräumen (älteste zuerst) neu setzen
        let dst = URL(fileURLWithPath: r.cacheDir).appendingPathComponent(key.fileName)
        let cachedFD = open(dst.path, O_RDONLY | O_CLOEXEC)
        if cachedFD >= 0 {
            if let m = try? TrackFile.map(fd: cachedFD, expect: key) {
                _ = futimens(cachedFD, nil)
                return .done(DecodeDone(id: r.id, frames: m.header.frames, fileSize: m.header.fileSize, cached: true,
                                        openMs: Date().timeIntervalSince(t0) * 1000), cachedFD)
            }
            close(cachedFD)
            unlink(dst.path)   // kaputt oder alt: neu dekodieren
        }

        let online = Self.state(r.path) == .online
        if online { set(r.id, .fetching) }
        var firstData: Date?
        var bytes = 0
        let a: TrackAudio
        do {
            a = try TrackAudio.decode(url: URL(fileURLWithPath: r.path), sampleRate: r.sampleRate) { [self] frames in
                if firstData == nil { firstData = Date() }
                set(r.id, .decoding, frames)
                let now = frames * 8
                if let k = faults.slowKBps, k > 0 { Thread.sleep(forTimeInterval: Double(now - bytes) / (k * 1000)) }
                bytes = now
                if let c = faults.crashAfter, bytes >= c { raise(SIGKILL) }
                return true
            }
        } catch TrackAudio.DecodeError.format {
            return fail(.format, "format")
        } catch let TrackAudio.DecodeError.convert(m) {
            return fail(.convert, m)
        } catch {
            if CloudRead.notLocal(path: r.path, datalessBefore: online, datalessAfter: Self.state(r.path) == .online) {
                return fail(.notLocal, r.path)
            }
            let ns = error as NSError
            return fail(.read, ns.localizedFailureReason ?? ns.localizedDescription)
        }
        let t1 = Date()
        set(r.id, .writing, a.frames)
        do {
            try FileManager.default.createDirectory(atPath: r.cacheDir, withIntermediateDirectories: true)
            try TrackFile.write(a, key: key, to: dst)
        } catch {
            return fail(.cacheWrite, "\(error)")
        }
        let fd = open(dst.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return fail(.cacheWrite, String(cString: strerror(errno))) }
        let t2 = Date()
        let size = Int((try? FileManager.default.attributesOfItem(atPath: dst.path)[.size] as? Int) ?? 0)
        return .done(DecodeDone(id: r.id, frames: a.frames, fileSize: size, cached: false,
                                openMs: (firstData ?? t1).timeIntervalSince(t0) * 1000,
                                decodeMs: t1.timeIntervalSince(firstData ?? t0) * 1000,
                                writeMs: t2.timeIntervalSince(t1) * 1000), fd)
    }
}
