import Darwin
import Foundation
import MixIPC
import MixMedia
import MixProtocol

/// Datei-Dienst aus Sicht des Engine-Prozesses: Tracks werden in `minos-files`-Prozessen dekodiert (ein Auftrag je
/// Prozess), das Ergebnis kommt als `.mtrk`-Datei (fd) zurück und wird nur lesend eingeblendet. Dieser Prozess
/// berührt keinen Musikpfad. Hängt ein Helfer (Cloud-Anbieter), wird er abgeschossen; stürzt er ab, ein neuer.
///
/// Abbruch nach Fortschritt, nicht nach Gesamtzeit: kein Herzschlag für `beatTimeout` -> Helfer hängt ganz;
/// keine neuen Daten für `hardTimeout` -> Datei kommt nicht (Drive antwortet nicht).
public final class FileServiceClient: @unchecked Sendable {
    public struct Config: Sendable {
        public var helper: URL
        public var cacheDir: URL
        public var cacheLimit: Int64
        /// zusätzliche Umgebung der Helfer (Tests: `MIX741_FAULT`)
        public var environment: [String: String] = [:]
        /// kein Herzschlag so lange -> Helfer hängt (Herzschlag alle 0,25 s)
        public var beatTimeout = 3.0
        /// Start bis Handshake
        public var spawnTimeout = 5.0
        /// bereitgehaltene Helfer (Start 5-20 ms, erster Start nach einem Build bis 0,5 s)
        public var idleWorkers = 2

        public init(helper: URL, cacheDir: URL, cacheLimit: Int64 = FileServiceClient.defaultCacheLimit) {
            self.helper = helper; self.cacheDir = cacheDir; self.cacheLimit = cacheLimit
        }
    }

    public enum ServiceError: Error, Equatable, Sendable {
        /// Helfer startet nicht (fehlt, falsche Version, stürzt sofort ab)
        case unavailable(String)
        case missing
        case failed(FileErrorCode, String)
        case crashed(String)
        /// kein Herzschlag: Helfer hängt ganz
        case unresponsive
        /// keine Daten für so viele Sekunden
        case stalled(Double)
        case cancelled
        /// Antwort passt nicht zum Auftrag (Kopf, Pfad, Rate)
        case invalid(String)
    }

    public struct Stats: Sendable, Equatable {
        public var spawns = 0
        public var startFailures = 0
        public var crashes = 0
        public var kills = 0
        /// abgeschossen, nach 2 s noch nicht beendet (hängt im Systemaufruf)
        public var zombies = 0
        public var cacheHits = 0
        public var decodes = 0
        /// Start bis Handshake des letzten Helfers
        public var lastSpawnMs = 0.0
    }

    public static let defaultCacheLimit: Int64 = 8 << 30
    public static let debug = ProcessInfo.processInfo.environment["MIX741_DEBUG"] == "1"

