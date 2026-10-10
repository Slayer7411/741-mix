import SwiftUI
import AppKit
import MixCore
import MixEngine

/// Deck: jede Zeile ist eine eigene Ansicht, die nur ihren Ausschnitt des Deck-Zustands liest (äußere Hülle) und ihn
/// als Wert an eine Equatable-Ansicht gibt. Ändert sich etwas anderes, überspringt SwiftUI Body und Layout der Zeile –
/// eine Zustandsänderung kostet so nur die Zeile, die sie zeigt, statt das ganze Deck neu zu messen.
struct DeckView: View {
    @Environment(MixModel.self) private var mix
    let d: Int

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 4) {
                DeckHeader(d: d)
                WaveformView(d: d)
                    .frame(minHeight: mix.prefs.ui.waveformHeight, maxHeight: .infinity)
                PhaseBar(d: d).frame(height: 8)
                OverviewView(d: d)
                    .frame(height: 18)
                TransportRow(d: d)
                CueRow(d: d)
                LoopRow(d: d)
                JumpRow(d: d)
                if mix.prefs.ui.showGridTools { GridToolsRow(d: d) }
            }
            TempoColumn(d: d)
        }
        .padding(6)
        .frame(maxHeight: .infinity)
        .background(Frame(d: d, border: false))
        .overlay(Frame(d: d, border: true))
        .contentShape(Rectangle())
        .onTapGesture { mix.focusedDeck = d }
    }

    /// Fläche und Rahmen (Fokus, Master gold) lesen Fokus und Master selbst: ein Master-Wechsel färbt nur sie neu,
    /// DeckView und seine Zeilen bleiben unberührt
    struct Frame: View {
        @Environment(MixModel.self) private var mix
        let d: Int
        let border: Bool

        var body: some View {
            let focused = mix.focusedDeck == d
            if border {
                Rectangle().stroke(mix.effectiveMaster == d ? Theme.gold : (focused ? Theme.bone.opacity(0.5) : Theme.hairline), lineWidth: 1)
            } else {
                Rectangle().fill(focused ? Theme.deckFocused : Theme.deck)
            }
        }
    }

    static func same(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }
}

/// Deck in eigener NSHostingView = Layout-Grenze. SwiftUI reicht jede Größen-Invalidierung bis zur Wurzel durch und
/// misst von dort alles neu (vier Decks, Mixer, Leiste, Browser); in eigener Hosting-View rechnet eine Zustandsänderung
/// nur das Layout dieses Decks. Größe kommt von außen (sizingOptions leer: keine Rückmeldung nach oben).
struct DeckHost: NSViewRepresentable {
    @Environment(MixModel.self) private var mix
    @Environment(WaveformCache.self) private var cache
    let d: Int

    struct Root: View {
        let d: Int
        let mix: MixModel
        let cache: WaveformCache
        var body: some View {
            DeckView(d: d)
                .environment(mix)
                .environment(cache)
                .foregroundStyle(Theme.bone)
                .tint(Theme.state)
        }
    }

    func makeNSView(context: Context) -> BoundaryHostingView<Root> {
        let v = BoundaryHostingView(rootView: Root(d: d, mix: mix, cache: cache))
        v.name = "deck " + deckLetters[d]
        v.sizingOptions = []
        return v
    }

    func updateNSView(_ v: BoundaryHostingView<Root>, context: Context) {
        if v.rootView.d != d || v.rootView.mix !== mix || v.rootView.cache !== cache { v.rootView = Root(d: d, mix: mix, cache: cache) }
    }

    /// nimmt den angebotenen Platz; sonst fragt SwiftUI bei jedem äußeren Layout fittingSize ab (Auto Layout + inneres Layout)
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: BoundaryHostingView<Root>, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}

/// Kopf: Buchstabe, Titel/Artist, FX-Zuweisung, Zeit, BPM, Code, Key, Phase
struct DeckHeader: View {
    @Environment(MixModel.self) private var mix
    let d: Int

    struct Model: Equatable {
        var playing = false, title = "", subtitle = "", isError = false
        var showFX = false, fxUnits = 2, fxAssign: [Bool] = []
        var bpm = 0.0, tempoPct = 0.0
        var time = TimeReadout.Model(), code = CodeReadout.Model(), key = KeyReadout.Model(), phaseActive = false
    }

