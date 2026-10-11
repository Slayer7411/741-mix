import AppKit
import AVFoundation
import SwiftUI
import MixCore
import MixEngine

/// Nur Selbsttest (MIX741_SHOT=status:<ordner>): Statusleiste mit Ladefehler + Last-Anzeigen und leere/fehlgeschlagene
/// Decks offscreen als PNG. Deck A: Datei fehlt (Totenkopf), Deck B: Dekoder hängt (Abbruch nach der Zeitgrenze),
/// Deck C: leer (Lobster), Deck D: spielt einen Testton mit Keylock (DSP-Last). Mit MIX741_SHOT_AUDIO=1 stumm auf
/// einem eingebauten Gerät, sonst ohne Ausgabe.
@MainActor
enum StatusShot {
    static func runIfRequested() {
        guard Session.isSelfTest, let spec = ProcessInfo.processInfo.environment["MIX741_SHOT"], spec.hasPrefix("status:") else { return }
        let dir = URL(fileURLWithPath: String(spec.dropFirst(7)))
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.prohibited)
        let audio = ProcessInfo.processInfo.environment["MIX741_SHOT_AUDIO"] == "1"
        if audio {
            let devs = MixEngine.outputDevices()
            let dev = devs.first { $0.channels == 2 && $0.name.localizedCaseInsensitiveContains("speaker") } ?? devs.first { $0.channels < 8 }
            UserDefaults.standard.setVolatileDomain(["deviceUID": dev?.uid ?? "-", "mixerMode": MixerMode.internalMixer.rawValue,
                                                     "sampleRate": 0.0, "bufferSize": 0, "masterVolume": 0.0],
                                                    forName: UserDefaults.argumentDomain)
        }
        let store = LibraryStore()
        store.status = "14211 Tracks · collection.nml · 1.2 s"
        let mix = MixModel()
        let core = mix.core
        core.engine.setMasterVolume(0)
        if !audio { core.engine.stop() }
        StatusCenter.shared.attach(core)
        MeterSampler.shared.attach(core.engine)
        var p = mix.prefs.engine
        p.loadTimeout = 4
        core.setPrefs(p)

        Task { @MainActor in
            // Deck D: Testton mit Keylock, damit die DSP-Anzeige etwas zeigt
            let tone = dir.appendingPathComponent("tone.wav")
            writeTone(tone, rate: core.engine.sampleRate)
            var t = Track(key: "tone", path: tone.path); t.title = "Testton"; t.artist = "MINOS-741"; t.bpm = 128
            core.load(t, deck: 3)
            while core.trackAudio(3) == nil { try? await Task.sleep(for: .milliseconds(50)) }
            core.toggleKeylock(3)
            if !core.snapshot().decks[3].keylock { core.toggleKeylock(3) }
            core.setTempo(3, 4)
            core.togglePlay(3)

            // Deck B: Dekoder hängt -> nach 4 s abgebrochen
            let hang = dir.appendingPathComponent("cloud-only.flac")
            FileManager.default.createFile(atPath: hang.path, contents: Data([0]))
            let real = core.decoder
            core.decoder = { url, rate, progress in
                if url.lastPathComponent == "cloud-only.flac" { Thread.sleep(forTimeInterval: 30) }
                return try real(url, rate, progress)
            }
            var b = Track(key: "hang", path: hang.path); b.title = "Night Drive (Extended Mix)"; b.artist = "Unknown Artist"
            let t0 = Date()
            core.load(b, deck: 1)
            while core.snapshot().decks[1].loading { try? await Task.sleep(for: .milliseconds(20)) }
            log(String(format: "Deck B abgebrochen nach %.2f s: %@", Date().timeIntervalSince(t0), core.snapshot().decks[1].error ?? "-"))

            // Deck A: Datei fehlt -> sofort
            var a = Track(key: "missing", path: "/Volumes/Gone/Music/Deep Cuts/missing-track.aiff")
            a.title = "Missing Track"; a.artist = "Somebody"
            let t1 = Date()
            core.load(a, deck: 0)
            while core.snapshot().decks[0].loading { try? await Task.sleep(for: .milliseconds(5)) }
            log(String(format: "Deck A abgebrochen nach %.3f s: %@", Date().timeIntervalSince(t1), core.snapshot().decks[0].error ?? "-"))
            StatusCenter.post(.info, String(localized: "Export läuft: Set Oktober"), detail: "/Users/dj/Exports/Set Oktober", key: "export",
                              progress: 0.35, progressText: "42/120")
            try? await Task.sleep(for: .milliseconds(1500))   // Messwerte sammeln (4 Hz)
            mix.pull()
            render(StatusBar().environment(store).environment(mix), size: CGSize(width: 1440, height: 34), dir.appendingPathComponent("statusbar.png"))
            render(HistoryShot(), size: CGSize(width: 560, height: 220), dir.appendingPathComponent("history.png"))
            render(DeckView(d: 0).environment(mix).environment(WaveformCache()), size: CGSize(width: 600, height: 300),
                   dir.appendingPathComponent("deck-failed.png"))
            render(DeckView(d: 2).environment(mix).environment(WaveformCache()), size: CGSize(width: 600, height: 300),
                   dir.appendingPathComponent("deck-empty.png"))
            render(DeckIdleView(d: 0, forced: .skull, forcedReason: "Nicht ladbar: Datei fehlt").environment(mix),
                   size: CGSize(width: 560, height: 150), dir.appendingPathComponent("skull-wide.png"))
            let s = MeterSampler.shared.sample
            log(String(format: "DSP %.1f %% (Spitze %.1f %%), Latenz %.1f ms, Puffer %d @ %g, Aussetzer %d, Speicher %@, CPU %.0f %%",
                       s.load.average * 100, s.peakHold * 100, s.load.outputLatency * 1000, s.load.bufferFrames, s.load.sampleRate,
                       s.dropouts, StatusMeters.megabytes(s.memoryBytes), s.cpu * 100))
            log("PNG \(dir.path)")
            try? FileManager.default.removeItem(at: tone)
            try? FileManager.default.removeItem(at: hang)
            exit(0)
        }
        NSApplication.shared.run()
    }

    private struct HistoryShot: View {
        var body: some View { StatusHistory() }
    }

    private static func render(_ v: some View, size: CGSize, _ url: URL) {
        let root = v
            .frame(width: size.width, height: size.height)
            .background(Theme.background)
            .foregroundStyle(Theme.bone)
            .tint(Theme.state)
            .preferredColorScheme(.dark)
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(origin: .zero, size: size)
        let win = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: .darkAqua)
        win.contentView = host
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// 60 s Stereo-Ton (Akkord) als WAV
    private static func writeTone(_ url: URL, rate: Double) {
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2),
              let file = try? AVAudioFile(forWriting: url, settings: fmt.settings),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(rate * 60)) else { return }
        buf.frameLength = buf.frameCapacity
        for i in 0..<Int(buf.frameLength) {
            let t = Double(i) / rate
            let v = Float(0.2 * (sin(2 * .pi * 220 * t) + sin(2 * .pi * 277 * t) + sin(2 * .pi * 330 * t)) / 3)
            buf.floatChannelData![0][i] = v; buf.floatChannelData![1][i] = v
        }
        try? file.write(from: buf)
    }

    static func log(_ s: String) {
        print("[shot] \(s)")
        fflush(stdout)
    }
}
