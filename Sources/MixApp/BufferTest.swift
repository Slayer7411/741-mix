import Foundation
import MixCore
import MixEngine
import Observation
import SwiftUI

/// Puffer-Test (⌘, -> AUDIO): je Puffergröße des Geräts ~14 s Last – 4 Decks (A/B Keylock, C/D Sync auf A),
/// FX 1 und 2 mit Delay + Hall, Hauptausgang auf 0 (nichts hörbar), Metronom aus. Messung über den Rechenkern
/// (`takeLoad`), Ergebnis -> `BufferTest.recommend`. Nur bei gestoppten Decks. Geladene Tracks werden ersetzt;
/// FX, Keylock, Sync und Master stellt der Lauf danach zurück, die Decks stehen still.
/// Nicht gemessen: Wellenform (zeichnet das Hauptfenster, nur mit sichtbaren Decks), Plugins, Link.
@MainActor @Observable
final class BufferTestRunner {
    enum State: Equatable {
        case idle
        case running(frames: Int, step: Int, of: Int)
        case done
        case cancelled
        case refused(String)
    }

    /// eine Zeile der Ergebnisliste
    struct Row: Equatable, Identifiable {
        var probe: BufferTest.Probe
        /// Ausgabelatenz laut Gerät + Kern (Puffer, Gerät, Sicherheit, Stream), ms
        var outputLatencyMs: Double
        /// Samplerate des Geräts
        var deviceRate: Double
        var id: Int { probe.frames }
    }

    /// Einschwingen (Puffer-Wechsel, Gerät neu öffnen) und Messfenster je Stufe, Sekunden
    static let settle = 2.0
    static let measure = 12.0
    static let deckCount = 4

    private(set) var state: State = .idle
    private(set) var rows: [Row] = []
    private(set) var recommendation: BufferTest.Recommendation?
    /// Puffer, den „EMPFEHLUNG SETZEN“ zuletzt gesetzt hat
    private(set) var appliedFrames: Int?
    /// Stufen dieses Laufs (aus dem Gerätebereich)
    private(set) var planned: [Int] = []

    @ObservationIgnored private weak var mix: MixModel?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var cancelFlag = false

    init(mix: MixModel) { self.mix = mix }

    var isRunning: Bool { if case .running = state { true } else { false } }

    /// Vor der Bestätigung: nil = startbar, sonst der Grund (Zustand wird auf „abgelehnt“ gesetzt)
    func check() -> Bool {
        guard let why = refusal() else { return true }
        refuse(why)
        return false
    }

    /// Grund, warum jetzt nicht gemessen werden kann (nil = startbar)
    func refusal() -> String? {
        guard let mix else { return nil }
        let core = mix.core, engine = mix.engine
        guard engine.running else { return String(localized: "Ausgabe läuft nicht – Gerät prüfen, dann testen.") }
        if mix.previewer.playing { return String(localized: "Vorhören läuft – erst stoppen, dann testen.") }
        if core.snapshot().decks.contains(where: \.playing) {
            return String(localized: "Ein Deck spielt – der Puffer-Test läuft nur bei gestoppten Decks.")
        }
        guard let range = MixEngine.bufferFrameRange(engine.outputDeviceID) else {
            return String(localized: "Puffergrößen des Geräts nicht lesbar.")
        }
        if BufferTest.sizes(range: range).isEmpty {
            return String(localized: "Das Gerät nimmt keine Puffergröße von 64 bis 1024 Frames.")
        }
        if pickTracks(mix).count < Self.deckCount {
            return String(localized: "Zu wenige lokale Tracks in der Collection (4 nötig, mindestens 100 s lang).")
        }
        return nil
    }

    /// Lauf starten (die Bestätigung liegt bei der Oberfläche)
    func start() {
        guard !isRunning, let mix, check() else { return }
        let range = MixEngine.bufferFrameRange(mix.engine.outputDeviceID) ?? 64...1024
        let sizes = BufferTest.sizes(range: range)
        let tracks = Array(pickTracks(mix).prefix(Self.deckCount))
        planned = sizes
        rows = []
        recommendation = nil
        appliedFrames = nil
        cancelFlag = false
        state = .running(frames: sizes[0], step: 1, of: sizes.count)
        task = Task { [weak self] in await self?.run(sizes: sizes, tracks: tracks) }
    }

    func cancel() {
        guard isRunning else { return }
        cancelFlag = true
    }

    /// Empfohlene Größe einstellen (wie ⌘, -> AUDIO -> Puffer, dauerhaft)
    func applyRecommendation() {
        guard let mix, let f = recommendation?.frames, !isRunning else { return }
        mix.setAudioFormat(buffer: f)
        appliedFrames = f
        StatusCenter.post(.ok, String(format: String(localized: "Puffer %lld Frames gesetzt"), f), key: "audio.buffer")
    }

