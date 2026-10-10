import AudioToolbox
import Foundation
import MixCore

// MARK: - Zustand (wird als Kopie an die Oberfläche gegeben)

public enum XFAssign: String, CaseIterable, Codable, Sendable { case a = "A", thru = "·", b = "B" }

/// Sync: Beat-Sync zieht auf Phase 0, Fix hält eine von Hand verschobene Phase, Nur Tempo lässt die Phase frei
public enum SyncMode: String, CaseIterable, Codable, Sendable {
    case dynamic = "Dynamisch (zurück auf Phase 0)", fixed = "Fix (verschobene Phase bleibt)", tempo = "Nur Tempo"
}

/// Wohin ein geladener Track springt
public enum LoadPosition: String, CaseIterable, Codable, Sendable {
    case loadCue = "Load-Cue / Grid", start = "Track-Anfang", firstHotcue = "Hotcue 1"
}

public enum CrossfaderCurve: String, CaseIterable, Codable, Sendable {
    case smooth = "Weich", sharp = "Scharf (Cut)"
}

/// Einstellungen, die der Steuerkern braucht (alle in ⌘, änderbar)
public struct EnginePrefs: Codable, Equatable, Sendable {
    /// Quant: Sprünge (Hotcue, Loop, Beatjump) halten die Beat-Phase
    public var quantize = true
    /// Snap: gesetzte Cues und Loop-Punkte rasten auf den nächsten Beat
    public var snap = true
    /// Metronom auf welches Kanalpaar (0-basiert)
    public var metronomeChannel = 0
    public var keylockDefault = true
    public var tempoRangeDefault = 8.0
    public var autoGain = true
    /// Headroom und Auto-Gain je Mixer-Modus, Main-Volume im externen Modus optional
    public var headroomInternal = 0.0
    public var headroomExternal = -3.0
    public var autoGainExternal = false
    public var masterVolumeExternal = false
    public var loadPosition = LoadPosition.loadCue
    public var hotcueKeepsPhase = true
    public var bendAmount = 0.04
    public var phaseLock = true
    public var syncMode = SyncMode.dynamic
    /// Link: Versatz in ms (positiv = die anderen Teilnehmer spielen später)
    public var linkOffsetMs = 0.0
    public var trackEndWarning = 30.0
    public var crossfaderCurve = CrossfaderCurve.smooth
    public var eqKill = true
    public var channelFilterResonance = 0.6
    public var defaultLoopSize = 4.0
    public var defaultJumpSize = 4.0
    /// Loop-Snap (nur mit Snap): gespeicherten Loop-Cue übernehmen, wenn er bis zu loopSnapCueBeats vor oder hinter
    /// der Position beginnt; sonst auf eine 4-Takt-Grenze innerhalb von loopSnapPhraseBeats
    public var loopSnapCues = true
    public var loopSnapPhrase = true
    public var loopSnapCueBeats = 4.0
    public var loopSnapPhraseBeats = 1.0
    public var delayFeedback = 0.45
    public var fxFilterResonance = 0.4
    /// Reverb: Pegel in dB (0 = Hall bei vollem D/W ≈ 4 dB unter dem Track), Helligkeit 0…1, Vorverzögerung in ms
    public var reverbLevelDb = 0.0
    public var reverbBrightness = 0.6
    public var reverbPreDelayMs = 15.0
    /// Track gilt als gespielt (History), wenn er so viele Sekunden hörbar lief
    public var historyThreshold = 30.0
    /// Grid-Anker beim Laden auf Takt-/Phrasenanfang prüfen (aus / vorschlagen / automatisch verschieben)
    public var phraseAnchor = PhraseAnchorMode.suggest
    public init() {}
}

public struct DeckState: Equatable, Sendable {
    public var track: Track?
    public var duration: Double = 0
    public var loading = false
    public var error: String?
    public var grid: BeatGrid?
    /// Phrasen-Anker-Vorschlag: Ankerzeit (s), auf der die Strukturwechsel auf 8-Takt-Grenzen fallen, und Sicherheit
    public var phraseTarget: Double?
    public var phraseConfidence = 0.0

    public var playing = false
    public var cuePoint: Double = 0
    public var cueHeld = false
    public var hotcues: [Int: Cue] = [:]
    public var reverse = false
    public var flux = false

    public var tempoPct: Double = 0
    public var tempoRange: Double = 8
    public var nudge: Double = 0
    public var bend: Double = 0
    public var keylock = true
    public var keyShift = 0
    public var sync = false

    public var loopSize: Double = 4
    public var jumpSize: Double = 4
    public var loopIn: Double?
    public var loopActive = false

    public var gainDb: Double = 0
    public var eqLow: Double = 0
    public var eqMid: Double = 0
    public var eqHigh: Double = 0
    public var filter: Double = 0
    public var fader: Double = 1
    public var xf: XFAssign = .a
    public var fxAssign: [Bool] = [false, false, false, false]

    public init() {}

    public var rate: Double { (1 + tempoPct / 100) * (1 + nudge + bend) }
    public var bpm: Double { (grid?.bpm ?? track?.bpm ?? 0) * (1 + tempoPct / 100) }
}

/// FX-Unit: Gruppenmodus (3 Slots Filter · Delay · Reverb, Regler = Stärke)
/// oder Single-Modus (ein Effekt, die 3 Regler = seine Parameter).
public struct FXUnitState: Equatable, Sendable, Codable {
    public struct Slot: Equatable, Sendable, Codable {
        public var on = false
        public var amount: Double
    }
    public enum Effect: Int, CaseIterable, Sendable {
        case filter = 0, delay, reverb, plugin
        public var name: String { ["FILTER", "DELAY", "REVERB", "PLUGIN"][rawValue] }
        /// Beschriftung der 3 Regler im Single-Modus
        public var params: [String] {
            switch self {
            case .filter: ["CUTOFF", "RES", "—"]
            case .delay: ["FILTER", "FEEDB", "RATE"]
            case .reverb: ["SIZE", "HP", "LP"]
            case .plugin: ["P1", "P2", "P3"]   // echte Namen: MixState.pluginParams
            }
        }
    }
    public static let slotNames = ["FILTER", "DELAY", "REVERB"]
    public var dryWet: Double = 1
    public var slots = [Slot(amount: 0.5), Slot(amount: 0.5), Slot(amount: 0.5)]
    /// Delay-Zeit (Index in MixEngine.delayBeats), Hallgröße 0–1
    public var delayIndex = 3
    public var reverbSize = 0.6
    public var single = false
    public var singleType = Effect.delay.rawValue
    public var singleOn = false
    public var params = [0.5, 0.45, 0.6]
    /// Effekt-Plugin (PluginInfo.id, z. B. "aufx:mrev:appl") und sein Zustand (ClassInfo, Binär-Plist)
    public var pluginID: String?
    public var pluginState: Data?
    public var anyOn: Bool { single ? singleOn : slots.contains { $0.on } }
    public init() {}

    // tolerant laden: neue Felder fehlen in alten Sitzungen
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dryWet = try c.decodeIfPresent(Double.self, forKey: .dryWet) ?? 1
        slots = try c.decodeIfPresent([Slot].self, forKey: .slots) ?? slots
        delayIndex = try c.decodeIfPresent(Int.self, forKey: .delayIndex) ?? 3
        reverbSize = try c.decodeIfPresent(Double.self, forKey: .reverbSize) ?? 0.6
        single = try c.decodeIfPresent(Bool.self, forKey: .single) ?? false
        singleType = try c.decodeIfPresent(Int.self, forKey: .singleType) ?? Effect.delay.rawValue
        singleOn = try c.decodeIfPresent(Bool.self, forKey: .singleOn) ?? false
        params = try c.decodeIfPresent([Double].self, forKey: .params) ?? params
        if params.count != 3 { params = [0.5, 0.45, 0.6] }
        pluginID = try c.decodeIfPresent(String.self, forKey: .pluginID)
        pluginState = try c.decodeIfPresent(Data.self, forKey: .pluginState)
    }
}

