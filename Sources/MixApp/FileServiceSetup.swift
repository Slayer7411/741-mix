import Foundation
import MixEngine

/// Datei-Dienst anbinden: Helfer `minos-files` neben dem eigenen Programm. Fehlt er (z. B. `swift run` ohne den
/// Helfer gebaut) oder ist MIX741_INPROC_FILES=1 gesetzt, arbeitet die App im eigenen Prozess (alter Weg).
/// Selbsttest und Messungen: eigener Cache im temporären Ordner (Christians Cache bleibt unberührt)
enum FileServiceSetup {
    /// ein Client für Kern und Bibliothek (nil = im Prozess)
    static let shared: FileServiceClient? = {
        let env = ProcessInfo.processInfo.environment
        if env["MIX741_INPROC_FILES"] == "1" {
            print("[files] im Prozess (MIX741_INPROC_FILES=1)")
            return nil
        }
        guard let helper = FileServiceClient.locateHelper() else {
            print("[files] Helfer minos-files fehlt neben \(Bundle.main.executablePath ?? "?") -> im Prozess")
            return nil
        }
        let dir = Session.isSelfTest
            ? FileManager.default.temporaryDirectory.appendingPathComponent("minos741-selftest-cache", isDirectory: true)
            : FileServiceClient.defaultCacheDir
        let fs = FileServiceClient(.init(helper: helper, cacheDir: dir))
        fs.warmUp()
        print("[files] Datei-Dienst: \(helper.path) · Cache \(dir.path)")
        return fs
    }()

    @MainActor static func attach(_ core: MixController) {
        core.fileService = shared   // Grenze kommt aus den Einstellungen
    }
}
