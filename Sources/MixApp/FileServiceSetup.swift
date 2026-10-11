import Foundation
import MixEngine

/// Datei-Dienst anbinden: Helfer `minos-files` neben dem eigenen Programm. Fehlt er (z. B. `swift run` ohne den
/// Helfer gebaut) oder ist MIX741_INPROC_FILES=1 gesetzt, dekodiert der Kern im eigenen Prozess (alter Weg).
/// Selbsttest und Messungen: eigener Cache im temporären Ordner (Christians Cache bleibt unberührt)
enum FileServiceSetup {
    @MainActor static func attach(_ core: MixController) {
        let env = ProcessInfo.processInfo.environment
        if env["MIX741_INPROC_FILES"] == "1" {
            print("[files] im Prozess (MIX741_INPROC_FILES=1)")
            return
        }
        guard let helper = FileServiceClient.locateHelper() else {
            print("[files] Helfer minos-files fehlt neben \(Bundle.main.executablePath ?? "?") -> im Prozess")
            return
        }
        let dir = Session.isSelfTest
            ? FileManager.default.temporaryDirectory.appendingPathComponent("minos741-selftest-cache", isDirectory: true)
            : FileServiceClient.defaultCacheDir
        let fs = FileServiceClient(.init(helper: helper, cacheDir: dir))
        core.fileService = fs   // Grenze kommt aus den Einstellungen
        fs.warmUp()
        print("[files] Datei-Dienst: \(helper.path) · Cache \(dir.path)")
    }
}
