import SwiftUI
import AppKit
import MixCore
import MixEngine

struct DeckView: View {
    @Environment(MixModel.self) private var mix
    let d: Int

    var body: some View {
        let deck = mix.deck(d)
        let focused = mix.focusedDeck == d
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 4) {
                header(deck)
                WaveformView(d: d)
                    .frame(minHeight: mix.prefs.ui.waveformHeight, maxHeight: .infinity)
                PhaseBar(d: d).frame(height: 8)
                OverviewView(d: d)
                    .frame(height: 18)
                transportRow(deck)
                cueRow(deck)
                loopRow(deck)
                jumpRow(deck)
                if mix.prefs.ui.showGridTools { gridRow(deck) }
            }
            TempoColumn(d: d)
        }
        .padding(6)
        .frame(maxHeight: .infinity)
        .background(Rectangle().fill(focused ? Theme.deckFocused : Theme.deck))
        .overlay(Rectangle().stroke(mix.effectiveMaster == d ? Theme.gold : (focused ? Theme.bone.opacity(0.5) : Theme.hairline),
                                    lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { mix.focusedDeck = d }
    }

    private func header(_ deck: DeckState) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Text(deckLetters[d]).font(Theme.label(22, .bold)).foregroundStyle(deck.playing ? Theme.state : Theme.bone)
            VStack(alignment: .leading, spacing: 0) {
                Text(deck.loading ? "Lade …" : (deck.track?.title ?? "—"))
                    .font(Theme.mono(13, .semibold)).lineLimit(1)
                Text(deck.error ?? deck.track?.artist ?? String(localized: "Kein Track geladen"))
                    .font(Theme.mono(11)).foregroundStyle(deck.error == nil ? Color.secondary : Color.red).lineLimit(1)
            }
            Spacer(minLength: 4)
            if !mix.prefs.ui.showMixer {
                // ohne Mixer-Ansicht: FX-Zuweisung direkt am Deck
                // FX-Zuweisung am Kanal: 1 2 (3 4)
                let n = mix.prefs.ui.fxUnitCount
                VStack(spacing: 2) {
                    ForEach(0..<(n == 4 ? 2 : 1), id: \.self) { row in
                        HStack(spacing: 2) {
                            ForEach([0, 1].map { row * 2 + $0 }, id: \.self) { u in
                                DeckButton(title: "FX\(u + 1)", active: deck.fxAssign[u], color: Theme.state) { mix.toggleFXAssign(d, u) }
                            }
                        }
                    }
                }
            }
            TimeReadout(d: d)
            VStack(alignment: .trailing, spacing: 0) {
                Text(String(format: "%.2f", deck.bpm)).font(Theme.mono(15, .bold))
                Text(String(format: "%+.2f%%", deck.tempoPct)).font(Theme.mono(10)).foregroundStyle(.secondary)
            }
            CodeReadout(d: d)
            VStack(alignment: .trailing, spacing: 0) {
                KeyReadout(d: d)
                PhaseMeter(d: d).frame(width: 44, height: 6)
            }
            .frame(minWidth: 46)
        }
    }

    private func transportRow(_ deck: DeckState) -> some View {
        HStack(spacing: 3) {
            DeckButton(title: "CUP", width: 26) { mix.cup(d) }
            PressButton(title: "CUE", active: deck.cueHeld, width: 30, down: { mix.cueDown(d) }, up: { mix.cueUp(d) })
            DeckButton(title: deck.playing ? "❚❚" : "▶", active: deck.playing, color: Theme.state, width: 30) { mix.togglePlay(d) }
            Divider().frame(height: 14)
            DeckButton(title: "SYNC", active: deck.sync, color: Theme.state) { mix.toggleSync(d) }
            DeckButton(title: "MASTER", active: mix.effectiveMaster == d,
                       color: Theme.secondary) { mix.toggleMaster(d) }
            DeckButton(title: "KEY", active: deck.keylock, color: Theme.state) { mix.toggleKeylock(d) }
            DeckButton(title: "−") { mix.shiftKey(d, -1) }
            DeckButton(title: "+") { mix.shiftKey(d, 1) }
            DeckButton(title: "REV", active: deck.reverse, color: Theme.state) { mix.toggleReverse(d) }
            DeckButton(title: "FLUX", active: deck.flux, color: Theme.state) { mix.toggleFlux(d) }
            Spacer(minLength: 2)
        }
    }

    /// Grid-Werkzeuge: verschieben, BPM, ×2/÷2, Marker setzen, zurücksetzen
    private func gridRow(_ deck: DeckState) -> some View {
        HStack(spacing: 3) {
            Text("GRID").font(Theme.label(9, .bold)).foregroundStyle(Theme.muted).frame(width: 30, alignment: .leading)
            DeckButton(title: "◂◂") { mix.shiftGrid(d, ms: -10) }.help("Grid 10 ms früher")
            DeckButton(title: "◂") { mix.shiftGrid(d, ms: -1) }.help("Grid 1 ms früher")
            DeckButton(title: "▸") { mix.shiftGrid(d, ms: 1) }.help("Grid 1 ms später")
            DeckButton(title: "▸▸") { mix.shiftGrid(d, ms: 10) }.help("Grid 10 ms später")
            Divider().frame(height: 14)
            DeckButton(title: "BPM −") { mix.setGridBPM(d, (deck.grid?.bpm ?? 0) - 0.01) }
            Text(deck.grid.map { String(format: "%.3f", $0.bpm) } ?? "—").font(Theme.mono(10)).frame(width: 52)
            DeckButton(title: "+") { mix.setGridBPM(d, (deck.grid?.bpm ?? 0) + 0.01) }
            DeckButton(title: "÷2") { mix.scaleGridBPM(d, 0.5) }
            DeckButton(title: "×2") { mix.scaleGridBPM(d, 2) }
            Divider().frame(height: 14)
            DeckButton(title: "SET") { mix.setGridAnchorHere(d) }.help("Beat 1 an die aktuelle Position")
            DeckButton(title: "RESET") { mix.resetGrid(d) }.help("Grid aus der Collection")
            // Anker um ganze Beats/Takte: Raster bleibt, nur Takt- und Phrasenzählung wandert; schmale Decks: weniger Knöpfe
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 3) { Divider().frame(height: 14); anchorButtons([-4, -1, 1, 4]); phraseButton(deck, short: false) }
                HStack(spacing: 3) { Divider().frame(height: 14); anchorButtons([-1, 1]); phraseButton(deck, short: true) }
                phraseButton(deck, short: true)
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
    @ViewBuilder private func phraseButton(_ deck: DeckState, short: Bool) -> some View {
        if let n = deck.phraseSuggestion {
            let v = n > 0 ? "+\(n)" : "\u{2212}\(-n)"
            DeckButton(title: short ? "PHR \(v)" : "PHRASE \(v)", active: true, color: Theme.state) { mix.applyPhraseAnchor(d) }
                .help(String(localized: "Phrasen-Anker: Strukturwechsel liegen \(n) Beats neben den 8-Takt-Grenzen – Klick verschiebt den Anker (Sicherheit \(String(format: "%.2f", deck.phraseConfidence)))"))
        }
    }

    /// Hotcues über die ganze Breite, rechts manueller Loop (IN / OUT / RE)
    private func cueRow(_ deck: DeckState) -> some View {
        HStack(spacing: 3) {
            ForEach(0..<8, id: \.self) { n in
                let c = deck.hotcues[n]
                DeckButton(title: "\(n + 1)", active: c != nil,
                           color: c.map { Theme.cueColor($0, deck: deck, prefs: mix.prefs) } ?? .gray, fill: true) {
                    mix.hotcue(d, n, delete: NSEvent.modifierFlags.contains(.option))
                }
                .help("Klick: springen/setzen · ⌥-Klick: löschen")
            }
            Divider().frame(height: 14)
            DeckButton(title: "IN", active: deck.loopIn != nil && !deck.loopActive, color: Theme.state) { mix.setLoopIn(d) }
            DeckButton(title: "OUT") { mix.setLoopOut(d) }
            DeckButton(title: "RE") { mix.reloop(d) }
        }
    }

    /// Loopgrößen über die ganze Breite: gewählte Größe rot (auch vom Encoder), LOOP = an/aus.
    /// Klick auf eine Größe wählt sie; läuft ein Loop, wird er auf die neue Größe gestellt.
    private func loopRow(_ deck: DeckState) -> some View {
        HStack(spacing: 3) {
            DeckButton(title: "LOOP", active: deck.loopActive, color: Theme.state, width: 30) { mix.autoLoop(d) }
            ForEach(BeatSizes.loop, id: \.self) { s in
                let selected = Self.same(deck.loopSize, s)
                DeckButton(title: BeatSizes.label(s), active: selected, color: Theme.state, fill: true) {
                    if deck.loopActive { if !selected { mix.autoLoop(d, size: s) } }
                    else { mix.core.setLoopSize(d, s); mix.pull() }
                }
            }
        }
    }

    /// Beatjump-Größen über die ganze Breite: gewählte Größe rot (auch über Flux + Pads / Encoder), ◀◀ ▶▶ springen
    private func jumpRow(_ deck: DeckState) -> some View {
        HStack(spacing: 3) {
            DeckButton(title: "◀◀", width: 30) { mix.beatjump(d, beats: -deck.jumpSize) }
            ForEach(BeatSizes.jump, id: \.self) { s in
                DeckButton(title: BeatSizes.label(s), active: Self.same(deck.jumpSize, s), color: Theme.state, fill: true) {
                    mix.setJumpSize(d, s)
                }
            }
            DeckButton(title: "▶▶", width: 30) { mix.beatjump(d, beats: deck.jumpSize) }
        }
    }

    private static func same(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }
}

