import SwiftUI
import MixCore
import MixEngine

/// Interner Mixer: Kanäle in Traktor-Reihenfolge C A B D, Crossfader. Im Extern-Modus nur Gain/Filter/FX.
struct MixerView: View {
    @Environment(MixModel.self) private var mix

    var body: some View {
        let order = mix.showFourDecks ? [2, 0, 1, 3] : [0, 1]
        VStack(spacing: 6) {
            HStack(alignment: .top, spacing: 4) {
                ForEach(order, id: \.self) { ChannelStrip(d: $0) }
            }
            if mix.mixerMode == .internalMixer {
                HStack(spacing: 4) {
                    Text("A").font(Theme.label(9, .bold)).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { mix.state.crossfader }, set: { mix.setCrossfader($0) }), in: -1...1)
                        .controlSize(.mini)
                    Text("B").font(Theme.label(9, .bold)).foregroundStyle(.secondary)
                }
                .onTapGesture(count: 2) { mix.setCrossfader(0) }
            } else {
                Text("EXTERN").font(Theme.label(9, .heavy)).foregroundStyle(.secondary)
            }
        }
        .padding(6)
        .background(Rectangle().fill(Theme.deck))
        .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
    }
}

struct ChannelStrip: View {
    @Environment(MixModel.self) private var mix
    let d: Int

