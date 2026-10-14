import SwiftUI
import AppKit
import MixCore
import MixEngine

/// Groove → MIDI: Muster des Tracks am Grid lesen, Hats / Bass dazu erzeugen, als MIDI-Quelle im Takt der Clock
/// ausgeben oder als .mid speichern. Eine Quelle für alle Decks (läuft für ein Deck zur Zeit).
@MainActor @Observable
final class GrooveCenter {
    static let shared = GrooveCenter()

    struct Slot: Equatable {
        var pattern: GroovePattern?
        var clip: GrooveClip?
        var seed: UInt64 = 1
        var trackKey = ""
        /// Grid-Beat von Schritt 0
        var startBeat = 0.0
        var bpm = 0.0
        var key: Int?
        var transpose = 0
        /// Kanal der Drums im Clip (Anzeige: Hats vs. Bass)
        var drumChannel: UInt8 = 9
    }

    fileprivate(set) var slots = [Slot](repeating: Slot(), count: MixEngine.deckCount)
    /// Deck, dessen Groove gerade an MIDI geht
    private(set) var running: Int?
    @ObservationIgnored private(set) var out: GrooveOut?
    @ObservationIgnored private var quitObserver: NSObjectProtocol?

    init() {
        // beim Beenden: offene Noten beenden (sonst hängen sie im Ziel)
        quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { GrooveCenter.shared.out?.stop() }
        }
    }

    // MARK: Muster

    /// Muster lesen: aktiver Loop, sonst die nächsten Takte ab der nächsten Eins
    @discardableResult
    func analyze(_ mix: MixModel, _ d: Int) -> Bool {
        let s = mix.deck(d)
        guard let t = s.track, let a = mix.audio(d), let g = s.grid, g.bpm > 0 else {
            StatusCenter.post(.warning, String(localized: "Groove: Deck \(deckLetters[d]) ohne Track mit Grid"), key: "groove")
            return false
        }
        let bps = a.sampleRate / Double(TrackAudio.blockFrames(sampleRate: a.sampleRate))
        var start: Double, beats: Double
        let loop = mix.engine.loop(d)
        if loop.active, loop.end > loop.start {
            start = g.beatPosition(at: loop.start).rounded()
            beats = min(8, max(1, (g.beatPosition(at: loop.end) - start).rounded()))
        } else {
            beats = Double(max(1, min(2, mix.prefs.groove.bars)) * 4)
            start = max(0, (g.beatPosition(at: mix.position(d)) / 4).rounded(.up) * 4)
            let last = g.beatPosition(at: a.duration)
            if start + beats > last { start = max(0, ((last - beats) / 4).rounded(.down) * 4) }
        }
        let p = GrooveAnalyzer.extract(a.spectrum, blocksPerSecond: bps, grid: g, startBeat: start, beats: beats)
        var slot = slots[d]
        slot.pattern = p
        slot.trackKey = t.key
        slot.startBeat = start
        slot.bpm = s.bpm
        slot.key = t.harmonyCode
        slot.transpose = Int(mix.keyDeviation(d).rounded())
        slots[d] = slot
        generate(mix, d)
        return true
    }

    func options(_ mix: MixModel, _ slot: Slot) -> GrooveGenerator.Options {
        let gp = mix.prefs.groove
        var o = GrooveGenerator.Options()
        o.instrument = gp.instrument
        o.style = gp.style
        o.seed = slot.seed
        o.key = slot.key
        o.transpose = slot.transpose
        o.bassOctave = max(0, min(4, gp.bassOctave))
        o.bassChannel = UInt8(max(1, min(16, gp.bassChannel)) - 1)
        o.drumChannel = UInt8(max(1, min(16, gp.drumChannel)) - 1)
        return o
    }

    /// Clip aus dem Muster neu erzeugen (Stil, Instrument, Seed, Kanäle); läuft das Deck, ohne Lücke tauschen
    func generate(_ mix: MixModel, _ d: Int) {
        guard let p = slots[d].pattern else { return }
        let o = options(mix, slots[d])
        let clip = GrooveGenerator.clip(p, o)
        slots[d].clip = clip
        slots[d].drumChannel = o.drumChannel
        if running == d { out?.update(clip: clip) }
    }

    /// neu würfeln
    func reroll(_ mix: MixModel, _ d: Int) {
        if slots[d].pattern == nil || slots[d].trackKey != mix.deck(d).track?.key { guard analyze(mix, d) else { return } }
        slots[d].seed = slots[d].seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        generate(mix, d)
    }

    /// Einstellungen geändert: alle Clips neu, Quelle umbenennen, Versatz
    func prefsChanged(_ mix: MixModel) {
        for d in slots.indices where slots[d].pattern != nil { generate(mix, d) }
        out?.rename(mix.prefs.groove.sourceName)
        out?.setOffset(ms: mix.prefs.groove.offsetMs)
    }

    // MARK: MIDI

    func toggle(_ mix: MixModel, _ d: Int) {
        if running == d { stop() } else { start(mix, d) }
    }

    func start(_ mix: MixModel, _ d: Int) {
        if slots[d].clip == nil || slots[d].trackKey != mix.deck(d).track?.key { guard analyze(mix, d) else { return } }
        guard let clip = slots[d].clip, let g = mix.deck(d).grid else { return }
        let o = out ?? GrooveOut(name: mix.prefs.groove.sourceName, hidden: Session.isSelfTest)
        out = o
        guard o.open() else {
            StatusCenter.post(.error, String(localized: "Groove: MIDI-Quelle nicht angelegt"), detail: o.lastError, key: "groove")
            return
        }
        // Schritt 0 = Grid-Beat `startBeat` des Decks; spielt das Deck, liegt die Clock einen ganzzahligen Versatz daneben
        let s = slots[d]
        var origin = s.startBeat
        if mix.deck(d).playing {
            origin += (mix.engine.clockBeat - g.beatPosition(at: mix.position(d))).rounded()
        }
        let core = mix.core
        o.start(clip: clip, origin: origin, offsetMs: mix.prefs.groove.offsetMs) {
            guard let st = core.engine.clockStamp else { return nil }
            return GrooveOut.Clock(beat: st.beat, hostTime: st.hostTime, bpm: core.clockTempo)
        }
        running = d
        StatusCenter.post(.info, Self.statusText(mix.prefs.groove.instrument, clip: clip), key: "groove")
    }

    func stop() {
        guard running != nil else { return }
        out?.stop()
        running = nil
        StatusCenter.post(.info, String(localized: "Groove → MIDI aus"), key: "groove")
    }

    static func statusText(_ i: GrooveInstrument, clip: GrooveClip) -> String {
        let what = switch i {
            case .hats: String(localized: "Hats")
            case .bass: String(localized: "Bass")
            case .both: String(localized: "Hats + Bass")
        }
        let bars = clip.beats / 4
        let len = bars >= 1 && bars == bars.rounded() ? String(localized: "\(Int(bars)) Takte") : String(localized: "\(BeatSizes.label(clip.beats)) Beats")
        return String(localized: "Groove → MIDI: \(what), \(len)")
    }

    // MARK: Datei

    func fileName(_ mix: MixModel, _ d: Int) -> String {
        let t = mix.deck(d).track
        let base = [t?.artist ?? "", t?.title ?? ""].filter { !$0.isEmpty }.joined(separator: " - ")
        let safe = (base.isEmpty ? "MINOS-741" : base).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return "\(safe) (groove \(mix.prefs.groove.style.rawValue)).mid"
    }

    func midiData(_ mix: MixModel, _ d: Int) -> Data? {
        if slots[d].clip == nil || slots[d].trackKey != mix.deck(d).track?.key { guard analyze(mix, d) else { return nil } }
        guard let clip = slots[d].clip else { return nil }
        return MIDIFile.clip(clip, bpm: slots[d].bpm > 0 ? slots[d].bpm : mix.masterBPM,
                             bassChannel: UInt8(max(1, min(16, mix.prefs.groove.bassChannel)) - 1))
    }

    /// Datei für Ziehen aus dem Deck (temporärer Ordner)
    func dragFile(_ mix: MixModel, _ d: Int) -> URL? {
        guard let data = midiData(mix, d) else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MINOS-741 Groove", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(fileName(mix, d))
        do { try data.write(to: url) } catch { return nil }
        return url
    }

    /// Speichern: Dateidialog im Ordner des Tracks (Selbsttest: ohne Dialog in den temporären Ordner)
    func save(_ mix: MixModel, _ d: Int) {
        guard let data = midiData(mix, d) else { return }
        if Session.isSelfTest {
            if let url = dragFile(mix, d) { StatusCenter.post(.ok, String(localized: "Groove gespeichert: \(url.lastPathComponent)"), key: "groove") }
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName(mix, d)
        panel.allowedContentTypes = [.midi]
        if let p = mix.deck(d).track?.path { panel.directoryURL = URL(fileURLWithPath: p).deletingLastPathComponent() }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
            StatusCenter.post(.ok, String(localized: "Groove gespeichert: \(url.lastPathComponent)"), detail: url.path, key: "groove")
        } catch {
            StatusCenter.post(.error, String(localized: "Groove nicht gespeichert"), detail: error.localizedDescription, key: "groove")
        }
    }
}

