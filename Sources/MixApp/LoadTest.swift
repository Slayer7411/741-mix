import AppKit
import Foundation
import MixCore
import MixEngine

/// MIX741_BENCH=loadtest (Selbsttest-Modus, schreibt keine Einstellungen): Live-Lasttest in Stufen.
/// Je Stufe (Puffer MIX741_BENCH_BUFFERS, Standard 512,256,128; Dauer MIX741_LOADTEST_MIN, Standard 10 min; Rechenkern
/// MIX741_BENCH_MODES=serial,parallel -> alle Puffer erst seriell, dann mit parallelen Decks):
/// 4 Decks Keylock, B–D Sync auf A, Link an, FX 1 (A/C) und FX 2 (B/D) Vorlage Gruppe mit Delay + Hall, FX 3 isoliertes Plugin
/// (MIX741_BENCH_PLUGIN, Standard AUMatrixReverb isoliert, "none" = ohne) auf allen Decks. Störlast: alle 60 s
/// Track-Wechsel (erstmals nach 45 s; B, C, D reihum, Datei-Dienst), alle 20 s Suche + Sortierung über die Collection auf dem Hauptthread,
/// alle 5 min (erstmals nach 30 s) Hauptthread 1 s blockiert. Ab 3 Geräte-Überlastungen endet die Stufe (FAIL).
/// Log: ~/Library/Application Support/MINOS-741/loadtest/<datum>.log (+ latest.log), Kurzfassung auf stdout.
/// Ctrl-C: Zusammenfassung, Ausgabe aus, Ende (Helfer enden mit dem Kanal)
@MainActor
enum LoadTest {
    struct Stage {
        var frames: UInt32
        var parallel = false
        var deviceFrames = 0, latencyMs = 0.0
        var seconds = 0.0
        var busy = 0.0, blocks = 0, peak = 0.0
        var overloads = 0, deviceOverloads = 0, reconnects = 0
        var hitches = 0, worstHitchMs = 0.0
        /// Link (nur mit Teilnehmern): Phase max/σ über alle Steuerticks der Stufe, Neusetzungen, Clock-Trims
        var linkMax: Double?, linkSigma = 0.0, linkPeers = 0, linkForces = 0, linkTrims = 0
        var loads: [Double] = [], loadFailures = 0
        var rssMax: UInt64 = 0
        var aborted = false
        var mean: Double { busy / Double(max(1, blocks)) }
        /// Toleranz der Nachführung (0,02 Beats) + Stempel-Jitter: jeder Tick zählt, nicht nur Stichproben
        static let linkLimit = 0.03
        var pass: Bool {
            peak < 0.7 && overloads == 0 && deviceOverloads == 0 && (linkMax.map { $0 < Self.linkLimit } ?? true) && !aborted
        }
    }

    private static var file: FileHandle?
    private static var stages: [Stage] = []
    private static var current: Stage?
    private static var startInfo = ""

    static func log(_ s: String, stdout: Bool = true) {
        let t = stamp()
        for l in s.split(separator: "\n", omittingEmptySubsequences: true) {
            file?.write(Data("\(t) \(l)\n".utf8))
            if stdout { print("[loadtest] \(l)") }
        }
        fflush(Darwin.stdout)
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }

