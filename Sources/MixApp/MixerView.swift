import SwiftUI
import MixCore
import MixEngine

/// Interner Mixer: Kanäle in der Reihenfolge C A B D, Crossfader. Im Extern-Modus nur Gain/Filter/FX.
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

/// FX-Unit: Gruppe (Filter · Delay · Reverb) oder Single (ein Effekt). D/W, Regler 1–3 und Tasten 1–3 liegen auf
/// zuweisbaren Parametern (Rechtsklick, ⌘, -> MIXER & FX); der Controller geht denselben Weg.
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
            FXKnob(u: u, c: .dryWet)
            if fx.single { single(fx) } else { group(fx) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Rectangle().fill(Theme.deck))
        .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
    }

    /// Regler 1–3 mit Taste darunter
    private var controls: some View {
        ForEach(0..<3, id: \.self) { i in
            VStack(spacing: 2) {
                FXKnob(u: u, c: .knob(i))
                FXButton(u: u, i: i)
            }
        }
    }

    @ViewBuilder private func group(_ fx: FXUnitState) -> some View {
        controls
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
        if effect == .plugin { pluginControls(fx) }
        controls
    }

    /// Plugin wählen (Name · Hersteller) und sein Fenster öffnen
    @ViewBuilder private func pluginControls(_ fx: FXUnitState) -> some View {
        let list = mix.core.pluginList()
        let current = list.first { $0.id == fx.pluginID } ?? fx.pluginID.flatMap(mix.core.pluginCatalog.info)   // auch abgeschaltet
        let error = mix.state.pluginErrors[u]
        VStack(spacing: 2) {
            Menu {
                ForEach(list) { p in
                    Button(p.name + " · " + p.manufacturer + (p.isVST3 ? "  VST3" : "")) { mix.setPlugin(u, p.id) }
                }
                Divider()
                Button("Plugin-Liste neu einlesen") { _ = mix.core.pluginList(refresh: true) }
            } label: {
                Text(error != nil ? "⚠︎ " + String((current?.name ?? "PLUGIN").prefix(10)) : current.map { String($0.name.prefix(12)) } ?? "—")
            }
            .menuStyle(.borderlessButton)
            .font(Theme.label(10, .bold))
            .fixedSize()
            .help(error ?? String(localized: "Effekt-Plugin wählen (Audio Unit oder VST3)"))
            DeckButton(title: "EDIT", active: false, color: Theme.state, width: 30) { PluginWindow.show(unit: u, core: mix.core) }
                .help("Plugin-Fenster öffnen")
        }
    }
}

/// Regler eines FX-Bedienelements: Beschriftung = zugewiesener Parameter (hell = eigene Zuweisung),
/// beim Drehen und Zeigen der Wert mit Einheit. Rechtsklick = zuweisen
struct FXKnob: View {
    @Environment(MixModel.self) private var mix
    let u: Int
    let c: FXControl
    @State private var hover = false
    @State private var flash = false
    @State private var flashTask: Task<Void, Never>?

    var body: some View {
        let info = mix.state.fxControls[u][c.slot]
        let showValue = info.param != nil && (hover || flash)
        VStack(spacing: 1) {
            Knob(value: Binding(get: { mix.state.fxControls[u][c.slot].value }, set: { mix.setFXControl(u, c, $0) }),
                 range: 0...1, defaultValue: info.param?.defaultValue ?? 0, bipolar: info.param?.bipolar ?? false,
                 color: Theme.state, size: 24)
                .opacity(info.param == nil ? 0.35 : 1)
            Text(verbatim: showValue ? mix.fxText(u, info) : info.label)
                .font(showValue ? Theme.mono(8) : Theme.label(8, .semibold))
                .foregroundStyle(showValue || !info.isDefault ? Theme.bone : Theme.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(width: 34)
        }
        .onHover { hover = $0 }
        .onChange(of: info.value) {
            // Wert kurz zeigen (Controller, Plugin-Fenster, Ziehen)
            flash = true
            flashTask?.cancel()
            flashTask = Task { try? await Task.sleep(for: .seconds(1.2)); if !Task.isCancelled { flash = false } }
        }
        .contextMenu { FXAssignMenu(u: u, c: c) }
        .help(fxHelp(info))
    }

    private func fxHelp(_ info: FXControlInfo) -> Text {
        guard let p = info.param else { return Text("Nicht zugewiesen · Rechtsklick = Parameter wählen") }
        return fxParamName(p) + Text(verbatim: " · " + mix.fxText(u, info) + " · ") + Text("Rechtsklick = Parameter wählen")
    }
}

/// Taste eines FX-Bedienelements: Schalter, Liste (nächste Stufe) oder min/max. Rechtsklick = zuweisen
struct FXButton: View {
    @Environment(MixModel.self) private var mix
    let u: Int
    let i: Int

