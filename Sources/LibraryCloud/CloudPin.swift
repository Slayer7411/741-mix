import Foundation

/// Zustand eines Cloud-Ordners beim Anbieter
public struct FolderStatus: Sendable, Equatable {
    public enum Pin: Sendable, Equatable {
        /// „Offline verfügbar“ gesetzt (Anbieter bietet „nicht mehr offline“ an)
        case pinned
        case notPinned
        /// nicht ermittelbar (anderer Anbieter, Werkzeug fehlt, Ausgabe unbekannt)
        case unknown
    }
    public var pin: Pin = .unknown
    /// alles darunter lokal (Anbieter-Angabe)
    public var recursivelyDownloaded: Bool?
    /// Systemeinstellung „Immer behalten“ (File Provider contentPolicy)
    public var keepDownloaded: Bool?

    public init(pin: Pin = .unknown, recursivelyDownloaded: Bool? = nil, keepDownloaded: Bool? = nil) {
        self.pin = pin
        self.recursivelyDownloaded = recursivelyDownloaded
        self.keepDownloaded = keepDownloaded
    }
}

/// Anheften („Offline verfügbar“) hat keine öffentliche Schnittstelle für andere Apps: Google Drive bietet es als
/// eigene Finder-Aktion an (File-Provider-Aktion ACTION_PIN / ACTION_UNPIN), contentPolicy setzt nur der Anbieter.
/// MINOS-741 setzt daher nichts, sondern liest den Zustand mit `fileproviderctl evaluate <ordner>` (nur lesen,
/// ~40 ms). Die Ausgabe ist nicht dokumentiert -> passt das Format nicht, bleibt alles `unknown`.
public enum CloudPin {
    public static let tool = "/usr/bin/fileproviderctl"

    /// Ausgabe von `fileproviderctl evaluate` auswerten
    public static func parse(_ text: String) -> FolderStatus {
        var s = FolderStatus()
        func flag(_ name: String) -> Bool? {
            guard let r = text.range(of: "\(name) = ") else { return nil }
            let v = text[r.upperBound...].prefix(1)
            return v == "1" ? true : v == "0" ? false : nil
        }
        let unpin = flag("\"ACTION_UNPIN\""), pin = flag("\"ACTION_PIN\"")
        if unpin == true, pin != true { s.pin = .pinned } else if pin == true, unpin != true { s.pin = .notPinned }
        s.recursivelyDownloaded = flag("isRecursivelyDownloaded")
        s.keepDownloaded = flag("isKeepDownloaded")
        return s
    }

    /// Zustand des Ordners lesen (blockiert höchstens `timeout`; Hintergrund-Thread)
    public static func status(of folder: String, timeout: TimeInterval = 5) -> FolderStatus {
        guard FileManager.default.isExecutableFile(atPath: tool) else { return FolderStatus() }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = ["evaluate", folder]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return FolderStatus() }
        let data = Locked(Data())
        let read = DispatchSemaphore(value: 0)
        let reader = Thread {
            data.set(out.fileHandleForReading.readDataToEndOfFile())
            read.signal()
        }
        reader.start()
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            return FolderStatus()
        }
        guard read.wait(timeout: .now() + 1) == .success else { return FolderStatus() }
        return parse(String(decoding: data.get(), as: UTF8.self))
    }
}

/// kleiner Behälter mit Sperre
final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    func get() -> T { lock.withLock { value } }
    func set(_ v: T) { lock.withLock { value = v } }
}
