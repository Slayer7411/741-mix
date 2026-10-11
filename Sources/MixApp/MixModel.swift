import AVFoundation
import Foundation
import QuartzCore
import Observation
import MixCore
import MixEngine

/// Intern: Mixer in der App, alle Decks auf ein Ausgangspaar. Extern: jedes Deck auf eigenes Paar (USB-Mischpult).
enum MixerMode: String, CaseIterable, Identifiable {
    case internalMixer = "Intern", external = "Extern"
    var id: String { rawValue }
}

let deckLetters = ["A", "B", "C", "D"]

/// Zustand eines Decks für die Oberfläche – eigenes Observable, damit eine Änderung an Deck A
/// nicht die Ansichten von B, C, D neu rendert (SwiftUI-Layout je Deck kostet messbar Zeit)
@MainActor @Observable
final class DeckMirror {
    var state = DeckState()
    /// geladener Track (Schlüssel) – für RUNNING TRACKS, ohne bei jeder Deck-Änderung mitzurendern
    var trackKey = ""
}

/// FX-Unit für die Oberfläche: eigenes Observable je Unit (FXUnitView liest nur ihre Unit)
@MainActor @Observable
final class FXMirror {
    var state = FXUnitState()
    var pluginParams: [String] = []
    var pluginError: String?
}

/// Was die Master-Clock-Leiste zeigt – nur bei Änderung gesetzt
struct ClockMirror: Equatable {
    var clockMaster = false, semiSync = false, metronome = false, linkEnabled = false
    var metronomeVolume = 0.5, masterVolume = 0.85, masterTempo = 128.0
    var linkPeers = 0

    init() {}
    init(_ s: MixState) {
        clockMaster = s.clockMaster; semiSync = s.semiSync; metronome = s.metronome; linkEnabled = s.linkEnabled
        metronomeVolume = s.metronomeVolume; masterVolume = s.masterVolume; masterTempo = s.masterTempo
        linkPeers = s.linkPeers
    }
}

/// Oberflächen-Seite: spiegelt den Zustand des Steuerkerns (30 Hz) und leitet Befehle weiter.
/// Hängt die Oberfläche, laufen Audio, Sync und Controller trotzdem weiter (eigene Threads).
@MainActor @Observable
final class MixModel {
    @ObservationIgnored let core = MixController()
    var engine: MixEngine { core.engine }

    /// Gespiegelter Zustand (ohne Sync-Nudge) – nicht beobachtet: Ansichten lesen nur die Teile, die sie zeigen
    /// (DeckMirror, FXMirror, clock, crossfader), sonst rendert jede Änderung alles neu, was `state` liest
    @ObservationIgnored private(set) var state = MixState()
    /// je Deck getrennt gespiegelt (siehe DeckMirror); Master und Clock-Modus ebenfalls einzeln
    @ObservationIgnored let decks = (0..<MixEngine.deckCount).map { _ in DeckMirror() }
    @ObservationIgnored let fxUnits = (0..<MixEngine.fxUnitCount).map { _ in FXMirror() }
    private(set) var clock = ClockMirror()
    private(set) var crossfader = 0.0
    /// Link-Teilnehmer, wie die LINK-Taste sie zeigt (0 = nur „LINK“) – Größen-Schlüssel der Master-Clock-Leiste
    private(set) var linkPeersShown = 0
    private(set) var effectiveMaster: Int?
    private(set) var clockMaster = false
    var focusedDeck = 0
    var prefs = AppPrefs.load() {
        didSet {
            guard prefs != oldValue else { return }
            prefs.save()
            if prefs.engine != oldValue.engine { core.setPrefs(prefs.engine) }
        }
    }

    var outputDevices: [MixEngine.OutputDevice] = []
    var engineStatus = ""
    var mixerMode: MixerMode = .internalMixer
    var deviceUID: String?
    var internalPair = 0
    var deckPairs = [0, 4, 2, 6]   // A 1/2 · B 5/6 · C 3/4 · D 7/8
    /// Samplerate fürs Gerät (0 = so lassen); der Kern übernimmt sie beim nächsten Start
    var sampleRate = 0.0
    /// Puffergröße in Frames (0 = Gerätestandard)
    var bufferSize = 0

    /// eigene Änderungen (Grid, Hotcues) dauerhaft je Track – die Collection bleibt unangetastet
    @ObservationIgnored let edits = TrackEditStore(url: HistoryStore.baseDir.appendingPathComponent("edits.json"))
    @ObservationIgnored private var originals: [Int: Track] = [:]
    @ObservationIgnored private var savedEdit: [Int: TrackEdit?] = [:]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var previewPlayer: AVAudioPlayer?
    @ObservationIgnored private var reroutePending = false