// MARK: - Deck-Zeile

/// GROOVE: Instrument, Stil, Muster (Klick = neu lesen, Ziehen = .mid), neu würfeln, ▶ MIDI, ■, .mid
struct GrooveRow: View {
    @Environment(MixModel.self) private var mix
    let d: Int

    var body: some View {
        let g = GrooveCenter.shared
        Content(d: d, slot: g.slots[d], running: g.running == d, instrument: mix.prefs.groove.instrument,
                style: mix.prefs.groove.style).equatable()
    }

    struct Content: View, Equatable {
        @Environment(MixModel.self) private var mix
        let d: Int
        let slot: GrooveCenter.Slot
        let running: Bool
        let instrument: GrooveInstrument
        let style: GrooveStyle
        static func == (a: Self, b: Self) -> Bool {
            a.d == b.d && a.slot == b.slot && a.running == b.running && a.instrument == b.instrument && a.style == b.style
        }

        static func name(_ i: GrooveInstrument, short: Bool = false) -> String {
            switch i { case .hats: short ? "H" : "HATS"; case .bass: short ? "B" : "BASS"; case .both: short ? "H+B" : "HATS+BASS" }
        }
        static func name(_ s: GrooveStyle, short: Bool = false) -> String {
            switch s { case .tight: "TIGHT"; case .off: "OFF"; case .rolling: short ? "ROLL" : "ROLLING" }
        }