    var body: some View {
        let s = mix.deck(d), ui = mix.prefs.ui
        var m = Model()
        m.playing = s.playing
        m.title = s.loading ? "Lade …" : (s.track?.title ?? "—")
        m.subtitle = s.error ?? s.track?.artist ?? String(localized: "Kein Track geladen")
        m.isError = s.error != nil
        m.showFX = !ui.showMixer
        m.fxUnits = ui.fxUnitCount
        m.fxAssign = s.fxAssign
        m.bpm = s.bpm
        m.tempoPct = s.tempoPct
        m.time = .init(hasTrack: s.track != nil, duration: s.duration, playing: s.playing, grid: s.grid, warnAt: mix.prefs.engine.trackEndWarning)
        m.code = .init(hasTrack: s.track != nil, playing: s.playing, bars: max(4, ui.phraseBeats) / 4)
        m.key = KeyReadout.Model(track: s.track, deviation: mix.keyDeviation(d))
        m.phaseActive = s.playing && (mix.clockMaster || mix.effectiveMaster != nil)
        return Content(d: d, m: m).equatable()
    }

    struct Content: View, Equatable {
        @Environment(MixModel.self) private var mix
        let d: Int
        let m: Model
        static func == (a: Self, b: Self) -> Bool { a.d == b.d && a.m == b.m }

        var body: some View {
            HStack(alignment: .center, spacing: 6) {
                Text(deckLetters[d]).font(Theme.label(22, .bold)).foregroundStyle(m.playing ? Theme.state : Theme.bone)
                VStack(alignment: .leading, spacing: 0) {
                    Text(m.title)
                        .font(Theme.mono(13, .semibold)).lineLimit(1)
                    Text(m.subtitle)
                        .font(Theme.mono(11)).foregroundStyle(m.isError ? Color.red : Color.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if m.showFX {
                    // ohne Mixer-Ansicht: FX-Zuweisung direkt am Deck
                    // FX-Zuweisung am Kanal: 1 2 (3 4)
                    VStack(spacing: 2) {
                        ForEach(0..<(m.fxUnits == 4 ? 2 : 1), id: \.self) { row in
                            HStack(spacing: 2) {
                                ForEach([0, 1].map { row * 2 + $0 }, id: \.self) { u in
                                    DeckButton(title: "FX\(u + 1)", active: m.fxAssign[u], color: Theme.state) { mix.toggleFXAssign(d, u) }
                                }
                            }
                        }
                    }
                }
                TimeReadout(d: d, m: m.time).equatable()
                VStack(alignment: .trailing, spacing: 0) {
                    Text(String(format: "%.2f", m.bpm)).font(Theme.mono(15, .bold))
                    Text(String(format: "%+.2f%%", m.tempoPct)).font(Theme.mono(10)).foregroundStyle(.secondary)
                }
                CodeReadout(d: d, m: m.code).equatable()
                VStack(alignment: .trailing, spacing: 0) {
                    KeyReadout(m: m.key).equatable()
                    PhaseMeter(d: d, active: m.phaseActive).equatable().frame(width: 44, height: 6)
                }
                .frame(minWidth: 46)
            }
        }
    }
}

/// Transport: CUP CUE ▶ | SYNC MASTER KEY − + REV FLUX
struct TransportRow: View {
    @Environment(MixModel.self) private var mix
    let d: Int

    struct Model: Equatable { var playing = false, cueHeld = false, sync = false, master = false, keylock = false, reverse = false, flux = false }

    var body: some View {
        let s = mix.deck(d)
        Content(d: d, m: Model(playing: s.playing, cueHeld: s.cueHeld, sync: s.sync, master: mix.effectiveMaster == d,
                               keylock: s.keylock, reverse: s.reverse, flux: s.flux)).equatable()
    }

    struct Content: View, Equatable {
        @Environment(MixModel.self) private var mix
        let d: Int
        let m: Model
        static func == (a: Self, b: Self) -> Bool { a.d == b.d && a.m == b.m }

