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
        VStack(alignment: .leading, spacing: 4) {
            header(deck)
            WaveformView(d: d)
                .frame(minHeight: mix.prefs.ui.waveformHeight, maxHeight: .infinity)
            OverviewView(d: d)
                .frame(height: 18)
            transportRow(deck)
            cueLoopRow(deck)
        }
        .padding(6)
        .frame(maxHeight: .infinity)
        .background(Rectangle().fill(focused ? Theme.deckFocused : Theme.deck))
        .overlay(Rectangle().stroke(focused ? Theme.bone.opacity(0.5) : Theme.hairline, lineWidth: 1))
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
            PressButton(title: "‹", width: 14, down: { mix.bend(d, -1) }, up: { mix.bend(d, 0) })
            Slider(value: Binding(get: { deck.tempoPct }, set: { mix.setTempo(d, $0) }),
                   in: -deck.tempoRange...deck.tempoRange)
                .controlSize(.mini)
                .frame(minWidth: 30)
                .disabled(deck.sync && mix.effectiveMaster != d)
            PressButton(title: "›", width: 14, down: { mix.bend(d, 1) }, up: { mix.bend(d, 0) })
            Menu(String(format: "±%g", deck.tempoRange)) {
                ForEach([6.0, 8, 10, 16, 50, 100], id: \.self) { r in Button(String(format: "±%g %%", r)) { mix.setTempoRange(d, r) } }
                Divider()
                Button("Tempo zurücksetzen") { mix.setTempo(d, 0) }
            }
            .menuStyle(.borderlessButton)
            .font(Theme.mono(10))
            .fixedSize()
        }
    }

    private func cueLoopRow(_ deck: DeckState) -> some View {
        HStack(spacing: 3) {
            ForEach(0..<8, id: \.self) { n in
                let c = deck.hotcues[n]
                DeckButton(title: "\(n + 1)", active: c != nil,
                           color: c.map { Theme.cueColor($0.kind, prefs: mix.prefs) } ?? .gray, width: 14) {
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
        TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
            let pos = mix.position(d)
            let remain = max(0, deck.duration - pos)
            let warn = deck.playing && warnAt > 0 && remain < warnAt && deck.duration > 0
            let blink = Int(ctx.date.timeIntervalSince1970 * 2) % 2 == 0
            VStack(alignment: .trailing, spacing: 0) {
                Text("-" + Theme.time(remain))
                    .font(Theme.mono(13, .semibold))
                    .foregroundStyle(warn && blink ? Theme.state : Theme.bone)
                if let g = deck.grid {
                    let bb = g.barBeat(at: pos)
                    Text("\(bb.bar).\(bb.beat)").font(Theme.mono(10)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Phasenanzeige gegenüber dem Master
struct PhaseMeter: View {
    @Environment(MixModel.self) private var mix
    let d: Int

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !mix.deck(d).sync && mix.effectiveMaster == nil)) { _ in
            GeometryReader { geo in
                let e = mix.phaseError(d)
                ZStack {
                    Rectangle().fill(Theme.void)
                    Rectangle().fill(Theme.muted).frame(width: 1)
                    if let e {
                        Rectangle().fill(abs(e) < 0.02 ? Theme.bone : Theme.state)
                            .frame(width: max(2, abs(e) * geo.size.width))
                            .offset(x: e * geo.size.width / 2)
                    }
                }
            }
        }
    }
}
