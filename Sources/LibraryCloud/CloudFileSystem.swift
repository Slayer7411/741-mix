import Foundation

/// Zugriff auf das Dateisystem für Prüfung und Download – austauschbar für Tests
public protocol CloudFileSystem: Sendable {
    /// Zustand + Größe; darf nie einen Download auslösen
    func probe(_ path: String) -> FileProbe
    /// Download beim Anbieter anfordern; kehrt sofort zurück (der Anbieter lädt im Hintergrund weiter,
    /// auch wenn MINOS-741 beendet wird)
    func requestDownload(_ path: String) throws
    /// freie Bytes auf dem Volume des Pfads (ohne „bereinigbaren“ Platz)
    func freeBytes(near path: String) -> Int64?
}

/// echtes Dateisystem
public struct SystemCloudFileSystem: CloudFileSystem {
    public init() {}

    /// Prüfen mit abgeschalteter Materialisierung (setiopolicy_np, nur dieser Thread, danach zurück):
    /// ein Zugriff auf einen Platzhalter liefert dann EDEADLK statt den Inhalt herunterzuladen
    public func probe(_ path: String) -> FileProbe {
        Self.withoutMaterializing {
            var st = stat()
            let r = stat(path, &st)
            let err = r == 0 ? 0 : errno
            return FileProbe(CloudClassifier.classify(err: err, flags: st.st_flags, mode: st.st_mode),
                             size: r == 0 ? Int64(st.st_size) : 0)
        }
    }

    public func requestDownload(_ path: String) throws {
        try FileManager.default.startDownloadingUbiquitousItem(at: URL(fileURLWithPath: path))
    }

    public func freeBytes(near path: String) -> Int64? {
        var dir = path
        var s = statfs()
        while !dir.isEmpty, dir != "/" {
            if statfs(dir, &s) == 0 { return Int64(s.f_bavail) * Int64(s.f_bsize) }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return statfs("/", &s) == 0 ? Int64(s.f_bavail) * Int64(s.f_bsize) : nil
    }

    /// `body` ohne Materialisierung von Platzhaltern ausführen (Thread-Richtlinie, danach wiederhergestellt)
    public static func withoutMaterializing<T>(_ body: () -> T) -> T {
        let old = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        defer { if old >= 0 { _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, old) } }
        return body()
    }
}