        var body: some View {
            HStack(spacing: 3) {
                DeckButton(title: "CUP", width: 26) { mix.cup(d) }
                PressButton(title: "CUE", active: m.cueHeld, width: 30, down: { mix.cueDown(d) }, up: { mix.cueUp(d) })
                DeckButton(title: m.playing ? "❚❚" : "▶", active: m.playing, color: Theme.state, width: 30) { mix.togglePlay(d) }
                Divider().frame(height: 14)
                DeckButton(title: "SYNC", active: m.sync, color: Theme.state) { mix.toggleSync(d) }
                DeckButton(title: "MASTER", active: m.master,
                           color: Theme.secondary) { mix.toggleMaster(d) }
                DeckButton(title: "KEY", active: m.keylock, color: Theme.state) { mix.toggleKeylock(d) }
                DeckButton(title: "−") { mix.shiftKey(d, -1) }
                DeckButton(title: "+") { mix.shiftKey(d, 1) }
                DeckButton(title: "REV", active: m.reverse, color: Theme.state) { mix.toggleReverse(d) }
                DeckButton(title: "FLUX", active: m.flux, color: Theme.state) { mix.toggleFlux(d) }
                Spacer(minLength: 2)
            }
        }
    }
}

/// Grid-Werkzeuge: verschieben, BPM, ×2/÷2, Marker setzen, zurücksetzen
struct GridToolsRow: View {
    @Environment(MixModel.self) private var mix
    let d: Int

    struct Model: Equatable { var bpm: Double?, suggestion: Int?, confidence = 0.0 }

    var body: some View {
        let s = mix.deck(d)
        Content(d: d, m: Model(bpm: s.grid?.bpm, suggestion: s.phraseSuggestion, confidence: s.phraseConfidence)).equatable()
    }

    struct Content: View, Equatable {
        @Environment(MixModel.self) private var mix
        let d: Int
        let m: Model
        static func == (a: Self, b: Self) -> Bool { a.d == b.d && a.m == b.m }

        var body: some View {
            HStack(spacing: 3) {
                Text("GRID").font(Theme.label(9, .bold)).foregroundStyle(Theme.muted).frame(width: 30, alignment: .leading)
                DeckButton(title: "◂◂") { mix.shiftGrid(d, ms: -10) }.help("Grid 10 ms früher")
                DeckButton(title: "◂") { mix.shiftGrid(d, ms: -1) }.help("Grid 1 ms früher")
                DeckButton(title: "▸") { mix.shiftGrid(d, ms: 1) }.help("Grid 1 ms später")
                DeckButton(title: "▸▸") { mix.shiftGrid(d, ms: 10) }.help("Grid 10 ms später")
                Divider().frame(height: 14)
                DeckButton(title: "BPM −") { mix.setGridBPM(d, (mix.deck(d).grid?.bpm ?? 0) - 0.01) }
                Text(m.bpm.map { String(format: "%.3f", $0) } ?? "—").font(Theme.mono(10)).frame(width: 52)
                DeckButton(title: "+") { mix.setGridBPM(d, (mix.deck(d).grid?.bpm ?? 0) + 0.01) }
                DeckButton(title: "÷2") { mix.scaleGridBPM(d, 0.5) }
                DeckButton(title: "×2") { mix.scaleGridBPM(d, 2) }
                Divider().frame(height: 14)
                DeckButton(title: "SET") { mix.setGridAnchorHere(d) }.help("Beat 1 an die aktuelle Position")
                DeckButton(title: "RESET") { mix.resetGrid(d) }.help("Grid aus der Collection")
                // Anker um ganze Beats/Takte: Raster bleibt, nur Takt- und Phrasenzählung wandert; schmale Decks: weniger Knöpfe
                // FirstFit statt ViewThatFits: ViewThatFits baut seine Kandidaten bei jedem Layout neu auf (Knöpfe mit
                // Tooltip, Fokus, Tastatur) – das kostete bei jeder Zustandsänderung ~40 ms über vier Decks
                FirstFit {
                    HStack(spacing: 3) { Divider().frame(height: 14); anchorButtons([-4, -1, 1, 4]); phraseButton(short: false) }
                    HStack(spacing: 3) { Divider().frame(height: 14); anchorButtons([-1, 1]); phraseButton(short: true) }
                    phraseButton(short: true)
                }
                Spacer(minLength: 0)
            }
        }

        private func anchorButtons(_ steps: [Int]) -> some View {
            ForEach(steps, id: \.self) { n in
                DeckButton(title: n < 0 ? "◂\(-n)" : "\(n)▸") { mix.shiftGridBeats(d, n) }
                    .help(LocalizedStringKey(n == -4 ? "Grid-Anker 1 Takt früher (Raster bleibt)" : n == 4 ? "Grid-Anker 1 Takt später (Raster bleibt)"
                                 : n < 0 ? "Grid-Anker 1 Beat früher (Raster bleibt)" : "Grid-Anker 1 Beat später (Raster bleibt)"))
            }
        }

