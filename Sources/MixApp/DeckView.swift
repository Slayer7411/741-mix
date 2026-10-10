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
                cueLoopRow(deck)
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
                Text(deck.error ?? deck.track?.artist ?? "Kein Track geladen")
                    .font(Theme.mono(11)).foregroundStyle(deck.error == nil ? Color.secondary : Color.red).lineLimit(1)
            }
            Spacer(minLength: 4)
            if !mix.prefs.ui.showMixer {
                // ohne Mixer-Ansicht: FX-Zuweisung direkt am Deck
                VStack(spacing: 2) {
                    ForEach(0..<MixEngine.fxUnitCount, id: \.self) { u in
                        DeckButton(title: "FX\(u + 1)", active: deck.fxAssign[u], color: Theme.state) { mix.toggleFXAssign(d, u) }
                    }
                }
            }
            TimeReadout(d: d)
            VStack(alignment: .trailing, spacing: 0) {
                Text(String(format: "%.2f", deck.bpm)).font(Theme.mono(15, .bold))
                Text(String(format: "%+.2f%%", deck.tempoPct)).font(Theme.mono(10)).foregroundStyle(.secondary)
            }
            VStack(alignment: .trailing, spacing: 0) {
                Text(mix.keyText(d)).font(Theme.mono(13, .semibold))
                    .foregroundStyle(Theme.bone)
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

    /// Grid-Werkzeuge wie Traktors GRID-Tab: verschieben, BPM, ×2/÷2, Marker setzen, zurücksetzen
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
            Spacer(minLength: 0)
        }
    }

    private func cueLoopRow(_ deck: DeckState) -> some View {
        HStack(spacing: 3) {
            ForEach(0..<8, id: \.self) { n in
                let c = deck.hotcues[n]
                DeckButton(title: "\(n + 1)", active: c != nil,
                           color: c.map { Theme.cueColor($0, deck: deck, prefs: mix.prefs) } ?? .gray, width: 14) {
                    mix.hotcue(d, n, delete: NSEvent.modifierFlags.contains(.option))
                }
                .help("Klick: springen/setzen · ⌥-Klick: löschen")
            }
            Divider().frame(height: 14)
            DeckButton(title: "IN", active: deck.loopIn != nil && !deck.loopActive, color: Theme.state) { mix.setLoopIn(d) }
            DeckButton(title: "OUT") { mix.setLoopOut(d) }
            DeckButton(title: "◂") { mix.changeLoopSize(d, by: -1) }
            DeckButton(title: BeatSizes.label(deck.loopSize), active: deck.loopActive, color: Theme.state, width: 26) { mix.autoLoop(d) }
            DeckButton(title: "▸") { mix.changeLoopSize(d, by: 1) }
            DeckButton(title: "RE") { mix.reloop(d) }
            Divider().frame(height: 14)
            DeckButton(title: "◀◀") { mix.beatjump(d, beats: -deck.jumpSize) }
            Menu(BeatSizes.label(deck.jumpSize)) {
                ForEach(BeatSizes.jump, id: \.self) { s in Button("Beatjump \(BeatSizes.label(s))") { mix.setJumpSize(d, s) } }
            }
            .menuStyle(.borderlessButton)
            .font(Theme.label(10, .bold))
            .fixedSize()
            DeckButton(title: "▶▶") { mix.beatjump(d, beats: deck.jumpSize) }
            Spacer(minLength: 0)
        }
    }
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

/// Phasenanzeige gegenüber dem Master
struct PhaseMeter: View {
    @Environment(MixModel.self) private var mix
    let d: Int

    var body: some View {
        let active = mix.deck(d).playing && (mix.state.clockMaster || mix.effectiveMaster != nil)
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

/// Großer Phasen-Anzeiger unter der Wellenform (wie Traktor): Abstand zum Master in Beats, Mitte = synchron
struct PhaseBar: View {
    @Environment(MixModel.self) private var mix
    let d: Int

    var body: some View {
        let active = mix.deck(d).playing && (mix.state.clockMaster || mix.effectiveMaster != nil)
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

/// Senkrechter Tempo-Fader rechts am Deck (wie Traktor), mit Bereich, Reset und Pitch-Bend
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
                let f = (deck.tempoPct / deck.tempoRange + 1) / 2   // 0 = schneller oben? Traktor: unten = schneller
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