        var body: some View {
            // schmales Deck: kurze Namen, ohne Beschriftung
            ViewThatFits(in: .horizontal) {
                row(short: false).frame(minWidth: 0)
                row(short: true)
            }
        }

        private func menu<T: Hashable>(_ value: T, _ all: [T], _ name: @escaping (T) -> String, set: @escaping (T) -> Void) -> some View {
            Menu {
                Picker(selection: Binding(get: { value }, set: set)) {
                    ForEach(all, id: \.self) { Text(verbatim: name($0)).tag($0) }
                } label: { EmptyView() }
                .pickerStyle(.inline)
            } label: {
                Text(verbatim: name(value) + " ▾").font(Theme.label(10.z, .bold)).foregroundStyle(Theme.bone.opacity(0.85))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).controlSize(zoomed: .small).tint(Theme.bone)
            .fixedSize()
        }

        @ViewBuilder private func row(short: Bool) -> some View {
            let g = GrooveCenter.shared
            HStack(spacing: 3.z) {
                if !short { Text(verbatim: "GROOVE").font(Theme.label(9.z, .bold)).foregroundStyle(Theme.muted).fixedSize() }
                menu(instrument, GrooveInstrument.allCases, { Self.name($0, short: short) }) { mix.prefs.groove.instrument = $0; g.prefsChanged(mix) }
                    .help("Instrument: Hats, Bass oder beide")
                menu(style, GrooveStyle.allCases, { Self.name($0, short: short) }) { mix.prefs.groove.style = $0; g.prefsChanged(mix) }
                    .help("Stil: tight = auf den Kicks, off = Offbeat, rolling = 16tel")
                GrooveGrid(slot: slot)
                    .frame(minWidth: short ? 48.z : 120.z, maxWidth: .infinity)
                    .frame(height: 18.z)
                    .contentShape(Rectangle())
                    .onTapGesture { g.analyze(mix, d) }
                    .onDrag {
                        guard let url = g.dragFile(mix, d) else { return NSItemProvider() }
                        let p = NSItemProvider(object: url as NSURL)
                        p.suggestedName = url.lastPathComponent
                        return p
                    }
                    .help("Klick = Muster ab der nächsten Eins lesen (aktiver Loop: der Loop) · Ziehen = .mid in die DAW")
                DeckButton(title: "⚄", width: 18) { g.reroll(mix, d) }.help("Neu würfeln")
                DeckButton(title: short ? "▶" : "▶ MIDI", active: running, color: Theme.state, width: short ? 18 : 46) { g.toggle(mix, d) }
                    .help("Groove als MIDI-Quelle im Takt der Clock")
                DeckButton(title: "■", width: 18) { g.stop() }.help("MIDI anhalten")
                DeckButton(title: ".mid", width: 30) { g.save(mix, d) }.help("Als MIDI-Datei speichern")
            }
        }
    }
}