        /// Phrasen-Anker-Vorschlag (rot), Klick verschiebt den Anker um die vorgeschlagenen Beats
        @ViewBuilder private func phraseButton(short: Bool) -> some View {
            if let n = m.suggestion {
                let v = n > 0 ? "+\(n)" : "\u{2212}\(-n)"
                DeckButton(title: short ? "PHR \(v)" : "PHRASE \(v)", active: true, color: Theme.state) { mix.applyPhraseAnchor(d) }
                    .help(String(localized: "Phrasen-Anker: Strukturwechsel liegen \(n) Beats neben den 8-Takt-Grenzen – Klick verschiebt den Anker (Sicherheit \(String(format: "%.2f", m.confidence)))"))
            }
        }
    }
}

/// Hotcues über die ganze Breite, rechts manueller Loop (IN / OUT / RE)
struct CueRow: View {
    @Environment(MixModel.self) private var mix
    let d: Int

    struct Model: Equatable { var colors: [Color?] = [], inArmed = false }

    var body: some View {
        let s = mix.deck(d), prefs = mix.prefs
        let colors = (0..<8).map { n in s.hotcues[n].map { Theme.cueColor($0, deck: s, prefs: prefs) } }
        Content(d: d, m: Model(colors: colors, inArmed: s.loopIn != nil && !s.loopActive)).equatable()
    }

    struct Content: View, Equatable {
        @Environment(MixModel.self) private var mix
        let d: Int
        let m: Model
        static func == (a: Self, b: Self) -> Bool { a.d == b.d && a.m == b.m }

        var body: some View {
            HStack(spacing: 3) {
                ForEach(0..<8, id: \.self) { n in
                    let c = m.colors[n]
                    DeckButton(title: "\(n + 1)", active: c != nil, color: c ?? .gray, fill: true) {
                        mix.hotcue(d, n, delete: NSEvent.modifierFlags.contains(.option))
                    }
                    .help("Klick: springen/setzen · ⌥-Klick: löschen")
                }
                Divider().frame(height: 14)
                DeckButton(title: "IN", active: m.inArmed, color: Theme.state) { mix.setLoopIn(d) }
                DeckButton(title: "OUT") { mix.setLoopOut(d) }
                DeckButton(title: "RE") { mix.reloop(d) }
            }
        }
    }
}

/// Loopgrößen über die ganze Breite: gewählte Größe rot (auch vom Encoder), LOOP = an/aus.
/// Klick auf eine Größe wählt sie; läuft ein Loop, wird er auf die neue Größe gestellt.
struct LoopRow: View {
    @Environment(MixModel.self) private var mix
    let d: Int

    struct Model: Equatable { var active = false, size = 4.0 }

    var body: some View {
        let s = mix.deck(d)
        Content(d: d, m: Model(active: s.loopActive, size: s.loopSize)).equatable()
    }

    struct Content: View, Equatable {
        @Environment(MixModel.self) private var mix
        let d: Int
        let m: Model
        static func == (a: Self, b: Self) -> Bool { a.d == b.d && a.m == b.m }

        var body: some View {
            HStack(spacing: 3) {
                DeckButton(title: "LOOP", active: m.active, color: Theme.state, width: 30) { mix.autoLoop(d) }
                ForEach(BeatSizes.loop, id: \.self) { s in
                    let selected = DeckView.same(m.size, s)
                    DeckButton(title: BeatSizes.label(s), active: selected, color: Theme.state, fill: true) {
                        let deck = mix.deck(d)
                        if deck.loopActive { if !DeckView.same(deck.loopSize, s) { mix.autoLoop(d, size: s) } }
                        else { mix.core.setLoopSize(d, s); mix.pull() }
                    }
                }
            }
        }
    }
}

/// Beatjump-Größen über die ganze Breite: gewählte Größe rot (auch über Flux + Pads / Encoder), ◀◀ ▶▶ springen
struct JumpRow: View {
    @Environment(MixModel.self) private var mix
    let d: Int

    var body: some View { Content(d: d, size: mix.deck(d).jumpSize).equatable() }

    struct Content: View, Equatable {
        @Environment(MixModel.self) private var mix
        let d: Int
        let size: Double
        static func == (a: Self, b: Self) -> Bool { a.d == b.d && a.size == b.size }