    /// Plugin-Verwaltung (⌘, → PLUGINS); teilt die Liste mit dem Kern
    @ObservationIgnored lazy var plugins = PluginManager(catalog: core.pluginCatalog)

    init() {
        // gespeicherte Plugin-Einstellungen + Absturz-Markierung vom letzten Lauf, bevor eine Sitzung Plugins lädt.
        // Selbsttest: nur lesen (keine Markierung, keine Änderungen)
        VST3Thread.useMain = true   // VST3: Laden, Zustand, Controller, Ansicht immer auf dem Haupt-Thread
        core.pluginCatalog = PluginCatalog(directory: HistoryStore.baseDir, readOnly: Session.isSelfTest)
        // Selbsttest: zusätzlicher Plugin-Ordner nur im Speicher (Bilder des PLUGINS-Tabs mit Test-Plugin)
        if Session.isSelfTest, let f = ProcessInfo.processInfo.environment["MIX741_SHOT_PLUGINS"] {
            core.pluginCatalog.update { $0.folders.append(f) }
        }
        if let c = core.pluginCatalog.crashedLastRun { print("[plugin] beim letzten Lauf abgestürzt beim Öffnen: \(c.name) -> blockiert") }
        loadSetup()
        core.setPrefs(prefs.engine)
        outputDevices = MixEngine.outputDevices()
        applyRouting()
        engine.onConfigurationChange = { [weak self] in
            Task { @MainActor in
                // Selbsttest: nie selbst umleiten (sonst landet der Test mit gespeicherter Lautstärke auf dem Live-Interface)
                guard let self, !self.reroutePending, !Session.isSelfTest else { return }
                self.reroutePending = true
                try? await Task.sleep(for: .milliseconds(300))
                self.reroutePending = false
                self.refreshDevices()
                if let why = self.rerouteReason() {
                    print("[audio] Geräteliste geändert: \(why) -> neu verbinden")
                    self.applyRouting()
                }
            }
        }
        // .common: läuft auch, solange ein Menü offen ist oder das Fenster gezogen wird (sonst steht die Anzeige still)
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pull() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        // MIX741_DEBUG=1: Hänger des Hauptthreads melden (Lücken zwischen zwei Takten > 30 ms)
        if MixController.debug {
            var last = CACurrentMediaTime()
            let h = Timer(timeInterval: 1.0 / 120, repeats: true) { _ in
                let now = CACurrentMediaTime(), gap = now - last
                last = now
                if gap > 0.03 { print(String(format: "[hitch] %.1f s: main thread %.0f ms", now, gap * 1000)); fflush(stdout) }
            }
            RunLoop.main.add(h, forMode: .common)
            hitchTimer = h
        }
    }
    @ObservationIgnored private var hitchTimer: Timer?

    /// Zustand vom Kern holen
    @ObservationIgnored private var changeCount = 0
    @ObservationIgnored private var lastReport = Date()

    func pull() {
        var s = core.snapshot()
        for i in s.decks.indices { s.decks[i].nudge = 0 }
        if s != state {
            if MixController.debug {
                changeCount += 1
                if Date().timeIntervalSince(lastReport) > 2 {
                    let diff = s.decks.indices.filter { s.decks[$0] != state.decks[$0] }
                    print("[debug] zustand geändert \(changeCount)× in 2 s, decks: \(diff), fx: \(s.fx != state.fx), rest: \(s.prefs != state.prefs) \(s.crossfader) \(s.masterVolume)")
                    fflush(stdout)
                    changeCount = 0; lastReport = Date()
                }
            }
            state = s
            for d in decks.indices where s.decks[d] != decks[d].state {
                decks[d].state = s.decks[d]
                let key = s.decks[d].track?.key ?? ""
                if key != decks[d].trackKey { decks[d].trackKey = key }
            }
            if s.effectiveMaster != effectiveMaster { effectiveMaster = s.effectiveMaster }
            if s.clockMaster != clockMaster { clockMaster = s.clockMaster }
            for (u, m) in fxUnits.enumerated() {
                if m.state != s.fx[u] { m.state = s.fx[u] }
                if m.pluginParams != s.pluginParams[u] { m.pluginParams = s.pluginParams[u] }
                if m.pluginError != s.pluginErrors[u] { m.pluginError = s.pluginErrors[u] }
            }
            let c = ClockMirror(s)
            if c != clock { clock = c }
            if s.crossfader != crossfader { crossfader = s.crossfader }
            let peers = s.linkEnabled ? s.linkPeers : 0
            if peers != linkPeersShown { linkPeersShown = peers }
            persistEdits()
        }
    }

