import AppKit
import AVFoundation
import Foundation
import QuartzCore
import UniformTypeIdentifiers
import MixCore
import MixEngine

/// Stummer Selbsttest (MIX741_SELFTEST=1): lädt zwei Tracks, spielt A, synct B, prüft Loop/Beatjump/FX
/// und dass Audio + Sync weiterlaufen, während der Hauptthread blockiert ist.
@MainActor
enum SelfTest {
    /// aus: Messungen mit der ganzen Oberfläche (ZoomShot), die Decks bleiben, wie sie sind
    static var enabled = true

    static func run(store: LibraryStore, mix: MixModel, browser: BrowserState) {
        guard enabled, ProcessInfo.processInfo.environment["MIX741_SELFTEST"] == "1" else { return }
        let core = mix.core
        Task { @MainActor in
            let env = ProcessInfo.processInfo.environment
            for _ in 0..<20 where mix.outputDevices.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
            core.engine.deviceRate = nil   // Geräterate nie umstellen (ein anderes MINOS könnte gerade darauf spielen)
            let named = env["MIX741_OUT"].flatMap { n in mix.outputDevices.first { $0.channels >= 8 && $0.name.localizedCaseInsensitiveContains(n) } }
            if env["MIX741_NOEXT"] == nil, let ext = named ?? mix.outputDevices.first(where: { $0.channels >= 8 }) {   // externes Interface, jedes Deck auf ein eigenes Paar
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
            if env["MIX741_BENCH"] == "memory" { await memoryProbe(core, tracks: store.tracks); exit(0) }
            if env["MIX741_BENCH"] == "loadtest" { await LoadTest.run(core, tracks: store.tracks); exit(0) }
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
            // Beat-FX (FX3 Single) auf Deck A: Pegel an / nach dem Ausschalten (Roll: Deck läuft darunter weiter)
            core.toggleFXAssign(0, 2)
            for e in FXCatalog.beatFX {
                core.updateFX(2) { $0.single = true; $0.singleType = e.rawValue; $0.singleOn = true; $0.dryWet = 1 }
                let on = await level()
                core.updateFX(2) { $0.singleOn = false }
                let off = await level()
                log(String(format: "%@ Single: an %.3f · aus %.3f (trocken %.3f)", e.name, on, off, dry))
            }
            core.toggleFXAssign(0, 2)
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
            await deviceProbe(core)
            await parallelProbe(core)
            await previewProbe(mix, tracks: c)
            await cutProbe(mix, tracks: c)
            await profileProbe(mix, browser: browser)
            await undoProbe(mix, store: store)
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

    /// Ansichts-Profile: die zwei Standard-Profile nacheinander anwenden, Felder und sichtbare Decks prüfen,
    /// Umschaltzeit (Felder setzen + Layout des Hauptfensters + Übergabe an Core Animation) messen, danach zurück
    static func profileProbe(_ mix: MixModel, browser: BrowserState) async {
        let savedUI = mix.prefs.ui, savedBig = browser.maximized, savedFocus = mix.focusedDeck
        let root = MainWindow.window?.contentView
        func decks() -> [Int] {
            var out: [Int] = [], stack = root.map { [$0] } ?? []
            while let v = stack.popLast() {
                if let h = v as? BoundaryHostingView<DeckHost.Root>, !h.isHiddenOrHasHiddenAncestor { out.append(h.rootView.d) }
                stack += v.subviews
            }
            return out.sorted()
        }
        var times: [Double] = []
        for round in 0..<3 {
            for p in LayoutProfile.defaults(from: savedUI) {
                mix.focusedDeck = 1
                let t0 = CACurrentMediaTime()
                LayoutProfiles.apply(p, mix: mix, browser: browser)
                root?.layoutSubtreeIfNeeded()
                CATransaction.flush()
                let dt = (CACurrentMediaTime() - t0) * 1000
                if round > 0 { times.append(dt) }   // erste Runde: Aufwärmen
                try? await Task.sleep(for: .milliseconds(150))
                let ui = mix.prefs.ui, shown = decks()
                let want = Array([0, 1, 2, 3].prefix(p.deckCount >= 4 ? 4 : p.deckCount))
                let ok = p.matches(ui, maximized: browser.maximized) && ui.activeProfile?.id == p.id
                    && !ui.profileModified(maximized: browser.maximized) && (root == nil || shown == want)
                    && (p.deckCount > 1 || mix.focusedDeck == 0)   // 1 Deck: Fokus auf A
                if round == 0 {
                    log(String(format: "Profil %@: %d Decks (sichtbar %@), Mixer %@, Browser %@ %.0f pt, Statusleiste %@ · %.1f ms",
                               p.name, ui.deckCount, root == nil ? "kein Fenster" : shown.map { deckLetters[$0] }.joined(),
                               "\(ui.showMixer)", ui.browserLayout.rawValue, ui.browserHeight, ui.statusBar.rawValue, dt))
                }
                guard ok else { log("FEHLER Profil \(p.name): Felder oder Decks stimmen nicht (sichtbar \(shown))"); exit(1) }
            }
        }
        // Änderung nach dem Umschalten -> „geändert“, Profil bleibt aktiv
        mix.prefs.ui.showMixer.toggle()
        let changed = mix.prefs.ui.profileModified(maximized: browser.maximized) && mix.prefs.ui.activeProfile != nil
        mix.prefs.ui = savedUI
        browser.maximized = savedBig
        mix.focusedDeck = savedFocus
        let s = times.sorted()
        log(String(format: "Profil umschalten (Hauptthread, Felder + Layout + Übergabe): median %.1f ms, max %.1f ms (n=%d) · Änderung erkannt %@",
                   s.isEmpty ? .nan : s[s.count / 2], s.last ?? .nan, s.count, "\(changed)"))
        guard changed else { log("FEHLER Profil: Änderung nicht erkannt"); exit(1) }
    }

    /// Geräte-Pfade ohne Ziehen/Stecken: Gerät weg (eingespeist) -> warten -> dasselbe Gerät neu öffnen, Ratenwechsel
    /// (eingespeist, Geräterate bleibt), Puffer am Gerät geändert (echter Listener), Ruhezustand/Aufwachen. Deck A spielt
    /// dabei weiter (Position läuft nach jedem Schritt)
    static func deviceProbe(_ core: MixController) async {
        let engine = core.engine
        let wasPlaying = core.snapshot().decks[0].playing
        if !wasPlaying { core.togglePlay(0) }
        func waitRunning() async -> Double {
            let t0 = Date()
            for _ in 0..<60 where engine.watch.phase != .running { try? await Task.sleep(for: .milliseconds(50)) }
            return Date().timeIntervalSince(t0)
        }
        func advancing() async -> Bool {
            let p0 = core.position(0)
            try? await Task.sleep(for: .milliseconds(300))
            return core.position(0) > p0 + 0.1
        }
        let n0 = engine.watch.reconnects
        engine.simulate(.alive(false))
        let lost = engine.watch.phase, stopped = !engine.running
        let back = await waitRunning()
        log(String(format: "Gerät weg (eingespeist): %@, Ausgabe aus %@ -> wieder verbunden nach %.0f ms (Öffnen %.0f ms), Neuverbindungen %d, A läuft %@",
                   lost.rawValue, "\(stopped)", back * 1000, (engine.lastReconnect ?? .nan) * 1000, engine.watch.reconnects - n0,
                   "\(await advancing())"))
        let rate = engine.outputRate
        engine.simulate(.rate(rate + 1000))
        let rr = await waitRunning()
        log(String(format: "Ratenwechsel (eingespeist): neu geöffnet nach %.0f ms, Gerät %.0f Hz (unverändert %@), Kern %.0f Hz, A läuft %@",
                   rr * 1000, engine.outputRate, "\(engine.outputRate == rate)", engine.sampleRate, "\(await advancing())"))
        let buf = engine.takeLoad().bufferFrames, want: UInt32 = buf == 256 ? 512 : 256
        engine.setDeviceBufferForTest(want)
        for _ in 0..<20 where engine.takeLoad().bufferFrames != Int(want) { try? await Task.sleep(for: .milliseconds(50)) }
        let l = engine.takeLoad()
        log(String(format: "Puffer am Gerät %d -> %d: gemeldet %d Frames, Latenz %.1f ms, Pufferwechsel %d, A läuft %@",
                   buf, want, l.bufferFrames, l.outputLatency * 1000, engine.watch.bufferChanges, "\(await advancing())"))
        engine.setDeviceBufferForTest(UInt32(buf))
        try? await Task.sleep(for: .milliseconds(200))
        engine.willSleep()
        let sleeping = engine.watch.phase, quiet = !engine.running, pos = core.position(0)
        try? await Task.sleep(for: .milliseconds(300))
        let frozen = abs(core.position(0) - pos) < 0.01
        engine.didWake()
        let woke = await waitRunning()
        log(String(format: "Ruhezustand: %@, Ausgabe aus %@, Position steht %@ -> aufgewacht, läuft nach %.0f ms, A läuft %@, Deck spielt %@",
                   sleeping.rawValue, "\(quiet)", "\(frozen)", woke * 1000, "\(await advancing())", "\(core.snapshot().decks[0].playing)"))
        if !wasPlaying { core.togglePlay(0) }
    }

    /// Decks parallel am laufenden Gerät: einschalten, Blöcke laufen weiter, keine Überläufe, Position läuft; danach zurück
    static func parallelProbe(_ core: MixController) async {
        let engine = core.engine
        let was = engine.parallelDecks
        let wasPlaying = core.snapshot().decks[0].playing
        if !wasPlaying { core.togglePlay(0) }
        _ = engine.takeLoad()
        engine.resetOverloads()
        engine.parallelDecks = true
        let p0 = core.position(0)
        try? await Task.sleep(for: .milliseconds(600))
        let l = engine.takeLoad()
        let moved = core.position(0) - p0
        let info = engine.parallelInfo
        engine.parallelDecks = was
        try? await Task.sleep(for: .milliseconds(200))
        let l2 = engine.takeLoad()
        let ok = l.blocks > 0 && l.overloads == 0 && moved > 0.4 && l2.blocks > 0 && info.joined == info.workers && info.realtime == info.workers
        log(String(format: "Decks parallel: an -> %d Blöcke, DSP %.1f %% (Spitze %.0f %%), über Budget %d, A lief %.2f s, Worker %d (Workgroup %d, Echtzeit %d); zurück %@ -> %d Blöcke · %@",
                   l.blocks, l.average * 100, l.peak * 100, l.overloads, moved, info.workers, info.joined, info.realtime, "\(was)", l2.blocks,
                   ok ? "OK" : "FAIL"))
        if !ok { log("FEHLER Decks parallel: Ausgabe läuft nicht sauber"); exit(1) }
        if !wasPlaying { core.togglePlay(0) }
    }

    /// MIX741_BENCH=memory: 4 lange Tracks (MIX741_BENCH_MIN Minuten, 10) laden, nur lokal vorhandene (nichts aus der
    /// Cloud), alle 4 spielen; Speicher (RSS, Footprint, fest), mlock-Fehler, Speicherdruck, Aussetzer beim Laden.
    /// Kernrate wie live mit MIX741_CORE_RATE (z. B. 96000)
    static func memoryProbe(_ core: MixController, tracks all: [Track]) async {
        let env = ProcessInfo.processInfo.environment
        let minSecs = (Double(env["MIX741_BENCH_MIN"] ?? "") ?? 10) * 60
        func local(_ t: Track) -> Bool {
            var st = stat()
            return stat(t.path, &st) == 0 && st.st_size > 0 && st.st_flags & UInt32(SF_DATALESS) == 0
        }
        let pick = Array(all.filter { $0.duration >= minSecs && $0.duration <= minSecs * 2.5 }
            .sorted { $0.duration > $1.duration }.lazy.filter(local).prefix(4))
        guard pick.count == 4 else { log("Speicherprobe: nur \(pick.count) lokale Tracks ≥ \(Int(minSecs / 60)) min"); return }
        func mem() -> String { Mem.line() }
        log(String(format: "Speicherprobe: Kern %.0f Hz, Gerät %.0f Hz · vorher %@", core.engine.sampleRate, core.engine.outputRate, mem()))
        for (d, t) in pick.enumerated() { log(String(format: "  %@: %.1f min · %@", deckLetters[d], t.duration / 60, t.title)) }
        core.engine.resetOverloads()
        _ = core.engine.takeLoad()
        let lock0 = core.fileService?.stats.lockFailures ?? 0, t0 = Date()
        for (d, t) in pick.enumerated() { core.load(t, deck: d) }
        for _ in 0..<1800 where (0..<4).contains(where: { core.trackAudio($0) == nil }) {
            let s = core.snapshot()
            if let e = (0..<4).compactMap({ s.decks[$0].error }).first { log("Speicherprobe: \(e)"); return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let loaded = (0..<4).filter { core.trackAudio($0) != nil }.count
        let bytes = (0..<4).compactMap { core.trackAudio($0) }.reduce(0) { $0 + $1.frames * 2 * 4 }
        log(String(format: "Speicherprobe: %d/4 geladen in %.1f s, Audio %.2f GB (Float, Kernrate) · mlock fehlgeschlagen %d · %@",
                   loaded, Date().timeIntervalSince(t0), Double(bytes) / 1_073_741_824,
                   (core.fileService?.stats.lockFailures ?? 0) - lock0, mem()))
        for d in 0..<4 { core.updateDeck(d) { $0.keylock = true } }
        for d in 0..<4 where !core.snapshot().decks[d].playing { core.togglePlay(d) }
        try? await Task.sleep(for: .seconds(Double(env["MIX741_BENCH_SECS"] ?? "") ?? 10))
        let l = core.engine.takeLoad()
        log(String(format: "Speicherprobe: 4 Decks Keylock spielen · DSP %.1f %% · Spitze %.0f %% · über Budget %d · Gerät überlastet %d · %@",
                   l.average * 100, l.peak * 100, l.overloads, l.deviceOverloads, mem()))
        for d in 0..<4 where core.snapshot().decks[d].playing { core.togglePlay(d) }
    }

    /// MIX741_BENCH=load: Lastprobe am Gerät. 4 Decks mit Keylock (Tempo ±3 %), Hall auf FX 1 (A/C), Plugin auf FX 2
    /// (B/D, MIX741_BENCH_PLUGIN=<id>, Standard AUMatrixReverb, "none" = ohne), Delay auf FX 3 (alle 4 Decks).
    /// Puffer MIX741_BENCH_BUFFERS (512,256,128) je MIX741_BENCH_SECS s (8; live 600 = 30 min): DSP-Last (Mittel,
    /// Spitze), Blöcke über Budget (eigene Messung), Überlastmeldungen des Geräts, Zwischenstand jede Minute.
    /// Stumm (Master 0); ohne MIX741_NOEXT auf dem externen Interface. Puffergröße wird danach zurückgestellt.
    /// Die Statusleiste holt dieselben Werte (4 Hz) ab: die Blockzahl zeigt, wie viel die Probe davon gesehen hat
    static func loadProbe(_ core: MixController, tracks c: [Track]) async {
        let engine = core.engine, env = ProcessInfo.processInfo.environment
        let secs = Double(env["MIX741_BENCH_SECS"] ?? "") ?? 8
        let buffers = (env["MIX741_BENCH_BUFFERS"] ?? "512,256,128").split(separator: ",").compactMap { UInt32($0.trimmingCharacters(in: .whitespaces)) }
        let plugin = env["MIX741_BENCH_PLUGIN"] ?? "aufx:mrev:appl"
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
        if plugin != "none" {
            core.setPlugin(1, id: plugin)
            for _ in 0..<200 where core.pluginParamNames(1).isEmpty && core.snapshot().pluginErrors[1] == nil {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if let e = core.snapshot().pluginErrors[1] { log("Lastprobe: Plugin \(plugin): \(e)") }
            core.updateFX(1) { $0.singleOn = true; $0.dryWet = 0.5 }
        }
        let delayAssigned = (0..<4).map { core.snapshot().decks[$0].fxAssign[2] }
        for d in 0..<4 where !delayAssigned[d] { core.toggleFXAssign(d, 2) }
        core.updateFX(2) { $0.single = true; $0.singleType = FXUnitState.Effect.delay.rawValue; $0.singleOn = true
                           $0.params = [0.5, 0.6, 0.5]; $0.dryWet = 0.5 }
        for d in 0..<4 where !core.snapshot().decks[d].playing { core.togglePlay(d) }
        let saved = engine.bufferFrames
        log(String(format: "Lastprobe: Puffer %@ je %.0f s · Hall FX1 · Plugin FX2 %@ · Delay FX3 (A–D) · Keylock A–D",
                   buffers.map(String.init).joined(separator: "/"), secs, plugin))
        for frames in buffers {
            engine.bufferFrames = frames
            engine.apply(engine.routing, restart: true)
            try? await Task.sleep(for: .seconds(1))   // einschwingen, erste Blöcke nach dem Start nicht zählen
            engine.resetOverloads()
            _ = engine.takeLoad()
            var busy = 0.0, blocks = 0, peak = 0.0, minute = 0
            let t0 = Date()
            while Date().timeIntervalSince(t0) < secs {
                try? await Task.sleep(for: .milliseconds(50))
                let l = engine.takeLoad()
                busy += l.average * Double(l.blocks); blocks += l.blocks; peak = max(peak, l.peak)
                let m = Int(Date().timeIntervalSince(t0) / 60)
                if m > minute {
                    minute = m
                    log(String(format: "  Puffer %d · %d min: DSP %.1f %% · Spitze %.0f %% · über Budget %d · Gerät überlastet %d · Gerät neu verbunden %d",
                               frames, m, busy / Double(max(1, blocks)) * 100, peak * 100, l.overloads, l.deviceOverloads, l.reconnects))
                }
            }
            let l = engine.takeLoad()
            let playing = (0..<4).filter { core.snapshot().decks[$0].playing }.count
            log(String(format: "Lastprobe Puffer %d (Gerät %d Frames, %.1f ms Latenz, %.0f Hz, Kern %.0f Hz, %d Decks): DSP %.1f %% · Spitze %.0f %% · %d Blöcke in %.0f s · über Budget %d · Gerät überlastet %d",
                       frames, l.bufferFrames, l.outputLatency * 1000, l.sampleRate, engine.sampleRate, playing,
                       busy / Double(max(1, blocks)) * 100, peak * 100, blocks, secs, l.overloads, l.deviceOverloads))
        }
        engine.bufferFrames = saved
        engine.apply(engine.routing, restart: true)
        for d in 0..<4 where core.snapshot().decks[d].playing { core.togglePlay(d) }
        core.updateFX(2) { $0.singleOn = false }
        for d in 0..<4 where !delayAssigned[d] { core.toggleFXAssign(d, 2) }
        core.updateFX(1) { $0.singleOn = false }
        core.setPlugin(1, id: nil)
        core.updateFX(0) { $0.singleOn = false }
    }

    /// Vorhören im Kern, stumm (nur Pegel): Paar wie im Extern-Modus automatisch nach den Deck-Paaren des Testgeräts
    /// (2-Kanal-Gerät: keins frei -> 1/2), Ladezeit (zufälliger Track: meist dekodiert, dann aus dem Cache), Pegel, Sprung, Stopp.
    /// Deck A läuft weiter: Pegel und DSP-Last mit und ohne Vorhören
    static func previewProbe(_ mix: MixModel, tracks c: [Track]) async {
        let pv = mix.previewer, engine = mix.engine
        let r = engine.routing.firstChannel
        let pair = PreviewPlayer.autoPair(external: true, deckPairs: r, mainPair: 0, channels: engine.deviceChannels)
        pv.setOutput(firstChannel: pair ?? 0, mute: true)
        log("Vorhören: 12 Kanäle extern, Decks A 1/2 · B 5/6 · C 3/4 · D 7/8 -> automatisch "
            + (PreviewPlayer.autoPair(external: true, deckPairs: [0, 4, 2, 6], mainPair: 0, channels: 12).map { "\($0 + 1)/\($0 + 2)" } ?? "keins")
            + " · Testgerät \(engine.deviceChannels) Kanäle, Decks \(r.map { "\($0 + 1)/\($0 + 2)" }.joined(separator: " ")) -> "
            + (pair.map { "\($0 + 1)/\($0 + 2)" } ?? "keins frei, gemessen auf 1/2"))
        func measure() async -> (deck: Float, dsp: Double) {
            _ = engine.takeLoad()
            var acc: Float = 0
            for _ in 0..<20 { try? await Task.sleep(for: .milliseconds(50)); acc += engine.levels[0].rms }
            return (acc / 20, engine.takeLoad().average)
        }
        let before = await measure()
        let t = c.count > 4 ? c[Int.random(in: 4..<c.count)] : c[c.count - 1]   // zufällig: meist noch nicht im Cache
        for round in 0..<2 {   // 1. dekodieren (oder Cache), 2. aus dem Cache
            mix.preview(t)
            for _ in 0..<3000 where mix.previewing == nil && mix.previewLoading != nil { try? await Task.sleep(for: .milliseconds(20)) }   // Cloud-Datei: bis 60 s
            guard mix.previewing != nil, let secs = mix.previewLoadSeconds else { log("Vorhören: nicht geladen"); return }
            log(String(format: "Vorhören Ladezeit %d: %.2f s (%@, %.0f s)", round + 1, secs, t.title, t.duration))
        }
        let p0 = pv.position
        let during = await measure()
        let lv = pv.level, routed = pv.routedPair
        log(String(format: "Vorhören: Pegel RMS %.3f · Spitze %.3f (stumm) · Paar %@ · lief %.2f s · Deck A RMS ohne/mit %.3f / %.3f · DSP ohne/mit %.1f / %.1f %%",
                   lv.rms, lv.peak, routed.map { "\($0 + 1)/\($0 + 2)" } ?? "keins", pv.position - p0, before.deck, during.deck,
                   before.dsp * 100, during.dsp * 100))
        if let v = mix.previewing {
            mix.seekPreview(v.key, fraction: 0.5)
            try? await Task.sleep(for: .milliseconds(200))
            log(String(format: "Vorhören Sprung auf 50 %%: Position %.2f s (Schnitt %.2f–%.2f)", pv.position, v.cut.lo, v.cut.hi))
        }
        mix.stopPreview()
        try? await Task.sleep(for: .milliseconds(300))
        log(String(format: "Vorhören gestoppt: spielt %@ · Pegel %.4f", "\(pv.playing)", pv.level.peak))
    }

    /// Schneiden, stumm, in einen temporären Ordner (nie neben die Originale, nichts in cuts.json): auf Deck A 64 Beats
    /// ab ~1:00 entfernen, während A spielt. Dauer, Quelle (Deck-Puffer / neu dekodiert), Länge und Rate der Datei,
    /// verschobenes Grid, längste Lücke des Hauptthreads (Takt 240 Hz). Die Datei wird danach gelöscht
    static func cutProbe(_ mix: MixModel, tracks c: [Track]) async {
        // 6-Minuten-Track (5:30–7:00) auf Deck C, sonst Deck A selbst
        var d = 0
        if let long = c.first(where: { $0.duration >= 330 && $0.duration <= 420 }) {
            mix.core.load(long, deck: 2)
            for _ in 0..<1500 where mix.core.trackAudio(2) == nil && mix.core.snapshot().decks[2].error == nil {
                try? await Task.sleep(for: .milliseconds(40))
            }
            if mix.core.trackAudio(2) != nil { d = 2 }
        }
        mix.pull()
        let s = mix.deck(d)
        guard s.track != nil, let g = s.grid, g.bpm > 0, s.duration > 120 else { log("Schneiden: übersprungen (Deck ohne Grid)"); return }
        let a = g.time(ofBeat: g.beatPosition(at: 60).rounded())
        let r = TrackRange(a, a + 64 * g.beat)
        mix.setRange(d, r)
        final class Gap: @unchecked Sendable { var worst = 0.0, last = CACurrentMediaTime(), hits: [(Double, Double)] = [] }
        let gap = Gap()
        let tick = Timer(timeInterval: 1.0 / 240, repeats: true) { _ in
            let now = CACurrentMediaTime()
            gap.worst = max(gap.worst, now - gap.last)
            if now - gap.last > 0.016 { gap.hits.append((now, now - gap.last)) }
            gap.last = now
        }
        RunLoop.main.add(tick, forMode: .common)
        try? await Task.sleep(for: .seconds(1))
        let idle = gap.worst
        gap.worst = 0
        gap.hits = []
        CutJob.lastResult = nil
        let t0 = Date(), c0 = CACurrentMediaTime()
        mix.cutRange(d, mode: .remove, load: false)
        while CutJob.running, Date().timeIntervalSince(t0) < 120 { try? await Task.sleep(for: .milliseconds(20)) }
        let c1 = CACurrentMediaTime()
        try? await Task.sleep(for: .milliseconds(500))
        tick.invalidate()
        log("Schneiden: Lücken > 16 ms (s ab Start, ms): " + gap.hits.map { String(format: "%.2f/%.0f", $0.0 - c0, $0.1 * 1000) }.joined(separator: " ")
            + String(format: " · fertig bei %.2f s", c1 - c0))
        mix.setRange(d, nil)
        guard let res = CutJob.lastResult else { log("Schneiden: kein Ergebnis"); return }
        let url = URL(fileURLWithPath: res.track.path)
        let f = try? AVAudioFile(forReading: url)
        let secs = f.map { Double($0.length) / $0.processingFormat.sampleRate } ?? 0
        let want = s.duration - r.length
        let ng = BeatGrid(track: res.track)
        log(String(format: "Schneiden Deck %@ (%.0f s, A spielt, Bereich %.1f–%.1f s entfernt): %.2f s (%@) · Datei %.3f s, soll %.3f · %.0f Hz · %d Kanäle · Apple Lossless %@ · Grid-Anker %.3f -> %.3f s · Hotcues %@ -> %@ · Hauptthread längste Lücke %.0f ms (1 s davor ohne Schneiden %.0f ms, Abschluss %.1f ms) · %@",
                   deckLetters[d], s.duration, r.start, r.end, res.seconds, res.fromDeck ? "Deck-Puffer" : "Datei neu dekodiert", secs, want, f?.processingFormat.sampleRate ?? 0,
                   Int(f?.processingFormat.channelCount ?? 0),
                   "\(f?.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatAppleLossless)", g.anchor, ng?.anchor ?? .nan,
                   s.hotcues.values.map { String(format: "%.1f", $0.startMs / 1000) }.sorted().joined(separator: "/"),
                   res.track.hotcues.map { String(format: "%.1f", $0.startMs / 1000) }.joined(separator: "/"),
                   gap.worst * 1000, idle * 1000, CutJob.mainSeconds * 1000, abs(secs - want) < 0.01 ? "ok" : "LÄNGE FALSCH"))
        try? FileManager.default.removeItem(at: url)
    }

    /// Rückgängig: auf Deck B (spielt, Sync) Hotcue setzen, Beatjump, Loop, Schnitt OUT, Grid-Anker verschieben, dann alles
    /// zurück und vergleichen; Preparation und Metadaten (nur im Speicher). Kosten: Sicherung je Aktion (zwei Kopien)
    static func undoProbe(_ mix: MixModel, store: LibraryStore) async {
        let d = 1, u = UndoStack.shared
        mix.pull()
        let s = mix.deck(d)
        guard s.track != nil, let g = s.grid, g.bpm > 0, s.duration > 60,
              let n = (0..<8).first(where: { s.hotcues[$0] == nil }) else { log("Rückgängig: übersprungen"); return }
        let before = mix.core.deckEdit(d), steps = u.done.count
        var ms: [Double] = []
        func timed(_ f: () -> Void) { let t = CACurrentMediaTime(); f(); ms.append((CACurrentMediaTime() - t) * 1000) }
        timed { mix.hotcue(d, n) }
        let p0 = mix.position(d)
        timed { mix.beatjump(d, beats: 16) }
        let jumped = mix.position(d) - p0
        timed { mix.autoLoop(d, size: 4) }
        timed { mix.setTrimPoint(d, end: true, s.duration - 20) }
        timed { mix.shiftGridBeats(d, 1) }
        let recorded = u.done.count - steps, label = u.undoLabel ?? "–"
        let changed = mix.core.deckEdit(d)
        for _ in 0..<3 { u.undo() }   // Grid, Schnitt, Loop
        let p1 = mix.position(d)
        u.undo()   // Beatjump: Position um den Sprung zurück (B läuft weiter)
        let back = mix.position(d) - p1
        u.undo()   // Hotcue
        let after = mix.core.deckEdit(d)
        let ok = recorded == 5 && changed.hotcues[n] != nil && after.hotcues == before.hotcues && after.trim == before.trim
            && after.grid == before.grid && after.gridEdited == before.gridEdited && after.loopActive == before.loopActive
            && abs(back + jumped) < 0.05
        // Sicherung allein (Kopie des Bearbeitungsstands unter der Sperre)
        let t0 = CACurrentMediaTime()
        for _ in 0..<1000 { _ = mix.core.deckEdit(d) }
        let snap = (CACurrentMediaTime() - t0) * 1000   // ms für 1000 = µs je Kopie
        // Preparation und Metadaten
        let keys = store.tracks.prefix(2).map(\.key)
        let prep0 = store.preparation
        store.appendToPreparation(keys)
        let prepAdded = store.preparation.count - prep0.count
        u.undo()
        let prepOK = prepAdded == keys.count && store.preparation == prep0
        var metaOK = false
        if let k = keys.first, let c0 = store.track(k)?.comment {
            store.applyEdits([k: [.comment: c0 + " undo"]], writeBack: false)
            let set = store.track(k)?.comment == c0 + " undo"
            u.undo()
            metaOK = set && store.track(k)?.comment == c0
        }
        log(String(format: "Rückgängig Deck %@: %d Schritte (oben: %@), Beatjump %+.2f s -> zurück %+.2f s, Hotcues/Schnitt/Grid/Loop wie vorher %@ · Preparation %@ · Metadaten %@ · Aktion mit Sicherung %@ ms · Kopie %.1f µs",
                   deckLetters[d], recorded, label, jumped, back, ok ? "ok" : "FALSCH", prepOK ? "ok" : "FALSCH", metaOK ? "ok" : "FALSCH",
                   ms.map { String(format: "%.2f", $0) }.joined(separator: "/"), snap))
        if !(ok && prepOK && metaOK) { log("RÜCKGÄNGIG FALSCH"); exit(1) }
    }

    /// wird vom HistoryStore gesetzt, damit der Test genau seine eigene Datei entfernen kann
    nonisolated(unsafe) static var historyURL: URL?

    static func log(_ s: String) {
        print("[selftest] \(s)")
        fflush(stdout)
    }
}

/// Speicher des Prozesses und des Systems (Messungen)
@MainActor enum Mem {
    static func rss() -> UInt64 {
        var info = mach_task_basic_info()
        var n = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let r = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &n) } }
        return r == KERN_SUCCESS ? info.resident_size : 0
    }

    /// fest (wired) im ganzen System
    static func wired() -> UInt64 {
        var vm = vm_statistics64()
        var c = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &vm) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(c)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &c) } }
        return r == KERN_SUCCESS ? UInt64(vm.wire_count) * UInt64(vm_kernel_page_size) : 0
    }

    /// Speicherdruck des Systems: normal · warnung · kritisch
    static func pressure() -> String {
        var level: Int32 = 0, size = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)
        return [1: "normal", 2: "warnung", 4: "kritisch"][Int(level)] ?? "\(level)"
    }

    static func gb(_ b: UInt64) -> String { String(format: "%.2f GB", Double(b) / 1_073_741_824) }

    static func line() -> String {
        "RSS \(gb(rss())) · Footprint \(gb(MeterSampler.footprint())) · System fest \(gb(wired())) · Speicherdruck \(pressure())"
    }
}