/// Laufzeit / Restzeit mit Track-End-Warnung
struct TimeReadout: View {
    @Environment(MixModel.self) private var mix
    let d: Int

    var body: some View {
        let deck = mix.deck(d)
        let warnAt = mix.prefs.engine.trackEndWarning
        LiveCanvas(fps: 10, running: deck.track != nil) { [mix, d] _, size in
            let pos = mix.position(d)
            let remain = max(0, deck.duration - pos)
            let warn = deck.playing && warnAt > 0 && remain < warnAt && deck.duration > 0
            let blink = Int(Date().timeIntervalSince1970 * 2) % 2 == 0
            CG.text("-" + Theme.time(remain), size: 13, color: NSColor(warn && blink ? Theme.state : Theme.bone), rightAt: size.width, y: 0)
            if let g = deck.grid {
                let bb = g.barBeat(at: pos)
                CG.text("\(bb.bar).\(bb.beat)", size: 10, weight: "Regular", color: NSColor(Theme.muted), rightAt: size.width, y: 17)
            }
        }
        .frame(width: 66, height: 31)
    }
}

/// „Code“ über dem Deck: Takt in der eigenen Phrase und Abstand zum Bar-Zähler.
/// Lila = im Code, rot = verschoben (Takte bzw. Beats), grau = Deck steht oder kein Zähler.
struct CodeReadout: View {
    @Environment(MixModel.self) private var mix
    let d: Int

