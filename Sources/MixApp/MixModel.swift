import AVFoundation
import AppKit
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
    /// EDIT-Modus: hier statt in `prefs` beobachtet – Umschalten rendert nur dieses Deck neu (gespeichert mit den Einstellungen)
    var editing = false
}

/// FX-Unit für die Oberfläche: eigenes Observable je Unit (FXUnitView liest nur ihre Unit)
@MainActor @Observable
final class FXMirror {
    var state = FXUnitState()
    /// Bedienelemente D/W, Regler 1–3, Tasten 1–3: Ziel, Stellung, Beschriftung (Länge wie MixState.fxControls)
    var controls = Array(repeating: FXControlInfo(), count: FXControl.allCases.count)
    /// zuweisbare Parameter des geladenen Effekts
    var params: [FXParam] = []
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
            savePrefs()
            if prefs.engine != oldValue.engine { core.setPrefs(prefs.engine) }
        }
    }

    /// Einstellungen speichern; der EDIT-Modus kommt aus den Deck-Spiegeln (in `prefs` steht er nur beim Start)
    private func savePrefs() {
        var p = prefs
        p.ui.editDecks = decks.map(\.editing)
        p.save()
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

    /// eigene Änderungen (Grid, Hotcues, Schnitt) dauerhaft je Track – die Collection bleibt unangetastet.
    /// Selbsttest/Messung: nur lesen (Christians edits.json nie schreiben)
    @ObservationIgnored let edits = TrackEditStore(url: HistoryStore.baseDir.appendingPathComponent("edits.json"), writes: !Session.isSelfTest)
    @ObservationIgnored private var originals: [Int: Track] = [:]
    @ObservationIgnored private var savedEdit: [Int: TrackEdit?] = [:]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var previewPlayer: AVAudioPlayer?
    /// Vorhören: zählt jede Anfrage (eine spät geöffnete Datei spielt nur, wenn danach nichts mehr kam)
    @ObservationIgnored private var previewSeq = 0
    @ObservationIgnored private var previewOpening = false
    /// Vorhören: Anhalten am Schnitt-Ende (der Player kennt nur das Dateiende)
    @ObservationIgnored private var previewStop: DispatchWorkItem?
    /// Vorhören: Track und gespielter Bereich, nil = still. Beobachtet von der Vorschau des Tracks und der Statuszeile
    private(set) var previewing: Previewing?
    struct Previewing: Equatable { var key: String; var cut: PreviewCut }
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
        FileServiceSetup.attach(core)
        loadSetup()
        for d in decks.indices { decks[d].editing = prefs.ui.editing(d) }
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
                if m.controls != s.fxControls[u] { m.controls = s.fxControls[u] }
                if m.params != s.fxParams[u] { m.params = s.fxParams[u] }
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

    /// Lade-Schutz (⌘, → DECKS): spielt das Deck, bleibt es, wie es ist (Hinweis in der Statusleiste).
    /// `force` nil = ⌥ beim Klick/Doppelklick lädt trotzdem; Controller (Shift + LOAD) und Tastatur geben ihn an
    @discardableResult
    func load(_ t: Track, deck d: Int, force: Bool? = nil) -> Bool {
        if !(force ?? NSEvent.modifierFlags.contains(.option)), core.loadBlocked(d) { return false }
        CloudLibrary.shared.deckWillLoad(t, deck: d)   // nur online -> sofort anfordern, Hinweis
        originals[d] = t
        let e = edits.edit(for: t.key)
        savedEdit[d] = e
        core.load(e?.apply(to: t) ?? t, deck: d, trim: e?.trim ?? TrackTrim(), gridEdited: e?.hasGrid ?? false)
        focusedDeck = d
        pull()
        return true
    }

    /// eigene Änderungen eines Decks speichern (nur wenn sich etwas geändert hat): von Hand gesetztes Grid ganz (BPM +
    /// Anker, gewinnt über Collection und spätere Analyse), Hotcues gegenüber der Collection, Schnitt.
    /// Geschrieben wird gesammelt im Hintergrund (TrackEditStore)
    private func persistEdits() {
        guard !Session.isSelfTest else { return }   // Selbsttest/Messung: Christians edits.json nie anfassen
        for d in state.decks.indices {
            guard let orig = originals[d], let t = state.decks[d].track, t.key == orig.key, !state.decks[d].loading else { continue }
            let deck = state.decks[d]
            var e = TrackEdit(trim: deck.trim)
            if deck.gridEdited, let g = deck.grid { e.bpm = g.bpm; e.gridAnchorMs = g.anchor * 1000 }
            let cues = deck.hotcues.values.sorted { $0.hotcue < $1.hotcue }
            if cues != orig.hotcues { e.hotcues = cues }
            let old = savedEdit[d] ?? nil
            if !e.same(as: old) {
                let newEdit: TrackEdit? = e.isEmpty ? nil : e
                edits.set(newEdit, for: orig.key)
                savedEdit[d] = newEdit
                if previewing?.key == orig.key { previewCutChanged(newEdit?.trim) }
            }
        }
    }

    /// offene Änderungen sofort schreiben (Beenden)
    func flushEdits() { edits.flush() }

    func shiftGrid(_ d: Int, ms: Double) { run { core.shiftGrid(d, ms: ms) } }
    func setGridBPM(_ d: Int, _ v: Double) { run { core.setGridBPM(d, v) } }
    func scaleGridBPM(_ d: Int, _ f: Double) { run { core.scaleGridBPM(d, f) } }
    func setGridAnchorHere(_ d: Int) { run { core.setGridAnchorHere(d) } }
    func shiftGridBeats(_ d: Int, _ n: Int) { run { core.shiftGridBeats(d, n) } }
    func applyPhraseAnchor(_ d: Int) { run { core.applyPhraseAnchor(d) } }
    func resetGrid(_ d: Int) { if let o = originals[d] { run { core.resetGrid(d, original: o) } } }
    func tapGrid(_ d: Int) { run { core.tapGrid(d) } }

    // Schnitt
    /// IN HERE / OUT HERE: Quantize rastet auf den Beat, ⌥ = genau hier
    func trimHere(_ d: Int, end: Bool, free: Bool = false) {
        var ok = false
        run { ok = core.trimHere(d, end: end, free: free) }
        if !ok, deck(d).track != nil { StatusCenter.post(.warning, String(localized: "Schnitt zu kurz (mindestens 1 s)"), key: "trim.\(d)") }
    }
    func setTrimPoint(_ d: Int, end: Bool, _ t: Double) { run { _ = core.setTrimPoint(d, end: end, t) } }
    /// Griff ziehen (Wellenform, Übersicht): Quantize rastet auf den Beat, ⌥ = frei
    func dragTrim(_ d: Int, end: Bool, to time: Double) {
        let s = deck(d)
        var t = time
        if prefs.engine.quantize, !NSEvent.modifierFlags.contains(.option), let g = s.grid, g.bpm > 0 { t = g.nearestBeat(to: t) }
        if abs(t - (end ? s.trim.end ?? s.duration : s.trim.start ?? 0)) < 1e-6 { return }
        setTrimPoint(d, end: end, t)
    }
    func clearTrim(_ d: Int) { run { core.clearTrim(d) } }

    /// EDIT-Modus je Deck (Schnitt- und Grid-Werkzeuge statt Loop / Beatjump), gemerkt in den Einstellungen
    func editing(_ d: Int) -> Bool { decks[d].editing }
    func toggleEdit(_ d: Int) { setEditing(d, !decks[d].editing) }
    /// nur das Deck beobachtet den Schalter; gespeichert wird ohne `prefs` zu ändern (das rendert sonst das ganze Fenster)
    func setEditing(_ d: Int, _ on: Bool) {
        guard decks.indices.contains(d), decks[d].editing != on else { return }
        decks[d].editing = on
        savePrefs()
    }
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
    func keySync(_ d: Int) { run { core.keySync(d) } }
    func bend(_ d: Int, _ v: Double) { run { core.bend(d, v) } }
    func updateDeck(_ d: Int, _ f: (inout DeckState) -> Void) { run { core.updateDeck(d, f) } }
    func setCrossfader(_ v: Double) { run { core.setCrossfader(v) } }
    func updateFX(_ u: Int, _ f: (inout FXUnitState) -> Void) { run { core.updateFX(u, f) } }
    func toggleFXAssign(_ d: Int, _ u: Int) { run { core.toggleFXAssign(d, u) } }
    func setFXControl(_ u: Int, _ c: FXControl, _ v: Double) { run { core.setFXControl(u, c, v) } }
    func pressFXButton(_ u: Int, _ i: Int) { run { core.pressFXButton(u, i) } }
    /// Zuweisung ändern (nil = Standard, "" = aus); die gemerkte Zuweisung je Effekt geht in die Einstellungen
    func setFXMapping(_ u: Int, _ c: FXControl, _ target: String?) {
        run { core.setFXMapping(u, c, target) }
        prefs.engine.fxMappings = state.prefs.fxMappings
    }
    func resetFXMapping(_ u: Int) {
        run { core.resetFXMapping(u) }
        prefs.engine.fxMappings = state.prefs.fxMappings
    }
    /// Wert eines Bedienelements mit Einheit (VST3: Text vom Plugin)
    func fxText(_ u: Int, _ info: FXControlInfo) -> String {
        guard let p = info.param else { return "—" }
        return core.pluginText(u, p, info.value) ?? p.text(info.value)
    }
    /// Name eines Effekts zur Kennung (Plugin: Name aus der Plugin-Liste)
    func effectName(_ key: String) -> String {
        switch key {
        case FXCatalog.groupKey: String(localized: "Gruppe")
        case "FILTER", "DELAY", "REVERB", "PLUGIN": key
        default: core.pluginCatalog.knownInfo(key).map { "\($0.name) · \($0.manufacturer)" } ?? key
        }
    }
    func setPlugin(_ u: Int, _ id: String?) {
        if id != state.fx[u].pluginID { PluginWindow.close(u) }
        run { core.setPlugin(u, id: id) }
    }
    func setMasterVolume(_ v: Double) {
        run { core.setMasterVolume(v) }
        if !Session.isSelfTest { UserDefaults.standard.set(v, forKey: "masterVolume") }
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
        engineStatus = engine.running
            ? "\(dev?.name ?? String(localized: "Standard")) · \(routeText)"
            : String(localized: "Audio-Fehler: \(engine.lastError ?? "?")")
        if engine.running {
            let khz = { (r: Double) in String(format: "%g kHz", r / 1000) }
            engineStatus += " · \(khz(engine.outputRate))"
            if abs(engine.outputRate - engine.sampleRate) > 1 { engineStatus += " " + String(localized: "(intern \(khz(engine.sampleRate)) bis Neustart)") }
        }
        if engine.running, let e = engine.lastError { engineStatus += " · ⚠︎ \(e)" }
        saveSetup()
        pull()
    }

    /// Modus und Kanäle für die Statusleiste
    var routeText: String {
        mixerMode == .external
            ? String(localized: "Extern") + " · " + zip(deckLetters, deckPairs).map { "\($0)→\($1 + 1)/\($1 + 2)" }.joined(separator: " ")
            : String(localized: "Intern") + " · " + String(localized: "alle→\(internalPair + 1)/\(internalPair + 2)")
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
        guard !Session.isSelfTest else { return }   // Selbsttest/Messung (eingebautes Gerät): Christians Routing bleibt
        let d = UserDefaults.standard
        d.set(mixerMode.rawValue, forKey: "mixerMode")
        d.set(deviceUID, forKey: "deviceUID")
        d.set(internalPair, forKey: "internalPair")
        d.set(deckPairs, forKey: "deckPairs")
        d.set(sampleRate, forKey: "sampleRate")
        d.set(bufferSize, forKey: "bufferSize")
    }

    // MARK: - Vorhören im Browser

    /// Datei im Hintergrund öffnen: eine Datei nur in der Cloud lädt der Anbieter beim Öffnen erst ganz herunter,
    /// auf dem Hauptthread stand die Oberfläche (Wellenformen, Browser) so lange. Gespielt wird nur der Schnitt,
    /// ab dem eingestellten Anteil davon. Selbsttest: stumm
    func preview(_ t: Track) {
        stopPreview()
        previewOpening = true
        let seq = previewSeq, url = URL(fileURLWithPath: t.path), start = prefs.ui.previewStart, key = t.key
        DispatchQueue.global(qos: .userInitiated).async {
            let p = try? AVAudioPlayer(contentsOf: url)
            p?.prepareToPlay()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard seq == self.previewSeq else { return }
                    self.previewOpening = false
                    guard let p else { return }
                    let cut = PreviewCut(trim: self.edits.edit(for: key)?.trim, duration: p.duration)
                    if Session.isSelfTest { p.volume = 0 }
                    p.currentTime = cut.start(fraction: start)
                    p.play()
                    self.previewPlayer = p
                    self.previewing = Previewing(key: key, cut: cut)
                    self.schedulePreviewStop()
                }
            }
        }
    }

    func togglePreview(_ t: Track) {
        if previewPlayer?.isPlaying == true || previewOpening { stopPreview() } else { preview(t) }
    }

    func stopPreview() {
        previewSeq += 1
        previewOpening = false
        previewStop?.cancel()
        previewStop = nil
        previewPlayer?.stop()
        previewPlayer = nil
        shotPreview = nil
        if previewing != nil { previewing = nil }
    }

    /// Position des Vorhörens (s), nil = still
    var previewPosition: Double? { previewPlayer?.currentTime ?? shotPreview?.position }
    /// Position als Anteil der Dateilänge (Strich in der Vorschau)
    var previewFraction: Double? {
        if let p = previewPlayer { return p.duration > 0 ? p.currentTime / p.duration : nil }
        return shotPreview.map { $0.position / $0.duration }
    }
    @ObservationIgnored private var shotPreview: (position: Double, duration: Double)?

    /// Selbsttest-Bilder: Vorhören darstellen ohne Player (kein Audio, keine Datei)
    func showPreviewForShot(_ t: Track, at position: Double) {
        guard Session.isSelfTest, t.duration > 0 else { return }
        stopPreview()
        let cut = PreviewCut(trim: edits.edit(for: t.key)?.trim, duration: t.duration)
        shotPreview = (cut.clamp(position), t.duration)
        previewing = Previewing(key: t.key, cut: cut)
    }

    /// Klick in die Vorschau des laufenden Tracks (Anteil der Dateilänge): außerhalb des Schnitts an den Rand innen
    func seekPreview(_ key: String, fraction: Double) {
        guard let p = previewPlayer, let v = previewing, v.key == key else { return }
        p.currentTime = v.cut.clamp(fraction * p.duration)
        schedulePreviewStop()
    }

    /// Schnitt des laufenden Tracks geändert (Deck): vor dem neuen Anfang -> dorthin, hinter dem neuen Ende -> Stopp
    private func previewCutChanged(_ trim: TrackTrim?) {
        guard let p = previewPlayer, var v = previewing else { return }
        let cut = PreviewCut(trim: trim, duration: p.duration)
        guard cut != v.cut else { return }
        v.cut = cut
        previewing = v
        if p.currentTime < cut.lo { p.currentTime = cut.lo }
        schedulePreviewStop()
    }

    /// am Schnitt-Ende (oder Dateiende) anhalten; Zeitpunkt aus der Restzeit, früh geweckt -> neu planen
    private func schedulePreviewStop() {
        previewStop?.cancel()
        guard let p = previewPlayer, let cut = previewing?.cut else { return }
        let seq = previewSeq
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, seq == self.previewSeq, let p = self.previewPlayer else { return }
                if !p.isPlaying || cut.isOver(p.currentTime) { self.stopPreview() } else { self.schedulePreviewStop() }
            }
        }
        previewStop = w
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.02, cut.hi - p.currentTime), execute: w)
    }
}