    private static func openLog() {
        let dir = HistoryStore.baseDir.appendingPathComponent("loadtest", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let url = dir.appendingPathComponent("\(f.string(from: Date())).log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        file = try? FileHandle(forWritingTo: url)
        let latest = dir.appendingPathComponent("latest.log")
        try? FileManager.default.removeItem(at: latest)
        try? FileManager.default.createSymbolicLink(at: latest, withDestinationURL: url)
        print("[loadtest] Log: \(url.path)  (tail -f \"\(latest.path)\")")
    }

    static func run(_ core: MixController, tracks all: [Track]) async {
        let env = ProcessInfo.processInfo.environment
        let engine = core.engine
        let minutes = Double(env["MIX741_LOADTEST_MIN"] ?? "") ?? 10
        let buffers = (env["MIX741_BENCH_BUFFERS"] ?? "512,256,128").split(separator: ",")
            .compactMap { UInt32($0.trimmingCharacters(in: .whitespaces)) }
        let plugin = env["MIX741_BENCH_PLUGIN"] ?? "aufx:mrev:appl"
        // Rechenkern je Stufe: seriell und/oder Decks parallel (MIX741_BENCH_MODES=serial,parallel)
        let modes = (env["MIX741_BENCH_MODES"] ?? "serial").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0 == "serial" || $0 == "parallel" }
        let stageList = modes.isEmpty ? buffers.map { ($0, false) } : modes.flatMap { m in buffers.map { ($0, m == "parallel") } }
        openLog()
        installInterrupt(core)

        // Ausgabe: externes Interface (Selbsttest-Routing A 1/2 · B 3/4 · C 5/6 · D 7/8) laut, sonst eingebaut stumm
        let ext = engine.deviceChannels >= 8
        let mute = !ext || env["MIX741_LOADTEST_MUTE"] == "1"
        var p = core.snapshot().prefs
        p.masterVolumeExternal = true   // Master wirkt auch extern: 0 dB laut, 0 = stumm (nur im Speicher)
        p.historyThreshold = 1e9        // Lasttest zählt nicht als gespielt
        core.setPrefs(p)
        core.setExternalMixer(ext)
        core.setMasterVolume(mute ? 0 : 1)
        let dev = MixEngine.outputDevices().first { $0.id == engine.routing.device }
        startInfo = String(format: "Gerät %@ (%d Kanäle, %@) · %@ · Kern %.0f Hz, Gerät %.0f Hz · Stufen %@ je %.0f min · %@",
                           dev?.name ?? "?", engine.deviceChannels, ext ? "extern A 1/2 · B 3/4 · C 5/6 · D 7/8" : "eingebaut",
                           mute ? "stumm" : "Master 0 dB", engine.sampleRate, engine.outputRate,
                           buffers.map(String.init).joined(separator: "/"), minutes,
                           (modes.isEmpty ? ["serial"] : modes).map { $0 == "parallel" ? "Decks parallel" : "seriell" }.joined(separator: " + "))
        log(startInfo)
        if !ext {
            log(env["MIX741_NOEXT"] != nil ? "eingebautes Gerät (MIX741_NOEXT), stumm"
                : "Hinweis: kein externes Interface gefunden (MIX741_OUT=<Name>?) -> eingebautes Gerät, stumm")
        }

        // lokale Tracks (nichts aus der Cloud), mit Grid, 120–140 BPM
        func local(_ t: Track) -> Bool {
            var st = stat()
            return stat(t.path, &st) == 0 && st.st_size > 0 && st.st_flags & UInt32(SF_DATALESS) == 0
        }
        let pool = all.filter { $0.bpm > 120 && $0.bpm < 140 && $0.gridAnchorMs != nil && $0.fileExists }.shuffled()
            .lazy.filter(local).prefix(40)
        let tracks = Array(pool)
        guard tracks.count >= 8 else { log("zu wenige lokale Tracks (\(tracks.count))"); return }
        var next = 4

        func waitLoaded(_ d: Int, _ t0: Date) async -> Double? {
            for _ in 0..<600 {
                let s = core.snapshot().decks[d]
                if s.error != nil { return nil }
                if core.trackAudio(d) != nil, !s.loading { return Date().timeIntervalSince(t0) }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return nil
        }
        func prepare(_ d: Int) {
            core.updateDeck(d) { $0.keylock = true }
            if d > 0, !core.snapshot().decks[d].sync { core.toggleSync(d) }
            if !core.snapshot().decks[d].playing { core.togglePlay(d) }
        }

        let t0 = Date()
        for d in 0..<4 { core.load(tracks[d], deck: d) }
        for d in 0..<4 { _ = await waitLoaded(d, t0) }
        log(String(format: "4 Decks geladen in %.1f s: %@", Date().timeIntervalSince(t0),
                   (0..<4).map { "\(deckLetters[$0]) \(core.snapshot().decks[$0].track?.title ?? "–")" }.joined(separator: " · ")))
        if core.snapshot().masterDeck != 0 { core.toggleMaster(0) }
        for d in 0..<4 { prepare(d) }
        core.setLinkEnabled(true)

        // FX: Zuweisung A/C -> FX 1, B/D -> FX 2, alle -> FX 3
        for d in 0..<4 {
            let want = [d % 2 == 0, d % 2 == 1, true, false]
            for u in 0..<4 where core.snapshot().decks[d].fxAssign[u] != want[u] { core.toggleFXAssign(d, u) }
        }
        // Vorlage Gruppe: Delay und Hall an (je 0,5), Filter aus
        for u in 0..<2 {
            core.updateFX(u) { fx in
                fx.slots = FXTemplate.group.slots
                fx.slots[1].on = true; fx.slots[1].mix = 0.5
                fx.slots[2].on = true; fx.slots[2].mix = 0.5; fx.dryWet = 0.5
            }
        }
        if plugin != "none" {
            if plugin == "aufx:mrev:appl" { core.pluginCatalog.setIsolation(plugin, true) }   // nur im Speicher (Selbsttest)
            core.setSlots(2, [FXSlot(id: plugin, on: true)])
            for _ in 0..<400 where core.pluginParamNames(2).isEmpty && core.snapshot().pluginErrors[2] == nil {
                try? await Task.sleep(for: .milliseconds(50))
            }
            core.updateFX(2) { $0.dryWet = 0.4 }
            log("Plugin FX 3: \(plugin) \(core.pluginCatalog.isolated(plugin) ? "isoliert" : "im Prozess")"
                + (core.snapshot().pluginErrors[2].map { " · Fehler: \($0)" } ?? ""))
        }
        log("FX 1 (A/C) + FX 2 (B/D): Delay + Hall · FX 3 (A–D): Plugin · Keylock A–D · Sync B–D auf A · Link an")

        // Hauptthread-Hänger messen (> 16 ms zwischen zwei Takten; der absichtliche 1-s-Block zählt nicht)
        var lastTick = CACurrentMediaTime(), blocking = false
        let hitch = Timer(timeInterval: 1.0 / 120, repeats: true) { _ in
            MainActor.assumeIsolated {
                let now = CACurrentMediaTime(), gap = (now - lastTick) * 1000
                lastTick = now
                guard gap > 16, !blocking, var c = current else { return }
                c.hitches += 1
                c.worstHitchMs = max(c.worstHitchMs, gap)
                current = c
                if gap > 50 { log(String(format: "  Hänger Hauptthread %.0f ms", gap), stdout: false) }
            }
        }
        RunLoop.main.add(hitch, forMode: .common)
        defer { hitch.invalidate() }

        MeterSampler.shared.paused = true
        let fs0 = core.fileService?.stats
        let saved = engine.bufferFrames, savedParallel = engine.parallelDecks
        let queries = ["the", "mix", "dub", "acid", "remix", "deep", "love", "techno"]
        var q = 0, deckTurn = 1

        for (frames, parallel) in stageList {
            engine.bufferFrames = frames
            engine.parallelDecks = parallel
            engine.apply(engine.routing, restart: true)
            for d in 0..<4 { prepare(d) }
            try? await Task.sleep(for: .seconds(2))   // einschwingen
            engine.resetOverloads()
            _ = engine.takeLoad()
            let info = engine.takeLoad()
            current = Stage(frames: frames, parallel: parallel, deviceFrames: info.bufferFrames, latencyMs: info.outputLatency * 1000)
            let r0 = engine.watch.reconnects
            let link0 = core.linkStats(resetWindow: true)
            log(String(format: "Stufe Puffer %d %@: Gerät %d Frames, Latenz %.1f ms, %.0f min", frames, parallel ? "Decks parallel" : "seriell",
                       info.bufferFrames, info.outputLatency * 1000, minutes))
            let start = Date()
            var lastLoad = -15.0, lastSearch = 0.0, lastLink = 0.0, lastLine = 0.0, nextBlock = 30.0
            var worstSeen: (total: Double, parts: [Double], frames: Int) = (0, [], 0)
            while true {
                try? await Task.sleep(for: .milliseconds(50))
                let el = Date().timeIntervalSince(start)
                let l = engine.takeLoad()
                current!.busy += l.average * Double(l.blocks); current!.blocks += l.blocks
                current!.peak = max(current!.peak, l.peak)
                // schwerster Block dieses Abhol-Fensters merken; über Budget oder Geräte-Überlast sofort mit Aufteilung loggen
                if l.worstTotalMs > worstSeen.total { worstSeen = (l.worstTotalMs, l.worstParts, l.worstFrames) }
                if l.overloads > current!.overloads || l.deviceOverloads > current!.deviceOverloads {
                    log("  Überlast: " + Self.profileLine(l.worstParts, frames: l.worstFrames, rate: engine.sampleRate), stdout: false)
                }
                current!.overloads = l.overloads; current!.deviceOverloads = l.deviceOverloads
                current!.reconnects = l.reconnects - r0
                current!.rssMax = max(current!.rssMax, Mem.rss())
                current!.seconds = el
                if l.deviceOverloads >= 3 { current!.aborted = true; log("  3 Geräte-Überlastungen -> Stufe FAIL, weiter mit der nächsten"); break }
                if el >= minutes * 60 { break }
                if el - lastLink >= 10 {
                    lastLink = el
                    let ls = core.linkStats()
                    if let d = ls.lastDiff {
                        current!.linkPeers = max(current!.linkPeers, ls.peers)
                        log(String(format: "  Link Phase %+.4f Beats · Drift %+.4f · Fenster max %.4f / σ %.4f · Neusetzungen %d · Clock-Trims %d · Tempo %d · %d Teilnehmer",
                                   d, ls.drift, ls.windowMax, ls.windowSigma, ls.forces - link0.forces, ls.trims - link0.trims,
                                   ls.tempoSets - link0.tempoSets, ls.peers), stdout: false)
                    }
                }
                if el - lastSearch >= 20 {
                    lastSearch = el
                    // absichtliche Last: zählt nicht als Hänger, Dauer steht im Log
                    let t = CACurrentMediaTime(), word = queries[q % queries.count]
                    q += 1
                    blocking = true
                    let hits = all.filter { "\($0.artist) \($0.title)".localizedCaseInsensitiveContains(word) }
                        .sorted { ($0.bpm, $0.title) < ($1.bpm, $1.title) }
                    blocking = false
                    lastTick = CACurrentMediaTime()
                    log(String(format: "  Suche „%@“ + Sortierung: %d Treffer, %.0f ms Hauptthread", word, hits.count,
                               (CACurrentMediaTime() - t) * 1000), stdout: false)
                }
                if el - lastLoad >= 60 {
                    lastLoad = el
                    let d = deckTurn
                    deckTurn = deckTurn % 3 + 1
                    let t = tracks[next % tracks.count]
                    next += 1
                    let tl = Date()
                    core.load(t, deck: d)
                    if let s = await waitLoaded(d, tl) {
                        current!.loads.append(s)
                        prepare(d)
                        log(String(format: "  Track-Wechsel %@: %.2f s · %@", deckLetters[d], s, t.title), stdout: false)
                    } else {
                        current!.loadFailures += 1
                        log("  Track-Wechsel \(deckLetters[d]) fehlgeschlagen: \(core.snapshot().decks[d].error ?? "Zeitgrenze") · \(t.title)")
                        prepare(d)
                    }
                }
                if el >= nextBlock {
                    nextBlock += 300
                    blocking = true
                    Thread.sleep(forTimeInterval: 1)
                    blocking = false
                    lastTick = CACurrentMediaTime()
                    log("  Hauptthread 1 s blockiert", stdout: false)
                }
                if el - lastLine >= 60 {
                    lastLine = el
                    let c = current!
                    log(String(format: "  %d · %.0f min: DSP %.1f %% · Spitze %.0f %% · über Budget %d · Gerät überlastet %d · Hänger %d · %@",
                               frames, el / 60, c.mean * 100, c.peak * 100, c.overloads, c.deviceOverloads, c.hitches, Mem.line()))
                    log("  schwerster Block: " + Self.profileLine(worstSeen.parts, frames: worstSeen.frames, rate: engine.sampleRate), stdout: false)
                    worstSeen = (0, [], 0)
                }
            }
            let link1 = core.linkStats(resetWindow: true)
            current!.linkForces = max(0, link1.forces - link0.forces); current!.linkTrims = max(0, link1.trims - link0.trims)
            current!.linkPeers = max(current!.linkPeers, link1.peers)
            if current!.linkPeers > 0, link1.windowCount > 0 { current!.linkMax = link1.windowMax; current!.linkSigma = link1.windowSigma }
            stages.append(current!)
            log(summaryLine(current!))
            current = nil
        }
        engine.bufferFrames = saved
        engine.parallelDecks = savedParallel
        engine.apply(engine.routing, restart: true)
        if let a = fs0, let b = core.fileService?.stats {
            log("Datei-Dienst: Helfer gestartet \(b.spawns - a.spawns) · abgestürzt \(b.crashes - a.crashes) · abgeschossen \(b.kills - a.kills) · mlock fehlgeschlagen \(b.lockFailures - a.lockFailures)")
        }
        finish(core)
    }

    /// „1.92 ms von 5.80 (33 %) · A 0.41 B 1.02 C 0.21 D 0.19 wait 0 mix 0.05 master 0.02 pre 0.01“
    static func profileLine(_ parts: [Double], frames: Int, rate: Double) -> String {
        guard !parts.isEmpty, frames > 0, rate > 0 else { return "–" }
        let total = parts.reduce(0, +), budget = Double(frames) / rate * 1000
        let names = MixEngine.worstPartNames
        let detail = zip(names, parts).map { String(format: "%@ %.2f", $0, $1) }.joined(separator: " ")
        return String(format: "%.2f ms von %.2f (%.0f %%) · %@", total, budget, total / budget * 100, detail)
    }

    private static func summaryLine(_ c: Stage) -> String {
        let loads = c.loads.isEmpty ? "–" : String(format: "%.2f / %.2f s", c.loads.reduce(0, +) / Double(c.loads.count), c.loads.max() ?? 0)
        return String(format: "Stufe %d %@ %@: %.1f min · DSP %.1f %% · Spitze %.0f %% · über Budget %d · Gerät überlastet %d · Hänger %d (max %.0f ms) · Link %@ · Laden Mittel/Max %@ (%d fehlgeschlagen) · RSS max %@ · neu verbunden %d",
                      c.frames, c.parallel ? "parallel" : "seriell", c.pass ? "PASS" : "FAIL", c.seconds / 60, c.mean * 100, c.peak * 100, c.overloads, c.deviceOverloads,
                      c.hitches, c.worstHitchMs, c.linkMax.map { String(format: "Phase max %.4f / σ %.4f Beats, Neusetzungen %d, Clock-Trims %d", $0, c.linkSigma, c.linkForces, c.linkTrims) } ?? "keine Teilnehmer",
                      loads, c.loadFailures, Mem.gb(c.rssMax), c.reconnects)
    }

    /// Tabelle je Stufe; Kriterien: Spitze < 70 %, 0 über Budget, 0 Geräte-Überlastungen, Link-Phase < 0,03 Beats
    private static func table() -> String {
        var s = "\nPuffer | Kern | Gerät | Latenz ms | Min | DSP % | Spitze % | über Budget | Overloads | Hänger | Link max | Link σ | Neusetzungen | Laden max s | Ergebnis\n"
        s += "---|---|---|---|---|---|---|---|---|---|---|---|---|---|---\n"
        for c in stages {
            s += String(format: "%d | %@ | %d | %.1f | %.1f | %.1f | %.0f | %d | %d | %d | %@ | %@ | %@ | %@ | %@\n", c.frames, c.parallel ? "parallel" : "seriell", c.deviceFrames, c.latencyMs,
                        c.seconds / 60, c.mean * 100, c.peak * 100, c.overloads, c.deviceOverloads, c.hitches,
                        c.linkMax.map { String(format: "%.4f", $0) } ?? "–", c.linkMax.map { _ in String(format: "%.4f", c.linkSigma) } ?? "–",
                        c.linkMax.map { _ in "\(c.linkForces)" } ?? "–", c.loads.max().map { String(format: "%.2f", $0) } ?? "–",
                        c.pass ? "PASS" : (c.aborted ? "FAIL (abgebrochen)" : "FAIL"))
        }
        return s + "Kriterien: Spitze < 70 % · 0 über Budget · 0 Overloads · Link-Phase < 0,03 Beats (nur mit Teilnehmern)"
    }

    private static func finish(_ core: MixController, interrupted: Bool = false) {
        if interrupted, var c = current { c.aborted = true; stages.append(c); current = nil }
        log((interrupted ? "abgebrochen (Ctrl-C) · " : "fertig · ") + startInfo)
        log(table())
        log(Mem.line())
        file?.closeFile()
        file = nil
        MeterSampler.shared.paused = false
        core.engine.stop()
    }

    /// Ctrl-C: Zusammenfassung schreiben, Ausgabe aus, beenden
    private static var interrupt: DispatchSourceSignal?
    private static func installInterrupt(_ core: MixController) {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let handler = {
            MainActor.assumeIsolated {
                finish(core, interrupted: true)
                exit(130)
            }
        }
        let a = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        a.setEventHandler(handler: handler)
        a.resume()
        let b = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        b.setEventHandler(handler: handler)
        b.resume()
        interrupt = a
        termSource = b
    }
    private static var termSource: DispatchSourceSignal?
}