/// Nur Bild (MIX741_SHOT=wave:<png>, Selbsttest): die Wellenform-Ebene eines Decks offscreen rendern – kein Fenster,
/// kein Audio, keine Controller. Oben der Zoom aus den Einstellungen, unten 4× weiter heraus; Grid-Anker links im Bild,
/// Spielkopf in einem 4-Beat-Loop, zwei Hotcues, darunter die Übersicht. Erster Track der Collection mit 120–140 BPM und Grid, wie im Selbsttest.
/// Optional: MIX741_SHOT_TRACK (Teil von Interpret/Titel/Pfad), MIX741_SHOT_AT (Sekunden, Spielkopf, ohne Loop),
/// MIX741_SHOT_SPAN (Sekunden je Seite), MIX741_SHOT_STYLE (Komma-Liste: blend, 3band, spectrum, fine, fine-mix, mono →
/// je Stil zwei Streifen untereinander, beschriftet), MIX741_SHOT_PALETTE (rgb, bone, orange, blue, classic), MIX741_SHOT_BOOST.
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

    /// Stil-Kürzel → (Stil, Beschriftung)
    private static func look(_ k: String, _ ui: UIPrefs) -> (WaveformStyle, String) {
        switch k.trimmingCharacters(in: .whitespaces) {
        case "blend": (.blend, "3-band blend")
        case "spectrum", "fine": (.spectrum, "spectrum (6 bands)")
        case "mono": (.mono, "mono")
        default: (ui.waveformStyle, "settings")
        }
    }

    private static func render(to url: URL) throws {
        let env = ProcessInfo.processInfo.environment
        var ui = AppPrefs.load().ui
        if let p = env["MIX741_SHOT_PALETTE"] {
            ui.waveformPalette = ["rgb": .rgb, "bone": .bone, "orange": .orange, "blue": .blue, "classic": .classic][p] ?? ui.waveformPalette
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
        var looks = (env["MIX741_SHOT_STYLE"] ?? "settings").split(separator: ",").map { look(String($0), ui) }
        // Versuchswerte der Mischung je Zeile: MIX741_SHOT_TUNE="sat,win,gl,gm,gh,base,fade,stack,warm,open;…" (eine Zeile je Eintrag,
        // Stil der ersten Zeile); MIX741_SHOT_PRESET=all|0,3,5: Varianten A…K der Mischung, eine Zeile je Variante
        let tunes = (env["MIX741_SHOT_TUNE"] ?? "").split(separator: ";").compactMap { BlendPaint.Tune(String($0)) }
        if !tunes.isEmpty, let first = looks.first { looks = tunes.map { (first.0, first.1 + " · " + $0.label) } }
        var presets: [Int] = [ui.blendPreset]
        if let ps = env["MIX741_SHOT_PRESET"] {
            presets = ps == "all" ? Array(BlendPreset.all.indices) : ps.split(separator: ",").compactMap { Int($0) }.map(BlendPreset.clamp)
            looks = presets.map { (WaveformStyle.blend, BlendPreset.all[$0].name) }
        }
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
            WaveLayerNSView.tileTime.withLock { $0 = (0, 0) }
            let tr = Date()
            let wf = RenderedWaveform.render(audio, style: lk.0, palette: ui.waveformPalette, highBoost: ui.waveformHighBoost,
                                             preset: presets.count > 1 ? presets[row] : presets[0], tune: tunes.isEmpty ? nil : tunes[row])
            SelfTest.log(String(format: "%@: Wellenform gerechnet in %.2f s, %.0f Pfade je Abschnitt", lk.1, Date().timeIntervalSince(tr), Double(wf.chunks.reduce(0) { $0 + $1.layers.count }) / Double(max(1, wf.chunks.count))))
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
            let text = String(format: "%@ · %@ – %@ · %.0f s", lk.1, t.artist, t.title, pos) as NSString
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
            let tt = WaveLayerNSView.tileTime.withLock { $0 }
            SelfTest.log(String(format: "%@: %d Kacheln, %.2f ms je Kachel", lk.1, tt.count, tt.seconds * 1000 / Double(max(1, tt.count))))
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
