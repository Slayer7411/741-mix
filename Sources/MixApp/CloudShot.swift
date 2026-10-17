import AppKit
import SwiftUI
import LibraryCloud
import MixCore

/// Selbsttest-Bilder (MIX741_SELFTEST=1 MIX741_SHOT=cloud:<ordner>): echte Prüfung der Collection (nur lesen,
/// Zeiten + Zahlen ins Protokoll), dann offscreen: Browser mit Spalte ☁ und Kopf (● LOKAL, SET-CHECK) mit echten
/// Zuständen, dieselbe Liste mit vorgegebenen Zuständen (die echte Library ist ganz lokal) und der Set-Check.
/// Kein Fenster, Audio stumm auf einem eingebauten Gerät, keine Einstellungen geschrieben, kein Download.
@MainActor
enum CloudShot {
    static func runIfRequested() {
        guard Session.isSelfTest, let spec = ProcessInfo.processInfo.environment["MIX741_SHOT"], spec.hasPrefix("cloud:") else { return }
        let dir = URL(fileURLWithPath: String(spec.dropFirst(6)), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.prohibited)
        func spin(_ s: Double, until done: () -> Bool = { false }) {
            let end = Date().addingTimeInterval(s)
            while Date() < end, !done() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }

        // Audio-Modell wie SettingsShot: eingebaute Lautsprecher, stumm, Setup danach zurück
        let d = E2E.defaults
        let keys = ["mixerMode", "deviceUID", "internalPair", "deckPairs", "sampleRate", "bufferSize", "prefs.v1"]
        let saved = keys.map { ($0, d.object(forKey: $0)) }
        d.setVolatileDomain(["deviceUID": "BuiltInSpeakerDevice", "mixerMode": "Intern", "sampleRate": 0.0, "bufferSize": 0],
                            forName: UserDefaults.argumentDomain)
        let mix = MixModel()
        mix.engine.setMasterVolume(0)
        d.removeVolatileDomain(forName: UserDefaults.argumentDomain)
        for (k, v) in saved { if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) } }

        let store = LibraryStore()
        let history = HistoryStore()
        let browser = BrowserState()
        browser.store = store
        browser.history = history
        store.load()
        spin(120) { !store.tracks.isEmpty }
        let cloud = CloudLibrary.shared
        let t0 = Date()
        cloud.collectionChanged(store.tracks)
        spin(60) { cloud.lastScan != nil }
        print(String(format: "[shot] cloud: %d tracks (%d in cloud-ordnern) · prüfung %.3f s (bis anzeige %.3f s) · %@",
                     store.tracks.count, cloud.cloudTracks, cloud.scanSeconds, Date().timeIntervalSince(t0),
                     CloudState.allCases.map { "\($0)=\(cloud.counts[$0] ?? 0)" }.joined(separator: " ")))
        spin(10) { cloud.folderStatus != nil }
        print("[shot] cloud: ordner \(cloud.folder ?? "-") · \(cloud.provider ?? "-") · \(String(describing: cloud.folderStatus))")

        // Liste: erste Playlist mit genug Tracks, sonst Collection
        func playlists(_ n: PlaylistNode) -> [PlaylistNode] { n.kind == .playlist ? [n] : n.children.flatMap(playlists) }
        let list = playlists(store.root).first { $0.trackKeys.count >= 24 && Set($0.trackKeys).count == $0.trackKeys.count && !$0.name.localizedCaseInsensitiveContains("preparation") }
        // eigener Bereich: gespeicherte Spalten der echten Bereiche bleiben unberührt
        let pane = BrowserPaneModel(name: "CloudShot", source: list.map { .node($0) } ?? .collection)
        pane.showTree = false
        let rows = pane.rows(from: store, history: history, separators: mix.prefs.ui.tagSeparators)

        func browserView() -> AnyView {
            AnyView(BrowserPane(model: pane)
                .frame(width: 1180, height: 520)
                .background(Theme.background)
                .environment(store).environment(mix).environment(browser).environment(history)
                .environment(WaveformCache())
                .preferredColorScheme(.dark))
        }
        render(browserView(), size: NSSize(width: 1180, height: 520), to: dir.appendingPathComponent("cloud-column.png"))

        // vorgegebene Zustände auf den ersten Zeilen (nur Bild)
        let r = Array(rows.prefix(16))
        var demo: [(String, CloudState)] = []
        var fetching = Set<String>(), queued = Set<String>()
        for (i, t) in r.enumerated() {
            switch i {
            case 2, 5, 6, 11: demo.append((t.path, .cloud))
            case 7: fetching.insert(t.path)
            case 8, 9: queued.insert(t.path)
            case 13: demo.append((t.path, .missing))
            default: break
            }
        }
        cloud.demo(demo, fetching: fetching, queued: queued)
        render(browserView(), size: NSSize(width: 1180, height: 520), to: dir.appendingPathComponent("cloud-column-demo.png"))

        var res = SetCheckResult(checked: 48)
        res.cloud = demo.filter { $0.1 == .cloud }.compactMap { p in r.first { $0.path == p.0 } }
        res.missing = demo.filter { $0.1 == .missing }.compactMap { p in r.first { $0.path == p.0 } }
        let check = SetCheckView(groups: [("Preparation", Array(r.prefix(12))), (pane.source.title, Array(rows.prefix(36)))], preset: res)
            .environment(store).preferredColorScheme(.dark)
        render(AnyView(check), size: nil, to: dir.appendingPathComponent("set-check-demo.png"))
        print("[shot] cloud -> \(dir.path)")
        exit(0)
    }

    private static func render(_ view: AnyView, size: NSSize?, to url: URL) {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: .darkAqua)
        let s = size ?? host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: s),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: s)
        for _ in 0..<8 {
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
