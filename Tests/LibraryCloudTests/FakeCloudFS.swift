import Foundation
@testable import LibraryCloud

/// Dateisystem zum Testen: Zustände, Hänger, fehlschlagende Anforderungen, freier Platz
final class FakeCloudFS: CloudFileSystem, @unchecked Sendable {
    struct File {
        var state: CloudState
        var size: Int64
        /// so lange hängt jede Prüfung (Sekunden)
        var hang: TimeInterval = 0
        /// so viele Anforderungen schlagen fehl
        var failRequests = 0
    }

    struct Failure: Error, LocalizedError {
        var errorDescription: String? { "anbieter nicht erreichbar" }
    }

    private let lock = NSLock()
    private var files: [String: File] = [:]
    private(set) var requests: [String] = []
    var free: Int64 = 1 << 40

    func add(_ path: String, _ state: CloudState, size: Int64 = 10_000_000, hang: TimeInterval = 0, failRequests: Int = 0) {
        lock.withLock { files[path] = File(state: state, size: size, hang: hang, failRequests: failRequests) }
    }

    /// Download beim Anbieter fertig
    func complete(_ path: String) { lock.withLock { files[path]?.state = .local } }
    func evict(_ path: String) { lock.withLock { files[path]?.state = .cloud } }
    var requestLog: [String] { lock.withLock { requests } }

    func probe(_ path: String) -> FileProbe {
        let f = lock.withLock { files[path] }
        guard let f else { return FileProbe(.missing) }
        if f.hang > 0 { Thread.sleep(forTimeInterval: f.hang) }
        return FileProbe(f.state, size: f.size)
    }

    func requestDownload(_ path: String) throws {
        try lock.withLock {
            requests.append(path)
            if let f = files[path], f.failRequests > 0 {
                files[path]?.failRequests -= 1
                throw Failure()
            }
        }
    }

    func freeBytes(near path: String) -> Int64? { lock.withLock { free } }
}
