import AppKit
import SwiftUI
import MixCore
import MixEngine

/// Selbsttest-Bilder (MIX741_SELFTEST=1 MIX741_SHOT=playlists:<ordner>), offscreen, ohne Audio: Baum mit PLAYLISTS
/// (eigene Ordner in Ordnern, Playlists, Smartlists, darunter die der Collection) und der Smartlist-Editor mit
/// mehreren Regelzeilen. Eigener Baum nur im Temp-Ordner des Selbsttests, Collection nur gelesen
@MainActor
enum PlaylistShot {
    static func runIfRequested() {
        guard Session.isSelfTest, let spec = ProcessInfo.processInfo.environment["MIX741_SHOT"], spec.hasPrefix("playlists:") else { return }
        run(String(spec.dropFirst("playlists:".count)))
    }

    private final class ShotWindow: NSWindow {
        override var canBecomeKey: Bool { true }
    }

    static func run(_ path: String) -> Never {
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.prohibited)
        func log(_ s: String) { print("[playlists] \(s)"); fflush(stdout) }
        func spin(_ s: Double, until done: () -> Bool = { false }) {
            let end = Date().addingTimeInterval(s)
            while Date() < end, !done() { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        }
        // Audio-Setup sichern, eingebautes Gerät, Ausgabe gleich wieder aus (wie TagShot)
        let d = UserDefaults.standard
        let keys = ["mixerMode", "deviceUID", "internalPair", "deckPairs", "sampleRate", "bufferSize", "prefs.v1"]
        let saved = keys.map { ($0, d.object(forKey: $0)) }
        let devs = MixEngine.outputDevices()
        let dev = devs.first { $0.channels == 2 && $0.name.localizedCaseInsensitiveContains("speaker") } ?? devs.first { $0.channels < 8 }
        d.setVolatileDomain(["deviceUID": dev?.uid ?? "-", "mixerMode": MixerMode.internalMixer.rawValue,
                             "sampleRate": 0.0, "bufferSize": 0, "masterVolume": 0.0], forName: UserDefaults.argumentDomain)
        let mix = MixModel()
        mix.engine.stop()
        d.removeVolatileDomain(forName: UserDefaults.argumentDomain)
        for (k, v) in saved { if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) } }

        let store = LibraryStore(), history = HistoryStore(), browser = BrowserState()
        browser.store = store
        browser.history = history
        browser.separators = { [mix] in mix.prefs.ui.tagSeparators }
        store.load()
        spin(120) { !store.tracks.isEmpty }
        log("collection \(store.tracks.count) tracks · playlists der collection \(store.root.children.count) oben")

        // eigener Baum: Ordner in Ordner, Playlists, Smartlists
        let sets = store.addOwn(.folder, into: nil, name: "Sets")
        let y = store.addOwn(.folder, into: sets.id, name: "2026")
        store.addOwn(.playlist, into: y.id, name: "Fr Hain", tracks: store.tracks.prefix(24).map(\.key))
        store.addOwn(.playlist, into: y.id, name: "Sa Closing", tracks: store.tracks.dropFirst(30).prefix(18).map(\.key))
        store.addOwn(.smartlist, into: sets.id, name: "Techno neu",
                     rules: SmartRules(rules: [SmartRule(.genre, .contains, "Techno"), SmartRule(.importDate, .inLast, "90", "d")]))
        store.addOwn(.playlist, into: nil, name: "Warm-up", tracks: store.tracks.dropFirst(60).prefix(12).map(\.key))
        let hypno = store.addOwn(.smartlist, into: nil, name: "Hypno 128+",
                                 rules: SmartRules(match: .all, rules: [SmartRule(.tag, .contains, "hypno"), SmartRule(.bpm, .atLeast, "128")]))
        for it in store.playlists.all where it.kind != .folder {
            log("\(OwnGlyph.of(it.kind)) \(it.name): \(store.tracks(for: .own(OwnRef(it))).count) tracks")
        }

        func host<V: View>(_ v: V, size: NSSize) -> (NSHostingView<AnyView>, NSWindow) {
            let view = AnyView(v.frame(width: size.width, height: size.height).background(Theme.background)
                .environment(store).environment(mix).environment(browser).environment(history).preferredColorScheme(.dark))
            let h = NSHostingView(rootView: view)
            h.appearance = NSAppearance(named: .darkAqua)
            let win = ShotWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            win.isReleasedWhenClosed = false
            win.appearance = NSAppearance(named: .darkAqua)
            win.contentView = h
            h.frame = NSRect(origin: .zero, size: size)
            win.orderFrontRegardless()
            return (h, win)
        }
        func png(_ v: NSView, _ name: String) {
            for _ in 0..<6 { v.layoutSubtreeIfNeeded(); spin(0.2) }
            guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep)
            let url = dir.appendingPathComponent(name)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            log("bild \(url.path)")
        }

        var source = BrowserSource.own(OwnRef(hypno))
        let (tree, _) = host(SourceTree(selection: Binding(get: { source }, set: { source = $0 })), size: NSSize(width: 300, height: 900))
        png(tree, "playlists-tree.png")

        let draft = SmartlistDraft(edit: store.playlists.item(hypno.id)!)
        draft.rules = SmartRules(match: .all, rules: [
            SmartRule(.genre, .contains, "Techno"), SmartRule(.tag, .contains, "hypno"), SmartRule(.bpm, .between, "126", "132"),
            SmartRule(.key, .equals, "21"), SmartRule(.importDate, .inLast, "6", "m"), SmartRule(.played, .no),
            SmartRule(.search, .contains, "dub"),
        ], sort: SmartSort(.importDate, ascending: false), limit: 50)
        let (ed, _) = host(SmartlistEditor(draft: draft), size: NSSize(width: 820, height: 560))
        spin(3) { draft.countIsCurrent }
        png(ed, "playlists-editor.png")
        log("editor: \(draft.rules.rules.count) regeln · \(draft.count.map(String.init) ?? "–") treffer")
        PlaylistFile.flush()
        PlaylistFile.removeSelfTestDir()
        exit(0)
    }
}