        var body: some View {
            HStack(spacing: 3) {
                DeckButton(title: "◀◀", width: 30) { mix.beatjump(d, beats: -mix.deck(d).jumpSize) }
                ForEach(BeatSizes.jump, id: \.self) { s in
                    DeckButton(title: BeatSizes.label(s), active: DeckView.same(size, s), color: Theme.state, fill: true) {
                        mix.setJumpSize(d, s)
                    }
                }
                DeckButton(title: "▶▶", width: 30) { mix.beatjump(d, beats: mix.deck(d).jumpSize) }
            }
        }
    }
}

/// Laufzeit / Restzeit mit Track-End-Warnung
struct TimeReadout: View, Equatable {
    @Environment(MixModel.self) private var mix
    let d: Int
    let m: Model

    struct Model: Equatable { var hasTrack = false, duration = 0.0, playing = false, grid: BeatGrid?, warnAt = 0.0 }
    static func == (a: Self, b: Self) -> Bool { a.d == b.d && a.m == b.m }

    var body: some View {
        let m = m
        LiveCanvas(fps: 10, running: m.hasTrack) { [mix, d] _, size in
            let pos = mix.position(d)
            let remain = max(0, m.duration - pos)
            let warn = m.playing && m.warnAt > 0 && remain < m.warnAt && m.duration > 0
            let blink = Int(Date().timeIntervalSince1970 * 2) % 2 == 0
            CG.text("-" + Theme.time(remain), size: 13, color: warn && blink ? CG.stateNS : CG.boneNS, rightAt: size.width, y: 0)
            if let g = m.grid {
                let bb = g.barBeat(at: pos)
                CG.text("\(bb.bar).\(bb.beat)", size: 10, weight: "Regular", color: CG.mutedNS, rightAt: size.width, y: 17)
            }
        }
        .frame(width: 66, height: 31)
    }
}

/// „Code“ über dem Deck: Takt in der eigenen Phrase und Abstand zum Bar-Zähler.
/// Lila = im Code, rot = verschoben (Takte bzw. Beats), grau = Deck steht oder kein Zähler.
struct CodeReadout: View, Equatable {
    @Environment(MixModel.self) private var mix
    let d: Int
    let m: Model

    struct Model: Equatable { var hasTrack = false, playing = false, bars = 16 }
    static func == (a: Self, b: Self) -> Bool { a.d == b.d && a.m == b.m }

    var body: some View {
        let m = m
        LiveCanvas(fps: 10, running: m.hasTrack) { [mix, d] _, size in
            let muted = CG.mutedNS, lila = CG.secondaryNS
            guard m.hasTrack, let c = mix.phraseCode(d) else {
                CG.text("—", size: 13, color: muted, rightAt: size.width, y: 0)
                return
            }
            let live = m.playing && c.offsetBeats != nil
            let top: NSColor = !live ? muted : c.aligned ? lila : CG.boneNS
            CG.text("\(c.bar)/\(c.phraseBars)", size: 13, color: top, rightAt: size.width, y: 0)
            let (s, col): (String, NSColor) = !live ? ("CODE", muted)
                : c.aligned ? ("◆ CODE", lila) : (c.offsetLabel ?? "", CG.stateNS)
            CG.text(s, size: 10, weight: "Regular", color: col, rightAt: size.width, y: 17)
        }
        .frame(width: 62, height: 31)
        .help(String(localized: "Code: Takt in der \(m.bars)-Takt-Phrase des Tracks, Abstand zum Bar-Zähler"))
    }
}

/// Tonart über dem Deck: Key des Tracks, daneben der hörbare Key (rot), sobald er abweicht,
/// darunter die Abweichung in Halbtönen (Keylock aus: aus dem Tempo, Keylock an: aus dem Key-Shift)
struct KeyReadout: View, Equatable {
    let m: Model

    struct Model: Equatable {
        var key: String?, shifted = "", deviation = 0.0
        init() {}
        init(track: Track?, deviation dev: Double) {
            key = track?.openKey
            deviation = dev
            if let track, abs(dev) >= 0.05 { shifted = track.openKey(shiftedBy: Int(dev.rounded())) }
        }
        var off: Bool { key != nil && abs(deviation) >= 0.05 }
    }