public struct MixState: Equatable, Sendable {
    public var decks = (0..<MixEngine.deckCount).map { i -> DeckState in
        var d = DeckState()
        d.xf = i % 2 == 0 ? .a : .b
        // FX 1 auf A/C, FX 2 auf B/D – sonst wirken eingeschaltete Effekte auf kein Deck
        d.fxAssign = i % 2 == 0 ? [true, false, false, false] : [false, true, false, false]
        return d
    }
    public var fx = [FXUnitState(), FXUnitState(), FXUnitState(), FXUnitState()]
    public var masterDeck: Int?
    /// automatisch gewählter Master: bleibt, solange er spielt (ein neu gestartetes Deck übernimmt ihn nicht)
    public var autoMaster: Int?
    /// Master-Clock: im Clock-Modus gibt MINOS das Tempo vor (kein Deck ist Master)
    public var clockMaster = false
    /// Semi-Sync: jeder neu geladene Track übernimmt das Tempo des aktuellen Masters (kein Phasen-Sync);
    /// ein ungesynctes Deck startet in Phase zum Master (einmaliger Sprung, danach frei)
    public var semiSync = false
    public var clockBPM: Double = 128
    public var metronome = false
    public var metronomeVolume: Double = 0.5
    public var linkEnabled = false
    /// verbundene Link-Teilnehmer
    public var linkPeers = 0
    public var crossfader: Double = 0
    public var masterVolume: Double = 0.85
    public var externalMixer = false
    public var prefs = EnginePrefs()
    /// je FX-Unit: Namen der ersten 3 Plugin-Parameter (Regler) und letzter Ladefehler
    public var pluginParams = [[String]](repeating: [], count: MixEngine.fxUnitCount)
    public var pluginErrors = [String?](repeating: nil, count: MixEngine.fxUnitCount)

    public init() {}

    /// Tempo, dem gesyncte Decks folgen (Clock oder Master-Deck)
    public var masterTempo: Double {
        if clockMaster { return clockBPM }
        return effectiveMaster.map { decks[$0].bpm } ?? clockBPM
    }

    public var effectiveMaster: Int? {
        if clockMaster { return nil }
        if let m = masterDeck, decks[m].grid != nil { return m }
        if let a = autoMaster, decks[a].playing, decks[a].grid != nil { return a }
        return decks.indices.first { decks[$0].playing && !decks[$0].sync && decks[$0].grid != nil }
            ?? decks.indices.first { decks[$0].playing && decks[$0].grid != nil }
    }
}

// MARK: - Steuerkern

/// Deck- und Mixlogik, unabhängig von der Oberfläche.
/// Läuft auf einer eigenen Steuer-Queue (hohe Priorität, 200 Hz): Sync-Nachführung, Controller, LEDs.
/// Oberfläche und Controller rufen nur Befehle auf; Zustand ist mit einer Sperre geschützt.
/// Der Audio-Thread nimmt die Sperre nie – er liest nur `DeckPlayer`.
public final class MixController: @unchecked Sendable {
    /// Rate aus den Audio-Einstellungen (0 = Gerät) – der Kern rechnet ab dem Start damit
    public let engine = MixEngine(rate: { let r = UserDefaults.standard.double(forKey: "sampleRate"); return r > 0 ? r : nil }())
    public let controlQueue = DispatchQueue(label: "minos741.control", qos: .userInteractive)

    private let lock = NSRecursiveLock()
    private var state = MixState()
    private var audio: [TrackAudio?] = Array(repeating: nil, count: MixEngine.deckCount)
    /// zählt Ladevorgänge je Deck: nur der zuletzt gestartete darf das Deck belegen
    /// (zwei Ladevorgänge kurz hintereinander enden sonst in beliebiger Reihenfolge)
    private var loadSeq = [Int](repeating: 0, count: MixEngine.deckCount)
    private var fluxReverseRestore: [Int: Bool] = [:]
    private var timer: DispatchSourceTimer?
    private var tickCount = 0
    private var bigError = [Int](repeating: 0, count: MixEngine.deckCount)
    /// Fix-Sync: von Hand eingestellter Phasenversatz je Deck (Beats)
    private var phaseOffset = [Double](repeating: 0, count: MixEngine.deckCount)
    // History: hörbare Spielzeit je Deck seit dem Laden
    private var playedTime = [Double](repeating: 0, count: MixEngine.deckCount)
    private var playedLogged = [Bool](repeating: false, count: MixEngine.deckCount)
    private var playStart = [Date?](repeating: nil, count: MixEngine.deckCount)
    /// Wird (auf der Steuer-Queue) gerufen, sobald ein Track als gespielt gilt: Deck, Track, Startzeit
    public var onPlayed: ((Int, Track, Date) -> Void)?

    /// zusätzliche Aufgaben im Steuertakt (z. B. Controller-LEDs)
    private var tickHandlers: [(MixController) -> Void] = []