    var body: some View {
        let deck = mix.deck(d)
        VStack(spacing: 3) {
            Text(deckLetters[d]).font(Theme.label(12, .heavy))
                .foregroundStyle(mix.focusedDeck == d ? Theme.bone : Theme.muted)
            knob(\.gainDb, -12...12, "GAIN")
            if mix.mixerMode == .internalMixer {
                knob(\.eqHigh, -26...12, "HI")
                knob(\.eqMid, -26...12, "MID")
                knob(\.eqLow, -26...12, "LO")
            }
            knob(\.filter, -1...1, "FILTER", color: Theme.state)
            HStack(spacing: 2) {
                ForEach(0..<mix.prefs.ui.fxUnitCount, id: \.self) { u in
                    DeckButton(title: "\(u + 1)", active: deck.fxAssign[u], color: Theme.state) { mix.toggleFXAssign(d, u) }
                }
            }
            if mix.mixerMode == .internalMixer {
                LevelFader(value: Binding(get: { deck.fader }, set: { v in mix.updateDeck(d) { $0.fader = v } }))
                    .frame(width: 22, height: 84)
                Picker("", selection: Binding(get: { deck.xf }, set: { v in mix.updateDeck(d) { $0.xf = v } })) {
                    ForEach(XFAssign.allCases, id: \.self) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                .pickerStyle(.segmented)
                .controlSize(.mini)
                .labelsHidden()
                .frame(width: 54)
            } else {
                let p = mix.deckPairs[d]
                Text("USB\n\(p + 1)/\(p + 2)")
                    .font(Theme.mono(10, .bold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
        .frame(width: 58)
    }

    private func knob(_ kp: WritableKeyPath<DeckState, Double>, _ r: ClosedRange<Double>, _ label: String,
                      color: Color = Theme.accent) -> some View {
        Knob(value: Binding(get: { mix.deck(d)[keyPath: kp] }, set: { v in mix.updateDeck(d) { $0[keyPath: kp] = v } }),
             range: r, defaultValue: 0, bipolar: true, label: label, color: color, size: 26)
    }
}

/// Senkrechter Kanalfader
struct LevelFader: View {
    @Binding var value: Double

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            ZStack(alignment: .bottom) {
                Rectangle().fill(Theme.void).frame(width: 4).overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
                Rectangle().fill(Theme.bone.opacity(0.5)).frame(width: 4, height: h * value)
                Rectangle().fill(Theme.bone)
                    .frame(width: geo.size.width, height: 8)
                    .offset(y: -(h - 8) * value)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                value = max(0, min(1, 1 - g.location.y / h))
            })
            .onTapGesture(count: 2) { value = 1 }
        }
    }
}

/// FX-Unit im Traktor-Gruppenmodus: Dry/Wet + 3 Slots (Filter · Delay · Reverb), je Knopf + Taste.
/// Am X1: D/W-Regler, Regler 1–3 = Stärke, Tasten 1–3 = an/aus.
struct FXUnitView: View {
    @Environment(MixModel.self) private var mix
    let u: Int

    var body: some View {
        let fx = mix.state.fx[u]
        HStack(spacing: 8) {
            VStack(spacing: 2) {
                Text("FX \(u + 1)").font(Theme.label(11, .heavy)).foregroundStyle(fx.anyOn ? Theme.state : Theme.muted)
                DeckButton(title: fx.single ? "SNGL" : "GRP", active: fx.single, color: Theme.secondary, width: 32) {
                    mix.updateFX(u) { $0.single.toggle() }
                }
                .help("Gruppe (3 Effekte) oder Single (1 Effekt, 3 Parameter)")
            }
            Knob(value: Binding(get: { mix.state.fx[u].dryWet }, set: { v in mix.updateFX(u) { $0.dryWet = v } }),
                 range: 0...1, defaultValue: 1, label: "D/W", color: Theme.state, size: 24)
            if fx.single { single(fx) } else { group(fx) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Rectangle().fill(Theme.deck))
        .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
    }

    @ViewBuilder private func group(_ fx: FXUnitState) -> some View {
        ForEach(0..<3, id: \.self) { i in
            VStack(spacing: 2) {
                Knob(value: Binding(get: { mix.state.fx[u].slots[i].amount },
                                    set: { v in mix.updateFX(u) { $0.slots[i].amount = v } }),
                     range: 0...1, defaultValue: 0.5, bipolar: i == 0, label: FXUnitState.slotNames[i],
                     color: Theme.state, size: 24)
                DeckButton(title: "ON", active: fx.slots[i].on, color: Theme.state, width: 22) {
                    mix.updateFX(u) { $0.slots[i].on.toggle() }
                }
            }
        }
        Menu(BeatSizes.label(MixEngine.delayBeats[fx.delayIndex])) {
            ForEach(MixEngine.delayBeats.indices, id: \.self) { i in
                Button("Delay \(BeatSizes.label(MixEngine.delayBeats[i])) Beat") { mix.updateFX(u) { $0.delayIndex = i } }
            }
        }
        .menuStyle(.borderlessButton)
        .font(Theme.label(10, .bold))
        .fixedSize()
        .help("Delay-Zeit in Beats")
        Knob(value: Binding(get: { mix.state.fx[u].reverbSize }, set: { v in mix.updateFX(u) { $0.reverbSize = v } }),
             range: 0...1, defaultValue: 0.6, label: "ROOM", color: Theme.state, size: 20)
    }

    @ViewBuilder private func single(_ fx: FXUnitState) -> some View {
        let effect = FXUnitState.Effect(rawValue: fx.singleType) ?? .delay
        VStack(spacing: 2) {
            Menu(effect.name) {
                ForEach(FXUnitState.Effect.allCases, id: \.self) { e in
                    Button(e.name) { mix.updateFX(u) { $0.singleType = e.rawValue } }
                }
            }
            .menuStyle(.borderlessButton)
            .font(Theme.label(10, .bold))
            .fixedSize()
            DeckButton(title: "ON", active: fx.singleOn, color: Theme.state, width: 30) { mix.updateFX(u) { $0.singleOn.toggle() } }
        }
        ForEach(0..<3, id: \.self) { i in
            Knob(value: Binding(get: { mix.state.fx[u].params[i] }, set: { v in mix.updateFX(u) { $0.params[i] = v } }),
                 range: 0...1, defaultValue: 0.5, bipolar: effect.params[i] == "FILTER" || effect.params[i] == "CUTOFF",
                 label: effect.params[i], color: Theme.state, size: 24)
        }
    }
}

/// Obere Leiste: FX 1 · Master-Clock (wie Traktor) · FX 2
struct TopBar: View {
    @Environment(MixModel.self) private var mix

    var body: some View {
        HStack(spacing: 6) {
            if mix.prefs.ui.showFXUnits {
                FXUnitView(u: 0)
                if mix.prefs.ui.fxUnitCount == 4 { FXUnitView(u: 2) }
            }
            Spacer(minLength: 4)
            MasterClockPanel()
            BarCounter()
            Spacer(minLength: 4)
            if mix.prefs.ui.showFXUnits {
                FXUnitView(u: 1)
                if mix.prefs.ui.fxUnitCount == 4 { FXUnitView(u: 3) }
            }
        }
    }
}

/// Master-Clock: LINK, AUTO/MASTER, Tempo mit −/+ und Tap, Metronom, Snap/Quant, Hauptlautstärke
struct MasterClockPanel: View {
    @Environment(MixModel.self) private var mix
    @State private var dragStart: Double?

    var body: some View {
        let s = mix.state
        HStack(spacing: 6) {
            DeckButton(title: "LINK", active: s.linkEnabled, color: Theme.secondary, width: 30) { mix.toggleLink() }
                .help("Ableton Link: MINOS gibt das Tempo vor")
            VStack(spacing: 2) {
                DeckButton(title: "AUTO", active: !s.clockMaster, width: 40) { mix.setClockMaster(false) }
                    .help("Ein Deck ist Master (automatisch oder per MASTER-Taste)")
                DeckButton(title: "MASTER", active: s.clockMaster, color: Theme.secondary, width: 40) { mix.setClockMaster(true) }
                    .help("Clock ist Master: MINOS gibt das Tempo vor, gesyncte Decks folgen")
            }
            VStack(spacing: 0) {
                Text(String(format: "%.2f", mix.masterBPM))
                    .font(Theme.mono(17, .semibold))
                    .foregroundStyle(s.clockMaster ? Theme.secondary : Theme.bone)
                    .gesture(DragGesture(minimumDistance: 1)
                        .onChanged { g in
                            // ziehen: 1 BPM pro 20 pt; schaltet auf Clock-Master
                            if dragStart == nil { dragStart = mix.masterBPM; mix.setClockMaster(true) }
                            mix.setClockBPM((dragStart ?? 128) - Double(g.translation.height) / 20)
                        }
                        .onEnded { _ in dragStart = nil })
                    .help("ziehen = Tempo ändern")
                Text(s.clockMaster ? "CLOCK" : (mix.effectiveMaster.map { "DECK " + deckLetters[$0] } ?? "KEIN MASTER"))
                    .font(Theme.label(8)).foregroundStyle(Theme.muted)
            }
            .frame(width: 66)
            VStack(spacing: 2) {
                HStack(spacing: 2) {
                    DeckButton(title: "−", width: 12) { mix.setClockMaster(true); mix.nudgeClock(-0.1) }
                    DeckButton(title: "+", width: 12) { mix.setClockMaster(true); mix.nudgeClock(0.1) }
                }
                DeckButton(title: "TAP", width: 34) { mix.tap() }
            }
            Text("│").foregroundStyle(Theme.hairline)
            VStack(spacing: 2) {
                DeckButton(title: "TICK", active: s.metronome, width: 30) { mix.setMetronome(!s.metronome) }
                    .help("Metronom auf dem Beat der Clock")
            }
            Knob(value: Binding(get: { mix.state.metronomeVolume }, set: { mix.setMetronome(mix.state.metronome, volume: $0) }),
                 range: 0...1, defaultValue: 0.5, label: "TICK", size: 20)
            Text("│").foregroundStyle(Theme.hairline)
            VStack(spacing: 2) {
                DeckButton(title: "S", active: mix.prefs.engine.snap, width: 14) { mix.toggleSnap() }
                    .help("Snap: Cues und Loop-Punkte rasten auf den Beat")
                DeckButton(title: "Q", active: mix.prefs.engine.quantize, width: 14) { mix.toggleQuantize() }
                    .help("Quant: Sprünge halten die Beat-Phase")
            }
            Knob(value: Binding(get: { mix.state.masterVolume }, set: { mix.setMasterVolume($0) }), range: 0...1,
                 defaultValue: 0.85, label: "MAIN", size: 24)
            SettingsLink { Text("⚙︎").font(Theme.mono(14)).foregroundStyle(Theme.bone) }
                .buttonStyle(.borderless)
                .help("Einstellungen (⌘,)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Rectangle().fill(Theme.deck))
        .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
    }
}

/// Bar-Zähler neben der Master-Clock: läuft ab dem ersten Play, zeigt die Lage im 4/8/16-Takt-Raster.
/// Doppelklick = neu auf Takt 1.
struct BarCounter: View {
    @Environment(MixModel.self) private var mix

    var body: some View {
        LiveCanvas(fps: 30) { [mix] ctx, size in
            ctx.setFillColor(CG.void); ctx.fill(CGRect(origin: .zero, size: size))
            guard let sb = mix.core.sessionBeat else {
                CG.text(String(localized: "BARS · ab erstem Play"), size: 10, weight: "Regular", color: NSColor(Theme.muted), rightAt: size.width - 6, y: 15)
                return
            }
            let beat = max(0, sb)
            let bar = Int(beat / 4), inBar = Int(beat) % 4
            let frac = beat - beat.rounded(.down)
            let pulse = CGFloat(max(0, 1 - frac * 2.5))
            CG.text("\(bar + 1).\(inBar + 1)", size: 15, weight: "SemiBold", color: NSColor(Theme.bone), rightAt: 46, y: 4)
            let toNext16 = 16 - bar % 16
            CG.text("16 ▸ \(toNext16)", size: 9, weight: "Regular", color: NSColor(toNext16 == 1 ? Theme.state : Theme.muted), rightAt: 46, y: 26)
            let x0: CGFloat = 66, w = size.width - x0 - 4
            for (row, n) in [4, 8, 16].enumerated() {
                let y = 3 + CGFloat(row) * 13, h: CGFloat = 10
                let cw = w / CGFloat(n)
                let cur = bar % n
                for i in 0..<n {
                    let r = CGRect(x: x0 + CGFloat(i) * cw + 1, y: y, width: cw - 2, height: h)
                    let last = cur == n - 1
                    if i < cur {
                        ctx.setFillColor(NSColor(Theme.bone).withAlphaComponent(0.55).cgColor)
                    } else if i == cur {
                        let c = last ? Theme.state : Theme.bone
                        ctx.setFillColor(NSColor(c).withAlphaComponent(0.6 + 0.4 * pulse).cgColor)
                    } else {
                        ctx.setFillColor(CG.hairline)
                    }
                    ctx.fill(r)
                    if i == cur {   // Beats im aktuellen Takt
                        ctx.setFillColor(CG.void)
                        for b in 1..<4 { ctx.fill(CGRect(x: r.minX + r.width * CGFloat(b) / 4, y: r.minY, width: 1, height: r.height)) }
                        ctx.setFillColor(NSColor.black.withAlphaComponent(0.5).cgColor)
                        ctx.fill(CGRect(x: r.minX + r.width * CGFloat(inBar + 1) / 4, y: r.minY, width: r.width * CGFloat(3 - inBar) / 4, height: r.height))
                    }
                }
                CG.text("\(n)", size: 8, weight: "Regular", color: NSColor(Theme.muted), rightAt: x0 - 2 + 0, y: y - 1)
            }
        }
        .frame(width: 300, height: 42)
        .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
        .onTapGesture(count: 2) { mix.core.resetSession() }
        .help("Bar-Zähler: läuft ab dem ersten Play · Doppelklick = neu auf Takt 1")
    }
}
