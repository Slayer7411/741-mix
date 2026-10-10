import AppKit
import SwiftUI
import MixCore
import MixEngine

/// Nur Selbsttest (MIX741_SHOT=header:<png>): Deck-Kopf offscreen als PNG, ohne Fenster auf dem Bildschirm.
/// A spielt im Code, B zwei Takte voraus, C steht. Stumm auf einem eingebauten Gerät, beendet sich selbst.
@MainActor
enum HeaderShot {
    static func run(_ spec: String) {
        guard spec.hasPrefix("header:") else { print("[shot] unbekannt: \(spec)"); exit(1) }
        let base = URL(fileURLWithPath: String(spec.dropFirst(7))).deletingPathExtension()
        NSApplication.shared.setActivationPolicy(.prohibited)
        // nie das Interface einer laufenden Live-Session: Routing nur für diesen Prozess auf ein eingebautes 2-Kanal-Gerät
        let devs = MixEngine.outputDevices()
        let dev = devs.first { $0.channels == 2 && $0.name.localizedCaseInsensitiveContains("speaker") } ?? devs.first { $0.channels < 8 }
        UserDefaults.standard.setVolatileDomain(["deviceUID": dev?.uid ?? "-", "mixerMode": MixerMode.internalMixer.rawValue,
                                                 "sampleRate": 0.0, "bufferSize": 0, "masterVolume": 0.0],
                                                forName: UserDefaults.argumentDomain)
        let store = LibraryStore()
        let mix = MixModel()
        let core = mix.core
        core.engine.deviceRate = nil
        core.engine.setMasterVolume(0)
        log("Routing \(dev?.name ?? "?") (stumm): läuft=\(core.engine.running)")
        store.load()
        Task { @MainActor in
            while store.tracks.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
            let c = store.tracks.filter { $0.bpm > 120 && $0.bpm < 140 && $0.gridAnchorMs != nil && $0.fileExists }
            guard c.count >= 3 else { log("zu wenige Tracks"); exit(1) }
            for d in 0..<3 { core.load(c[d], deck: d) }
            while (0..<3).contains(where: { core.trackAudio($0) == nil }) {
                if let e = core.snapshot().decks.compactMap(\.error).first { log(e); exit(1) }
                try? await Task.sleep(for: .milliseconds(100))
            }
            mix.pull()
            let phrase = max(4, mix.prefs.ui.phraseBeats)
            // A: spielt, Master, ganze Beats auf den Zähler schieben (Zähler bleibt beim Master-Sprung stehen)
            core.togglePlay(0)
            try? await Task.sleep(for: .milliseconds(600))
            shift(mix, 0, toBeats: 0, phrase: phrase)
            // B: Sync, zwei Takte voraus
            core.toggleSync(1)
            core.togglePlay(1)
            try? await Task.sleep(for: .milliseconds(600))
            shift(mix, 1, toBeats: 8, phrase: phrase)
            try? await Task.sleep(for: .seconds(1))
            mix.pull()
            for (d, name) in [(0, "aligned"), (1, "off"), (2, "stopped")] {
                let url = base.deletingLastPathComponent().appendingPathComponent(base.lastPathComponent + "-\(name).png")
                let c = mix.phraseCode(d)
                log("Deck \(deckLetters[d]) \(name): Takt \(c.map { "\($0.bar)/\($0.phraseBars)" } ?? "-"), Abstand \(c?.offsetBeats.map(String.init) ?? "-") Beats, Zähler \(String(format: "%.2f", core.sessionBeat ?? .nan))")
                render(mix, d, to: url)
                log("PNG \(url.path)")
            }
            exit(0)
        }
        NSApplication.shared.run()
    }

    /// Deck um ganze Beats verschieben, bis es `toBeats` vom Zähler entfernt ist
    private static func shift(_ mix: MixModel, _ d: Int, toBeats want: Int, phrase: Int) {
        guard let g = mix.deck(d).grid, let o = mix.phraseCode(d)?.offsetBeats else { return }
        var beats = Double(PhraseCode.wrap(want - o, beats: phrase))
        if g.beatPosition(at: mix.position(d)) + beats < 0 { beats += Double(phrase) }
        mix.core.seek(d, seconds: mix.position(d) + beats * g.beat)
    }

    private static func render(_ mix: MixModel, _ d: Int, to url: URL) {
        let size = NSSize(width: 600, height: 260)
        let root = DeckView(d: d)
            .frame(width: size.width, height: size.height)
            .background(Theme.background)
            .foregroundStyle(Theme.bone)
            .environment(mix)
            .environment(WaveformCache())
            .preferredColorScheme(.dark)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        // Fenster nur als Zeichenfläche, wird nie eingeblendet
        let win = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: .darkAqua)
        win.contentView = host
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    static func log(_ s: String) {
        print("[shot] \(s)")
        fflush(stdout)
    }
}