    private func refuse(_ why: String) {
        state = .refused(why)
        StatusCenter.post(.warning, why, key: "buffer.test")
    }

    /// Lokale Tracks mit mindestens 100 s Länge (Lauf ~70 s), mit Grid zuerst (Sync braucht es)
    private func pickTracks(_ mix: MixModel) -> [Track] {
        func local(_ t: Track) -> Bool {
            var st = stat()
            return stat(t.path, &st) == 0 && st.st_size > 0 && st.st_flags & UInt32(SF_DATALESS) == 0
        }
        let all: [Track] = mix.library?.tracks ?? []
        var ok: [Track] = []
        for t in all where t.fileExists && t.duration >= 100 {
            if CloudLibrary.shared.peek(t.path) == .cloud || !local(t) { continue }
            ok.append(t)
        }
        let withGrid: [Track] = ok.filter { $0.gridAnchorMs != nil }
        let noGrid: [Track] = ok.filter { $0.gridAnchorMs == nil }
        return withGrid.shuffled() + noGrid.shuffled()
    }

    // MARK: - Lauf

    /// Einstellungen des Kerns, die der Lauf ändert (am Ende wieder gesetzt)
    private struct Saved {
        var prefs: EnginePrefs
        var master: Double
        var metronome: Bool
        var masterDeck: Int?
        var keylock: [Bool]
        var sync: [Bool]
        var fxAssign: [[Bool]]
        var fx: [FXUnitState]
        var bufferFrames: UInt32?
    }

    private func run(sizes: [Int], tracks: [Track]) async {
        guard let mix else { return }
        let core = mix.core, engine = mix.engine
        let snap = core.snapshot()
        let saved = Saved(prefs: snap.prefs, master: snap.masterVolume, metronome: snap.metronome, masterDeck: snap.masterDeck,
                          keylock: snap.decks.map(\.keylock), sync: snap.decks.map(\.sync), fxAssign: snap.decks.map(\.fxAssign),
                          fx: snap.fx, bufferFrames: engine.bufferFrames)
        MeterSampler.shared.paused = true   // der Lauf holt die Last selbst ab (takeLoad hat nur einen Abholer)
        var failure: String?

        // Stille: Hauptausgang 0 (auch extern), Metronom aus, Verlauf zählt nicht
        var p = saved.prefs
        p.historyThreshold = 1e9
        p.masterVolumeExternal = true
        core.setPrefs(p)
        core.setMasterVolume(0)
        core.setMetronome(false)

        for d in 0..<Self.deckCount { core.load(tracks[d], deck: d) }
        for d in 0..<Self.deckCount where failure == nil && !cancelFlag {
            let ok = await waitLoaded(d)
            if !ok && !cancelFlag {
                failure = core.snapshot().decks[d].error ?? String(localized: "Track laden hat nicht geklappt.")
            }
        }
        if failure == nil && !cancelFlag {
            setupDecks(core)
            await measure(sizes: sizes, mix: mix)
        }
        restore(saved, core: core, engine: engine)
        MeterSampler.shared.paused = false
        finish(failure: failure)
    }

    /// Keylock A/B, Sync C/D auf A, FX 1 (A/C) und FX 2 (B/D) mit Delay + Hall, alle Decks an
    private func setupDecks(_ core: MixController) {
        if core.snapshot().masterDeck != 0 { core.toggleMaster(0) }
        for d in 0..<Self.deckCount {
            core.updateDeck(d) { $0.keylock = d < 2; $0.fxAssign = d % 2 == 0 ? [true, false, false, false] : [false, true, false, false] }
            if d >= 2, !core.snapshot().decks[d].sync { core.toggleSync(d) }
        }
        for u in 0..<2 {
            core.updateFX(u) { fx in
                fx.slots = FXTemplate.group.slots
                fx.slots[1].on = true; fx.slots[1].mix = 0.5
                fx.slots[2].on = true; fx.slots[2].mix = 0.5; fx.dryWet = 0.5
            }
        }
        for d in 0..<Self.deckCount { playIfStopped(core, d) }
    }

    private func playIfStopped(_ core: MixController, _ d: Int) {
        if !core.snapshot().decks[d].playing { core.togglePlay(d) }
    }