    private func run(_ f: () -> Void) { f(); pull() }

    // MARK: - Abfragen

    func deck(_ d: Int) -> DeckState { decks[d].state }
    func position(_ d: Int) -> Double { core.position(d) }
    /// Abspielgeschwindigkeit für die Anzeige (s Track je s): 0 = steht, negativ = rückwärts, CUE gehalten läuft
    func playSpeed(_ d: Int) -> Double {
        let s = decks[d].state
        return s.playing || s.cueHeld ? s.rate * (s.reverse ? -1 : 1) : 0
    }
    func audio(_ d: Int) -> TrackAudio? { core.trackAudio(d) }
    func phaseError(_ d: Int) -> Double? { core.phaseError(d) }
    var masterBPM: Double { clock.masterTempo }
    var showFourDecks: Bool { prefs.ui.showFourDecks }

    /// hörbare Abweichung von der Tonart des Tracks in Halbtönen: Key-Shift, ohne Keylock zusätzlich das Tempo
    /// (Kern: transpose = 2^(keyShift/12) · rate ohne Keylock)
    func keyDeviation(_ d: Int) -> Double {
        let s = decks[d].state
        return Double(s.keyShift) + (s.keylock ? 0 : 12 * log2(max(s.rate, 1e-6)))
    }

    /// Lage des Decks im „Code“ (Bar-Zähler); Phrase wie in der Wellenform (⌘, → Anzeige), nil ohne Grid
    func phraseCode(_ d: Int) -> PhraseCode? {
        guard let g = decks[d].state.grid, g.bpm > 0 else { return nil }
        return PhraseCode(deckBeat: g.beatPosition(at: position(d)), sessionBeat: core.sessionBeat,
                          phraseBars: max(4, prefs.ui.phraseBeats) / 4)
    }

    // MARK: - Befehle (weitergeleitet an den Kern)

    func load(_ t: Track, deck d: Int) {
        CloudLibrary.shared.deckWillLoad(t, deck: d)   // nur online -> sofort anfordern, Hinweis
        originals[d] = t
        let e = edits.edit(for: t.key)
        savedEdit[d] = e
        core.load(e?.apply(to: t) ?? t, deck: d)
        focusedDeck = d
        pull()
    }

    /// Grid/Hotcue-Änderungen eines Decks gegenüber der Collection speichern (nur wenn sich etwas geändert hat)
    private func persistEdits() {
        guard !Session.isSelfTest else { return }   // Selbsttest/Messung: Christians edits.json nie anfassen
        for d in state.decks.indices {
            guard let orig = originals[d], let t = state.decks[d].track, t.key == orig.key, !state.decks[d].loading else { continue }
            let deck = state.decks[d]
            var e = TrackEdit()
            if let g = deck.grid, let og = BeatGrid(track: orig) {
                if abs(g.bpm - og.bpm) > 0.0001 { e.bpm = g.bpm }
                if abs(g.anchor - og.anchor) > 0.0001 { e.gridAnchorMs = g.anchor * 1000 }
            } else if let g = deck.grid {
                e.bpm = g.bpm; e.gridAnchorMs = g.anchor * 1000
            }
            let cues = deck.hotcues.values.sorted { $0.hotcue < $1.hotcue }
            if cues != orig.hotcues { e.hotcues = cues }
            let newEdit: TrackEdit? = (e.bpm == nil && e.gridAnchorMs == nil && e.hotcues == nil) ? nil : e
            let old = savedEdit[d] ?? nil
            if newEdit?.bpm != old?.bpm || newEdit?.gridAnchorMs != old?.gridAnchorMs || newEdit?.hotcues != old?.hotcues {
                edits.set(newEdit, for: orig.key)
                savedEdit[d] = newEdit
            }
        }
    }

