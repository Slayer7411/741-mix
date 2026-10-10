import AVFoundation
import Foundation
import Observation
import MixCore
import MixEngine

/// Intern: Mixer in der App, alle Decks auf ein Ausgangspaar. Extern: jedes Deck auf eigenes Paar (z. B. Xone:96).
enum MixerMode: String, CaseIterable, Identifiable {
    case internalMixer = "Intern", external = "Extern"
    var id: String { rawValue }
}

let deckLetters = ["A", "B", "C", "D"]

/// Oberflächen-Seite: spiegelt den Zustand des Steuerkerns (30 Hz) und leitet Befehle weiter.
/// Hängt die Oberfläche, laufen Audio, Sync und Controller trotzdem weiter (eigene Threads).
@MainActor @Observable
final class MixModel {
    @ObservationIgnored let core = MixController()
    var engine: MixEngine { core.engine }

    /// Gespiegelter Zustand (ohne Sync-Nudge, damit die Oberfläche nicht ständig neu zeichnet)
    private(set) var state = MixState()
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
    var deckPairs = [0, 2, 4, 6]

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var previewPlayer: AVAudioPlayer?
    @ObservationIgnored private var reroutePending = false

    init() {
        loadSetup()
        core.setPrefs(prefs.engine)
        outputDevices = MixEngine.outputDevices()
        applyRouting()
        engine.onConfigurationChange = { [weak self] in
            print("[audio] Konfigurationswechsel gemeldet")
            Task { @MainActor in
                guard let self, !self.reroutePending else { return }
                self.reroutePending = true
                try? await Task.sleep(for: .milliseconds(300))
                self.reroutePending = false
                self.refreshDevices()
                self.applyRouting()
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pull() }
        }
    }

    /// Zustand vom Kern holen
    func pull() {
        var s = core.snapshot()
        for i in s.decks.indices { s.decks[i].nudge = 0 }
        if s != state { state = s }
    }

    private func run(_ f: () -> Void) { f(); pull() }

    // MARK: - Abfragen

    func deck(_ d: Int) -> DeckState { state.decks[d] }
    func position(_ d: Int) -> Double { core.position(d) }
    func audio(_ d: Int) -> TrackAudio? { core.trackAudio(d) }
    func phaseError(_ d: Int) -> Double? { core.phaseError(d) }
    var effectiveMaster: Int? { state.effectiveMaster }
    var masterBPM: Double { state.effectiveMaster.map { state.decks[$0].bpm } ?? 0 }
    var showFourDecks: Bool { prefs.ui.showFourDecks }

    func keyText(_ d: Int) -> String {
        let s = state.decks[d]
        guard let t = s.track else { return "" }
        return s.keyShift == 0 ? t.openKey : "\(t.openKey) \(s.keyShift > 0 ? "+" : "")\(s.keyShift)"
    }

    // MARK: - Befehle (weitergeleitet an den Kern)

    func load(_ t: Track, deck d: Int) { core.load(t, deck: d); focusedDeck = d; pull() }
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
    func setMasterVolume(_ v: Double) {
        run { core.setMasterVolume(v) }
        UserDefaults.standard.set(v, forKey: "masterVolume")
    }
    func toggleQuantize() { prefs.engine.quantize.toggle() }

    // MARK: - Audio-Setup

    var currentDevice: MixEngine.OutputDevice? {
        if let uid = deviceUID, let d = outputDevices.first(where: { $0.uid == uid }) { return d }
        let def = MixEngine.defaultOutputDevice()
        return outputDevices.first { $0.id == def }
    }

    var deviceChannels: Int { currentDevice?.channels ?? 2 }

    func refreshDevices() { outputDevices = MixEngine.outputDevices() }

    /// Routing an die Engine geben (startet die Deck-Ausgänge neu) und speichern.
    func applyRouting() {
        print("[audio] Routing wird angewendet")
        let dev = currentDevice
        let firsts = mixerMode == .external ? deckPairs : Array(repeating: internalPair, count: MixEngine.deckCount)
        engine.apply(MixEngine.Routing(device: dev?.id, firstChannel: firsts))
        core.setMasterVolume(core.snapshot().masterVolume)
        core.setExternalMixer(mixerMode == .external)
        let route = mixerMode == .external
            ? zip(deckLetters, deckPairs).map { "\($0)→\($1 + 1)/\($1 + 2)" }.joined(separator: " ")
            : "alle→\(internalPair + 1)/\(internalPair + 2)"
        engineStatus = engine.running
            ? "\(dev?.name ?? "Standard") · \(mixerMode.rawValue) · \(route)"
            : "Audio-Fehler: \(engine.lastError ?? "?")"
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
    }

    private func saveSetup() {
        let d = UserDefaults.standard
        d.set(mixerMode.rawValue, forKey: "mixerMode")
        d.set(deviceUID, forKey: "deviceUID")
        d.set(internalPair, forKey: "internalPair")
        d.set(deckPairs, forKey: "deckPairs")
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