    /// ~/Library/Application Support/MINOS-741/cache
    public static var defaultCacheDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MINOS-741/cache", isDirectory: true)
    }

    /// Helfer neben dem eigenen Programm (App: Contents/MacOS, Entwicklung: .build/<konfig>/)
    public static func locateHelper(next executable: URL? = Bundle.main.executableURL) -> URL? {
        guard let dir = executable?.resolvingSymlinksInPath().deletingLastPathComponent() else { return nil }
        let u = dir.appendingPathComponent(FileProtocol.helperName)
        return access(u.path, X_OK) == 0 ? u : nil
    }

    public let config: Config
    private let lock = NSLock()
    private var idle: [Worker] = []
    private var limit: Int64
    private var nextID: UInt64 = 1
    private var failuresInRow = 0
    private var blockedUntil: Date?
    private var counters = Stats()
    /// eingeblendete Cache-Dateien (Name -> Abbildung): beim Aufräumen ausgenommen
    private var live: [String: WeakMapping] = [:]
    private let trimQueue = DispatchQueue(label: "minos741.files.trim", qos: .utility)
    private let spawnQueue = DispatchQueue(label: "minos741.files.spawn", qos: .userInitiated)

    public init(_ config: Config) {
        self.config = config
        limit = config.cacheLimit
        Self.prepare(config.cacheDir)
    }

    deinit { lock.withLock { idle }.forEach { $0.helper.kill() } }

    /// Cache-Ordner anlegen, nicht ins Backup
    private static func prepare(_ dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var u = dir
        var v = URLResourceValues()
        v.isExcludedFromBackup = true
        try? u.setResourceValues(v)
    }

    public var stats: Stats { lock.withLock { counters } }

    public var cacheLimit: Int64 {
        get { lock.withLock { limit } }
        set {
            lock.withLock { limit = max(0, newValue) }
            trimSoon()
        }
    }

    /// Helfer startet nicht (mehrmals hintereinander): bis zum Ablauf der Sperre im Prozess dekodieren
    public var unavailable: Bool { lock.withLock { blockedUntil.map { $0 > Date() } ?? false } }

    /// einen Helfer im Voraus starten, damit das erste Laden nicht auf den Start wartet
    public func warmUp() {
        spawnQueue.async { [self] in
            guard lock.withLock({ idle.count < config.idleWorkers }), !unavailable, let w = try? spawn() else { return }
            release(w)
        }
    }

    // MARK: Dekodieren

    /// Track über den Dienst laden (blockiert; Hintergrund-Thread). `progress`: Stufe + Frames bei jeder Änderung,
    /// `cancelled` wird alle 0,1 s gefragt (true = Helfer abschießen, `.cancelled`)
    public func decode(path: String, sampleRate: Double, hardTimeout: Double,
                       progress: (DecodeStage, Int) -> Void = { _, _ in },
                       cancelled: () -> Bool = { false }) throws -> TrackAudio {
        var retried = false
        let t0 = Date()
        attempt: while true {
            if cancelled() { throw ServiceError.cancelled }
            let w = try acquire()
            let id: UInt64 = lock.withLock { defer { nextID += 1 }; return nextID }
            do {
                try w.helper.channel.send(FileProtocol.Kind.decode.rawValue,
                                          DecodeRequest(id: id, path: path, sampleRate: sampleRate, cacheDir: config.cacheDir.path))
            } catch {
                discard(w)
                if !retried { retried = true; continue attempt }
                throw ServiceError.crashed("send: \(error)")
            }
            var lastBeat = Date(), lastChange = Date()
            var last = DecodeProgress(id: id, stage: .opening, frames: 0)
            while true {
                if cancelled() { discard(w); throw ServiceError.cancelled }
                let event = w.next(timeout: 0.1)
                let now = Date()
                switch event {
                case nil:
                    break
                case let .gone(why)?:
                    discard(w)
                    lock.withLock { counters.crashes += 1 }
                    log("helper \(w.helper.pid) gone (\(why)) while loading \(path)")
                    // ein Neuversuch (Absturz kann am Helfer liegen, nicht an der Datei)
                    if !retried, !cancelled() { retried = true; continue attempt }
                    throw ServiceError.crashed(why)
                case let .frame(f)?:
                    switch FileProtocol.Kind(rawValue: f.type) {
                    case .progress?:
                        guard let p = try? f.decode(DecodeProgress.self), p.id == id else { break }
                        lastBeat = now
                        if p != last {
                            lastChange = now
                            last = p
                            progress(p.stage, p.frames)
                        }
                    case .done?:
                        guard let fd = f.fd else { discard(w); throw ServiceError.invalid("done without fd") }
                        defer { close(fd) }
                        guard let d = try? f.decode(DecodeDone.self), d.id == id else { discard(w); throw ServiceError.invalid("done id") }
                        release(w)
                        let a = try adopt(fd: fd, path: path, sampleRate: sampleRate, done: d)
                        log(String(format: "%@ %@: %.0f ms (open %.0f, decode %.0f, write %.0f), %.0f MB",
                                   d.cached ? "hit" : "decoded", (path as NSString).lastPathComponent,
                                   Date().timeIntervalSince(t0) * 1000, d.openMs, d.decodeMs, d.writeMs, Double(d.fileSize) / 1e6))
                        return a
                    case .failed?:
                        guard let e = try? f.decode(DecodeFailed.self), e.id == id else { break }
                        release(w)
                        if e.code == .missing { throw ServiceError.missing }
                        throw ServiceError.failed(e.code, e.detail)
                    default:
                        if let fd = f.fd { close(fd) }
                    }
                }
                if now.timeIntervalSince(lastBeat) > config.beatTimeout {
                    discard(w)
                    log("helper \(w.helper.pid) unresponsive (no beat \(config.beatTimeout) s): \(path)")
                    throw ServiceError.unresponsive
                }
                if now.timeIntervalSince(lastChange) > hardTimeout {
                    discard(w)
                    log("helper \(w.helper.pid) stalled (no data \(hardTimeout) s, \(last.stage.rawValue)): \(path)")
                    throw ServiceError.stalled(hardTimeout)
                }
            }
        }
    }

    // MARK: Pfade prüfen

    /// Zustand vieler Pfade (ohne herunterzuladen), in Blöcken je Helfer. nil = unbekannt (Helfer hängt oder fehlt):
    /// nach dem ersten Block ohne Fortschritt für `timeout` bleibt der Rest unbekannt
    public func check(paths: [String], timeout: Double = 5) -> [PathState?] {
        var out = [PathState?](repeating: nil, count: paths.count)
        var start = 0
        while start < paths.count {
            let end = min(paths.count, start + FileProtocol.statChunk)
            guard let states = statChunk(Array(paths[start..<end]), timeout: timeout) else { break }
            for (k, s) in states.enumerated() where start + k < end { out[start + k] = s }
            start = end
        }
        return out
    }

    private func statChunk(_ paths: [String], timeout: Double) -> [PathState]? {
        guard let w = try? acquire() else { return nil }
        let id: UInt64 = lock.withLock { defer { nextID += 1 }; return nextID }
        guard (try? w.helper.channel.send(FileProtocol.Kind.stat.rawValue, StatRequest(id: id, paths: paths))) != nil else {
            discard(w); return nil
        }
        var lastChange = Date(), lastBeat = Date(), last = -1
        while true {
            let event = w.next(timeout: 0.1)
            let now = Date()
            switch event {
            case nil: break
            case .gone?:
                discard(w)
                lock.withLock { counters.crashes += 1 }
                return nil
            case let .frame(f)?:
                switch FileProtocol.Kind(rawValue: f.type) {
                case .progress?:
                    guard let p = try? f.decode(DecodeProgress.self), p.id == id else { break }
                    lastBeat = now
                    if p.frames != last { last = p.frames; lastChange = now }
                case .statResult?:
                    guard let r = try? f.decode(StatResult.self), r.id == id else { break }
                    release(w)
                    return r.states
                case .failed?:
                    release(w)
                    return nil
                default:
                    if let fd = f.fd { close(fd) }
                }
            }
            if now.timeIntervalSince(lastBeat) > config.beatTimeout || now.timeIntervalSince(lastChange) > timeout {
                discard(w)
                log("stat: helper \(w.helper.pid) stalled (\(max(0, last)) / \(paths.count) paths)")
                return nil
            }
        }
    }

    /// fd der fertigen Datei einblenden, prüfen, festhalten (mlock) – vor der Übergabe an den Kern
    private func adopt(fd: Int32, path: String, sampleRate: Double, done: DecodeDone) throws -> TrackAudio {
        let m: TrackFile.Mapping
        do { m = try TrackFile.map(fd: fd) } catch { throw ServiceError.invalid("\(error)") }
        guard m.header.key.sampleRate == sampleRate, m.header.frames == done.frames,
              m.header.key.path == path || path.utf8.count > 3800 else { throw ServiceError.invalid("header does not match request") }
        if !m.lock() {
            // Grenze für festen Speicher: Seiten nur einmal gelesen, können unter Speicherdruck wieder ausgelagert werden
            print("[files] mlock fehlgeschlagen (\(String(cString: strerror(errno)))): \(m.length / 1_000_000) MB nur vorgelesen")
        }
        lock.withLock {
            if done.cached { counters.cacheHits += 1 } else { counters.decodes += 1 }
            live = live.filter { $0.value.mapping != nil }
            live[m.header.key.fileName] = WeakMapping(m)
        }
        if !done.cached { trimSoon() }
        return TrackFile.audio(m)
    }

    // MARK: Helfer-Pool

    private func acquire() throws -> Worker {
        let w: Worker? = lock.withLock {
            while let w = idle.popLast() { if w.usable { return w } else { w.helper.kill() } }
            return nil
        }
        if let w { return w }
        if let until = lock.withLock({ blockedUntil }), until > Date() { throw ServiceError.unavailable("blocked") }
        return try spawn()
    }

    private func spawn() throws -> Worker {
        let t0 = Date()
        do {
            let h = try Helper.spawn(executable: config.helper, environment: config.environment, qos: QOS_CLASS_USER_INITIATED)
            let w = Worker(h)
            guard case let .frame(f)? = w.next(timeout: config.spawnTimeout), f.type == FileProtocol.Kind.handshake.rawValue,
                  let hs = try? f.decode(Handshake.self), hs.service == FileProtocol.service, hs.major == FileProtocol.major else {
                h.kill()
                throw ServiceError.unavailable("no handshake from \(config.helper.lastPathComponent)")
            }
            let ms = Date().timeIntervalSince(t0) * 1000
            lock.withLock {
                counters.spawns += 1; counters.lastSpawnMs = ms
                failuresInRow = 0; blockedUntil = nil
            }
            log(String(format: "helper %d up in %.0f ms", h.pid, ms))
            return w
        } catch {
            let blocked: Bool = lock.withLock {
                counters.startFailures += 1
                failuresInRow += 1
                // dreimal hintereinander: 60 s Pause (Absturz-Schleife), dann neuer Versuch
                if failuresInRow >= 3 { blockedUntil = Date().addingTimeInterval(60); failuresInRow = 0; return true }
                return false
            }
            log("helper start failed: \(error)\(blocked ? " -> blocked 60 s" : "")")
            if let e = error as? ServiceError { throw e }
            throw ServiceError.unavailable("\(error)")
        }
    }

    private func release(_ w: Worker) {
        let keep: Bool = lock.withLock {
            guard w.usable, idle.count < config.idleWorkers else { return false }
            idle.append(w)
            return true
        }
        if !keep { w.helper.kill() }
    }

    /// abschießen; endet er nicht binnen 2 s, zählt er als Zombie (hängt im Systemaufruf)
    private func discard(_ w: Worker) {
        guard w.helper.running else { return }
        lock.withLock { counters.kills += 1 }
        w.helper.kill()
        DispatchQueue.global(qos: .utility).async { [self] in
            guard !w.helper.wait(timeout: 2) else { return }
            lock.withLock { counters.zombies += 1 }
            log("helper \(w.helper.pid) still alive 2 s after SIGKILL")
            w.helper.onExit { [weak self] _ in self?.lock.withLock { self?.counters.zombies -= 1 } }
        }
    }

    // MARK: Cache

    public struct CacheUsage: Sendable, Equatable {
        public var files = 0
        public var bytes: Int64 = 0
    }

    /// Größe des Caches (lokaler Ordner der App)
    public func cacheUsage() -> CacheUsage {
        var u = CacheUsage()
        for e in Self.entries(config.cacheDir) where e.complete { u.files += 1; u.bytes += e.size }
        return u
    }

    private func trimSoon() { trimQueue.async { [self] in _ = trim(now: Date()) } }

    /// Aufräumen: älteste zuerst (Zeitstempel = letzte Nutzung), eingeblendete bleiben; nur `unlink`, nie kürzen.
    /// Reste abgebrochener Schreibvorgänge (`*.tmp-*`) älter als 1 h. Liefert gelöschte Dateien und Bytes
    @discardableResult
    public func trimCache(now: Date = Date()) -> (files: Int, bytes: Int64) { trimQueue.sync { trim(now: now) } }

    private func trim(now: Date) -> (files: Int, bytes: Int64) {
        let (max, pinned): (Int64, Set<String>) = lock.withLock {
            live = live.filter { $0.value.mapping != nil }
            return (limit, Set(live.keys))
        }
        var all = Self.entries(config.cacheDir)
        var removed = 0
        var freed: Int64 = 0
        for e in all where !e.complete && now.timeIntervalSince(e.mtime) > 3600 {
            if unlink(e.url.path) == 0 { removed += 1; freed += e.size }
        }
        all = all.filter(\.complete).sorted { $0.mtime < $1.mtime }
        var total = all.reduce(Int64(0)) { $0 + $1.size }
        for e in all where total > max && !pinned.contains(e.url.lastPathComponent) {
            if unlink(e.url.path) == 0 { removed += 1; freed += e.size }
            total -= e.size   // auch wenn schon weg
        }
        if removed > 0 { log("cache: removed \(removed) files, \(freed / 1_000_000) MB, now \(total / 1_000_000) MB") }
        return (removed, freed)
    }

    private struct Entry { var url: URL; var size: Int64; var mtime: Date; var complete: Bool }

    private static func entries(_ dir: URL) -> [Entry] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.compactMap { n -> Entry? in
            let complete = n.hasSuffix(".\(TrackFile.fileExtension)")
            guard complete || n.contains(".\(TrackFile.fileExtension).tmp-") else { return nil }
            let u = dir.appendingPathComponent(n)
            var st = stat()
            guard lstat(u.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return nil }
            let t = Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9)
            return Entry(url: u, size: Int64(st.st_size), mtime: t, complete: complete)
        }
    }

    private func log(_ s: String) {
        guard Self.debug else { return }
        print("[files] \(s)")
        fflush(stdout)
    }
}

