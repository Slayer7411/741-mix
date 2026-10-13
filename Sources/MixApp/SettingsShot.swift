import AppKit
import SwiftUI
import MixEngine

/// Selbsttest-Bilder der Einstellungen (MIX741_SELFTEST=1 MIX741_SHOT=settings:<ordner>):
/// jeden Bereich offscreen rendern, je Bereich PNGs schreiben, beenden. Kein sichtbares Fenster, keine Aktivierung.
@MainActor
enum SettingsShot {
    static func runIfRequested() {
        guard Session.isSelfTest, let arg = ProcessInfo.processInfo.environment["MIX741_SHOT"],
              arg.hasPrefix("settings:") else { return }
        let dir = URL(fileURLWithPath: String(arg.dropFirst("settings:".count)), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.prohibited)

        // Audio-Einstellungen sichern: MixModel öffnet beim Start das gespeicherte Gerät und schreibt das Setup zurück.
        // Für die Bilder nur die eingebauten Lautsprecher (nie das Interface einer laufenden Live-Session), danach zurück.
        let d = UserDefaults.standard
        let keys = ["mixerMode", "deviceUID", "internalPair", "deckPairs", "sampleRate", "bufferSize", "prefs.v1"]
        let saved = keys.map { ($0, d.object(forKey: $0)) }
        let restore = { for (k, v) in saved { if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) } } }
        d.setVolatileDomain(["deviceUID": "BuiltInSpeakerDevice", "mixerMode": "Intern", "sampleRate": 0.0, "bufferSize": 0],
                            forName: UserDefaults.argumentDomain)
        let mix = MixModel()
        mix.engine.setMasterVolume(0)
        print("[shot] Audio: \(mix.engineStatus)")
        d.removeVolatileDomain(forName: UserDefaults.argumentDomain)
        restore()
        let store = LibraryStore()
        store.load()
        let status = ControllerStatus()
        let browser = BrowserState()
        // zwei Beispiel-Controller, damit die Geräte-Blöcke im Bild stehen
        status.devices = [.init(id: "SHOT-1", location: 1, left: 0, right: 2, fxUnit: 10, name: "Controller", serial: "SHOT-1", side: .left),
                          .init(id: "loc-14200000", location: 2, left: 1, right: 3, pane: 1, fxUnit: 11, name: "Controller", side: .right)]
        status.lastEvent = "—"
        let deadline = Date().addingTimeInterval(20)
        while store.tracks.isEmpty, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }

        for (i, tab) in SettingsView.tabs.enumerated() {
            let name = String(format: "%02d-%@", i + 1, slug(tab.id))
            let window = { (w: CGFloat, h: CGFloat) in
                AnyView(SettingsView(selection: i).environment(mix).environment(store).environment(status).environment(browser))
                    .frame(width: w, height: h)
            }
            render(AnyView(window(820, 640)), to: dir.appendingPathComponent("\(name).png"))
            render(AnyView(window(720, 520)), to: dir.appendingPathComponent("\(name)-min.png"))
            // ganze Seite ohne Scrollen (prüft, dass nichts abgeschnitten ist)
            let page = AnyView(SettingsPage { tab.content() }.environment(mix).environment(store).environment(status).environment(browser)
                .frame(width: 643).background(Theme.chitin).preferredColorScheme(.dark))
            render(page, to: dir.appendingPathComponent("\(name)-page.png"), fitHeight: true)
        }
        restore()
        print("[shot] \(SettingsView.tabs.count) Bereiche -> \(dir.path)")
        exit(0)
    }

    /// nur der PLUGINS-Tab (MIX741_SELFTEST=1 MIX741_SHOT=plugins:<ordner>, optional MIX741_SHOT_PLUGINS=<plugin-ordner>):
    /// ohne MixModel – kein Audiogerät, kein Controller, Plugin-Einstellungen nur gelesen. Geht auch, während MINOS-741 läuft
    static func runPluginsIfRequested() {
        guard Session.isSelfTest, let arg = ProcessInfo.processInfo.environment["MIX741_SHOT"], arg.hasPrefix("plugins:") else { return }
        let dir = URL(fileURLWithPath: String(arg.dropFirst("plugins:".count)), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.prohibited)
        VST3Thread.useMain = true
        let catalog = PluginCatalog(directory: HistoryStore.baseDir, readOnly: true)
        if let f = ProcessInfo.processInfo.environment["MIX741_SHOT_PLUGINS"] { catalog.update { $0.folders.append(f) } }
        let pm = PluginManager(catalog: catalog)
        let deadline = Date().addingTimeInterval(30)
        while pm.scanning, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        let vst3 = pm.entries.filter { $0.format == .vst3 }
        print("[shot] Plugins: \(pm.entries.count), VST3: " + vst3.map { "\($0.name) (\($0.info != nil ? "ladbar" : $0.problem ?? "?"))" }.joined(separator: ", "))
        let page = { (search: String, expanded: String?) in
            AnyView(SettingsPage { PluginSettingsPage(pm: pm, search: search, expanded: expanded) }
                .frame(width: 643).background(Theme.chitin).preferredColorScheme(.dark))
        }
        render(page("", nil), to: dir.appendingPathComponent("plugins-page.png"), fitHeight: true)
        render(page("vst3", vst3.first { $0.info != nil }?.id), to: dir.appendingPathComponent("plugins-vst3.png"), fitHeight: true)
        print("[shot] PLUGINS -> \(dir.path)")
        exit(0)
    }

    private static func slug(_ s: String) -> String {
        s.lowercased().split { !($0.isLetter || $0.isNumber) }.joined(separator: "-")
    }

    /// in ein nie gezeigtes Fenster hängen (manche AppKit-Steuerelemente zeichnen nur mit Fenster), dann als PNG
    private static func render(_ view: AnyView, to url: URL, fitHeight: Bool = false) {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: .darkAqua)
        var size = host.fittingSize
        if fitHeight { size.height = min(max(size.height, 100), 6000) }
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.contentView = nil
        window.close()
    }
}