    public init() {
        observeInvalidation()
        timer = DispatchSource.makeTimerSource(flags: .strict, queue: controlQueue)
        timer?.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .milliseconds(1))
        timer?.setEventHandler { [weak self] in self?.tick() }
        timer?.resume()
    }

    // MARK: Zugriff

    public func snapshot() -> MixState { locked { state } }
    public func trackAudio(_ d: Int) -> TrackAudio? { locked { audio[d] } }
    public func position(_ d: Int) -> Double { engine.position(d) }
    /// hörbare Spielzeit seit dem Laden (für die History-Dauer)
    public func playedSeconds(_ d: Int) -> Double { locked { playedTime[d] } }

    /// Aufgabe, die bei jedem 6. Takt (~33 Hz) auf der Steuer-Queue läuft
    public func addTickHandler(_ h: @escaping (MixController) -> Void) { locked { tickHandlers.append(h) } }

    @discardableResult
    private func locked<T>(_ f: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return f()
    }

    public func setPrefs(_ p: EnginePrefs) {
        locked {
            state.prefs = p
            engine.setMetronome(on: state.metronome, volume: state.metronomeVolume, firstChannel: p.metronomeChannel)
            applyAllMixer()
            applyAllFX()
            applyMaster()
        }
    }

    public func setExternalMixer(_ on: Bool) { locked { state.externalMixer = on; applyAllMixer(); applyMaster() } }

    // MARK: Positionen / Phase

    /// tatsächlicher Phasenabstand zum Master (Anzeige)
    public func phaseError(_ d: Int) -> Double? { locked { rawPhaseError(d) } }

    /// Beat-Position, an der sich gesyncte Decks ausrichten (Clock oder Master-Deck)
    private func masterBeat() -> Double? {
        if state.clockMaster { return engine.clockBeat }
        guard let m = state.effectiveMaster, let mg = state.decks[m].grid else { return nil }
        return mg.beatPosition(at: position(m))
    }

    /// Phasenfehler gegenüber dem Ziel (Master-Phase plus gehaltener Versatz im Fix-Sync)
    private func phaseErrorLocked(_ d: Int) -> Double? {
        guard let e = rawPhaseError(d) else { return nil }
        var r = e - phaseOffset[d]
        r -= r.rounded()
        return r
    }

    // MARK: Laden

    public func load(_ t: Track, deck d: Int) {
        let rate = engine.sampleRate
        let seq: Int = locked {
            loadSeq[d] += 1
            state.decks[d].loading = true
            state.decks[d].error = nil
            state.decks[d].playing = false
            engine.player(d).playing = false
            return loadSeq[d]
        }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            do {
                let t0 = Date()
                let a = try TrackAudio.decode(url: URL(fileURLWithPath: t.path), sampleRate: rate)
                if Self.debug {
                    print(String(format: "[load] deck %d: %.2f s, %.0f MB", d, Date().timeIntervalSince(t0), Double(a.frames) * 8 / 1e6))
                }
                finishLoad(t, a, d, seq: seq)
            } catch {
                locked {
                    guard seq == loadSeq[d] else { return }   // inzwischen ein anderer Track gewählt
                    state.decks[d].loading = false
                    state.decks[d].error = "Laden fehlgeschlagen: \(error.localizedDescription)"
                }
            }
        }
    }

    /// MIX741_DEBUG=1: Lade-, Hänger- und Controller-Protokoll
    public static let debug = ProcessInfo.processInfo.environment["MIX741_DEBUG"] == "1"

    private func finishLoad(_ t: Track, _ a: TrackAudio, _ d: Int, seq: Int) {
        let r: (TrackAudio?, UInt32)? = locked {
            guard seq == loadSeq[d] else { return nil }   // überholt: ein später gewählter Track lädt noch oder liegt schon
            let old = audio[d]
            var s = state.decks[d]
            let p = state.prefs
            s.track = t
            s.grid = BeatGrid(track: t)
            s.phraseTarget = nil
            s.duration = a.duration
            s.hotcues = Dictionary(t.hotcues.map { ($0.hotcue, $0) }, uniquingKeysWith: { x, _ in x })
            let loadCue = (t.cues.first { $0.kind == .load }?.startMs ?? t.gridAnchorMs ?? 0) / 1000
            s.cuePoint = switch p.loadPosition {
                case .loadCue: loadCue
                case .start: 0
                case .firstHotcue: (s.hotcues[0]?.startMs ?? loadCue * 1000) / 1000
            }
            s.loopActive = false
            s.loopIn = nil
            s.reverse = false
            s.keyShift = 0
            s.loading = false
            s.playing = false
            if old == nil {   // erster Track im Deck: Standardwerte aus den Einstellungen
                s.keylock = p.keylockDefault
                s.tempoRange = p.tempoRangeDefault
                s.loopSize = p.defaultLoopSize
                s.jumpSize = p.defaultJumpSize
            }
            if state.semiSync, t.bpm > 0, state.clockMaster || state.effectiveMaster != nil {
                // Semi-Sync: Tempo des aktuellen Masters übernehmen (ohne Phasen-Sync); halbes/doppeltes Tempo wählt
                // das nächste Verhältnis; der Tempo-Bereich wächst bei Bedarf auf die nächste Stufe
                var ratio = state.masterTempo / t.bpm
                while ratio > 1.5 { ratio /= 2 }
                while ratio < 0.75 { ratio *= 2 }
                let pct = (ratio - 1) * 100
                if abs(pct) > s.tempoRange, let r = [6.0, 8, 10, 16, 50, 100].first(where: { $0 >= abs(pct) }) { s.tempoRange = r }
                s.tempoPct = max(-s.tempoRange, min(s.tempoRange, pct))
            }
            state.decks[d] = s
            audio[d] = a
            playedTime[d] = 0
            playedLogged[d] = false
            playStart[d] = nil
            let gen = engine.attach(a, deck: d, startAt: s.cuePoint)
            applyRate(d)
            applyMixer(d)
            applyAllFX()
            return (old, gen)
        }
        guard let (old, gen) = r else { return }   // `a` wird hier freigegeben, der Kern hat es nie gesehen
        releaseWhenFree(old, deck: d, gen: gen)
        analyzePhrase(d, a)
    }

    /// Phrasen-Anker im Hintergrund prüfen; gilt nur, solange derselbe Track mit demselben Grid im Deck liegt
    private func analyzePhrase(_ d: Int, _ a: TrackAudio) {
        guard let (mode, grid) = locked({ () -> (PhraseAnchorMode, BeatGrid)? in
            guard state.prefs.phraseAnchor != .off, let g = state.decks[d].grid, g.bpm > 0 else { return nil }
            return (state.prefs.phraseAnchor, g)
        }) else { return }
        DispatchQueue.global(qos: .utility).async { [self] in
            let r = PhraseAnchor.analyze(a, grid: grid)
            guard r.suggests else { return }
            let applied: Bool = locked {
                guard audio[d] === a, state.decks[d].grid == grid else { return false }
                if mode == .auto {
                    state.decks[d].grid?.anchor += Double(r.shiftBeats) * grid.beat
                } else {
                    state.decks[d].phraseTarget = grid.anchor + Double(r.shiftBeats) * grid.beat
                    state.decks[d].phraseConfidence = r.confidence
                }
                return true
            }
            if applied, ProcessInfo.processInfo.environment["MIX741_DEBUG"] == "1" {
                print(String(format: "[phrase] deck %d: %@ %+d beats (conf %.2f)", d, mode == .auto ? "anchor" : "suggest",
                             r.shiftBeats, r.confidence))
                fflush(stdout)
            }
        }
    }

    /// alten Puffer halten, bis der Audio-Thread den neuen übernommen hat – ohne Zeitlimit
    /// (steht die Ausgabe, liest ihn niemand; hängt sie, bleibt lieber ein Puffer liegen als dass sie in freien Speicher greift)
    private func releaseWhenFree(_ old: TrackAudio?, deck d: Int, gen: UInt32) {
        guard let old else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { [self] in
            if engine.trackConsumed(d, gen) || !engine.running { _ = old; return }
            releaseWhenFree(old, deck: d, gen: gen)
        }
    }

    // MARK: Transport

    public func togglePlay(_ d: Int) {
        locked {
            guard audio[d] != nil else { return }
            let p = engine.player(d)
            if p.playing { p.playing = false } else {
                if state.decks[d].sync { alignPhase(d, hard: true) } else { semiAlignStart(d) }
                p.playing = true
            }
            state.decks[d].cueHeld = false
            state.decks[d].playing = p.playing
            applyRate(d)
        }
    }

    public func cueDown(_ d: Int) {
        locked {
            guard audio[d] != nil else { return }
            let p = engine.player(d)
            if p.playing {
                p.playing = false
                engine.seek(d, seconds: state.decks[d].cuePoint)
            } else if abs(position(d) - state.decks[d].cuePoint) < 0.02 {
                semiAlignStart(d)   // Cue-Vorhören startet ebenfalls in Phase; CUE loslassen springt zurück zum Cue
                p.playing = true
                state.decks[d].cueHeld = true
            } else {
                state.decks[d].cuePoint = snapped(d, position(d))
                engine.seek(d, seconds: state.decks[d].cuePoint)
            }
            state.decks[d].playing = p.playing
            applyRate(d)
        }
    }

    public func cueUp(_ d: Int) {
        locked {
            guard state.decks[d].cueHeld else { return }
            engine.player(d).playing = false
            engine.seek(d, seconds: state.decks[d].cuePoint)
            state.decks[d].cueHeld = false
            state.decks[d].playing = false
            applyRate(d)
        }
    }

    public func cup(_ d: Int) {
        locked {
            guard audio[d] != nil else { return }
            engine.seek(d, seconds: state.decks[d].cuePoint)
            semiAlignStart(d)   // vom Cue aus in Phase zum Master starten
            engine.player(d).playing = true
            state.decks[d].playing = true
            applyRate(d)
        }
    }

    public func seek(_ d: Int, fraction: Double) {
        locked { seek(d, seconds: max(0, min(1, fraction)) * state.decks[d].duration) }
    }

    /// Von Hand verschoben (Wellenform ziehen, Touchstrip): im Fix-Sync bleibt die neue Phase
    public func seek(_ d: Int, seconds: Double) {
        locked {
            engine.seek(d, seconds: seconds)
            if state.prefs.syncMode == .fixed, state.decks[d].sync, let g = state.decks[d].grid, let mb = masterBeat() {
                phaseOffset[d] = BeatGrid.phaseError(own: g.beatPosition(at: seconds), master: mb)
                bigError[d] = 0
            }
        }
    }

    public func setReverse(_ d: Int, _ on: Bool) {
        locked {
            state.decks[d].reverse = on
            engine.player(d).reverse = on
            if !on, state.decks[d].flux { engine.seek(d, seconds: engine.fluxPosition(d)) }
        }
    }

    public func toggleReverse(_ d: Int) { locked { setReverse(d, !state.decks[d].reverse) } }

    public func toggleFlux(_ d: Int) {
        locked {
            state.decks[d].flux.toggle()
            engine.player(d).flux = state.decks[d].flux
        }
    }

    /// Flux Reverse: gehalten rückwärts, beim Loslassen an der Stelle weiter, an der der Track ohne Reverse wäre.
    public func fluxReverse(_ d: Int, on: Bool) {
        locked {
            guard audio[d] != nil else { return }
            let p = engine.player(d)
            if on {
                fluxReverseRestore[d] = state.decks[d].flux
                state.decks[d].flux = true; p.flux = true
                state.decks[d].reverse = true; p.reverse = true
            } else {
                state.decks[d].reverse = false; p.reverse = false
                engine.seek(d, seconds: engine.fluxPosition(d))
                let r = fluxReverseRestore[d] ?? false
                state.decks[d].flux = r; p.flux = r
                fluxReverseRestore[d] = nil
            }
        }
    }

    // MARK: Hotcues

    public func hotcue(_ d: Int, _ n: Int, delete: Bool = false) {
        locked {
            guard audio[d] != nil else { return }
            if delete { state.decks[d].hotcues[n] = nil; return }
            if let c = state.decks[d].hotcues[n] {
                var target = c.startMs / 1000
                if state.prefs.quantize, state.prefs.hotcueKeepsPhase, state.decks[d].playing, let g = state.decks[d].grid {
                    target += position(d) - g.beatFloor(position(d))
                }
                engine.seek(d, seconds: target)
                if c.kind == .loop, c.lengthMs > 0 {
                    engine.setLoop(d, active: true, start: c.startMs / 1000, end: (c.startMs + c.lengthMs) / 1000)
                    state.decks[d].loopActive = true
                }
            } else if state.decks[d].loopActive {
                let l = engine.loop(d)
                state.decks[d].hotcues[n] = Cue(name: "Loop", kind: .loop, startMs: l.start * 1000,
                                                lengthMs: (l.end - l.start) * 1000, hotcue: n)
            } else {
                state.decks[d].hotcues[n] = Cue(name: "Cue", kind: .cue, startMs: snapped(d, position(d)) * 1000,
                                                lengthMs: 0, hotcue: n)
            }
        }
    }

    // MARK: Loops / Beatjump

    private func beatLength(_ d: Int) -> Double { state.decks[d].grid?.beat ?? 0.5 }

    /// Snap: Cue-/Loop-Punkte auf den nächsten Beat
    private func snapped(_ d: Int, _ t: Double) -> Double {
        guard state.prefs.snap, let g = state.decks[d].grid else { return t }
        return g.nearestBeat(to: t)
    }

    /// Beats je Snap-Phrase: 4 Takte, gezählt ab dem Grid-Anker
    private static let snapPhraseBeats = 16.0

    /// Loop-Snap: gespeicherter Loop-Cue (Hotcue oder Memory-Cue), der kurz vor der Position beginnt
    /// oder gerade überspielt wird (Position noch im Loop). Der nächstgelegene gewinnt.
    private func nearbyLoopCue(_ d: Int) -> (start: Double, end: Double)? {
        let p = state.prefs
        guard p.snap, p.loopSnapCues, !state.decks[d].reverse, let g = state.decks[d].grid else { return nil }
        let pos = position(d), w = p.loopSnapCueBeats * g.beat
        let memory = state.decks[d].track?.cues.filter { $0.hotcue < 0 } ?? []
        return (Array(state.decks[d].hotcues.values) + memory)
            .filter { $0.kind == .loop && $0.lengthMs > 0 }
            .map { (start: $0.startMs / 1000, end: ($0.startMs + $0.lengthMs) / 1000) }
            .filter { $0.start <= pos + w && $0.start >= pos - w && pos < $0.end }
            .min { abs($0.start - pos) < abs($1.start - pos) }
    }

    /// Loop-Snap: 4-Takt-Grenze (ab dem Grid-Anker) innerhalb der Toleranz um die Position
    private func nearbyPhraseStart(_ d: Int) -> Double? {
        let p = state.prefs
        guard p.snap, p.loopSnapPhrase, !state.decks[d].reverse, let g = state.decks[d].grid else { return nil }
        let b = g.beatPosition(at: position(d))
        let n = (b / Self.snapPhraseBeats).rounded() * Self.snapPhraseBeats
        guard abs(b - n) <= p.loopSnapPhraseBeats + 1e-9 else { return nil }
        return g.time(ofBeat: n)
    }

    /// Loop-Cue als Loop übernehmen, ohne Sprung (die Position läuft hinein bzw. ist schon drin)
    private func activateLoopCue(_ d: Int, _ c: (start: Double, end: Double)) {
        engine.setLoop(d, active: true, start: c.start, end: c.end)
        state.decks[d].loopActive = true
        let beats = (c.end - c.start) / beatLength(d)
        if let s = BeatSizes.loop.first(where: { abs($0 - beats) < 0.01 }) { state.decks[d].loopSize = s }
    }

    public func autoLoop(_ d: Int, size: Double? = nil) {
        locked {
            guard audio[d] != nil else { return }
            let s = size ?? state.decks[d].loopSize
            if state.decks[d].loopActive, size == nil || s == state.decks[d].loopSize { exitLoop(d); return }
            if !state.decks[d].loopActive, let c = nearbyLoopCue(d) { activateLoopCue(d, c); return }
            state.decks[d].loopSize = s
            let pos = position(d)
            // 4-Takt-Grenze: Loop beginnt dort, die Position läuft hinein oder ist schon drin (sonst normaler Snap)
            if !state.decks[d].loopActive, let start = nearbyPhraseStart(d), pos < start + s * beatLength(d) {
                engine.setLoop(d, active: true, start: start, end: start + s * beatLength(d))
                state.decks[d].loopActive = true
                return
            }
            var start = state.decks[d].loopActive ? engine.loop(d).start : pos
            if !state.decks[d].loopActive, state.prefs.quantize, let g = state.decks[d].grid {
                let unit = min(1, s)
                start = g.time(ofBeat: (g.beatPosition(at: pos) / unit).rounded(.down) * unit)
            }
            engine.setLoop(d, active: true, start: start, end: start + s * beatLength(d))
            state.decks[d].loopActive = true
        }
    }

    public func exitLoop(_ d: Int) {
        locked {
            let l = engine.loop(d)
            engine.setLoop(d, active: false, start: l.start, end: l.end)
            state.decks[d].loopActive = false
            if state.decks[d].flux { engine.seek(d, seconds: engine.fluxPosition(d)) }
        }
    }

    public func reloop(_ d: Int) {
        locked {
            let l = engine.loop(d)
            guard l.end > l.start else { return }
            if state.decks[d].loopActive { exitLoop(d); return }
            engine.setLoop(d, active: true, start: l.start, end: l.end)
            if position(d) > l.end || position(d) < l.start { engine.seek(d, seconds: l.start) }
            state.decks[d].loopActive = true
        }
    }

    public func changeLoopSize(_ d: Int, by step: Int) {
        locked {
            let sizes = BeatSizes.loop
            let i = sizes.firstIndex(of: state.decks[d].loopSize) ?? 7
            state.decks[d].loopSize = sizes[max(0, min(sizes.count - 1, i + step))]
            if state.decks[d].loopActive {
                let l = engine.loop(d)
                engine.setLoop(d, active: true, start: l.start, end: l.start + state.decks[d].loopSize * beatLength(d))
            }
        }
    }

    public func setLoopSize(_ d: Int, _ s: Double) { locked { state.decks[d].loopSize = s } }

    public func setLoopIn(_ d: Int) {
        locked {
            if !state.decks[d].loopActive, let c = nearbyLoopCue(d) {
                state.decks[d].loopIn = c.start
                activateLoopCue(d, c)
                return
            }
            state.decks[d].loopIn = nearbyPhraseStart(d) ?? snapped(d, position(d))
        }
    }

    public func setLoopOut(_ d: Int) {
        locked {
            guard let a = state.decks[d].loopIn else { return }
            let b = snapped(d, position(d))
            guard b > a + 0.01 else { return }
            engine.setLoop(d, active: true, start: a, end: b)
            engine.seek(d, seconds: a)
            state.decks[d].loopActive = true
        }
    }

    public func beatjump(_ d: Int, beats: Double) {
        locked {
            guard audio[d] != nil else { return }
            let delta = beats * beatLength(d)
            if state.decks[d].loopActive {
                let l = engine.loop(d)
                engine.setLoop(d, active: true, start: l.start + delta, end: l.end + delta)
            }
            engine.seek(d, seconds: max(0, position(d) + delta))
        }
    }

    /// genau einen Takt springen; im Loop bleibt der Loop stehen und die Position läuft darin um
    /// (so landen beide Tracks auf derselben Takt-Eins im 4/4)
    public func barJump(_ d: Int, bars: Int) {
        locked {
            guard audio[d] != nil else { return }
            var t = position(d) + Double(bars * 4) * beatLength(d)
            if state.decks[d].loopActive {
                let l = engine.loop(d)
                let len = l.end - l.start
                if len > 0 { t = l.start + (t - l.start).truncatingRemainder(dividingBy: len); if t < l.start { t += len } }
            }
            engine.seek(d, seconds: max(0, t))
        }
    }

    public func changeJumpSize(_ d: Int, by step: Int) {
        locked {
            let sizes = BeatSizes.jump
            let i = sizes.firstIndex(of: state.decks[d].jumpSize) ?? 4
            state.decks[d].jumpSize = sizes[max(0, min(sizes.count - 1, i + step))]
        }
    }

    public func setJumpSize(_ d: Int, _ s: Double) { locked { state.decks[d].jumpSize = s } }

    // MARK: Tempo / Sync

    public func setTempo(_ d: Int, _ pct: Double) { locked { state.decks[d].tempoPct = pct; applyRate(d) } }
    public func setTempoRange(_ d: Int, _ r: Double) { locked { state.decks[d].tempoRange = r } }

    public func toggleSync(_ d: Int) {
        locked {
            state.decks[d].sync.toggle()
            if state.decks[d].sync { alignPhase(d, hard: state.decks[d].playing) }
            else { state.decks[d].nudge = 0; applyRate(d) }
        }
    }

    public func toggleMaster(_ d: Int) {
        locked {
            state.masterDeck = state.masterDeck == d ? nil : d
            state.decks[d].nudge = 0
            applyRate(d)
        }
    }

    public func toggleKeylock(_ d: Int) { locked { state.decks[d].keylock.toggle(); applyRate(d) } }

    public func shiftKey(_ d: Int, _ step: Int) {
        locked {
            state.decks[d].keyShift = step == 0 ? 0 : max(-12, min(12, state.decks[d].keyShift + step))
            applyRate(d)
        }
    }

    /// Pitch-Bend: −1…1 × eingestellte Stärke
    public func bend(_ d: Int, _ v: Double) {
        locked {
            let was = state.decks[d].bend
            state.decks[d].bend = v * state.prefs.bendAmount
            // Bend losgelassen: im Fix-Sync die erreichte Phase halten, sonst zurück auf 0
            if v == 0, was != 0 {
                phaseOffset[d] = state.prefs.syncMode == .fixed ? (rawPhaseError(d) ?? 0) : 0
                bigError[d] = 0
            }
            applyRate(d)
        }
    }

    /// Phasenfehler ohne gehaltenen Versatz
    private func rawPhaseError(_ d: Int) -> Double? {
        if !state.clockMaster, state.effectiveMaster == d { return nil }
        guard let g = state.decks[d].grid, let mb = masterBeat() else { return nil }
        return BeatGrid.phaseError(own: g.beatPosition(at: position(d)), master: mb)
    }

    private func alignPhase(_ d: Int, hard: Bool) {
        guard let g = state.decks[d].grid, g.bpm > 0 else { return }
        if !state.clockMaster { guard let m = state.effectiveMaster, m != d else { return } }
        state.decks[d].tempoPct = (state.masterTempo / g.bpm - 1) * 100
        state.decks[d].nudge = 0
        phaseOffset[d] = 0
        applyRate(d)
        if hard, let e = phaseErrorLocked(d) {
            engine.seek(d, seconds: position(d) - e * g.beat)
        }
    }

    /// Semi-Sync-Start: ein ungesynctes Deck springt beim Start einmalig auf den nächsten Beat des laufenden Masters
    /// (Fehler −0,5…0,5 Beats) und läuft dann frei – Tempo, Nudge und Sync-Zustand bleiben unverändert.
    /// Nichts passiert ohne laufenden Master oder wenn das Deck selbst Master ist.
    private func semiAlignStart(_ d: Int) {
        guard state.semiSync, !state.decks[d].sync, let g = state.decks[d].grid, g.bpm > 0 else { return }
        if !state.clockMaster { guard let m = state.effectiveMaster, m != d, state.decks[m].playing else { return } }
        guard let e = rawPhaseError(d) else { return }
        let t = position(d) - e * g.beat
        engine.seek(d, seconds: t < 0 ? t + g.beat : t)   // vor dem Trackanfang: einen Beat später
    }

    // MARK: Beatgrid bearbeiten

    /// Grid verschieben (ms, + = später)
    public func shiftGrid(_ d: Int, ms: Double) {
        locked {
            guard var g = state.decks[d].grid else { return }
            g.anchor += ms / 1000
            state.decks[d].grid = g
        }
    }

    /// BPM des Grids ändern (Anker bleibt)
    public func setGridBPM(_ d: Int, _ bpm: Double) {
        locked {
            guard var g = state.decks[d].grid, bpm > 20, bpm < 400 else { return }
            g.bpm = bpm
            state.decks[d].grid = g
            applyRate(d)
        }
    }

    public func scaleGridBPM(_ d: Int, _ f: Double) { locked { if let g = state.decks[d].grid { setGridBPM(d, g.bpm * f) } } }

    /// Grid-Marker an die aktuelle Position (Beat 1 hier)
    public func setGridAnchorHere(_ d: Int) {
        locked {
            let pos = position(d)
            if var g = state.decks[d].grid {
                g.anchor = pos
                state.decks[d].grid = g
            } else if let t = state.decks[d].track, t.bpm > 0 {
                state.decks[d].grid = BeatGrid(anchor: pos, bpm: t.bpm)
            }
        }
    }

    /// Anker um ganze Beats verschieben (+ = später): Raster und BPM bleiben, nur die Takt-/Phrasenzählung wandert
    public func shiftGridBeats(_ d: Int, _ n: Int) {
        locked {
            guard var g = state.decks[d].grid, g.bpm > 0 else { return }
            g.anchor += Double(n) * g.beat
            state.decks[d].grid = g
        }
    }

    /// Phrasen-Anker-Vorschlag übernehmen
    public func applyPhraseAnchor(_ d: Int) {
        locked {
            guard let n = state.decks[d].phraseSuggestion else { return }
            shiftGridBeats(d, n)
        }
    }

    /// Grid auf den Wert aus der Collection zurücksetzen
    public func resetGrid(_ d: Int, original: Track) { locked { state.decks[d].grid = BeatGrid(track: original) } }

    // MARK: Master-Clock

    /// Semi-Sync: neue Tracks laden mit dem Tempo des Masters (kein Phasen-Sync), ein ungesynctes Deck startet in Phase
    public func setSemiSync(_ on: Bool) { locked { state.semiSync = on } }

    /// Clock als Master an/aus. Beim Einschalten übernimmt sie Tempo und Phase des bisherigen Masters (kein Sprung).
    public func setClockMaster(_ on: Bool) {
        locked {
            if on, !state.clockMaster, let m = state.effectiveMaster, let g = state.decks[m].grid {
                state.clockBPM = state.decks[m].bpm
                engine.setClockBPM(state.clockBPM)
                jumpClock(to: g.beatPosition(at: position(m)))
            }
            state.clockMaster = on
            if on { state.masterDeck = nil }
        }
    }

    public func setClockBPM(_ bpm: Double) {
        locked {
            state.clockBPM = max(40, min(250, (bpm * 100).rounded() / 100))
            engine.setClockBPM(state.clockBPM)
        }
    }

    public func nudgeClock(_ delta: Double) { locked { setClockBPM(state.clockBPM + delta) } }

    private var taps: [Date] = []
    /// Tap-Tempo: Mittel der letzten Abstände (Pause > 2 s beginnt neu)
    public func tap() {
        locked {
            let now = Date()
            if let last = taps.last, now.timeIntervalSince(last) > 2 { taps.removeAll() }
            taps.append(now)
            if taps.count > 8 { taps.removeFirst() }
            guard taps.count >= 3 else { return }
            let span = taps.last!.timeIntervalSince(taps.first!) / Double(taps.count - 1)
            if span > 0 {
                setClockBPM(60 / span)
                if !state.clockMaster { state.clockMaster = true; state.masterDeck = nil }
                jumpClock(to: 0)
            }
        }
    }

    public func setMetronome(_ on: Bool, volume: Double? = nil) {
        locked {
            state.metronome = on
            if let v = volume { state.metronomeVolume = v }
            engine.setMetronome(on: on, volume: state.metronomeVolume, firstChannel: state.prefs.metronomeChannel)
        }
    }

    public func setLinkEnabled(_ on: Bool) { locked { state.linkEnabled = on; link.enabled = on } }

    /// Link – MINOS gibt Tempo und Takt vor
    public let link = LinkSession()
    private var linkTicks = 0

    // MARK: Bar-Zähler (läuft ab dem ersten Play durch, bleibt beim Master-Wechsel auf dem Beat)

    private var sessionOffset: Double?

    /// Beats seit dem ersten Play (nil = noch nichts gespielt)
    public var sessionBeat: Double? { locked { sessionOffset.map { engine.clockBeat + $0 } } }

    /// Zähler neu auf Takt 1 setzen (am nächsten Beat)
    public func resetSession() { locked { sessionOffset = -engine.clockBeat.rounded() } }

    /// Clock-Beat springt (Master-Wechsel, Tap) – der Zähler läuft ohne Sprung weiter, im Beat des neuen Masters
    private func jumpClock(to v: Double) {
        if let o = sessionOffset { sessionOffset = o + (engine.clockBeat - v).rounded() }
        engine.setClockBeat(v)
    }

    /// gespeicherte Sitzung übernehmen (Mixer, FX, Clock)
    public func restore(_ f: (inout MixState) -> Void) {
        locked {
            f(&state)
            for d in state.decks.indices { applyRate(d) }
            applyAllMixer(); applyAllFX()
            engine.setClockBPM(state.clockBPM)
            engine.setMetronome(on: state.metronome, volume: state.metronomeVolume, firstChannel: state.prefs.metronomeChannel)
            applyMaster()
            link.enabled = state.linkEnabled
        }
    }

    /// Tempo an die Engine; steht das Deck, laufen Time-Stretch/Varispeed im Bypass (spart viel CPU im Leerlauf)
    private func applyRate(_ d: Int) {
        let s = state.decks[d]
        engine.setRate(d, rate: s.rate, keylock: s.keylock, keyShift: Double(s.keyShift), idle: !engine.player(d).playing)
    }

    // MARK: Mixer

    public func updateDeck(_ d: Int, _ f: (inout DeckState) -> Void) {
        locked { f(&state.decks[d]); applyMixer(d); applyAllFX() }
    }

    public func setCrossfader(_ v: Double) { locked { state.crossfader = v; applyAllMixer() } }

    public func setMasterVolume(_ v: Double) { locked { state.masterVolume = v; applyMaster() } }

    private func applyMaster() {
        let ext = state.externalMixer && !state.prefs.masterVolumeExternal
        engine.setMasterVolume(ext ? 1 : state.masterVolume)
    }

    private func applyMixer(_ d: Int) {
        let s = state.decks[d], p = state.prefs
        let ext = state.externalMixer
        let auto = (ext ? p.autoGainExternal : p.autoGain) ? -(s.track?.perceivedDb ?? 0) : 0
        engine.setGain(d, db: s.gainDb + auto + (ext ? p.headroomExternal : p.headroomInternal))
        engine.setChannelFilter(d, s.filter, resonance: p.channelFilterResonance)
        if state.externalMixer {
            engine.setEQ(d, low: 0, mid: 0, high: 0, kill: p.eqKill)
            engine.setChannelVolume(d, 1)
            return
        }
        engine.setEQ(d, low: s.eqLow, mid: s.eqMid, high: s.eqHigh, kill: p.eqKill)
        let x = state.crossfader
        let side: Double = switch s.xf {
            case .a: x <= 0 ? 1 : 1 - x
            case .b: x >= 0 ? 1 : 1 + x
            case .thru: 1
        }
        let xfGain = p.crossfaderCurve == .sharp ? (side > 0.02 ? 1 : 0) : max(0, side)
        engine.setChannelVolume(d, s.fader * s.fader * xfGain)
    }

    private func applyAllMixer() { for d in state.decks.indices { applyMixer(d) } }

    /// Ist das Deck gerade hörbar? (Extern: immer – das Pult entscheidet)
    private func audible(_ d: Int) -> Bool {
        if state.externalMixer { return true }
        let s = state.decks[d], x = state.crossfader
        let side: Double = switch s.xf {
            case .a: x <= 0 ? 1 : 1 - x
            case .b: x >= 0 ? 1 : 1 + x
            case .thru: 1
        }
        return s.fader * side > 0.05
    }

    // MARK: FX

    public func updateFX(_ u: Int, _ f: (inout FXUnitState) -> Void) {
        locked {
            let oldSize = state.fx[u].reverbSize
            f(&state.fx[u])
            if state.fx[u].reverbSize != oldSize { engine.setReverbSize(unit: u, state.fx[u].reverbSize) }
            applyFX(u)
        }
    }

    public func toggleFXAssign(_ d: Int, _ u: Int) {
        locked { state.decks[d].fxAssign[u].toggle(); applyFX(u) }
    }

    private func applyFX(_ u: Int) {
        syncPlugins(u)
        let fx = state.fx[u]
        for d in state.decks.indices {
            let bpm = state.masterTempo > 0 ? state.masterTempo : 125
            engine.applyFX(unit: u, deck: d, fx, assigned: state.decks[d].fxAssign[u], bpm: bpm,
                           feedback: state.prefs.delayFeedback, filterResonance: state.prefs.fxFilterResonance,
                           reverbLevel: pow(10, state.prefs.reverbLevelDb / 20), reverbBrightness: state.prefs.reverbBrightness,
                           reverbPreDelay: state.prefs.reverbPreDelayMs / 1000)
        }
    }

    private func applyAllFX() { for u in state.fx.indices { applyFX(u) } }

    // MARK: Plugins
    // je FX-Unit eine Instanz pro Deck (auch nicht zugewiesene: Zuweisen wirkt sofort, ohne Ladepause).
    // Laden auf eigener Queue außerhalb der Sperre (Plugins brauchen teils lange), Einsetzen unter der Sperre;
    // alte Instanzen werden erst frei, wenn der Audio-Thread sie nicht mehr rechnet.

    private var plugins = [[PluginInstance?]](repeating: Array(repeating: nil, count: MixEngine.deckCount), count: MixEngine.fxUnitCount)
    private var pluginGen = [Int](repeating: 0, count: MixEngine.fxUnitCount)
    private var pluginLoading = [String?](repeating: nil, count: MixEngine.fxUnitCount)
    private var pluginFailed = [String?](repeating: nil, count: MixEngine.fxUnitCount)
    /// Regler steuern das Plugin gerade (Single + PLUGIN); zuletzt gesendete Werte
    private var knobsLive = [Bool](repeating: false, count: MixEngine.fxUnitCount)
    private var lastKnobs = [[Double]](repeating: [], count: MixEngine.fxUnitCount)
    /// beim nächsten Aktivieren die gespeicherten Regler senden (Sitzung) statt sie vom Plugin zu lesen (neues Plugin)
    private var pushKnobsOnActivate = [Bool](repeating: false, count: MixEngine.fxUnitCount)
    private let pluginQueue = DispatchQueue(label: "minos741.plugins", qos: .userInitiated)
    private let pluginEvents = DispatchQueue(label: "minos741.plugin-events", qos: .userInitiated)
    /// Plugin-Liste, Einstellungen, Absturz-Markierung (die App setzt vor dem ersten Laden eine gespeicherte ein)
    public var pluginCatalog = PluginCatalog(directory: nil) {
        didSet { observeInvalidation() }
    }
    private var invalidationObserver: NSObjectProtocol?

    /// Effekt-Plugins fürs FX-Menü: eingeschaltet und nicht blockiert (einmal eingelesen, `refresh` liest neu)
    public func pluginList(refresh: Bool = false) -> [PluginInfo] { pluginCatalog.menuList(refresh: refresh) }

    /// Namen der Plugin-Parameter auf den 3 Reglern
    public func pluginParamNames(_ u: Int) -> [String] { locked { state.pluginParams[u] } }

    /// Plugin einer Unit wählen (schaltet auf Single + PLUGIN)
    public func setPlugin(_ u: Int, id: String?) {
        locked {
            if state.fx[u].pluginID != id {
                state.fx[u].pluginID = id
                state.fx[u].pluginState = nil
            }
            pluginFailed[u] = nil   // nochmals gewählt = neuer Versuch
            state.pluginErrors[u] = nil
            if id != nil { state.fx[u].single = true; state.fx[u].singleType = FXUnitState.Effect.plugin.rawValue }
            applyFX(u)
        }
    }

    /// Instanz für das Plugin-Fenster (die des ersten Decks); Änderungen darin gehen live an die anderen Decks
    public func beginPluginEdit(_ u: Int) -> PluginInstance? {
        locked {
            guard let first = plugins[u].compactMap({ $0 }).first else { return nil }
            first.observe(on: pluginEvents) { [weak self, weak first] id, v in
                guard let self, let first else { return }
                self.pluginParamChanged(u, first, id, v)
            }
            return first
        }
    }

    /// Fenster zu: Zuhören beenden, Zustand für die Sitzung merken
    public func endPluginEdit(_ u: Int, _ inst: PluginInstance) {
        inst.stopObserving()
        locked {
            guard plugins[u].contains(where: { $0 === inst }) else { return }
            if let st = inst.state { state.fx[u].pluginState = st }
        }
    }

    private func pluginParamChanged(_ u: Int, _ src: PluginInstance, _ id: AudioUnitParameterID, _ v: Float) {
        locked {
            guard plugins[u].contains(where: { $0 === src }) else { return }
            for case let p? in plugins[u] where p !== src && p.value(id) != v { p.set(id, v) }
            // Regler in der Oberfläche folgen dem Fenster
            if knobsLive[u], let i = src.parameters.prefix(3).firstIndex(where: { $0.id == id }), let k = src.knob(i),
               abs(k - state.fx[u].params[i]) > 1e-4 {
                state.fx[u].params[i] = k
                if i < lastKnobs[u].count { lastKnobs[u][i] = k }
            }
        }
    }

    private func syncPlugins(_ u: Int) {
        let fx = state.fx[u]
        guard let want = fx.pluginID else {
            if plugins[u].contains(where: { $0 != nil }) || pluginLoading[u] != nil {
                pluginGen[u] += 1; pluginLoading[u] = nil
                for d in plugins[u].indices { installPlugin(nil, unit: u, deck: d) }
                state.pluginParams[u] = []
                knobsLive[u] = false
            }
            return
        }
        let loaded = plugins[u].allSatisfy { $0?.info.id == want }
        if !loaded {
            knobsLive[u] = false
            guard pluginLoading[u] != want, pluginFailed[u] != want else { return }
            // blockiert (Absturz) oder abgeschaltet: nicht laden, auch nicht aus einer gespeicherten Sitzung
            if let why = pluginCatalog.unusableReason(want) {
                pluginFailed[u] = want
                state.pluginErrors[u] = why
                return
            }
            pluginGen[u] += 1
            let gen = pluginGen[u], saved = fx.pluginState, rate = engine.sampleRate
            pluginLoading[u] = want
            let catalog = pluginCatalog
            pluginQueue.async { [self] in
                do {
                    // Liste ggf. erst hier einlesen (außerhalb der Sperre)
                    guard let info = catalog.info(want) ?? PluginHost.codes(want).map({
                        PluginInfo(id: want, name: PluginHost.fourCC($0.1), manufacturer: PluginHost.fourCC($0.2), type: $0.0, subtype: $0.1, manu: $0.2)
                    }) else { throw NSError(domain: "minos741.plugin", code: 2, userInfo: [NSLocalizedDescriptionKey: want]) }
                    let isolated = catalog.isolated(want)
                    // Absturz-Markierung: stürzt MINOS-741 beim Öffnen ab, ist das Plugin beim nächsten Start blockiert
                    catalog.beginOpen(key: want, name: info.name)
                    defer { catalog.endOpen() }
                    let insts = try (0..<MixEngine.deckCount).map { _ -> PluginInstance in
                        let p = try PluginInstance(info, sampleRate: rate, outOfProcess: isolated)
                        if let saved { p.state = saved }
                        _ = p.parameters
                        return p
                    }
                    finishPluginLoad(u, gen, insts, restored: saved != nil)
                } catch {
                    locked {
                        guard gen == pluginGen[u] else { return }
                        pluginLoading[u] = nil; pluginFailed[u] = want
                        state.pluginErrors[u] = error.localizedDescription
                    }
                }
            }
            return
        }
        guard fx.single, fx.singleType == FXUnitState.Effect.plugin.rawValue, let first = plugins[u][0] else { knobsLive[u] = false; return }
        if !knobsLive[u] {
            knobsLive[u] = true
            if pushKnobsOnActivate[u] {
                for p in plugins[u] { for i in 0..<3 { p?.setKnob(i, fx.params[i]) } }
            } else {
                for i in 0..<3 { if let k = first.knob(i) { state.fx[u].params[i] = k } }
            }
            pushKnobsOnActivate[u] = false
            lastKnobs[u] = state.fx[u].params
            return
        }
        for i in 0..<3 where lastKnobs[u].count == 3 && fx.params[i] != lastKnobs[u][i] {
            for p in plugins[u] { p?.setKnob(i, fx.params[i]) }
            lastKnobs[u][i] = fx.params[i]
        }
    }

    private func finishPluginLoad(_ u: Int, _ gen: Int, _ insts: [PluginInstance], restored: Bool) {
        locked {
            // inzwischen anderes Plugin gewählt: die neuen Instanzen waren nie im Kern → einfach verwerfen
            guard gen == pluginGen[u], state.fx[u].pluginID == insts[0].info.id else { return }
            pluginLoading[u] = nil; pluginFailed[u] = nil; state.pluginErrors[u] = nil
            for d in insts.indices { installPlugin(insts[d], unit: u, deck: d) }
            state.pluginParams[u] = insts[0].parameters.prefix(3).map { Self.shortName($0.name) }
            knobsLive[u] = false
            pushKnobsOnActivate[u] = restored
            if state.fx[u].pluginState == nil { state.fx[u].pluginState = insts[0].state }
            applyFX(u)
        }
    }

    private func installPlugin(_ p: PluginInstance?, unit u: Int, deck d: Int) {
        let old = plugins[u][d]
        plugins[u][d] = p
        engine.setPlugin(unit: u, deck: d, p)
        if let old { retirePlugin(old, unit: u, deck: d) }
    }

    /// alte Instanz halten, bis der Audio-Thread einen Block ohne sie gerechnet hat (steht die Ausgabe, rechnet niemand)
    private func retirePlugin(_ old: PluginInstance, unit u: Int, deck d: Int) {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { [self] in
            if engine.pluginReleased(unit: u, deck: d, old) || !engine.running { return }
            retirePlugin(old, unit: u, deck: d)
        }
    }

    /// isoliertes Plugin abgestürzt (der Systemdienst ist weg, MINOS-741 läuft weiter): Instanzen heraus, Plugin blockieren
    private func observeInvalidation() {
        if invalidationObserver != nil { return }
        let name = NSNotification.Name(kAudioComponentInstanceInvalidationNotification as String)
        invalidationObserver = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] n in
            guard let self, let v = n.userInfo?["audioUnit"] as? NSValue, let raw = v.pointerValue else { return }
            self.pluginInvalidated(OpaquePointer(raw))
        }
    }

    private func pluginInvalidated(_ au: OpaquePointer) {
        locked {
            for u in plugins.indices {
                guard let hit = plugins[u].compactMap({ $0 }).first(where: { OpaquePointer($0.audioUnit) == au }) else { continue }
                let id = hit.info.id
                pluginCatalog.block(id, reason: String(localized: "abgestürzt (isoliert, MINOS-741 lief weiter)"))
                pluginGen[u] += 1; pluginLoading[u] = nil; pluginFailed[u] = id
                for d in plugins[u].indices { installPlugin(nil, unit: u, deck: d) }
                state.pluginParams[u] = []
                state.pluginErrors[u] = String(format: String(localized: "%@ abgestürzt – blockiert"), hit.info.name)
                knobsLive[u] = false
                applyFX(u)
            }
        }
    }

    /// Parametername für einen Regler: versal, kurz
    static func shortName(_ n: String) -> String {
        let up = n.uppercased()
        if up.count <= 7 { return up }
        let first = up.split(whereSeparator: { $0 == " " || $0 == "_" || $0 == "-" }).first.map(String.init) ?? up
        return String(first.prefix(7))
    }

    // MARK: Steuertakt (200 Hz, Steuer-Queue)

    private func tick() {
        let handlers: [(MixController) -> Void] = locked {
            state.autoMaster = state.effectiveMaster   // Auto-Master klebt am laufenden Deck
            let master = state.effectiveMaster
            for d in state.decks.indices {
                let p = engine.player(d)
                if state.decks[d].playing != p.playing, !state.decks[d].cueHeld {
                    state.decks[d].playing = p.playing
                    applyRate(d)
                }
                let hasMaster = state.clockMaster || (master != nil && master != d)
                guard state.decks[d].sync, state.decks[d].playing, hasMaster,
                      let g = state.decks[d].grid, g.bpm > 0 else {
                    if state.decks[d].nudge != 0, !state.decks[d].sync { state.decks[d].nudge = 0; applyRate(d) }
                    continue
                }
                let target = (state.masterTempo / g.bpm - 1) * 100
                var changed = abs(target - state.decks[d].tempoPct) > 0.0001
                state.decks[d].tempoPct = target
                // rückwärts (Flux-Reverse, Reverse) nicht nachziehen – beim Loslassen kommt die Flux-Position, die bleibt in Phase
                if state.prefs.phaseLock, state.prefs.syncMode != .tempo, !state.decks[d].reverse, state.decks[d].bend == 0,
                   let e = phaseErrorLocked(d) {
                    // harter Sprung nur, wenn der Fehler groß ist und > 100 ms anhält – sonst weich nachziehen
                    bigError[d] = abs(e) > 0.25 ? bigError[d] + 1 : 0
                    if bigError[d] >= 20 {
                        engine.seek(d, seconds: position(d) - e * g.beat)
                        state.decks[d].nudge = 0
                        bigError[d] = 0
                    } else {
                        let n = abs(e) < 0.004 ? 0 : max(-0.06, min(0.06, -e * 0.6))
                        changed = changed || n != state.decks[d].nudge
                        state.decks[d].nudge = n
                    }
                }
                if changed { applyRate(d) }
            }
            // AUTO-Modus: Clock folgt Tempo und Phase des Master-Decks (für Metronom und Link)
            if !state.clockMaster, let m = master, let g = state.decks[m].grid, state.decks[m].playing {
                let bpm = state.decks[m].bpm
                if abs(bpm - state.clockBPM) > 0.005 { state.clockBPM = bpm; engine.setClockBPM(bpm) }
                let want = g.beatPosition(at: position(m))
                if abs(BeatGrid.phaseError(own: engine.clockBeat, master: want)) > 0.02 { jumpClock(to: want) }
            }
            // Link: Tempo und Beat der Clock vorgeben, Teilnehmer zählen
            if state.linkEnabled {
                if let st = engine.clockStamp {
                    link.offsetMicros = Int64(state.prefs.linkOffsetMs * 1000)
                    link.lead(bpm: state.clockBPM, beat: st.beat, hostTime: st.hostTime)
                }
                linkTicks += 1
                if linkTicks % 100 == 0 { let n = link.peers; if n != state.linkPeers { state.linkPeers = n } }
            } else if state.linkPeers != 0 { state.linkPeers = 0 }
            // Bar-Zähler startet mit dem ersten Play
            if sessionOffset == nil, state.decks.contains(where: { $0.playing }) { sessionOffset = -engine.clockBeat.rounded() }
            // History: hörbare Spielzeit zählen, ab Schwelle als gespielt melden
            var played: [(Int, Track, Date)] = []
            for d in state.decks.indices where state.decks[d].playing {
                guard let t = state.decks[d].track else { continue }
                if playStart[d] == nil { playStart[d] = Date() }
                if audible(d) { playedTime[d] += 0.005 }
                if !playedLogged[d], playedTime[d] >= state.prefs.historyThreshold {
                    playedLogged[d] = true
                    played.append((d, t, playStart[d] ?? Date()))
                }
            }
            if !played.isEmpty, let cb = onPlayed { DispatchQueue.global().async { for p in played { cb(p.0, p.1, p.2) } } }
            tickCount += 1
            // beat-synchrones Delay folgt dem Tempo
            if tickCount % 50 == 0, state.fx.contains(where: { $0.slots[1].on }) { applyAllFX() }
            return tickCount % 6 == 0 ? tickHandlers : []
        }
        for h in handlers { h(self) }
    }
}
