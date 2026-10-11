import Darwin
import Foundation

/// Kindprozess mit Steuer-Kanal: Start per posix_spawn (nur fd 0–3 erben), Ende per kqueue (EVFILT_PROC),
/// Abschießen mit SIGKILL. Der Kanal liegt im Kind auf `childFD`; endet der Elternprozess, sieht das Kind EOF.
public final class Helper: @unchecked Sendable {
    /// fd des Kanals im Kind
    public static let childFD: Int32 = 3
    /// Umgebungsvariable im Kind: Nummer des Kanal-fd
    public static let fdVariable = "MIX741_IPC_FD"

    public let pid: pid_t
    public let channel: Channel
    public let started: Date

    private let lock = NSLock()
    private var status: Int32?
    private var exitHandlers: [(Int32) -> Void] = []
    private var source: DispatchSourceProcess?
    private let exitSignal = DispatchSemaphore(value: 0)

    public enum SpawnError: Error, Equatable, Sendable { case notFound(String), spawn(Int32) }

    private init(pid: pid_t, channel: Channel) {
        self.pid = pid; self.channel = channel; started = Date()
    }

    /// Kind starten. `qos`: Dienstklasse des Kinds (Laden fürs Deck = userInitiated, Vorarbeit = utility)
    public static func spawn(executable: URL, arguments: [String] = [], environment: [String: String] = [:],
                             qos: qos_class_t = QOS_CLASS_USER_INITIATED) throws -> Helper {
        guard access(executable.path, X_OK) == 0 else { throw SpawnError.notFound(executable.path) }
        let (channel, childEnd) = try Channel.pair()
        defer { close(childEnd) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addinherit_np(&actions, 1)
        posix_spawn_file_actions_addinherit_np(&actions, 2)
        posix_spawn_file_actions_adddup2(&actions, childEnd, childFD)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // alle anderen fds schließen (Geräte, Sockets, Dateien des Elternprozesses), Signale auf Standard
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        var none = sigset_t(), all = sigset_t()
        sigemptyset(&none); sigfillset(&all)
        posix_spawnattr_setsigmask(&attr, &none)
        posix_spawnattr_setsigdefault(&attr, &all)
        posix_spawnattr_set_qos_class_np(&attr, qos)

        var env = ProcessInfo.processInfo.environment
        for (k, v) in environment { env[k] = v }
        env[fdVariable] = String(childFD)
        let argv = [executable.path] + arguments
        let cArgs = argv.map { strdup($0) } + [nil]
        let cEnv = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (cArgs + cEnv).forEach { free($0) } }

        var pid: pid_t = 0
        let r = posix_spawn(&pid, executable.path, &actions, &attr, cArgs, cEnv)
        guard r == 0 else { channel.close(); throw SpawnError.spawn(r) }
        let h = Helper(pid: pid, channel: channel)
        h.watch()
        return h
    }

    private func watch() {
        let s = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global(qos: .userInitiated))
        s.setEventHandler { [weak self] in self?.reap(exited: true) }
        source = s
        s.resume()
        reap()   // schon vor dem Anmelden beendet
    }

    /// `exited`: NOTE_EXIT kommt, bevor das Kind abholbar ist (WNOHANG liefert dann 0, kein zweites Ereignis) -> blockierend
    private func reap(exited: Bool = false) {
        var st: Int32 = 0
        var r: pid_t
        repeat { r = waitpid(pid, &st, exited ? 0 : WNOHANG) } while r == -1 && errno == EINTR
        guard r == pid else { return }
        let handlers: [(Int32) -> Void] = lock.withLock {
            guard status == nil else { return [] }
            status = st
            defer { exitHandlers = [] }   // Zyklen über die Handler lösen
            return exitHandlers
        }
        source?.cancel()
        exitSignal.signal()
        channel.shutdown()
        handlers.forEach { $0(st) }
    }

    /// Wait-Status, sobald beendet (nil = läuft)
    public var exitStatus: Int32? { lock.withLock { status } }
    public var running: Bool { exitStatus == nil }

    /// läuft auf einer Hintergrund-Queue; ist das Kind schon beendet, sofort
    public func onExit(_ f: @escaping (Int32) -> Void) {
        let done: Int32? = lock.withLock {
            if let status { return status }
            exitHandlers.append(f)
            return nil
        }
        if let done { f(done) }
    }

    /// SIGKILL; ein in einem Systemaufruf (Cloud-Anbieter) festhängendes Kind endet evtl. erst später
    public func kill() {
        guard running else { return }
        _ = Darwin.kill(pid, SIGKILL)
    }

    /// wartet auf das Ende; false = läuft nach `timeout` noch
    @discardableResult
    public func wait(timeout: Double) -> Bool {
        if !running { return true }
        if exitSignal.wait(timeout: .now() + timeout) == .success { exitSignal.signal(); return true }
        return !running
    }

    /// Kurzbeschreibung des Wait-Status fürs Protokoll
    public static func describe(_ st: Int32) -> String {
        let sig = st & 0x7f
        if sig == 0 { return "exit \((st >> 8) & 0xff)" }
        return "signal \(sig)"
    }
}