    var body: some View {
        let deck = mix.deck(d)
        let bars = max(4, mix.prefs.ui.phraseBeats) / 4
        LiveCanvas(fps: 10, running: deck.track != nil) { [mix, d] _, size in
            let muted = NSColor(Theme.muted), lila = NSColor(Theme.secondary)
            guard deck.track != nil, let c = mix.phraseCode(d) else {
                CG.text("—", size: 13, color: muted, rightAt: size.width, y: 0)
                return
            }
            let live = deck.playing && c.offsetBeats != nil
            let top: NSColor = !live ? muted : c.aligned ? lila : NSColor(Theme.bone)
            CG.text("\(c.bar)/\(c.phraseBars)", size: 13, color: top, rightAt: size.width, y: 0)
            let (s, col): (String, NSColor) = !live ? ("CODE", muted)
                : c.aligned ? ("◆ CODE", lila) : (c.offsetLabel ?? "", NSColor(Theme.state))
            CG.text(s, size: 10, weight: "Regular", color: col, rightAt: size.width, y: 17)
        }
        .frame(width: 62, height: 31)
        .help(String(localized: "Code: Takt in der \(bars)-Takt-Phrase des Tracks, Abstand zum Bar-Zähler"))
    }
}

/// Tonart über dem Deck: Key des Tracks, daneben der hörbare Key (rot), sobald er abweicht,
/// darunter die Abweichung in Halbtönen (Keylock aus: aus dem Tempo, Keylock an: aus dem Key-Shift)
struct KeyReadout: View {
    @Environment(MixModel.self) private var mix
    let d: Int

