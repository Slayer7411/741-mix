import Foundation
import MixCore
import MixEngine

/// Stummer Selbsttest (MIX741_SELFTEST=1): lädt zwei Tracks, spielt A, synct B, prüft Loop/Beatjump/FX
/// und dass Audio + Sync weiterlaufen, während der Hauptthread blockiert ist.
@MainActor
enum SelfTest {
    static func run(store: LibraryStore, mix: MixModel) {
        guard ProcessInfo.processInfo.environment["MIX741_SELFTEST"] == "1" else { return }
        let core = mix.core
        Task { @MainActor in
            if ProcessInfo.processInfo.environment["MIX741_NOXONE"] == nil,
               let xone = mix.outputDevices.first(where: { $0.name.localizedCaseInsensitiveContains("xone") }) {
                core.engine.apply(.init(device: xone.id, firstChannel: [0, 2, 4, 6]))
                log("Routing \(xone.name) extern: läuft=\(core.engine.running) Fehler=\(core.engine.lastError ?? "keine")")
            }
            core.engine.setMasterVolume(0)   // stumm, Einstellung bleibt unverändert
            var p = mix.prefs.engine
            p.historyThreshold = 3            // nur im Test: schnell als gespielt markieren (nicht gespeichert)
            core.setPrefs(p)
            while store.tracks.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
            let c = store.tracks.filter { $0.bpm > 120 && $0.bpm < 140 && $0.gridAnchorMs != nil && $0.fileExists }
            guard c.count >= 2 else { log("zu wenige Tracks"); exit(1) }
            log("A: \(c[0].artist) – \(c[0].title) \(c[0].bpm) · B: \(c[1].artist) – \(c[1].title) \(c[1].bpm)")
            core.load(c[0], deck: 0)
            core.load(c[1], deck: 1)
            while core.trackAudio(0) == nil || core.trackAudio(1) == nil {
                let s = core.snapshot()
                if let e = s.decks[0].error ?? s.decks[1].error { log(e); exit(1) }
                try? await Task.sleep(for: .milliseconds(100))
            }
            core.togglePlay(0)
            try? await Task.sleep(for: .seconds(2))
            log(String(format: "A läuft: Position %.2f s", core.position(0)))
            core.toggleSync(1)
            core.togglePlay(1)
            try? await Task.sleep(for: .seconds(3))
            log(String(format: "B %.2f BPM vs Master %.2f · Phase %.4f Beats",
                       core.snapshot().decks[1].bpm, core.snapshot().decks[0].bpm, core.phaseError(1) ?? .nan))
            // Hauptthread 3 s blockieren: Audio und Sync müssen weiterlaufen
            let p0 = core.position(0)
            core.setTempo(0, 3)
            Thread.sleep(forTimeInterval: 3)
            log(String(format: "Hauptthread 3 s blockiert: A lief %.2f s weiter, B folgt %.2f BPM, Phase %.4f",
                       core.position(0) - p0, core.snapshot().decks[1].bpm, core.phaseError(1) ?? .nan))
            core.autoLoop(0, size: 4)
            try? await Task.sleep(for: .seconds(4))
            let l = core.engine.loop(0), pos = core.position(0)
            log("Loop aktiv laut Engine: \(l.active), laut Kern: \(core.snapshot().decks[0].loopActive)")
            log(String(format: "Loop A %.2f–%.2f, Position %.2f, im Loop: %@", l.start, l.end, pos,
                       "\(pos >= l.start - 0.01 && pos <= l.end + 0.01)"))
            core.exitLoop(0)
            let before = core.position(0)
            core.beatjump(0, beats: 16)
            try? await Task.sleep(for: .milliseconds(100))
            log(String(format: "Beatjump +16: %.2f → %.2f", before, core.position(0)))
            // FX messen: Pegel am Kanal A ohne Effekt, mit Filter (Highpass zu), mit Reverb
            func level() async -> Float {
                var acc: Float = 0
                for _ in 0..<20 { try? await Task.sleep(for: .milliseconds(50)); acc += core.engine.levels[0].rms }
                return acc / 20
            }
            log("FX-Zuweisung A: \(core.snapshot().decks[0].fxAssign)")
            let dry = await level()
            core.updateFX(0) { $0.slots[0].on = true; $0.slots[0].amount = 1.0 }
            let hp = await level()
            core.updateFX(0) { $0.slots[0].on = false; $0.slots[2].on = true; $0.slots[2].amount = 1.0 }
            let rev = await level()
            core.updateFX(0) { $0.slots[2].on = false }
            log(String(format: "Pegel A: trocken %.3f · Filter HP %.3f (%.0f %%) · Reverb %.3f (%.0f %%)",
                       dry, hp, hp / max(dry, 1e-6) * 100, rev, rev / max(dry, 1e-6) * 100))
            // nur die eigene Test-History entfernen (Datei dieser Sitzung), nichts anderes anfassen
            if ProcessInfo.processInfo.environment["MIX741_KEEP_HISTORY"] == nil, let url = SelfTest.historyURL {
                try? FileManager.default.removeItem(at: url)
                log("Test-History entfernt: \(url.lastPathComponent)")
            }
            log("SELFTEST OK")
        }
    }

    /// wird vom HistoryStore gesetzt, damit der Test genau seine eigene Datei entfernen kann
    nonisolated(unsafe) static var historyURL: URL?

    static func log(_ s: String) {
        print("[selftest] \(s)")
        fflush(stdout)
    }
}