    var body: some View {
        let c = FXControl.button(i)
        let info = mix.state.fxControls[u][c.slot]
        DeckButton(title: info.label, active: info.active, color: Theme.state, width: 22, verbatim: true) { mix.pressFXButton(u, i) }
            .opacity(info.param == nil ? 0.5 : 1)
            .contextMenu { FXAssignMenu(u: u, c: c) }
            .help(info.param.map { fxParamName($0) + Text(verbatim: " · " + mix.fxText(u, info) + " · ") + Text("Rechtsklick = Parameter wählen") }
                  ?? Text("Nicht zugewiesen · Rechtsklick = Parameter wählen"))
    }
}

/// Name eines Parameters (eigene Effekte übersetzt, Plugins wie geliefert)
func fxParamName(_ p: FXParam) -> Text {
    p.pluginParam == nil ? Text(LocalizedStringKey(p.name)) : Text(verbatim: p.name)
}

extension FXControl {
    /// Beschriftung in Menüs und Einstellungen (Lokalisierungsschlüssel)
    var title: LocalizedStringKey {
        switch self {
        case .dryWet: "D/W"
        case .knob1: "Regler 1"
        case .knob2: "Regler 2"
        case .knob3: "Regler 3"
        case .button1: "Taste 1"
        case .button2: "Taste 2"
        case .button3: "Taste 3"
        }
    }
}

/// FX-Belegung eines Bedienelements: Standard, nicht zugewiesen, alle Parameter des geladenen Effekts.
/// Gruppen als Abschnitte, bei vielen Parametern als Untermenüs (je 20). Tasten: Schalter/Listen oben, stufenlose als min/max.
/// `filter` = Suche (Einstellungen)
struct FXAssignMenu: View {
    @Environment(MixModel.self) private var mix
    let u: Int
    let c: FXControl
    var filter = ""

    private static let flatLimit = 24, chunk = 20

    var body: some View {
        let s = mix.state
        let mapped = s.fx[u].mapping[c]
        let params = s.fxParams[u]
        let def = FXCatalog.defaultTarget(c, effect: s.fx[u].effectKey, params: params).flatMap { k in params.first { $0.id == k } }
        let list = filter.isEmpty ? params : params.filter {
            $0.name.localizedCaseInsensitiveContains(filter) || $0.group.localizedCaseInsensitiveContains(filter)
        }
        Toggle(isOn: Binding(get: { mapped == nil }, set: { _ in mix.setFXMapping(u, c, nil) })) {
            Text("Standard") + Text(verbatim: " · ") + (def.map(fxParamName) ?? Text(verbatim: "—"))
        }
        Toggle(isOn: Binding(get: { mapped == "" }, set: { _ in mix.setFXMapping(u, c, "") })) { Text("Nicht zugewiesen") }
        Divider()
        if list.isEmpty {
            params.isEmpty ? Text("Effekt lädt …") : Text("Kein Parameter gefunden")
        }
        if c == .dryWet {
            let wet = list.filter { p in p.pluginParam != nil && ["mix", "wet", "dry"].contains { p.name.lowercased().contains($0) } }
            if !wet.isEmpty { Section("Mix des Plugins") { items(wet, mapped) } }
        }
        if c.isButton {
            let switches = list.filter(\.isSwitch), rest = list.filter { !$0.isSwitch }
            if !switches.isEmpty { Section("Schalter und Listen") { tree(switches, mapped) } }
            if !rest.isEmpty { Menu("Stufenlos (min/max)") { tree(rest, mapped) } }
        } else {
            tree(list, mapped)
        }
    }