    func shiftGrid(_ d: Int, ms: Double) { run { core.shiftGrid(d, ms: ms) } }
    func setGridBPM(_ d: Int, _ v: Double) { run { core.setGridBPM(d, v) } }
    func scaleGridBPM(_ d: Int, _ f: Double) { run { core.scaleGridBPM(d, f) } }
    func setGridAnchorHere(_ d: Int) { run { core.setGridAnchorHere(d) } }
    func shiftGridBeats(_ d: Int, _ n: Int) { run { core.shiftGridBeats(d, n) } }
    func applyPhraseAnchor(_ d: Int) { run { core.applyPhraseAnchor(d) } }
    func resetGrid(_ d: Int) { if let o = originals[d] { run { core.resetGrid(d, original: o) } } }
    func togglePlay(_ d: Int) { run { core.togglePlay(d) } }
    func cueDown(_ d: Int) { run { core.cueDown(d) } }
    func cueUp(_ d: Int) { run { core.cueUp(d) } }
    func cup(_ d: Int) { run { core.cup(d) } }
    func seek(_ d: Int, fraction: Double) { core.seek(d, fraction: fraction) }
    func toggleReverse(_ d: Int) { run { core.toggleReverse(d) } }
    func toggleFlux(_ d: Int) { run { core.toggleFlux(d) } }
    func hotcue(_ d: Int, _ n: Int, delete: Bool = false) { run { core.hotcue(d, n, delete: delete) } }
    func autoLoop(_ d: Int, size: Double? = nil) { run { core.autoLoop(d, size: size) } }
    func exitLoop(_ d: Int) { run { core.exitLoop(d) } }
    func reloop(_ d: Int) { run { core.reloop(d) } }
    func changeLoopSize(_ d: Int, by s: Int) { run { core.changeLoopSize(d, by: s) } }
    func setLoopIn(_ d: Int) { run { core.setLoopIn(d) } }
    func setLoopOut(_ d: Int) { run { core.setLoopOut(d) } }
    func beatjump(_ d: Int, beats: Double) { run { core.beatjump(d, beats: beats) } }
    func setJumpSize(_ d: Int, _ s: Double) { run { core.setJumpSize(d, s) } }
    func setTempo(_ d: Int, _ v: Double) { run { core.setTempo(d, v) } }
    func setTempoRange(_ d: Int, _ v: Double) { run { core.setTempoRange(d, v) } }
    func toggleSync(_ d: Int) { run { core.toggleSync(d) } }
    func toggleMaster(_ d: Int) { run { core.toggleMaster(d) } }
    func toggleKeylock(_ d: Int) { run { core.toggleKeylock(d) } }
    func shiftKey(_ d: Int, _ s: Int) { run { core.shiftKey(d, s) } }
    func bend(_ d: Int, _ v: Double) { run { core.bend(d, v) } }
    func updateDeck(_ d: Int, _ f: (inout DeckState) -> Void) { run { core.updateDeck(d, f) } }
    func setCrossfader(_ v: Double) { run { core.setCrossfader(v) } }
    func updateFX(_ u: Int, _ f: (inout FXUnitState) -> Void) { run { core.updateFX(u, f) } }
    func toggleFXAssign(_ d: Int, _ u: Int) { run { core.toggleFXAssign(d, u) } }
    func setPlugin(_ u: Int, _ id: String?) {
        if id != state.fx[u].pluginID { PluginWindow.close(u) }
        run { core.setPlugin(u, id: id) }
    }
    func setMasterVolume(_ v: Double) {
        run { core.setMasterVolume(v) }
        UserDefaults.standard.set(v, forKey: "masterVolume")
    }
    /// MAIN wirkt nur im internen Modus oder mit „Main-Volume wirkt auch extern“ (sonst setzt der Kern 1)
    var masterVolumeActive: Bool { mixerMode == .internalMixer || prefs.engine.masterVolumeExternal }
    func toggleQuantize() { prefs.engine.quantize.toggle() }
    func toggleSnap() { prefs.engine.snap.toggle() }
    func setClockMaster(_ on: Bool) { run { core.setClockMaster(on) } }
    func setSemiSync(_ on: Bool) { run { core.setSemiSync(on) } }
    func nudgeClock(_ d: Double) { run { core.nudgeClock(d) } }
    func setClockBPM(_ v: Double) { run { core.setClockBPM(v) } }
    func tap() { run { core.tap() } }
    func setMetronome(_ on: Bool, volume: Double? = nil) { run { core.setMetronome(on, volume: volume) } }
    func toggleLink() { run { core.setLinkEnabled(!state.linkEnabled) } }

    // MARK: - Audio-Setup

    var currentDevice: MixEngine.OutputDevice? {
        if let uid = deviceUID, let d = outputDevices.first(where: { $0.uid == uid }) { return d }
        let def = MixEngine.defaultOutputDevice()
        return outputDevices.first { $0.id == def }
    }

    var deviceChannels: Int { currentDevice?.channels ?? 2 }

    func refreshDevices() { outputDevices = MixEngine.outputDevices() }