private final class WeakMapping {
    weak var mapping: TrackFile.Mapping?
    init(_ m: TrackFile.Mapping) { mapping = m }
}

/// ein Helfer-Prozess + Lese-Thread; Nachrichten und das Prozessende landen in einer Warteschlange
private final class Worker: @unchecked Sendable {
    enum Event { case frame(Channel.Frame), gone(String) }

    let helper: Helper
    private let lock = NSLock()
    private var events: [Event] = []
    private var isGone = false
    private let signal = DispatchSemaphore(value: 0)

    init(_ helper: Helper) {
        self.helper = helper
        let t = Thread { [self] in
            while true {
                do { push(.frame(try helper.channel.receive())) } catch {
                    push(.gone("channel: \(error)"))
                    return
                }
            }
        }
        t.qualityOfService = .userInitiated
        t.stackSize = 1 << 18
        t.start()
        helper.onExit { [self] st in push(.gone(Helper.describe(st))) }
    }

    /// läuft und hat nichts Offenes (alte Fortschrittsmeldungen werden verworfen)
    var usable: Bool {
        guard helper.running else { return false }
        return lock.withLock {
            for case let .frame(f) in events { if let fd = f.fd { close(fd) } }
            events.removeAll()
            return !isGone
        }
    }

    private func push(_ e: Event) {
        lock.withLock {
            if case .gone = e { if isGone { return }; isGone = true }
            events.append(e)
        }
        signal.signal()
    }

    func next(timeout: Double) -> Event? {
        let deadline = DispatchTime.now() + timeout
        while true {
            if let e = lock.withLock({ events.isEmpty ? nil : events.removeFirst() }) { return e }
            if signal.wait(timeout: deadline) == .timedOut {
                return lock.withLock { events.isEmpty ? nil : events.removeFirst() }
            }
        }
    }
}