    var body: some View {
        let off = m.off
        VStack(alignment: .trailing, spacing: 0) {
            HStack(spacing: 3) {
                Text(m.key ?? "").font(Theme.mono(13, .semibold))
                    .foregroundStyle(off ? Color.secondary : Theme.bone)
                if off {
                    Text("→").font(Theme.mono(10)).foregroundStyle(.secondary)
                    Text(m.shifted).font(Theme.mono(13, .semibold))
                        .foregroundStyle(Theme.state)
                }
            }
            Text(m.key == nil ? " " : String(format: "%+.2f", m.deviation)).font(Theme.mono(10))
                .foregroundStyle(off ? Theme.state : Color.secondary)
                .help(String(localized: "Abweichung von der Tonart des Tracks in Halbtönen"))
        }
    }
}

/// Phasenanzeige gegenüber dem Master
struct PhaseMeter: View, Equatable {
    @Environment(MixModel.self) private var mix
    let d: Int
    let active: Bool
    static func == (a: Self, b: Self) -> Bool { a.d == b.d && a.active == b.active }

    var body: some View {
        let active = active
        LiveCanvas(fps: 20, running: active) { [mix, d] ctx, size in
            let w = size.width, h = size.height
            ctx.setFillColor(CG.void); ctx.fill(CGRect(origin: .zero, size: size))
            ctx.setFillColor(CG.muted); ctx.fill(CGRect(x: w / 2 - 0.5, y: 0, width: 1, height: h))
            guard active, let e = mix.phaseError(d) else { return }
            let bw = max(2, abs(e) * w)
            ctx.setFillColor(abs(e) < 0.02 ? CG.bone : CG.state)
            ctx.fill(CGRect(x: w / 2 + e * w / 2 - bw / 2, y: 0, width: bw, height: h))
        }
    }
}

/// Großer Phasen-Anzeiger unter der Wellenform: Abstand zum Master in Beats, Mitte = synchron
struct PhaseBar: View {
    @Environment(MixModel.self) private var mix
    let d: Int

    var body: some View {
        Content(d: d, active: mix.deck(d).playing && (mix.clockMaster || mix.effectiveMaster != nil)).equatable()
    }

    struct Content: View, Equatable {
        @Environment(MixModel.self) private var mix
        let d: Int
        let active: Bool
        static func == (a: Self, b: Self) -> Bool { a.d == b.d && a.active == b.active }

        var body: some View {
            let active = active
            LiveCanvas(fps: 30, running: active) { [mix, d] ctx, size in
                let w = size.width, h = size.height
                ctx.setFillColor(CG.void); ctx.fill(CGRect(origin: .zero, size: size))
                ctx.setFillColor(CG.muted); ctx.fill(CGRect(x: w / 2 - 0.5, y: 0, width: 1, height: h))
                ctx.setFillColor(CG.hairline)
                for q in [0.25, 0.75] { ctx.fill(CGRect(x: w * q, y: h / 2, width: 1, height: h / 2)) }
                guard active, let e = mix.phaseError(d) else { return }
                let x = w / 2 + CGFloat(e) * w
                ctx.setFillColor(abs(e) < 0.02 ? CG.bone : CG.state)
                ctx.fill(CGRect(x: min(w / 2, x), y: 1, width: max(2, abs(x - w / 2)), height: h - 2))
            }
            .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
        }
    }
}

/// Senkrechter Tempo-Fader rechts am Deck, mit Bereich, Reset und Pitch-Bend
struct TempoColumn: View {
    @Environment(MixModel.self) private var mix
    let d: Int

    struct Model: Equatable { var range = 8.0, pct = 0.0, sync = false, master = false }

    var body: some View {
        let s = mix.deck(d)
        Content(d: d, m: Model(range: s.tempoRange, pct: s.tempoPct, sync: s.sync, master: mix.effectiveMaster == d)).equatable()
    }

    struct Content: View, Equatable {
        @Environment(MixModel.self) private var mix
        let d: Int
        let m: Model
        static func == (a: Self, b: Self) -> Bool { a.d == b.d && a.m == b.m }