    /// nach Gruppen: wenige = Abschnitte, viele = Untermenüs
    @ViewBuilder private func tree(_ list: [FXParam], _ mapped: String?) -> some View {
        let groups = Self.groups(list)
        if list.count <= Self.flatLimit || groups.count == 1 {
            ForEach(groups, id: \.0) { g in
                if g.0.isEmpty || groups.count == 1 { chunked(g.1, mapped) } else { Section(g.0) { chunked(g.1, mapped) } }
            }
        } else {
            ForEach(groups, id: \.0) { g in
                if g.0.isEmpty { chunked(g.1, mapped) } else { Menu { chunked(g.1, mapped) } label: { Text(verbatim: g.0) } }
            }
        }
    }

    @ViewBuilder private func chunked(_ list: [FXParam], _ mapped: String?) -> some View {
        if list.count <= Self.flatLimit {
            items(list, mapped)
        } else {
            ForEach(Array(stride(from: 0, to: list.count, by: Self.chunk)), id: \.self) { i in
                let part = Array(list[i..<min(i + Self.chunk, list.count)])
                Menu { items(part, mapped) } label: { Text(verbatim: "\(part[0].name) … \(part[part.count - 1].name)") }
            }
        }
    }

    private func items(_ list: [FXParam], _ mapped: String?) -> some View {
        ForEach(list) { p in
            Toggle(isOn: Binding(get: { mapped == p.id }, set: { _ in mix.setFXMapping(u, c, p.id) })) {
                // Art bzw. Bereich hinter dem Namen (Plugins: Einheit, AU mit Bereich)
                let detail: Text? = p.steps == 1 ? Text("Schalter") : p.steps > 1 ? Text("\(p.steps + 1) Stufen")
                    : p.pluginParam == nil || p.rangeText.isEmpty ? nil : Text(verbatim: p.rangeText)
                detail.map { fxParamName(p) + Text(verbatim: " · ") + $0 } ?? fxParamName(p)
            }
        }
    }

    /// Gruppen in der Reihenfolge des ersten Auftretens
    private static func groups(_ list: [FXParam]) -> [(String, [FXParam])] {
        var order: [String] = [], by: [String: [FXParam]] = [:]
        for p in list {
            if by[p.group] == nil { order.append(p.group) }
            by[p.group, default: []].append(p)
        }
        return order.map { ($0, by[$0] ?? []) }
    }
}

/// Obere Leiste: FX 1 · Master-Clock · FX 2
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
            Button { mix.core.resetSession() } label: {
                Text("↺").font(Theme.mono(14)).foregroundStyle(Theme.bone).frame(width: 22, height: 42)
            }
            .buttonStyle(.plain)
            .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
            .help("Takt-Zähler neu starten: der aktuelle Beat wird Takt 1")
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
            DeckButton(title: s.linkEnabled && s.linkPeers > 0 ? "LINK \(s.linkPeers)" : "LINK", active: s.linkEnabled,
                       color: Theme.secondary, width: 38) { mix.toggleLink() }
                .help("Link: MINOS gibt das Tempo vor")
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
            DeckButton(title: "SEMI", active: s.semiSync, color: Theme.state, width: 38) { mix.setSemiSync(!s.semiSync) }
                .help("Semi-Sync: neue Tracks laden mit dem Tempo des Masters, ohne Phasen-Sync")
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