/// Muster als Raster: Spuren Kick · Snare · Hats · Bass, Track-Schläge hell, erzeugte Hats rot, Bass lila
struct GrooveGrid: View {
    let slot: GrooveCenter.Slot

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.void))
            guard let p = slot.pattern else {
                ctx.draw(Text("Klick = Muster lesen").font(.system(size: 9.z, design: .monospaced)).foregroundStyle(Theme.muted),
                         at: CGPoint(x: size.width / 2, y: size.height / 2))
                return
            }
            let n = max(1, p.steps), lanes = 4
            let w = size.width / CGFloat(n), h = size.height / CGFloat(lanes)
            for s in stride(from: 0, through: n, by: GroovePattern.stepsPerBeat) {
                let x = CGFloat(s) * w
                ctx.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)),
                         with: .color(s % GroovePattern.stepsPerBar == 0 ? Theme.muted : Theme.hairline))
            }
            func cell(_ s: Int, _ lane: Int, _ c: Color, _ v: UInt8) {
                let r = CGRect(x: CGFloat(s) * w + 1, y: CGFloat(lane) * h + 0.5, width: max(1, w - 2), height: max(1, h - 1))
                ctx.fill(Path(r), with: .color(c.opacity(0.35 + 0.65 * Double(v) / 127)))
            }
            for s in 0..<n {
                if p.has(.kick, s) { cell(s, 0, Theme.bone, p.velocity(.kick, s)) }
                if p.has(.snare, s) { cell(s, 1, Theme.bone, p.velocity(.snare, s)) }
                if p.has(.closedHat, s) { cell(s, 2, Theme.muted, p.velocity(.closedHat, s)) }
                if p.has(.openHat, s) { cell(s, 2, Theme.bone, p.velocity(.openHat, s)) }
            }
            for note in slot.clip?.notes ?? [] where note.step < n {
                if note.channel == slot.drumChannel {
                    cell(note.step, 2, note.note == GrooveGenerator.openHatNote ? Theme.gold : Theme.state, note.velocity)
                } else {
                    // Bass: Länge als Balken
                    let r = CGRect(x: CGFloat(note.step) * w + 1, y: 3 * h + 0.5, width: max(1, CGFloat(note.length) * w - 1), height: max(1, h - 1))
                    ctx.fill(Path(r), with: .color(Theme.secondary.opacity(0.4 + 0.6 * Double(note.velocity) / 127)))
                }
            }
        }
        .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
    }
}

// MARK: - Einstellungen

/// ⌘, -> DECKS -> Groove → MIDI
struct GrooveSettingsSection: View {
    @Environment(MixModel.self) private var mix

    var body: some View {
        @Bindable var mix = mix
        Section("Groove → MIDI") {
            LabeledContent("Name der MIDI-Quelle") {
                TextField("", text: $mix.prefs.groove.sourceName).settingsField()
            }
            Stepper("Kanal Bass: \(mix.prefs.groove.bassChannel)", value: $mix.prefs.groove.bassChannel, in: 1...16)
            Stepper("Kanal Drums: \(mix.prefs.groove.drumChannel)", value: $mix.prefs.groove.drumChannel, in: 1...16)
            Stepper("Oktave Bass: \(mix.prefs.groove.bassOctave) (C\(mix.prefs.groove.bassOctave) = \(12 * (mix.prefs.groove.bassOctave + 2)))",
                    value: $mix.prefs.groove.bassOctave, in: 0...3)
            Picker("Länge ohne Loop", selection: $mix.prefs.groove.bars) {
                Text("1 Takt").tag(1)
                Text("2 Takte").tag(2)
            }
            Stepper("Versatz (ms): \(Int(mix.prefs.groove.offsetMs))", value: $mix.prefs.groove.offsetMs, in: -100...100, step: 1)
            Text("deck-zeile groove: muster des tracks am grid lesen (aktiver loop, sonst ab der nächsten eins), hats / bass dazu erzeugen. ▶ midi = virtuelle midi-quelle im takt der clock, in der daw als midi-eingang wählen. bass = grundton aus dem key, kanal 10 = drums (42 / 46 hats). ziehen aus dem raster oder .mid = midi-datei.")
                .settingsHint()
        }
        .onChange(of: mix.prefs.groove) { GrooveCenter.shared.prefsChanged(mix) }
    }
}

