import AppKit
import SwiftUI
import MixCore

/// Nur Selbsttest (MIX741_SELFTEST=1 MIX741_SHOT=basics:<ordner>, optional MIX741_MANUAL=<handbuch.md>): About, Handbuch,
/// Tastenkürzel, Protokoll und Collection-Backup offscreen als PNG (`basics-*.png`). Erfundene Angaben und Zeilen,
/// Sicherungen in einem temporären Ordner. Endet mit exit(0).
@MainActor
enum BasicsShot {
    static func runIfRequested() {
        guard Session.isSelfTest, let arg = ProcessInfo.processInfo.environment["MIX741_SHOT"], arg.hasPrefix("basics:") else { return }
        let dir = URL(fileURLWithPath: String(arg.dropFirst("basics:".count)), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.prohibited)

        let info = AboutInfo.make(["CFBundleShortVersionString": "0.8.2", "CFBundleVersion": "db052b1",
                                   "MINOSCodename": "LIMBUS", "MINOSBuildDate": "2026-10-17T00:00:00Z"])
        SettingsShot.render(AnyView(AboutView(info: info).frame(width: 580, height: 720)),
                            to: dir.appendingPathComponent("basics-about.png"))

        if let url = Manual.source, let md = try? String(contentsOf: url, encoding: .utf8) {
            SettingsShot.render(AnyView(ManualView(blocks: Manual.blocks(md)).frame(width: 680, height: 760)),
                                to: dir.appendingPathComponent("basics-handbuch.png"))
        } else {
            SettingsShot.render(AnyView(ManualMissingView().frame(width: 680, height: 300)),
                                to: dir.appendingPathComponent("basics-handbuch.png"))
        }

        SettingsShot.render(AnyView(ShortcutReferenceView(source: { ShortcutMap() }).frame(width: 600, height: 680)),
                            to: dir.appendingPathComponent("basics-tastenkuerzel.png"))

        let fake = """
        2026-10-17 09:12:01 info Statusleiste bereit
        2026-10-17 09:12:04 ok Collection geladen: 1240 Tracks
        2026-10-17 09:14:37 warning Datei fehlt · Musik/Beispiel/track-01.wav
        2026-10-17 09:15:02 info Sicherung der Collection angelegt
        2026-10-17 09:20:18 error Audio-Gerät nicht gefunden
        2026-10-17 09:21:00 ok LIVE aus
        """
        SettingsShot.render(AnyView(StatusLogView(loadFile: { fake }).frame(width: 760, height: 520)),
                            to: dir.appendingPathComponent("basics-protokoll.png"))

        // Sicherungen: drei Stände mit 3, 5 und 8 Tracks in einem temporären Ordner
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("basics-shot-\(UUID().uuidString)")
        let collection = root.appendingPathComponent("collection.nml")
        let t0 = Date(timeIntervalSince1970: 1_792_000_000)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (i, n) in [3, 5, 8].enumerated() {
            try? nml(n).write(to: collection)
            _ = try? CollectionBackups.backupNow(collection, now: t0.addingTimeInterval(Double(i) * 7200))
        }
        SettingsShot.render(AnyView(CollectionBackupView(collection: collection, restore: { _ in })
            .frame(width: 640, height: 460)), to: dir.appendingPathComponent("basics-backup.png"))
        try? FileManager.default.removeItem(at: root)

        print("[shot] Grundfunktionen -> \(dir.path)")
        exit(0)
    }

    private static func nml(_ n: Int) -> Data {
        var s = #"<?xml version="1.0" encoding="UTF-8" standalone="no" ?><NML VERSION="19"><COLLECTION ENTRIES="\#(n)">"#
        for i in 0..<n {
            s += #"<ENTRY TITLE="Track \#(i)" ARTIST="Test"><LOCATION DIR="/:music/:" FILE="t\#(i).wav" VOLUME="Macintosh HD" VOLUMEID="Macintosh HD"/></ENTRY>"#
        }
        return Data((s + "</COLLECTION></NML>").utf8)
    }
}