    var body: some View {
        let track = mix.deck(d).track
        let dev = mix.keyDeviation(d)
        let off = track != nil && abs(dev) >= 0.05
        VStack(alignment: .trailing, spacing: 0) {
            HStack(spacing: 3) {
                Text(track?.openKey ?? "").font(Theme.mono(13, .semibold))
                    .foregroundStyle(off ? Color.secondary : Theme.bone)
                if off, let track {
                    Text("→").font(Theme.mono(10)).foregroundStyle(.secondary)
                    Text(track.openKey(shiftedBy: Int(dev.rounded()))).font(Theme.mono(13, .semibold))
                        .foregroundStyle(Theme.state)
                }
            }
            Text(track == nil ? " " : String(format: "%+.2f", dev)).font(Theme.mono(10))
                .foregroundStyle(off ? Theme.state : Color.secondary)
                .help(String(localized: "Abweichung von der Tonart des Tracks in Halbtönen"))
        }
    }
}

/// Phasenanzeige gegenüber dem Master
struct PhaseMeter: View {
    @Environment(MixModel.self) private var mix
    let d: Int

    var body: some View {
        let active = mix.deck(d).playing && (mix.clockMaster || mix.effectiveMaster != nil)
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
        let active = mix.deck(d).playing && (mix.clockMaster || mix.effectiveMaster != nil)
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

/// Senkrechter Tempo-Fader rechts am Deck, mit Bereich, Reset und Pitch-Bend
struct TempoColumn: View {
    @Environment(MixModel.self) private var mix
    let d: Int

    var body: some View {
        let deck = mix.deck(d)
        VStack(spacing: 3) {
            Menu(String(format: "±%g", deck.tempoRange)) {
                ForEach([6.0, 8, 10, 16, 50, 100], id: \.self) { r in Button(String(format: "±%g %%", r)) { mix.setTempoRange(d, r) } }
            }
            .menuStyle(.borderlessButton).font(Theme.mono(9)).fixedSize()
            GeometryReader { geo in
                let h = geo.size.height
                let f = (deck.tempoPct / deck.tempoRange + 1) / 2   // unten = schneller
                ZStack(alignment: .top) {
                    Rectangle().fill(Theme.void).frame(width: 4).overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
                    Rectangle().fill(Theme.muted).frame(width: 14, height: 1).offset(y: h / 2)
                    Rectangle().fill(deck.sync ? Theme.secondary : Theme.bone)
                        .frame(width: geo.size.width, height: 8)
                        .offset(y: (h - 8) * CGFloat(f))
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    guard !(deck.sync && mix.effectiveMaster != d) else { return }
                    let v = max(0, min(1, g.location.y / h)) * 2 - 1
                    mix.setTempo(d, v * deck.tempoRange)
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