// MARK: - Bild (Selbsttest)

/// Nur Selbsttest: MIX741_SHOT=groove:<pfad.png> rendert die Groove-Zeile (Muster: Kick auf jedem Beat, Clap auf 2 / 4,
/// Hats auf 8teln) in 640 / 400 / 300 pt Breite und Deck A mit der Zeile (480 × 260), offscreen, und beendet sich
@MainActor
enum GrooveShot {
    static func runIfRequested() {
        guard Session.isSelfTest, let spec = ProcessInfo.processInfo.environment["MIX741_SHOT"], spec.hasPrefix("groove:") else { return }
        var base = String(spec.dropFirst(7))
        if base.hasSuffix(".png") { base.removeLast(4) }
        NSApplication.shared.setActivationPolicy(.prohibited)
        let devs = MixEngine.outputDevices()
        let dev = devs.first { $0.channels == 2 && $0.name.localizedCaseInsensitiveContains("speaker") } ?? devs.first { $0.channels < 8 }
        UserDefaults.standard.setVolatileDomain(["deviceUID": dev?.uid ?? "-", "mixerMode": MixerMode.internalMixer.rawValue,
                                                 "sampleRate": 0.0, "bufferSize": 0, "masterVolume": 0.0],
                                                forName: UserDefaults.argumentDomain)
        let mix = MixModel()
        mix.engine.stop()
        mix.prefs.ui.showAllDeckRows()
        var t = Track(key: "shot", path: "/dev/null")
        t.title = "Groove Shot"; t.artist = "MINOS-741"; t.bpm = 130; t.musicalKey = 21; t.duration = 300
        mix.updateDeck(0) { $0.track = t; $0.duration = 300; $0.grid = BeatGrid(anchor: 0.2, bpm: 130) }
        var p = GroovePattern.fourOnTheFloor(steps: 32)
        for s in [4, 12, 20, 28] { p.set(.snare, s, 100) }
        for s in stride(from: 2, to: 32, by: 4) { p.set(s % 16 == 14 ? .openHat : .closedHat, s, 90) }
        GrooveCenter.shared.setForShot(mix, 0, pattern: p, key: 21, bpm: 130)
        var paths: [String] = []
        for w in [640.0, 400.0, 300.0] {
            let path = "\(base)-row-\(Int(w)).png"
            render(GrooveRow(d: 0), mix: mix, size: CGSize(width: w, height: 26), to: path)
            paths.append(path)
        }
        let path = "\(base)-deck-480x260.png"
        render(DeckView(d: 0).environment(WaveformCache()).environment(LibraryStore()).environment(BrowserState()),
               mix: mix, size: CGSize(width: 480, height: 260), to: path)
        paths.append(path)
        print("[shot] " + paths.joined(separator: " "))
        fflush(stdout)
        exit(0)
    }

    private static func render<V: View>(_ v: V, mix: MixModel, size: CGSize, to path: String) {
        let root = v.environment(mix)
            .padding(4)
            .frame(width: size.width, height: size.height)
            .background(Theme.deck)
            .foregroundStyle(Theme.bone)
            .tint(Theme.state)
            .preferredColorScheme(.dark)
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(origin: .zero, size: size)
        let win = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: .darkAqua)
        win.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

extension GrooveCenter {
    /// Bild / Test: Muster direkt setzen (ohne Audio)
    func setForShot(_ mix: MixModel, _ d: Int, pattern: GroovePattern, key: Int?, bpm: Double) {
        slots[d].pattern = pattern
        slots[d].key = key
        slots[d].bpm = bpm
        slots[d].trackKey = mix.deck(d).track?.key ?? ""
        generate(mix, d)
    }
}
