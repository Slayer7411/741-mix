import AppKit
import SwiftUI

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
        // zwei Beispiel-Controller, damit die Geräte-Blöcke im Bild stehen
        status.devices = [.init(id: "SHOT-1", location: 1, left: 0, right: 1),
                          .init(id: "SHOT-2", location: 2, left: 2, right: 3, pane: 1, fxUnit: 11)]
        status.lastEvent = "—"
        let deadline = Date().addingTimeInterval(20)
        while store.tracks.isEmpty, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }

        for (i, tab) in SettingsView.tabs.enumerated() {
            let name = String(format: "%02d-%@", i + 1, slug(tab.id))
            let window = { (w: CGFloat, h: CGFloat) in
                AnyView(SettingsView(selection: i).environment(mix).environment(store).environment(status))
                    .frame(width: w, height: h)
            }
            render(AnyView(window(820, 640)), to: dir.appendingPathComponent("\(name).png"))
            render(AnyView(window(720, 520)), to: dir.appendingPathComponent("\(name)-min.png"))
            // ganze Seite ohne Scrollen (prüft, dass nichts abgeschnitten ist)
            let page = AnyView(SettingsPage { tab.content() }.environment(mix).environment(store).environment(status)
                .frame(width: 643).background(Theme.chitin).preferredColorScheme(.dark))
            render(page, to: dir.appendingPathComponent("\(name)-page.png"), fitHeight: true)
        }
        restore()
        print("[shot] \(SettingsView.tabs.count) Bereiche -> \(dir.path)")
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