        var body: some View {
            VStack(spacing: 3) {
                RangeMenu(d: d, range: m.range).equatable()
                GeometryReader { geo in
                    let h = geo.size.height
                    let f = (m.pct / m.range + 1) / 2   // unten = schneller
                    ZStack(alignment: .top) {
                        Rectangle().fill(Theme.void).frame(width: 4).overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
                        Rectangle().fill(Theme.muted).frame(width: 14, height: 1).offset(y: h / 2)
                        Rectangle().fill(m.sync ? Theme.secondary : Theme.bone)
                            .frame(width: geo.size.width, height: 8)
                            .offset(y: (h - 8) * CGFloat(f))
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                        guard !(m.sync && !m.master) else { return }
                        let v = max(0, min(1, g.location.y / h)) * 2 - 1
                        mix.setTempo(d, v * m.range)
                    })
                    .onTapGesture(count: 2) { mix.setTempo(d, 0) }
                }
                .frame(width: 22)
                HStack(spacing: 1) {
                    PressButton(title: "‹", width: 8, down: { mix.bend(d, -1) }, up: { mix.bend(d, 0) })
                    PressButton(title: "›", width: 8, down: { mix.bend(d, 1) }, up: { mix.bend(d, 0) })
                }
                DeckButton(title: "0", width: 10) { mix.setTempo(d, 0) }.help("Tempo zurücksetzen")
            }
            .frame(width: 34)
        }
    }

    /// Bereichs-Menü eigene Ansicht: Tempo ziehen baut das Menü nicht neu
    struct RangeMenu: View, Equatable {
        @Environment(MixModel.self) private var mix
        let d: Int
        let range: Double
        static func == (a: Self, b: Self) -> Bool { a.d == b.d && a.range == b.range }

        var body: some View {
            Menu(String(format: "±%g", range)) {
                ForEach([6.0, 8, 10, 16, 50, 100], id: \.self) { r in Button(String(format: "±%g %%", r)) { mix.setTempoRange(d, r) } }
            }
            .menuStyle(.borderlessButton).font(Theme.mono(9)).fixedSize()
        }
    }
}

/// Nur Selbsttest: MIX741_SHOT=deck:<pfad.png> rendert Deck A (Track geladen, Loop 8, Beatjump 4) ohne Fenster auf dem
/// Bildschirm als PNG in zwei Größen (<pfad>-640x300.png Loop aus, <pfad>-480x260.png Loop an) und beendet sich.
@MainActor
enum DeckShot {
    static func runIfRequested() {
        guard Session.isSelfTest, let spec = ProcessInfo.processInfo.environment["MIX741_SHOT"], spec.hasPrefix("deck:") else { return }
        var base = String(spec.dropFirst(5))
        if base.hasSuffix(".png") { base.removeLast(4) }
        NSApplication.shared.setActivationPolicy(.prohibited)   // kein Dock-Symbol, kein Fokuswechsel
        let mix = MixModel()
        mix.engine.stop()   // kein Ton, Gerät sofort wieder frei
        var t = Track(key: "shot", path: "/dev/null")
        t.title = "Deck Size Shot"; t.artist = "MINOS-741"; t.bpm = 128; t.musicalKey = 9; t.duration = 300
        let cues = [Cue(name: "", kind: .cue, startMs: 1000, lengthMs: 0, hotcue: 0),
                    Cue(name: "", kind: .cue, startMs: 30000, lengthMs: 0, hotcue: 1),
                    Cue(name: "", kind: .loop, startMs: 60000, lengthMs: 3750, hotcue: 3)]
        var paths: [String] = []
        for (w, h, loop) in [(640.0, 300.0, false), (480.0, 260.0, true)] {
            mix.updateDeck(0) {
                $0.track = t; $0.duration = 300; $0.grid = BeatGrid(anchor: 1, bpm: 128)
                $0.phraseTarget = 1 - 60.0 / 128   // Phrasen-Vorschlag −1 (roter PHRASE-Knopf in der Grid-Zeile)
                $0.hotcues = Dictionary(uniqueKeysWithValues: cues.map { ($0.hotcue, $0) })
                $0.loopSize = 8; $0.jumpSize = 4; $0.loopActive = loop
            }
            let path = "\(base)-\(Int(w))x\(Int(h)).png"
            render(mix: mix, size: CGSize(width: w, height: h), to: path)
            paths.append(path)
        }
        print("[shot] " + paths.joined(separator: " "))
        fflush(stdout)
        exit(0)
    }

    private static func render(mix: MixModel, size: CGSize, to path: String) {
        let root = DeckView(d: 0)
            .environment(mix)
            .environment(WaveformCache())
            .frame(width: size.width, height: size.height)
            .background(Theme.background)
            .foregroundStyle(Theme.bone)
            .tint(Theme.state)
            .preferredColorScheme(.dark)
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(origin: .zero, size: size)
        // Fenster nur als Zeichenfläche, wird nie angezeigt
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