    /// Geräteliste hat sich geändert: neu verbinden, wenn unser Gerät weg ist, die Ausgabe steht oder das gewählte
    /// Interface (USB-Aussetzer) wieder da ist. Folgt die Ausgabe dem Systemstandard, bleibt sie, solange ihr Gerät da ist.
    private func rerouteReason() -> String? {
        let cur = engine.routing.device
        if !engine.running { return "Ausgabe steht" }
        if let cur, !outputDevices.contains(where: { $0.id == cur }) { return "Gerät weg" }
        if let uid = deviceUID, let want = outputDevices.first(where: { $0.uid == uid }), want.id != cur { return "\(want.name) wieder da" }
        return nil
    }

    /// Routing an die Engine geben (startet die Deck-Ausgänge neu) und speichern.
    func applyRouting(restart: Bool = false) {
        print("[audio] Routing wird angewendet")
        let dev = currentDevice
        let firsts = mixerMode == .external ? deckPairs : Array(repeating: internalPair, count: MixEngine.deckCount)
        engine.apply(MixEngine.Routing(device: dev?.id, firstChannel: firsts), restart: restart)
        core.setMasterVolume(core.snapshot().masterVolume)
        core.setExternalMixer(mixerMode == .external)
        let route = mixerMode == .external
            ? zip(deckLetters, deckPairs).map { "\($0)→\($1 + 1)/\($1 + 2)" }.joined(separator: " ")
            : "alle→\(internalPair + 1)/\(internalPair + 2)"
        engineStatus = engine.running
            ? "\(dev?.name ?? "Standard") · \(mixerMode.rawValue) · \(route)"
            : "Audio-Fehler: \(engine.lastError ?? "?")"
        if engine.running {
            let khz = { (r: Double) in String(format: "%g kHz", r / 1000) }
            engineStatus += " · \(khz(engine.outputRate))"
            if abs(engine.outputRate - engine.sampleRate) > 1 { engineStatus += " (intern \(khz(engine.sampleRate)) bis Neustart)" }
        }
        if engine.running, let e = engine.lastError { engineStatus += " · ⚠︎ \(e)" }
        saveSetup()
        pull()
    }

    private func loadSetup() {
        let d = UserDefaults.standard
        if let m = d.string(forKey: "mixerMode").flatMap(MixerMode.init(rawValue:)) { mixerMode = m }
        deviceUID = d.string(forKey: "deviceUID")
        internalPair = d.integer(forKey: "internalPair")
        if let p = d.array(forKey: "deckPairs") as? [Int], p.count == MixEngine.deckCount { deckPairs = p }
        if d.object(forKey: "masterVolume") != nil { core.setMasterVolume(d.double(forKey: "masterVolume")) }
        sampleRate = d.double(forKey: "sampleRate")
        bufferSize = d.integer(forKey: "bufferSize")
        engine.deviceRate = sampleRate > 0 ? sampleRate : nil
        engine.bufferFrames = bufferSize > 0 ? UInt32(bufferSize) : nil
    }

    /// Samplerate/Puffer setzen und die Ausgabe neu starten
    func setAudioFormat(rate: Double? = nil, buffer: Int? = nil) {
        if let rate { sampleRate = rate; engine.deviceRate = rate > 0 ? rate : nil }
        if let buffer { bufferSize = buffer; engine.bufferFrames = buffer > 0 ? UInt32(buffer) : nil }
        applyRouting(restart: true)
    }

    /// Interface neu verbinden (z. B. nach USB-Aussetzer): Geräte neu einlesen, Ausgabe neu starten
    func reconnect() {
        refreshDevices()
        applyRouting(restart: true)
    }

    private func saveSetup() {
        let d = UserDefaults.standard
        d.set(mixerMode.rawValue, forKey: "mixerMode")
        d.set(deviceUID, forKey: "deviceUID")
        d.set(internalPair, forKey: "internalPair")
        d.set(deckPairs, forKey: "deckPairs")
        d.set(sampleRate, forKey: "sampleRate")
        d.set(bufferSize, forKey: "bufferSize")
    }

    // MARK: - Vorhören im Browser

    func preview(_ t: Track) {
        previewPlayer?.stop()
        previewPlayer = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: t.path))
        previewPlayer?.currentTime = (previewPlayer?.duration ?? 0) * prefs.ui.previewStart
        previewPlayer?.play()
    }

    func togglePreview(_ t: Track) {
        if previewPlayer?.isPlaying == true { previewPlayer?.stop() } else { preview(t) }
    }
}
