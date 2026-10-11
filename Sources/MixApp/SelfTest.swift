import AppKit
import AVFoundation
import Foundation
import UniformTypeIdentifiers
import MixCore
import MixEngine

/// Stummer Selbsttest (MIX741_SELFTEST=1): lädt zwei Tracks, spielt A, synct B, prüft Loop/Beatjump/FX
/// und dass Audio + Sync weiterlaufen, während der Hauptthread blockiert ist.
@MainActor
enum SelfTest {
    /// aus: Messungen mit der ganzen Oberfläche (ZoomShot), die Decks bleiben, wie sie sind
    static var enabled = true

    static func run(store: LibraryStore, mix: MixModel) {
        guard enabled, ProcessInfo.processInfo.environment["MIX741_SELFTEST"] == "1" else { return }
        let core = mix.core
        Task { @MainActor in
            let env = ProcessInfo.processInfo.environment
            for _ in 0..<20 where mix.outputDevices.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
            core.engine.deviceRate = nil   // Geräterate nie umstellen (ein anderes MINOS könnte gerade darauf spielen)
            if env["MIX741_NOEXT"] == nil, let ext = mix.outputDevices.first(where: { $0.channels >= 8 }) {   // externes Interface, jedes Deck auf ein eigenes Paar
                core.engine.apply(.init(device: ext.id, firstChannel: [0, 2, 4, 6]))
                log("Routing \(ext.name) extern: läuft=\(core.engine.running) Fehler=\(core.engine.lastError ?? "keine")")
            } else if let dev = mix.outputDevices.first(where: { d in env["MIX741_OUT"].map { d.name.localizedCaseInsensitiveContains($0) } ?? false })
                        ?? mix.outputDevices.first(where: { $0.channels == 2 && $0.name.localizedCaseInsensitiveContains("speaker") })
                        ?? mix.outputDevices.first(where: { $0.channels < 8 }) {
                // MIX741_NOEXT: nie auf das Interface einer laufenden Live-Session, sondern auf ein eingebautes
                // 2-Kanal-Gerät (MIX741_OUT=<Name> wählt eines); Master-Volume 0 -> stumm
                core.engine.apply(.init(device: dev.id, firstChannel: [0, 0, 0, 0]))
                log("Routing \(dev.name) (Selbsttest, stumm): läuft=\(core.engine.running) Fehler=\(core.engine.lastError ?? "keine")")
            }
            core.engine.setMasterVolume(0)   // stumm, Einstellung bleibt unverändert
            log("Audio: Gerät \(core.engine.outputRate) Hz, Kern \(core.engine.sampleRate) Hz, Raten \(MixEngine.availableRates(mix.currentDevice?.id ?? MixEngine.defaultOutputDevice() ?? 0))")
            // Link nur auf Wunsch (sonst würde der Test das Tempo einer laufenden Link-Session ändern)
            core.setLinkEnabled(ProcessInfo.processInfo.environment["MIX741_LINKTEST"] != nil)
            var p = mix.prefs.engine
            p.historyThreshold = 3            // nur im Test: schnell als gespielt markieren (nicht gespeichert)
            p.phraseAnchor = .suggest         // nur vorschlagen: der Test verschiebt keinen Anker (keine eigenen Änderungen)
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
            // Phrasen-Anker läuft nach dem Laden im Hintergrund (Vorschlag oder keiner)
            try? await Task.sleep(for: .milliseconds(800))
            for d in 0..<2 {
                let s = core.snapshot().decks[d]
                log(String(format: "Phrasen-Anker %@: %@", deckLetters[d], s.phraseSuggestion.map { String(format: "%+d Beats (Sicherheit %.2f)", $0, s.phraseConfidence) } ?? "kein Vorschlag"))
            }
            // nur Bild: beide Decks auf 1:00 stellen, nicht abspielen, kurz stehen lassen (für Screenshots)
            if ProcessInfo.processInfo.environment["MIX741_SNAPSHOT"] != nil {
                core.seek(0, seconds: 60); core.seek(1, seconds: 60)
                try? await Task.sleep(for: .seconds(2))
                log("SNAPSHOT bereit")
                try? await Task.sleep(for: .seconds(8))
                exit(0)
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
            // Master-Clock: MINOS gibt das Tempo vor, B (Sync) folgt Tempo und Phase der Clock
            core.setClockMaster(true)
            core.setClockBPM(126)
            try? await Task.sleep(for: .seconds(3))
            log(String(format: "Clock-Master 126: B %.2f BPM, Phase zur Clock %.4f Beats, Clock-Beat %.2f",
                       core.snapshot().decks[1].bpm, core.phaseError(1) ?? .nan, core.engine.clockBeat))
            core.setClockMaster(false)
            // Semi-Sync-Start: B ungesynct stoppen und neu starten, A ist Master -> B springt beim Start in Phase,
            // Tempo (von Sync übernommen) und Sync-Zustand bleiben; danach wieder Sync wie zuvor
            try? await Task.sleep(for: .milliseconds(300))   // Sync zieht B erst wieder auf A nach
            core.toggleSync(1)
            core.togglePlay(1)
            try? await Task.sleep(for: .milliseconds(300))
            core.setSemiSync(true)
            let semiTempo = core.snapshot().decks[1].tempoPct, semiBefore = core.phaseError(1) ?? .nan
            core.togglePlay(1)
            try? await Task.sleep(for: .seconds(1))
            let sB = core.snapshot().decks[1]
            log(String(format: "Semi-Start B ungesynct (A Master): Phase vor Start %.4f, nach 1 s %.4f Beats (soll < 0.05) · B %.2f vs A %.2f BPM · Tempo %.2f -> %.2f %% · Sync %@",
                       semiBefore, core.phaseError(1) ?? .nan, sB.bpm, core.snapshot().decks[0].bpm, semiTempo, sB.tempoPct, "\(sB.sync)"))
            core.setSemiSync(false)
            core.toggleSync(1)
            core.autoLoop(0, size: 4)
            try? await Task.sleep(for: .seconds(4))
            let l = core.engine.loop(0), pos = core.position(0)
            log("Loop aktiv laut Engine: \(l.active), laut Kern: \(core.snapshot().decks[0].loopActive)")
            log(String(format: "Loop A %.2f–%.2f, Position %.2f, im Loop: %@", l.start, l.end, pos,
                       "\(pos >= l.start - 0.01 && pos <= l.end + 0.01)"))
            // Takt-Sprung im 8-Beat-Loop: Loop bleibt, Position +4 Beats (umlaufend)
            core.exitLoop(0)
            core.autoLoop(0, size: 8)
            try? await Task.sleep(for: .milliseconds(300))
            let l8 = core.engine.loop(0), q0 = core.position(0), t0 = Date()
            let ph0 = core.phaseError(1) ?? .nan
            core.barJump(0, bars: 1)
            try? await Task.sleep(for: .milliseconds(50))
            let l8b = core.engine.loop(0), q1 = core.position(0), len = l8.end - l8.start
            let rate = core.snapshot().decks[0].bpm / 130.000473   // Wiedergabe-Rate, abgelaufene Zeit abziehen
            var moved = (q1 - q0 - Date().timeIntervalSince(t0) * rate).truncatingRemainder(dividingBy: len); if moved < 0 { moved += len }
            log(String(format: "Phase B vor/nach Takt-Sprung: %.4f / %.4f Beats", ph0, core.phaseError(1) ?? .nan))
            log(String(format: "Takt-Sprung im Loop: Loop gleich %@, Versatz %.3f von %.3f Beats (soll 4)",
                       "\(abs(l8b.start - l8.start) < 0.001)", moved / len * 8, 8.0))
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
            // FX 3 im Single-Modus (Delay) auf Deck A
            core.toggleFXAssign(0, 2)
            core.updateFX(2) { $0.single = true; $0.singleType = FXUnitState.Effect.delay.rawValue; $0.singleOn = true; $0.params = [0.5, 0.7, 0.5] }
            try? await Task.sleep(for: .seconds(1))
            core.togglePlay(0)                       // Deck stoppen: hörbar bleibt nur noch die Echo-Fahne
            try? await Task.sleep(for: .milliseconds(150))
            let tail = await level()
            core.updateFX(2) { $0.singleOn = false }   // aus: Eingang zu, Echo muss weiter ausklingen
            try? await Task.sleep(for: .milliseconds(200))
            let spill = await level()
            try? await Task.sleep(for: .seconds(4))
            let gone = await level()
            core.toggleFXAssign(0, 2)
            log(String(format: "FX3 Single-Delay: Echo nach Stopp %.3f (ohne Delay ~0)", tail))
            log(String(format: "FX3 aus: Echo klingt aus %.3f, nach 4 s %.4f", spill, gone))
            // Reverb (FX4 Single): D/W 0 = trocken unverändert, D/W hoch = Hall aus den Höhen dazu, aus = klingt lange aus
            core.togglePlay(0)
            core.toggleFXAssign(0, 3)
            core.updateFX(3) { $0.single = true; $0.singleType = FXUnitState.Effect.reverb.rawValue; $0.singleOn = true
                               $0.params = [0.9, 0.75, 1.0]; $0.dryWet = 0 }
            let rDry = await level()
            core.updateFX(3) { $0.dryWet = 1 }
            try? await Task.sleep(for: .seconds(2))
            let rWet = await level()
            core.updateFX(3) { $0.dryWet = 0 }       // Drop: nichts Neues mehr in den Hall
            core.togglePlay(0)
            try? await Task.sleep(for: .seconds(1))
            let r1 = await level()
            try? await Task.sleep(for: .seconds(3))
            let r4 = await level()
            core.updateFX(3) { $0.singleOn = false }
            core.toggleFXAssign(0, 3)
            log(String(format: "Reverb Single HP: D/W 0 %.3f (trocken %.3f) · D/W 1 %.3f · nach Drop 1 s %.4f · 4 s %.4f",
                       rDry, dry, rWet, r1, r4))
            core.togglePlay(0)
            // Plugin (FX4 Single): Apples AUMatrixReverb, lädt im Hintergrund, Regler = erste 3 Parameter, Fahne nach Stopp
            core.toggleFXAssign(0, 3)
            core.setPlugin(3, id: "aufx:mrev:appl")
            for _ in 0..<60 where core.pluginParamNames(3).isEmpty { try? await Task.sleep(for: .milliseconds(50)) }
            core.updateFX(3) { $0.singleOn = true; $0.dryWet = 0.5 }
            try? await Task.sleep(for: .seconds(1))
            let pWet = await level()
            core.updateFX(3) { $0.singleOn = false }
            core.togglePlay(0)
            try? await Task.sleep(for: .milliseconds(150))
            let pTail = await level()
            let pNames = core.pluginParamNames(3).joined(separator: "/"), pErr = core.snapshot().pluginErrors[3]
            core.setPlugin(3, id: nil)
            core.toggleFXAssign(0, 3)
            core.togglePlay(0)
            log(String(format: "Plugin %@: Regler %@ · D/W 0.5 %.3f · Fahne nach Stopp %.4f%@",
                       "aufx:mrev:appl", pNames, pWet, pTail, pErr.map { " · Fehler: \($0)" } ?? ""))
            log(String(format: "Pegel A: trocken %.3f · Filter HP %.3f (%.0f %%) · Reverb %.3f (%.0f %%)",
                       dry, hp, hp / max(dry, 1e-6) * 100, rev, rev / max(dry, 1e-6) * 100))
            if env["MIX741_BENCH"] == "load" { await loadProbe(core, tracks: c) }
            // nur die eigene Test-History entfernen (Datei dieser Sitzung), nichts anderes anfassen
            if ProcessInfo.processInfo.environment["MIX741_KEEP_HISTORY"] == nil, let url = SelfTest.historyURL {
                try? FileManager.default.removeItem(at: url)
                log("Test-History entfernt: \(url.lastPathComponent)")
            }
            log("SELFTEST OK")
            fflush(stdout)
            if ProcessInfo.processInfo.environment["MIX741_STAY"] == nil { exit(0) }
        }
    }

    /// MIX741_BENCH=load: Lastprobe am Gerät. 4 Decks mit Keylock (Tempo ±3 %), Hall auf FX 1 (A/C), Plugin
    /// AUMatrixReverb auf FX 2 (B/D), Puffer 64 / 128 / 256 je MIX741_BENCH_SECS s (8): DSP-Last (Mittel, Spitze),
    /// Blöcke über Budget (eigene Messung) und Überlastmeldungen des Geräts. Stumm, nur eingebautes Gerät
    /// (MIX741_NOEXT=1); die Puffergröße wird danach zurückgestellt. Statusleiste holt dieselben Werte (4 Hz) ab:
    /// die Blockzahl zeigt, wie viel die Probe davon gesehen hat
    static func loadProbe(_ core: MixController, tracks c: [Track]) async {
        let engine = core.engine
        let secs = Double(ProcessInfo.processInfo.environment["MIX741_BENCH_SECS"] ?? "") ?? 8
        core.load(c[min(2, c.count - 1)], deck: 2)
        core.load(c[min(3, c.count - 1)], deck: 3)
        for _ in 0..<300 where core.trackAudio(2) == nil || core.trackAudio(3) == nil {
            let s = core.snapshot()
            if let e = s.decks[2].error ?? s.decks[3].error { log("Lastprobe: \(e)"); return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard core.trackAudio(2) != nil, core.trackAudio(3) != nil else { log("Lastprobe: Decks C/D nicht geladen"); return }
        for d in 0..<4 { core.updateDeck(d) { $0.keylock = true; $0.tempoPct = d % 2 == 0 ? 3 : -3 } }
        core.updateFX(0) { $0.single = true; $0.singleType = FXUnitState.Effect.reverb.rawValue; $0.singleOn = true
                           $0.params = [0.8, 0.3, 1.0]; $0.dryWet = 1 }
        core.setPlugin(1, id: "aufx:mrev:appl")
        for _ in 0..<60 where core.pluginParamNames(1).isEmpty { try? await Task.sleep(for: .milliseconds(50)) }
        core.updateFX(1) { $0.singleOn = true; $0.dryWet = 0.5 }
        for d in 0..<4 where !core.snapshot().decks[d].playing { core.togglePlay(d) }
        let saved = engine.bufferFrames
        for frames: UInt32 in [64, 128, 256] {
            engine.bufferFrames = frames
            engine.apply(engine.routing, restart: true)
            try? await Task.sleep(for: .seconds(1))   // einschwingen, erste Blöcke nach dem Start nicht zählen
            engine.resetOverloads()
            _ = engine.takeLoad()
            var busy = 0.0, blocks = 0, peak = 0.0
            let t0 = Date()
            while Date().timeIntervalSince(t0) < secs {
                try? await Task.sleep(for: .milliseconds(50))
                let l = engine.takeLoad()
                busy += l.average * Double(l.blocks); blocks += l.blocks; peak = max(peak, l.peak)
            }
            let l = engine.takeLoad()
            let playing = (0..<4).filter { core.snapshot().decks[$0].playing }.count
            log(String(format: "Lastprobe Puffer %d (Gerät %d Frames, %.1f ms Latenz, %.0f Hz, %d Decks): DSP %.1f %% · Spitze %.0f %% · %d Blöcke in %.0f s · über Budget %d · Gerät überlastet %d",
                       frames, l.bufferFrames, l.outputLatency * 1000, l.sampleRate, playing,
                       busy / Double(max(1, blocks)) * 100, peak * 100, blocks, secs, l.overloads, l.deviceOverloads))
        }
        engine.bufferFrames = saved
        engine.apply(engine.routing, restart: true)
        for d in 0..<4 where core.snapshot().decks[d].playing { core.togglePlay(d) }
        core.updateFX(1) { $0.singleOn = false }
        core.setPlugin(1, id: nil)
        core.updateFX(0) { $0.singleOn = false }
    }

    /// wird vom HistoryStore gesetzt, damit der Test genau seine eigene Datei entfernen kann
    nonisolated(unsafe) static var historyURL: URL?

    static func log(_ s: String) {
        print("[selftest] \(s)")
        fflush(stdout)
    }
}

/// Nur Bild (MIX741_SHOT=wave:<png>, Selbsttest): die Wellenform-Ebene eines Decks offscreen rendern – kein Fenster,
/// kein Audio, keine Controller. Oben der Zoom aus den Einstellungen, unten 4× weiter heraus; Grid-Anker links im Bild,
/// Spielkopf in einem 4-Beat-Loop, zwei Hotcues, darunter die Übersicht. Erster Track der Collection mit 120–140 BPM und Grid, wie im Selbsttest.
/// Optional: MIX741_SHOT_TRACK (Teil von Interpret/Titel/Pfad), MIX741_SHOT_AT (Sekunden, Spielkopf, ohne Loop),
/// MIX741_SHOT_SPAN (Sekunden je Seite), MIX741_SHOT_STYLE (Komma-Liste: 3band, spectrum, fine, fine-mix, mono →
/// je Stil zwei Streifen untereinander, beschriftet), MIX741_SHOT_PALETTE (bone, orange, blue, classic), MIX741_SHOT_BOOST.
@MainActor
enum WaveShot {
    static func run(path: String) -> Never {
        do {
            try render(to: URL(fileURLWithPath: path))
            SelfTest.log("SHOT \(path)")
            exit(0)
        } catch {
            SelfTest.log("SHOT Fehler: \(error)")
            exit(1)
        }
    }

    enum ShotError: Error { case noTrack, context, png }

    /// Stil-Kürzel → (Stil, Spektrum-Variante, Beschriftung)
    private static func look(_ k: String, _ ui: UIPrefs) -> (WaveformStyle, SpectrumDetail, String) {
        switch k.trimmingCharacters(in: .whitespaces) {
        case "3band": (.threeBand, ui.spectrumDetail, "3-band layers")
        case "spectrum": (.spectrum, .simple, "spectrum (3 bands)")
        case "fine": (.spectrum, .fine, "spectrum fine (6 bands)")
        case "fine-mix": (.spectrum, .fineMix, "spectrum fine, no high layer")
        case "mono": (.mono, ui.spectrumDetail, "mono")
        default: (ui.waveformStyle, ui.spectrumDetail, "settings")
        }
    }

    private static func render(to url: URL) throws {
        let env = ProcessInfo.processInfo.environment
        var ui = AppPrefs.load().ui
        if let p = env["MIX741_SHOT_PALETTE"] {
            ui.waveformPalette = ["bone": .bone, "orange": .orange, "blue": .blue, "classic": .classic][p] ?? ui.waveformPalette
        }
        if let b = env["MIX741_SHOT_BOOST"].flatMap(Double.init) { ui.waveformHighBoost = b }
        if let sp = env["MIX741_SHOT_SPAN"].flatMap(Double.init) { ui.waveformSeconds = sp }
        let tracks = try NMLParser.parse(url: LibraryStore.defaultNML).tracks
        let want = env["MIX741_SHOT_TRACK"]?.lowercased()
        guard let t = tracks.first(where: { t in
            guard FileManager.default.fileExists(atPath: t.path) else { return false }
            if let want { return "\(t.artist) \(t.title) \(t.path)".lowercased().contains(want) }
            return t.bpm > 120 && t.bpm < 140 && t.gridAnchorMs != nil
        }) else { throw ShotError.noTrack }
        let grid = BeatGrid(track: t)
        SelfTest.log("Track: \(t.artist) – \(t.title) \(t.bpm) BPM")
        let file = URL(fileURLWithPath: t.path)
        let rate = try AVAudioFile(forReading: file).processingFormat.sampleRate   // Dateirate: keine Wandlung nötig
        let t0 = Date()
        let audio = try TrackAudio.decode(url: file, sampleRate: rate)
        SelfTest.log(String(format: "dekodiert + analysiert: %.2f s für %.0f s Audio", Date().timeIntervalSince(t0), audio.duration))
        let at = env["MIX741_SHOT_AT"].flatMap(Double.init)
        let pos = at ?? grid.map { $0.time(ofBeat: 6.3) } ?? 10
        let loop = at == nil && grid != nil
            ? (active: true, start: grid!.time(ofBeat: 4), end: grid!.time(ofBeat: 8)) : (active: false, start: 0.0, end: 0.0)
        let looks = (env["MIX741_SHOT_STYLE"] ?? "settings").split(separator: ",").map { look(String($0), ui) }
        let w: CGFloat = 1200, h: CGFloat = 180, gap: CGFloat = 8, label: CGFloat = 18, scale: CGFloat = 2, oh: CGFloat = 48
        let rowH = (label + h * 2 + oh + gap * 3)
        let totalH = rowH * CGFloat(looks.count)
        guard let ctx = CGContext(data: nil, width: Int(w * scale), height: Int(totalH * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ShotError.context }
        ctx.scaleBy(x: scale, y: scale)
        ctx.setFillColor(NSColor(Theme.background).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: totalH))
        let tick = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in }   // hält den Run-Loop wach
        defer { tick.invalidate() }
        for (row, lk) in looks.enumerated() {
            let tr = Date()
            let wf = RenderedWaveform.render(audio, style: lk.0, palette: ui.waveformPalette, detail: lk.1, highBoost: ui.waveformHighBoost)
            SelfTest.log(String(format: "%@: Wellenform gerechnet in %.2f s, %.0f Pfade je Abschnitt", lk.2, Date().timeIntervalSince(tr), Double(wf.chunks.reduce(0) { $0 + $1.layers.count }) / Double(max(1, wf.chunks.count))))
            let view = WaveLayerNSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
            view.position = { pos }
            view.loop = { loop }
            view.wave = wf
            var scene = WaveScene(
                waveID: ObjectIdentifier(wf), duration: audio.duration, grid: grid, span: ui.waveformSeconds,
                showGrid: true, colorful: ui.colorfulGrid, phraseBeats: ui.phraseBeats, barNumbers: ui.showBarNumbers, barMarkers: ui.barMarkers,
                dimPlayed: ui.dimPlayed,
                cues: grid.map { g in [WaveScene.Mark(t: g.time(ofBeat: 2), number: 1, color: NSColor(Theme.cueColor(.cue))),
                                       WaveScene.Mark(t: g.time(ofBeat: 12), number: 2, color: NSColor(Theme.cueColor(.loop)))] } ?? [],
                cuePoint: grid?.anchor ?? 0, hasTrack: true)
            let top = totalH - CGFloat(row) * rowH   // CG: y nach oben
            let text = String(format: "%@ · %@ – %@ · %.0f s", lk.2, t.artist, t.title, pos) as NSString
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            text.draw(at: NSPoint(x: 6, y: top - label + 3),
                      withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor(Theme.bone)])
            NSGraphicsContext.restoreGraphicsState()
            for (i, span) in [ui.waveformSeconds, ui.waveformSeconds * 4].enumerated() {
                scene.span = span
                view.scene = scene
                RunLoop.main.run(until: Date() + 1.5)   // Kacheln kommen von der Hintergrund-Queue auf den Hauptthread
                ctx.saveGState()
                ctx.translateBy(x: 0, y: top - label - h - CGFloat(i) * (h + gap))
                view.layer?.render(in: ctx)
                ctx.restoreGState()
            }
            // Übersicht (ganzer Track) darunter
            if let img = wf.overview {
                let r = CGRect(x: 0, y: top - label - h * 2 - gap * 2 - oh, width: w, height: oh)
                ctx.setFillColor(NSColor(Theme.wave).cgColor)
                ctx.fill(r)
                ctx.draw(img, in: r)
            }
        }
        guard let img = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw ShotError.png }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { throw ShotError.png }
    }
}