    private func measure(sizes: [Int], mix: MixModel) async {
        let core = mix.core, engine = mix.engine
        for (i, frames) in sizes.enumerated() {
            if cancelFlag { break }
            state = .running(frames: frames, step: i + 1, of: sizes.count)
            engine.bufferFrames = UInt32(frames)
            engine.apply(engine.routing, restart: true)
            let rate = engine.outputRate
            let window = Self.settle + Self.measure
            let t0 = Date()
            // Zählerstände sind seit Start kumuliert: Differenz zum Ende des Einschwingens (der Aussetzer-Zähler bleibt unberührt)
            var ov0 = 0, dov0 = 0, wd0 = 0, latency = 0.0
            var baselined = false
            var busy = 0.0, blocks = 0, worst = 0.0, lost = false, lastProgress = -1.0, lastPlay = Date.distantPast
            var ov = 0, dov = 0
            while !cancelFlag, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                let el = Date().timeIntervalSince(t0)
                if el >= window { break }
                if Date().timeIntervalSince(lastPlay) >= 0.5 {
                    lastPlay = Date()
                    for d in 0..<Self.deckCount { playIfStopped(core, d) }
                }
                let l = engine.takeLoad()
                // Einschwingen: Fenster leeren, nichts werten; danach die Ausgangswerte merken
                guard el >= Self.settle else { continue }
                if !baselined {
                    baselined = true
                    ov0 = l.overloads; dov0 = l.deviceOverloads; wd0 = engine.parallelWatchdog.timeouts
                    ov = ov0; dov = dov0
                    continue
                }
                busy += l.average * Double(l.blocks); blocks += l.blocks
                worst = max(worst, l.peak)
                ov = l.overloads; dov = l.deviceOverloads; latency = l.outputLatency
                if engine.watch.phase != .running { lost = true; break }
                let frac = (Double(i) + el / window) / Double(sizes.count)
                if frac - lastProgress >= 0.02 || lastProgress < 0 {
                    lastProgress = frac
                    postProgress(frames: frames, step: i + 1, of: sizes.count, frac: frac)
                }
            }
            let wd = engine.parallelWatchdog.timeouts - wd0
            let completed = !cancelFlag && !lost && blocks > 0
            let probe = BufferTest.Probe(frames: frames, worstPct: worst * 100,
                                         avgPct: blocks > 0 ? busy / Double(blocks) * 100 : 0,
                                         overruns: max(0, ov - ov0) + max(0, dov - dov0), watchdogTimeouts: max(0, wd),
                                         completed: completed)
            rows.append(Row(probe: probe, outputLatencyMs: latency * 1000, deviceRate: rate))
            if lost { break }
        }
    }

    private func postProgress(frames: Int, step: Int, of n: Int, frac: Double) {
        let f = min(1, frac)
        StatusCenter.post(.info, String(format: String(localized: "Puffertest %lld Frames · %lld/%lld"), frames, step, n),
                          key: "buffer.test", progress: f, progressText: "\(Int(f * 100)) %", job: true,
                          cancel: { [weak self] in self?.cancel() })
    }

    private func waitLoaded(_ d: Int) async -> Bool {
        guard let core = mix?.core else { return false }
        for _ in 0..<600 {
            if cancelFlag { return false }
            let s = core.snapshot().decks[d]
            if s.error != nil { return false }
            if core.trackAudio(d) != nil, !s.loading { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    /// Decks stoppen, Kern-Einstellungen und Ausgang zurück (die geladenen Tracks bleiben)
    private func restore(_ s: Saved, core: MixController, engine: MixEngine) {
        for d in 0..<Self.deckCount where core.snapshot().decks[d].playing { core.togglePlay(d) }
        core.setPrefs(s.prefs)
        core.setMasterVolume(s.master)
        core.setMetronome(s.metronome)
        for d in 0..<Self.deckCount {
            core.updateDeck(d) { $0.keylock = s.keylock[d]; $0.fxAssign = s.fxAssign[d] }
            if core.snapshot().decks[d].sync != s.sync[d] { core.toggleSync(d) }
        }
        let cur = core.snapshot().masterDeck
        if cur != s.masterDeck { core.toggleMaster(s.masterDeck ?? cur ?? 0) }
        for u in 0..<s.fx.count { core.updateFX(u) { $0 = s.fx[u] } }
        if engine.bufferFrames != s.bufferFrames {
            engine.bufferFrames = s.bufferFrames
            engine.apply(engine.routing, restart: true)
        }
    }

    private func finish(failure: String?) {
        if let failure {
            state = .refused(failure)
            StatusCenter.post(.error, String(format: String(localized: "Puffertest abgebrochen: %@"), failure), key: "buffer.test")
            return
        }
        if cancelFlag {
            state = .cancelled
            StatusCenter.post(.info, String(localized: "Puffertest abgebrochen"), key: "buffer.test")
            return
        }
        let rec = BufferTest.recommend(rows.map(\.probe))
        recommendation = rec
        state = .done
        let text = rec.frames.map { String(format: String(localized: "Puffertest fertig · Empfehlung %lld Frames"), $0) }
            ?? String(localized: "Puffertest fertig · keine Stufe ohne Aussetzer")
        StatusCenter.post(rec.frames == nil ? .warning : .ok, text, key: "buffer.test")
    }
}

/// ⌘, -> AUDIO -> Puffer-Test: Start mit Bestätigung, Fortschritt, Ergebnisliste, Empfehlung
struct BufferTestSettings: View {
    @Environment(MixModel.self) private var mix
    @State private var confirm = false

    /// Beschreibung (Schlüssel = Index-Hinweis, Englisch in der Strings-Tabelle)
    static let hint = "misst je puffergröße des geräts (64 bis 1024) ~14 s: 4 decks, a/b keylock, c/d sync auf a, fx 1 + 2 mit delay und hall, hauptausgang 0 (stumm), metronom aus. lädt 4 tracks aus der collection (ersetzt geladene), stoppt danach die decks. wellenform nur mit sichtbaren decks im hauptfenster. ein spielendes deck verhindert den test."

    var body: some View {
        let t = mix.bufferTest
        Section("Puffer-Test") {
            LabeledContent("Test") {
                HStack(spacing: 8) {
                    Button("PUFFER TESTEN") { if t.check() { confirm = true } }
                        .disabled(t.isRunning)
                    if t.isRunning {
                        Button("ABBRECHEN") { t.cancel() }
                    }
                }
            }
            .settingsAnchor("audio.buffertest")
            Text(LocalizedStringKey(Self.hint)).settingsHint()
            if case let .running(frames, step, of) = t.state {
                Text(verbatim: String(format: String(localized: "Puffer %lld Frames · Stufe %lld von %lld"), frames, step, of))
                    .font(Theme.mono(11))
            }
            ForEach(t.rows) { r in
                Text(verbatim: Self.rowText(r)).font(Theme.mono(11)).foregroundStyle(r.probe.completed ? Color.primary : Theme.muted)
            }
            if t.state == .cancelled { Text("abgebrochen").settingsHint() }
            if case let .refused(why) = t.state { Text(verbatim: why).settingsHint().foregroundStyle(Theme.state) }
            if t.state == .done, let rec = t.recommendation {
                Text(verbatim: Self.recText(rec, rate: t.rows.first?.deviceRate ?? 48000)).font(Theme.mono(11))
                    .foregroundStyle(rec.frames == nil ? Theme.state : Color.primary)
                Button("EMPFEHLUNG SETZEN") { t.applyRecommendation() }
                    .disabled(rec.frames == nil || t.appliedFrames == rec.frames)
                    .settingsControlColumn()
            }
        }
        .confirmationDialog("PUFFER TESTEN", isPresented: $confirm, titleVisibility: .visible) {
            Button("Testen") { t.start() }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Vier Decks laden Tracks aus der Collection, geladene Tracks werden ersetzt. Der Hauptausgang ist auf 0, nichts ist hörbar. Dauer etwa 1,5 min bei 5 Stufen. Die Decks stehen danach still.")
        }
    }

    /// „256 Frames · 5.3 ms Puffer · Ausgabe 12.1 ms · Spitze 34 % · Mittel 12 % · Aussetzer 0 · Watchdog 0“
    static func rowText(_ r: BufferTestRunner.Row) -> String {
        let p = r.probe
        guard p.completed else { return String(format: String(localized: "%lld Frames · abgebrochen"), p.frames) }
        let buf = BufferTest.bufferMs(frames: p.frames, rate: r.deviceRate)
        return String(format: String(localized: "%lld Frames · %.1f ms Puffer · Ausgabe %.1f ms · Spitze %.0f %% · Mittel %.0f %% · Aussetzer %lld · Watchdog %lld %@"),
                      p.frames, buf, r.outputLatencyMs, p.worstPct, p.avgPct, p.overruns, p.watchdogTimeouts,
                      p.overruns == 0 && p.worstPct < BufferTest.worstLimit ? "✓" : "✕")
    }

    static func recText(_ rec: BufferTest.Recommendation, rate: Double) -> String {
        switch rec.reason {
        case .none: return String(localized: "keine Messung gewertet")
        case .noSafe:
            return String(format: String(localized: "keine Stufe ohne Aussetzer und unter %.0f %% – Gerät und Lasttest prüfen (scripts/loadtest.sh)"), BufferTest.worstLimit)
        case .safe, .margin:
            let f = rec.frames ?? 0
            let base = String(format: String(localized: "Empfehlung %lld Frames · %.1f ms Puffer"), f, BufferTest.bufferMs(frames: f, rate: rate))
            guard rec.reason == .margin else { return base }
            return base + " · " + String(format: String(localized: "mit Reserve: die kleinere Stufe lag über %.0f %%"), BufferTest.marginAbove)
        }
    }
}
