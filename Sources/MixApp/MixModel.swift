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
    /// markierter Bereich der Wellenform (⌃ + Ziehen), bis Esc, Klick daneben, neue Markierung oder anderer Track
    var range: TrackRange?
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
    var focusedDeck = 0 { didSet { if focusedDeck != oldValue { updateHarmony() } } }
    /// Bezug für den Browser (Key-Farben, Matching, Sortierung „Harmonie“): hörbarer Key (Code 0–23) und Tempo (0,1 BPM,
    /// 0 = keins) des Master-Decks, ohne spielenden Master des Fokus-Decks. Getrennt beobachtet: die Key-Farben hängen
    /// nur am Key, Filter und Sortierung (nur wenn eingeschaltet) am Tempo
    private(set) var harmonyKey: Int?
    private(set) var harmonyBPM = 0.0
    /// Selbsttest-Bilder: fester Bezug statt der Decks
    @ObservationIgnored var harmonyFixed: HarmonyRef? { didSet { updateHarmony() } }
    var prefs = AppPrefs.load() {
        didSet {
            guard prefs != oldValue else { return }
            savePrefs()
            if prefs.engine != oldValue.engine { core.setPrefs(prefs.engine) }
            if prefs.ui.previewVolume != oldValue.ui.previewVolume { previewer.setVolume(prefs.ui.previewVolume) }
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
    /// Vorhören: erster Kanal des Paars, `previewAuto` = Extern erstes freies Paar nach den Decks / Intern Hauptausgang,
    /// `previewOff` = aus
    var previewPair = MixModel.previewAuto
    static let previewAuto = -1, previewOff = -2
    /// Vorhör-Player im Kern (eigenes Kanalpaar, Laden über den Datei-Dienst)
    @ObservationIgnored private(set) lazy var previewer: PreviewPlayer = {
        let p = PreviewPlayer(engine: engine)
        p.service = FileServiceSetup.shared
        return p
    }()
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
    /// Vorhören: zählt jede Anfrage (ein spät geladener Track spielt nur, wenn danach nichts mehr kam)
    @ObservationIgnored private var previewSeq = 0
    /// Vorhören: Dauer des geladenen Tracks (s)
    @ObservationIgnored private var previewDuration = 0.0
    /// Vorhören: prüft, ob der Kern am Ende angehalten hat (der Kern stoppt selbst am Schnitt- bzw. Track-Ende)
    @ObservationIgnored private var previewWatch: Timer?
    /// Vorhören: Ladezeit des letzten Tracks (s)
    @ObservationIgnored private(set) var previewLoadSeconds: Double?
    /// Vorhören: Track und gespielter Bereich, nil = still. Beobachtet von der Vorschau des Tracks und der Statuszeile
    private(set) var previewing: Previewing?
    /// Vorhören: Track wird geladen (Schlüssel)
    private(set) var previewLoading: String?
    struct Previewing: Equatable { var key: String; var cut: PreviewCut }
    @ObservationIgnored private var reroutePending = false
    @ObservationIgnored private var sleepObservers: [NSObjectProtocol] = []
    /// Gerät, auf das die Engine wartet (Statuszeile)
    @ObservationIgnored private var lostDevice: String?

    /// Bibliothek (Schneiden: neue Datei in CUTS), beim Start gesetzt
    @ObservationIgnored weak var library: LibraryStore?

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
        BrowserPaneModel.harmonySource = { [weak self] in
            BrowserPaneModel.HarmonyInput(ref: self.flatMap { m in m.harmonyKey != nil || m.harmonyBPM > 0 ? HarmonyRef(key: m.harmonyKey, bpm: m.harmonyBPM) : nil },
                                          rule: self?.prefs.ui.match ?? MatchRule())
        }
        loadSetup()
        for d in decks.indices { decks[d].editing = prefs.ui.editing(d) }
        core.setPrefs(prefs.engine)
        previewer.setVolume(prefs.ui.previewVolume)
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
                } else {
                    self.refreshEngineStatus()
                }
            }
        }
        // Gerät weg / wieder da / Rate / Puffer: macht die Engine selbst (Geräte-Queue), hier nur Hinweis + Statuszeile
        engine.onOutputEvent = { [weak self] e in
            Task { @MainActor in self?.outputEvent(e) }
        }
        // Ruhezustand: Ausgabe sauber anhalten, nach dem Aufwachen dasselbe Gerät neu öffnen (Decks spielen weiter)
        let ws = NSWorkspace.shared.notificationCenter
        sleepObservers = [
            ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.engine.willSleep() }
            },
            ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    print("[audio] aufgewacht: Ausgabe neu öffnen")
                    self.engine.didWake()
                    self.refreshDevices()
                    self.refreshEngineStatus()
                }
            },
        ]
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
                if key != decks[d].trackKey {
                    decks[d].trackKey = key
                    if decks[d].range != nil { decks[d].range = nil }
                    // Instant Double (auch vom Controller): Collection-Stand und gespeicherte Änderung vom Quell-Deck
                    if !key.isEmpty, originals[d]?.key != key, let e = originals.first(where: { $0.value.key == key })?.key {
                        originals[d] = originals[e]
                        savedEdit[d] = savedEdit[e]
                    }
                }
            }
            if s.effectiveMaster != effectiveMaster { effectiveMaster = s.effectiveMaster }
            if s.clockMaster != clockMaster { clockMaster = s.clockMaster }
            updateHarmony()
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

    /// Bezugs-Deck: spielender Master, sonst Fokus-Deck; Key = Track-Key um die hörbare Abweichung (gerundet) verschoben
    private func updateHarmony() {
        var key: Int?, bpm = 0.0
        if let f = harmonyFixed {
            key = f.key; bpm = f.bpm
        } else {
            let m = effectiveMaster.flatMap { decks[$0].state.playing ? $0 : nil }
            let d = m ?? focusedDeck
            if decks.indices.contains(d), let t = decks[d].state.track {
                key = t.harmonyCode.map { Harmony.shifted($0, by: Int(keyDeviation(d).rounded())) }
                bpm = m != nil || state.clockMaster ? state.masterTempo : decks[d].state.bpm
            }
        }
        bpm = (bpm * 10).rounded() / 10
        if key != harmonyKey { harmonyKey = key }
        if bpm != harmonyBPM { harmonyBPM = bpm }
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
        core.load(e?.apply(to: t) ?? t, deck: d, trim: e?.trim ?? TrackTrim(), gridEdited: e?.hasGrid ?? false,
                  activeLoops: Set(e?.activeLoops ?? []))
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
            if !deck.activeLoops.isEmpty { e.activeLoops = deck.activeLoops.sorted() }
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

    // Bereich (Markierung in der Wellenform): Schneiden, Schnitt, Loop
    func range(_ d: Int) -> TrackRange? { decks.indices.contains(d) ? decks[d].range : nil }
    func setRange(_ d: Int, _ r: TrackRange?) { if decks.indices.contains(d), decks[d].range != r { decks[d].range = r } }
    /// Esc: Bereich des Fokus-Decks weg, sonst alle; false = keiner da (Taste bleibt frei)
    @discardableResult
    func clearRange(_ d: Int? = nil) -> Bool {
        let hit = d.flatMap { decks.indices.contains($0) && decks[$0].range != nil ? [$0] : nil } ?? decks.indices.filter { decks[$0].range != nil }
        for i in hit { decks[i].range = nil }
        return !hit.isEmpty
    }
    /// Schnitt IN / OUT auf den Bereich (nicht destruktiv)
    func rangeToTrim(_ d: Int) {
        guard let r = range(d) else { return }
        var ok = false
        run { ok = core.setTrim(d, TrackTrim(start: r.start, end: r.end)) }
        if !ok { StatusCenter.post(.warning, String(localized: "Schnitt zu kurz (mindestens 1 s)"), key: "trim.\(d)") }
    }
    /// Loop auf den Bereich
    func rangeToLoop(_ d: Int) {
        guard let r = range(d) else { return }
        var ok = false
        run { ok = core.setLoop(d, start: r.start, end: r.end) }
        if !ok { StatusCenter.post(.warning, String(localized: "Loop aus Bereich nicht möglich (außerhalb des Schnitts)"), key: "loop.\(d)") }
    }

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
    func toggleActiveLoop(_ d: Int, _ n: Int) { run { core.toggleActiveLoop(d, n) } }
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
    /// Instant Double; `force` nil = ⌥ beim Klick übergeht den Lade-Schutz
    func instantDouble(from s: Int, to d: Int, force: Bool? = nil) {
        run { core.instantDouble(from: s, to: d, force: force ?? NSEvent.modifierFlags.contains(.option)) }
    }
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
        case _ where FXCatalog.isGroup(key):
            String(localized: "Gruppe") + " · " + FXCatalog.groupTypes(key).map(\.name).joined(separator: " · ")
        case _ where FXUnitState.Effect.allCases.contains { $0.name == key }: key
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

    /// Geräteliste hat sich geändert: auf ein anderes Gerät wechseln? Gerät weg / wieder da / Ruhezustand macht die
    /// Engine (wartet auf dieselbe UID, kein Ausweichen auf die Lautsprecher). Hier: gewähltes Interface ist (wieder) da,
    /// die Ausgabe steht, oder die Ausgabe folgt dem Systemstandard und der hat gewechselt.
    private func rerouteReason() -> String? {
        let cur = engine.routing.device, w = engine.watch
        let def = MixEngine.defaultOutputDevice().flatMap { d in outputDevices.contains { $0.id == d } ? d : nil }
        if w.phase == .sleeping { return nil }
        if w.waiting { return deviceUID == nil && def != nil ? "Standardgerät gewechselt" : nil }
        if !engine.running { return "Ausgabe steht" }
        if let cur, !outputDevices.contains(where: { $0.id == cur }) { return "Gerät weg" }
        if let uid = deviceUID, let want = outputDevices.first(where: { $0.uid == uid }), want.id != cur { return "\(want.name) wieder da" }
        if deviceUID == nil, let def, def != cur { return "Standardgerät gewechselt" }
        return nil
    }

    /// Meldung der Engine zur Ausgabe (Hinweis in der Statusleiste, Audio-Zeile)
    private func outputEvent(_ e: MixEngine.OutputEvent) {
        let khz = { (r: Double) in String(format: "%g", r / 1000) }
        switch e {
        case let .lost(name):
            lostDevice = name
            StatusCenter.post(.error, String(format: String(localized: "%@ weg – Ausgabe angehalten, wartet auf das Gerät"), name), key: "audio.device")
        case let .restored(name, secs, gap):
            lostDevice = nil
            StatusCenter.post(.ok, String(format: String(localized: "%@ wieder verbunden (%.0f ms nach dem Erkennen, Pause %.1f s)"),
                                          name, secs * 1000, gap), key: "audio.device")
        case let .rateChanged(from, to):
            StatusCenter.post(.warning, String(format: String(localized: "Geräterate %@ → %@ kHz: Ausgabe neu geöffnet, Kern bleibt %@ kHz"),
                                               khz(from), khz(to), khz(engine.sampleRate)), key: "audio.rate")
        case let .bufferChanged(from, to):
            StatusCenter.post(.info, String(format: String(localized: "Puffer %lld → %lld Frames"), Int(from), Int(to)), key: "audio.buffer")
        case .sleeping:
            StatusCenter.post(.info, String(localized: "Ruhezustand: Ausgabe angehalten"), key: "audio.device")
        }
        refreshDevices()
        refreshEngineStatus()
    }

    /// Routing an die Engine geben (startet die Deck-Ausgänge neu) und speichern.
    func applyRouting(restart: Bool = false) {
        print("[audio] Routing wird angewendet")
        let dev = currentDevice
        let firsts = mixerMode == .external ? deckPairs : Array(repeating: internalPair, count: MixEngine.deckCount)
        engine.apply(MixEngine.Routing(device: dev?.id, firstChannel: firsts), restart: restart)
        previewer.setOutput(firstChannel: previewRoute, mute: Session.isSelfTest)   // Selbsttest: nur Pegel messen
        core.setMasterVolume(core.snapshot().masterVolume)
        core.setExternalMixer(mixerMode == .external)
        refreshEngineStatus()
        saveSetup()
        pull()
    }

    /// Audio-Zeile der Statusleiste aus dem Zustand der Engine
    func refreshEngineStatus() {
        let w = engine.watch
        var s: String
        if w.waiting || w.phase == .sleeping {
            s = String(format: String(localized: "Warte auf %@ …"), lostDevice ?? outputDevices.first { $0.uid == w.uid }?.name ?? "?")
        } else if engine.running {
            let dev = outputDevices.first { $0.id == engine.routing.device }
            let khz = { (r: Double) in String(format: "%g kHz", r / 1000) }
            s = "\(dev?.name ?? String(localized: "Standard")) · \(routeText) · \(khz(engine.outputRate))"
            if abs(engine.outputRate - engine.sampleRate) > 1 { s += " " + String(localized: "(intern \(khz(engine.sampleRate)) bis Neustart)") }
            if let e = engine.lastError { s += " · ⚠︎ \(e)" }
        } else {
            s = String(localized: "Audio-Fehler: \(engine.lastError ?? "?")")
        }
        if s != engineStatus { engineStatus = s }
    }

    /// Modus und Kanäle für die Statusleiste
    var routeText: String {
        let pre = previewRoute.map { "PRE→\($0 + 1)/\($0 + 2)" } ?? "PRE→–"
        return mixerMode == .external
            ? String(localized: "Extern") + " · " + zip(deckLetters, deckPairs).map { "\($0)→\($1 + 1)/\($1 + 2)" }.joined(separator: " ") + " " + pre
            : String(localized: "Intern") + " · " + String(localized: "alle→\(internalPair + 1)/\(internalPair + 2)") + " " + pre
    }

    /// Vorhör-Paar am aktuellen Gerät (erster Kanal), nil = aus, keins frei oder nicht am Gerät
    var previewRoute: Int? {
        let ch = deviceChannels
        switch previewPair {
        case Self.previewOff: return nil
        case Self.previewAuto:
            return PreviewPlayer.autoPair(external: mixerMode == .external, deckPairs: deckPairs, mainPair: internalPair, channels: ch)
        default: return previewPair + 1 < ch ? previewPair : nil
        }
    }

    private func loadSetup() {
        let d = UserDefaults.standard
        if let m = d.string(forKey: "mixerMode").flatMap(MixerMode.init(rawValue:)) { mixerMode = m }
        deviceUID = d.string(forKey: "deviceUID")
        internalPair = d.integer(forKey: "internalPair")
        if let p = d.array(forKey: "deckPairs") as? [Int], p.count == MixEngine.deckCount { deckPairs = p }
        if d.object(forKey: "previewPair") != nil { previewPair = d.integer(forKey: "previewPair") }
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
        d.set(previewPair, forKey: "previewPair")
        d.set(sampleRate, forKey: "sampleRate")
        d.set(bufferSize, forKey: "bufferSize")
    }

    // MARK: - Vorhören im Browser

    /// Track im Hintergrund laden wie ein Deck (Datei-Dienst: eine hängende Cloud-Datei hängt nur den Helfer), dann im
    /// Kern auf dem Vorhör-Paar abspielen (⌘, -> AUDIO). Gespielt wird nur der Schnitt, ab dem eingestellten Anteil davon.
    /// Selbsttest: stumm (nur Pegel)
    func preview(_ t: Track) {
        stopPreview()
        let seq = previewSeq, key = t.key, start = prefs.ui.previewStart, trim = edits.edit(for: key)?.trim
        previewLoading = key
        previewer.play(path: t.path, hardTimeout: max(5, prefs.engine.loadAbortTimeout), plan: { d in
            let cut = PreviewCut(trim: trim, duration: d)
            return .init(start: cut.start(fraction: start), trimStart: cut.lo, trimEnd: cut.cutEnd ? cut.hi : 0)
        }, done: { [weak self] r in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, seq == self.previewSeq else { return }
                    self.previewLoading = nil
                    switch r {
                    case let .success(ok):
                        self.previewDuration = ok.duration
                        self.previewLoadSeconds = ok.seconds
                        self.previewing = Previewing(key: key, cut: PreviewCut(trim: trim, duration: ok.duration))
                        self.watchPreview()
                        if MixController.debug { print(String(format: "[preview] %@: %.2f s bis zum Start", key, ok.seconds)) }
                    case .failure(.missing):
                        StatusCenter.post(.warning, String(localized: "Vorhören: Datei fehlt"), key: "preview")
                    case let .failure(.failed(why)):
                        StatusCenter.post(.warning, String(localized: "Vorhören nicht möglich: \(why)"), key: "preview")
                    }
                }
            }
        })
    }

    func togglePreview(_ t: Track) {
        if previewing != nil || previewLoading != nil { stopPreview() } else { preview(t) }
    }

    func stopPreview() {
        previewSeq += 1
        previewer.stop()
        previewWatch?.invalidate()
        previewWatch = nil
        shotPreview = nil
        if previewLoading != nil { previewLoading = nil }
        if previewing != nil { previewing = nil }
    }

    /// Position des Vorhörens (s), nil = still
    var previewPosition: Double? { previewing != nil && shotPreview == nil ? previewer.position : shotPreview?.position }
    /// Position als Anteil der Dateilänge (Strich in der Vorschau)
    var previewFraction: Double? {
        if let s = shotPreview { return s.position / s.duration }
        guard previewing != nil, previewDuration > 0 else { return nil }
        return previewer.position / previewDuration
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
        guard shotPreview == nil, let v = previewing, v.key == key, previewDuration > 0 else { return }
        previewer.seek(v.cut.clamp(fraction * previewDuration))
    }

    /// Schnitt des laufenden Tracks geändert (Deck): vor dem neuen Anfang -> dorthin, hinter dem neuen Ende -> Stopp (Kern)
    private func previewCutChanged(_ trim: TrackTrim?) {
        guard shotPreview == nil, var v = previewing else { return }
        let cut = PreviewCut(trim: trim, duration: previewDuration)
        guard cut != v.cut else { return }
        v.cut = cut
        previewing = v
        previewer.setTrim(start: cut.lo, end: cut.cutEnd ? cut.hi : 0)
    }

    /// Kern hat am Ende angehalten -> Vorhören beenden (Statuszeile, Spielkopf)
    private func watchPreview() {
        previewWatch?.invalidate()
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.previewing != nil, !self.previewer.playing else { return }
                self.stopPreview()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        previewWatch = t
    }
}
