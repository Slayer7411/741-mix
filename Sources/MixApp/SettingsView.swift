import SwiftUI
import AppKit
import MixCore
import MixEngine

/// Einstellungen (⌘,) – jede Option der App ist hier einstellbar.
/// Links die Bereiche (neuer Bereich = eine Zeile in `tabs`), rechts der Inhalt scrollbar.
struct SettingsView: View {
    static let tabs: [SettingsTab] = [
        SettingsTab("DECKS") { DeckSettings() },
        SettingsTab("MIXER & FX") { MixerFXSettings() },
        SettingsTab("PLUGINS") { PluginSettingsView() },
        SettingsTab("ANZEIGE") { WaveformSettings() },
        SettingsTab("BROWSER") { BrowserSettings() },
        SettingsTab("AUDIO") { AudioSettings() },
        SettingsTab("CONTROLLER") { ControllerSettings() },
        SettingsTab("TAGS") { TagColorSettings() },
        SettingsTab("CLOUD") { CloudSettings() },
        SettingsTab("TASTATUR") { ShortcutSettings() },
    ]

    @State var selection = 0

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(tabs: Self.tabs, selection: $selection)
            Rectangle().fill(Theme.hairline).frame(width: 1)
            ScrollView {
                SettingsPage { Self.tabs[min(selection, Self.tabs.count - 1)].content() }
            }
            .id(selection)
            .background(Theme.chitin)
        }
        .frame(minWidth: 720, idealWidth: 820, maxWidth: .infinity, minHeight: 520, idealHeight: 640, maxHeight: .infinity)
        .background(Theme.void)
        .background(ResizableWindow())
        .preferredColorScheme(.dark)
    }
}

/// ein Bereich der Einstellungen
struct SettingsTab: Identifiable {
    /// Lokalisierungsschlüssel des Titels
    let id: String
    let content: @MainActor () -> AnyView
    var title: LocalizedStringKey { LocalizedStringKey(id) }

    init<V: View>(_ key: String, @ViewBuilder _ content: @escaping @MainActor () -> V) {
        id = key
        self.content = { AnyView(content()) }
    }
}

/// Seitenleiste: Cinzel versal, roter Balken am aktiven Eintrag
private struct SettingsSidebar: View {
    let tabs: [SettingsTab]
    @Binding var selection: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: "MINOS-741").font(Theme.label(11, .bold)).foregroundStyle(Theme.muted)
                .padding(.leading, 18).padding(.top, 20).padding(.bottom, 14)
            ForEach(tabs.indices, id: \.self) { i in
                let active = i == selection
                Button { selection = i } label: {
                    HStack(spacing: 0) {
                        Rectangle().fill(active ? Theme.state : .clear).frame(width: 3)
                        Text(tabs[i].title).font(Theme.label(12, .bold))
                            .foregroundStyle(active ? Theme.bone : Theme.bone.opacity(0.6))
                            .lineLimit(1)
                            .padding(.leading, 15)
                        Spacer(minLength: 0)
                    }
                    .frame(height: 32)
                    .background(active ? Theme.chitinRaised : .clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .frame(width: 176)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.void)
    }
}

/// Rahmen einer Einstellungsseite: Abstände, Schrift, Stile für Form, Zeilen, Schalter, Tasten
struct SettingsPage<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .formStyle(SettingsFormStyle())
            .labeledContentStyle(SettingsRowStyle())
            .toggleStyle(SettingsToggleStyle())
            .buttonStyle(SettingsButtonStyle())
            .controlSize(.small)
            .font(Theme.mono(11))
            .foregroundStyle(Theme.bone)
            .tint(Theme.state)
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum SettingsMetrics {
    /// feste Breite der Beschriftungsspalte
    static let labelWidth: CGFloat = 220
    static let rowSpacing: CGFloat = 16
    static let readoutWidth: CGFloat = 64
    /// größte Breite der Bedienelement-Spalte (Popups, Regler)
    static let controlWidth: CGFloat = 340
}

/// Form ohne macOS-Kästen: je Abschnitt `◆ TITEL` mit Haarlinie, darunter die Zeilen
struct SettingsFormStyle: FormStyle {
    func makeBody(configuration: Configuration) -> some View {
        LazyVStack(alignment: .leading, spacing: 30) {
            ForEach(sections: configuration.content) { section in
                VStack(alignment: .leading, spacing: 0) {
                    if !section.header.isEmpty {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(verbatim: "◆").font(Theme.label(9)).foregroundStyle(Theme.muted)
                                section.header.font(Theme.label(12, .bold)).textCase(.uppercase).foregroundStyle(Theme.bone)
                            }
                            Rectangle().fill(Theme.hairline).frame(height: 1)
                        }
                        .padding(.bottom, 8)
                    }
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(subviews: section.content) { row in
                            if row.containerValues.settingsHint {
                                row.padding(.top, 1).padding(.bottom, 6)
                            } else {
                                row.padding(.vertical, 5)
                            }
                        }
                    }
                }
            }
        }
    }
}

extension ContainerValues {
    @Entry var settingsHint = false
}

extension View {
    /// Hinweistext unter einer Zeile: Plex Mono 10, gedämpft
    func settingsHint() -> some View {
        font(Theme.mono(10)).foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .containerValue(\.settingsHint, true)
    }

    /// in die Spalte der Bedienelemente einrücken (Zeile ohne eigene Beschriftung)
    func settingsControlColumn() -> some View {
        padding(.leading, SettingsMetrics.labelWidth + SettingsMetrics.rowSpacing)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Eingabefeld mit Haarlinie (wie die Browser-Suche)
    func settingsField() -> some View {
        textFieldStyle(.plain)
            .font(Theme.mono(11))
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(Theme.void)
            .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
    }
}

/// Zeile: Beschriftung links in fester Breite (Plex Mono), Bedienelement rechts
struct SettingsRowStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: SettingsMetrics.rowSpacing) {
            configuration.label
                .font(Theme.mono(11)).foregroundStyle(Theme.bone)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: SettingsMetrics.labelWidth, alignment: .leading)
            configuration.content
                .font(Theme.mono(11))
                .frame(maxWidth: SettingsMetrics.controlWidth, alignment: .leading)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 22)
    }
}

/// Schalter als Quadrat: Haarlinie, an = rot gefüllt
struct SettingsToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: SettingsMetrics.rowSpacing) {
            configuration.label
                .font(Theme.mono(11)).foregroundStyle(Theme.bone)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: SettingsMetrics.labelWidth, alignment: .leading)
            ZStack {
                Rectangle().fill(Theme.void)
                Rectangle().stroke(configuration.isOn ? Theme.state : Theme.muted, lineWidth: 1)
                if configuration.isOn { Rectangle().fill(Theme.state).padding(3) }
            }
            .frame(width: 14, height: 14)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 22)
        .contentShape(Rectangle())
        .onTapGesture { configuration.isOn.toggle() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// Taste: Cinzel versal, Haarlinie, gedrückt rot
struct SettingsButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.label(10, .bold))
            .textCase(.uppercase)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(minHeight: 20)
            .foregroundStyle(Theme.bone)
            .background(Rectangle().fill(configuration.isPressed ? Theme.state.opacity(0.85) : Theme.void))
            .overlay(Rectangle().stroke(configuration.isPressed ? Theme.state : Theme.hairline, lineWidth: 1))
            .fixedSize()
            .contentShape(Rectangle())
    }
}

/// Fenster der Einstellungen in der Größe veränderbar machen
private struct ResizableWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.styleMask.insert(.resizable)
        }
    }
}

/// kleine Helfer für Zeilen; `unit` steht hinter dem Zahlenwert (s, ms, pt, %, dB)
private func sliderRow(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, step: Double? = nil,
                       format: String = "%.2f", unit: String = "") -> some View {
    LabeledContent(LocalizedStringKey(title)) {
        HStack(spacing: 10) {
            // Schritt über die Bindung statt Slider(step:) – sonst zeichnet macOS je Schritt einen Teilstrich
            Slider(value: Binding(get: { value.wrappedValue },
                                  set: { v in value.wrappedValue = step.map { min(range.upperBound, max(range.lowerBound, ($0 * (v / $0).rounded()))) } ?? v }),
                   in: range)
            Text(verbatim: String(format: format, value.wrappedValue) + (unit.isEmpty ? "" : " \(unit)"))
                .font(Theme.mono(11)).monospacedDigit().foregroundStyle(Theme.bone)
                .frame(width: SettingsMetrics.readoutWidth, alignment: .trailing)
        }
    }
}

struct DeckSettings: View {
    @Environment(MixModel.self) private var mix

    var body: some View {
        @Bindable var mix = mix
        Form {
            Section("Abspielen") {
                Toggle("Snap (Cues und Loop-Punkte rasten auf den Beat)", isOn: $mix.prefs.engine.snap)
                Toggle("Quant (Sprünge halten die Beat-Phase)", isOn: $mix.prefs.engine.quantize)
                Toggle("Hotcue-Sprung hält die Beat-Phase", isOn: $mix.prefs.engine.hotcueKeepsPhase)
                Picker("Beim Laden springen zu", selection: $mix.prefs.engine.loadPosition) {
                    ForEach(LoadPosition.allCases, id: \.self) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                sliderRow("Track-Ende-Warnung (s, 0 = aus)", $mix.prefs.engine.trackEndWarning, 0...90, step: 5, format: "%.0f", unit: "s")
                Toggle("Lade-Schutz bei laufendem Deck", isOn: $mix.prefs.engine.loadProtection)
                Text("spielt das deck, wird nicht geladen (doppelklick, taste, controller-load) -> hinweis in der statusleiste. trotzdem laden: ⌥-doppelklick, shift + load, taste „auswahl ins fokus-deck laden (auch wenn es spielt)“.")
                    .settingsHint()
            }
            Section("Master-Clock & Metronom") {
                Picker("Metronom auf Kanalpaar", selection: $mix.prefs.engine.metronomeChannel) {
                    ForEach(Array(stride(from: 0, to: max(2, mix.deviceChannels - 1), by: 2)), id: \.self) { c in
                        Text("\(c + 1)/\(c + 2)").tag(c)
                    }
                }
                Text("im extern-modus z. b. auf das paar vom kopfhörer-cue legen -> klick nur auf dem kopfhörer").settingsHint()
            }
            Section("Tempo & Sync") {
                Toggle("Keylock beim ersten Laden an", isOn: $mix.prefs.engine.keylockDefault)
                Picker("Tempo-Bereich (Standard)", selection: $mix.prefs.engine.tempoRangeDefault) {
                    ForEach([6.0, 8, 10, 16, 50, 100], id: \.self) { Text(String(format: "±%g %%", $0)).tag($0) }
                }
                Toggle("Phase laufend nachführen (Beat-Sync)", isOn: $mix.prefs.engine.phaseLock)
                Picker("Sync-Modus", selection: $mix.prefs.engine.syncMode) {
                    ForEach(SyncMode.allCases, id: \.self) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                sliderRow("Pitch-Bend-Stärke", $mix.prefs.engine.bendAmount, 0.01...0.12, format: "%.2f")
                sliderRow("Link-Versatz (ms)", $mix.prefs.engine.linkOffsetMs, -50...50, step: 1, format: "%+.0f", unit: "ms")
            }
            Section("Phrasen-Anker") {
                Picker("Grid-Anker auf Phrasen ausrichten", selection: $mix.prefs.engine.phraseAnchor) {
                    ForEach(PhraseAnchorMode.allCases, id: \.self) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                Text("beim laden prüft minos, ob die strukturwechsel des tracks auf 8-takt-grenzen ab dem grid-anker liegen. vorschlagen -> roter phrase-knopf in der grid-zeile, automatisch -> anker wird um ganze beats verschoben. bpm und raster bleiben, gespeichert in den eigenen änderungen, nie in der collection.")
                    .font(Theme.mono(10)).foregroundStyle(Theme.muted)
            }
            Section("Loops & Beatjump") {
                Picker("Loopgröße (Standard)", selection: $mix.prefs.engine.defaultLoopSize) {
                    ForEach(BeatSizes.loop, id: \.self) { Text(BeatSizes.label($0)).tag($0) }
                }
                Picker("Beatjump-Größe (Standard)", selection: $mix.prefs.engine.defaultJumpSize) {
                    ForEach(BeatSizes.jump, id: \.self) { Text(BeatSizes.label($0)).tag($0) }
                }
                Group {
                    Toggle("Loop-Snap auf Loop-Cues", isOn: $mix.prefs.engine.loopSnapCues)
                    Stepper("Fenster (Beats): \(Int(mix.prefs.engine.loopSnapCueBeats))", value: $mix.prefs.engine.loopSnapCueBeats, in: 1...8, step: 1)
                        .disabled(!mix.prefs.engine.loopSnapCues)
                    Toggle("Loop-Snap auf 4-Bar-Raster", isOn: $mix.prefs.engine.loopSnapPhrase)
                    Stepper("Toleranz (Beats): \(Int(mix.prefs.engine.loopSnapPhraseBeats))", value: $mix.prefs.engine.loopSnapPhraseBeats, in: 1...8, step: 1)
                        .disabled(!mix.prefs.engine.loopSnapPhrase)
                    Text("nur mit snap. loop, loop in: ein loop-cue, der bis zum fenster vor der position beginnt oder gerade überspielt wird, wird übernommen; sonst beginnt der loop auf der nächsten 4-takt-grenze (ab grid-anker) innerhalb der toleranz; sonst normaler snap. kein sprung: die position läuft in den loop hinein oder ist schon drin.")
                        .settingsHint()
                }
                .disabled(!mix.prefs.engine.snap)
                Picker("Active Loop greift", selection: $mix.prefs.engine.activeLoopMode) {
                    ForEach(ActiveLoopMode.allCases, id: \.self) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                Text("rechtsklick auf einen loop-hotcue -> active loop (punkt auf der taste, gestrichelter rahmen in der wellenform). erreicht die position den loop-anfang, rastet der loop ein, die loop-taste verlässt ihn. gespeichert je track in den eigenen änderungen.")
                    .settingsHint()
            }
            Section("History & Preparation") {
                sliderRow("Als gespielt nach (s hörbar)", $mix.prefs.engine.historyThreshold, 5...120, step: 5, format: "%.0f", unit: "s")
                Toggle("History zusätzlich in den History-Ordner der Collection schreiben", isOn: $mix.prefs.ui.historyToExternal)
                Text("history und preparation werden als nml gespeichert (~/Library/Application Support/MINOS-741) -> direkt in die collection importierbar. preparation wird bei jedem start archiviert und geleert.")
                    .settingsHint()
            }
            Section("Ansicht") {
                Toggle("4 Decks anzeigen", isOn: $mix.prefs.ui.showFourDecks)
                sliderRow("Vorhören im Browser ab (Anteil)", $mix.prefs.ui.previewStart, 0...0.9, format: "%.1f")
            }
            Section("Zeilen je Deck") {
                ForEach(Array(DeckRows.all.enumerated()), id: \.offset) { _, row in
                    Toggle(LocalizedStringKey(row.1), isOn: Binding(get: { mix.prefs.ui[keyPath: row.0] },
                                                                  set: { mix.prefs.ui[keyPath: row.0] = $0 }))
                }
                Toggle("Kompakte Decks (ohne Pitch-Fader, Hotcues, Grid-Werkzeuge)", isOn: $mix.prefs.ui.compactDecks)
                Text("auch im menü decks -> zeilen / kompakte decks. ohne pitch-fader nimmt die wellenform die breite. wellenform und kopfzeile bleiben immer.").settingsHint()
            }
        }
    }
}

struct MixerFXSettings: View {
    @Environment(MixModel.self) private var mix
    @State private var search = ""

    var body: some View {
        @Bindable var mix = mix
        Form {
            Section("Mixer") {
                Toggle("Internen Mixer anzeigen", isOn: $mix.prefs.ui.showMixer)
                Toggle("Auto-Gain (Lautheit aus der Collection)", isOn: $mix.prefs.engine.autoGain)
                headroomPicker("Headroom", $mix.prefs.engine.headroomInternal)
            }
            Section("Externer Mixer") {
                headroomPicker("Headroom", $mix.prefs.engine.headroomExternal)
                Toggle("Auto-Gain", isOn: $mix.prefs.engine.autoGainExternal)
                Toggle("Main-Volume wirkt auch extern", isOn: $mix.prefs.engine.masterVolumeExternal)
            }
            Section("Mixer-Optionen") {
                Toggle("EQ-Kill (ganz links = aus)", isOn: $mix.prefs.engine.eqKill)
                Picker("Crossfader-Kurve", selection: $mix.prefs.engine.crossfaderCurve) {
                    ForEach(CrossfaderCurve.allCases, id: \.self) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                sliderRow("Kanalfilter-Resonanz", $mix.prefs.engine.channelFilterResonance, 0.2...1.5)
            }
            Section("FX-Units (Gruppenmodus: Filter · Delay · Reverb)") {
                Toggle("FX-Units anzeigen", isOn: $mix.prefs.ui.showFXUnits)
                Picker("Anzahl FX-Units", selection: $mix.prefs.ui.fxUnitCount) {
                    Text(verbatim: "2").tag(2)
                    Text(verbatim: "4").tag(4)
                }
                .pickerStyle(.segmented)
                sliderRow("Delay-Feedback", $mix.prefs.engine.delayFeedback, 0...1)
                sliderRow("FX-Filter-Resonanz", $mix.prefs.engine.fxFilterResonance, 0...1)
                Picker("Reverb-Typ", selection: $mix.prefs.engine.reverbType) {
                    ForEach(ReverbType.allCases, id: \.self) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                sliderRow("Reverb-Pegel (dB)", $mix.prefs.engine.reverbLevelDb, -18...6, step: 1, format: "%+.0f")
                sliderRow("Reverb-Helligkeit", $mix.prefs.engine.reverbBrightness, 0...1)
                sliderRow("Reverb-Vorverzögerung (ms)", $mix.prefs.engine.reverbPreDelayMs, 0...120, step: 1, format: "%.0f")
            }
            Section("FX-Belegung (D/W · Regler · Tasten)") {
                LabeledContent("Parameter suchen") {
                    TextField("", text: $search, prompt: Text("Name oder Gruppe")).settingsField()
                }
                ForEach(0..<min(mix.prefs.ui.fxUnitCount, MixEngine.fxUnitCount), id: \.self) { u in
                    LabeledContent {
                        HStack(spacing: 10) {
                            Text(verbatim: mix.effectName(mix.fxUnits[u].state.effectKey)).foregroundStyle(Theme.bone)
                            Button("Alle auf Standard") { mix.resetFXMapping(u) }
                        }
                    } label: {
                        Text(verbatim: "FX \(u + 1)").font(Theme.label(11, .bold))
                    }
                    ForEach(FXControl.allCases, id: \.self) { c in
                        LabeledContent { FXAssignRow(u: u, c: c, search: search) } label: { Text(c.title) }
                    }
                }
                Text("rechtsklick auf einen regler oder eine taste der fx-unit wählt den parameter direkt. gilt für die unit und wird je effekt bzw. plugin gemerkt: lädt die unit denselben effekt wieder, ist die belegung wieder da. die sitzung behält die belegung jeder unit. tasten: schalter um, listen eine stufe weiter, stufenlose zwischen min und max. d/w der unit wirkt nur, solange ein bedienelement darauf liegt.")
                    .settingsHint()
            }
            Section("Gemerkte Belegungen") {
                let stored = mix.prefs.engine.fxMappings
                if stored.isEmpty { Text("keine – alle effekte in standardbelegung").settingsHint() }
                ForEach(stored.keys.sorted(), id: \.self) { k in
                    LabeledContent {
                        HStack(spacing: 10) {
                            Text("\(stored[k]?.targets.count ?? 0) Bedienelemente").foregroundStyle(Theme.muted)
                            Button("Vergessen") { mix.prefs.engine.fxMappings[k] = nil }
                        }
                    } label: {
                        Text(verbatim: mix.effectName(k))
                    }
                }
            }
        }
    }
}

/// Zeile der FX-Belegung: Menü mit dem Ziel, dahinter der Wert
private struct FXAssignRow: View {
    @Environment(MixModel.self) private var mix
    let u: Int
    let c: FXControl
    let search: String

    var body: some View {
        let info = mix.fxUnits[u].controls[c.slot]
        HStack(spacing: 10) {
            Menu {
                FXAssignMenu(u: u, c: c, filter: search)
            } label: {
                if let p = info.param {
                    fxParamName(p) + (info.isDefault ? Text(verbatim: " · ") + Text("Standard") : Text(verbatim: ""))
                } else {
                    Text("Nicht zugewiesen")
                }
            }
            .frame(maxWidth: 240, alignment: .leading)
            Text(verbatim: info.param == nil ? "" : mix.fxText(u, info))
                .font(Theme.mono(11)).monospacedDigit().foregroundStyle(Theme.muted)
                .lineLimit(1)
        }
    }
}

struct WaveformSettings: View {
    @Environment(MixModel.self) private var mix

    var body: some View {
        @Bindable var mix = mix
        Form {
            Section("Wellenform") {
                // Stil und Spektrum-Variante in einer Liste: 3-Band, Spektrum fein / fein ohne Ebene / 3 Bänder, Einfarbig
                Picker("Stil", selection: Binding(
                    get: { mix.prefs.ui.waveformStyle == .spectrum ? mix.prefs.ui.spectrumDetail.rawValue : mix.prefs.ui.waveformStyle.rawValue },
                    set: { v in
                        if let d = SpectrumDetail(rawValue: v) {
                            mix.prefs.ui.waveformStyle = .spectrum
                            mix.prefs.ui.spectrumDetail = d
                        } else if let st = WaveformStyle(rawValue: v) {
                            mix.prefs.ui.waveformStyle = st
                        }
                    })) {
                    ForEach([WaveformStyle.blend.rawValue, WaveformStyle.threeBand.rawValue] + SpectrumDetail.allCases.map(\.rawValue) + [WaveformStyle.mono.rawValue], id: \.self) {
                        Text(LocalizedStringKey($0)).tag($0)
                    }
                }
                let fine = mix.prefs.ui.waveformStyle == .spectrum && mix.prefs.ui.spectrumDetail != .simple
                Picker("Farben", selection: $mix.prefs.ui.waveformPalette) {
                    ForEach(WaveformPalette.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                .disabled(fine)
                if mix.prefs.ui.waveformStyle != .mono {
                    sliderRow("Höhen-Betonung", $mix.prefs.ui.waveformHighBoost, 0...2, step: 0.25, format: "%.2f")
                }
                if mix.prefs.ui.waveformStyle == .blend {
                    Text("Je Pixelzeile gemischt: Farbe aus Bass (< 150 Hz), Mitten (um 670 Hz) und Höhen (> 3 kHz) der Samples, die die Zeile erreichen, Helligkeit nach oben weich auslaufend. Spektrum (RGB): Bass rot, Mitten grün, Höhen blau, Mischungen gelb / cyan / weiß.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !fine, mix.prefs.ui.waveformStyle == .threeBand {
                    Text("Bass < 250 Hz hinten · Mitten 250 Hz – 4 kHz · Höhen > 4 kHz vorn, je Band eigene Amplitude. Das stärkste Band reicht bis zum echten Pegel.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if fine {
                    Text("Sub orange · Bass/Kick rot · Mitten grün, obere Mitten gelbgrün · kurze Höhen (geschlossene Hats) blau · gehaltene Höhen (offene Hats, Ride) hellblau. Jedes Band gegen den eigenen Track normiert, Höhe = echter Pegel.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                sliderRow("Sichtbare Sekunden je Seite (Zoom)", $mix.prefs.ui.waveformSeconds, 1...16, step: 0.5, format: "%.1f", unit: "s")
                sliderRow("Mindesthöhe (pt, wächst mit dem Fenster)", $mix.prefs.ui.waveformHeight, 30...200, step: 5, format: "%.0f", unit: "pt")
                Toggle("Gespielten Teil abdunkeln", isOn: $mix.prefs.ui.dimPlayed)
            }
            Section("Beatgrid") {
                Toggle("Beatgrid anzeigen", isOn: $mix.prefs.ui.showBeatgrid)
                Toggle("Farbig (Phrasen, Takte, Beats)", isOn: $mix.prefs.ui.colorfulGrid)
                Picker("Phrase", selection: $mix.prefs.ui.phraseBeats) {
                    ForEach([16, 32, 64, 128], id: \.self) { Text("\($0) Beats (\($0 / 4) Takte)").tag($0) }
                }
                Toggle("Taktnummern", isOn: $mix.prefs.ui.showBarNumbers)
                Toggle("Marker alle 8 / 16 / 32 Takte (magenta)", isOn: $mix.prefs.ui.barMarkers)
            }
            Section("Zoom") {
                Picker("Hauptfenster (⌘+ / ⌘− / ⌘0)", selection: Binding(get: { mix.prefs.ui.zoom }, set: { ZoomControl.set($0, mix: mix) })) {
                    ForEach(Set(ZoomSteps.levels + [mix.prefs.ui.zoom]).sorted(), id: \.self) { Text(verbatim: ZoomSteps.percent($0)).tag($0) }
                }
            }
            Section("Sprache") {
                Picker("Sprache (wirkt nach Neustart)", selection: $mix.prefs.ui.language) {
                    Text("Systemstandard").tag("system")
                    Text(verbatim: "Deutsch").tag("de")
                    Text(verbatim: "English").tag("en")
                }
            }
            Section("Browser") {
                Picker("Anordnung", selection: $mix.prefs.ui.browserLayout) { ForEach(BrowserLayout.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) } }
                Toggle("Ordner-Baum ausblenden, solange Decks sichtbar sind", isOn: $mix.prefs.ui.hideTreeWithDecks)
                MusicFolderSettings()
                Toggle("Änderungen in die Collection-Datei schreiben (Backup davor)", isOn: $mix.prefs.ui.writeCollection)
                Text("aus: änderungen (inline, ⌘E) liegen nur in MINOS-741 (metadata.json). an: nach ÜBERNEHMEN in die collection.nml, sicherung höchstens stündlich in „Backup MINOS-741“ neben der datei. nicht, solange die collection-software läuft.")
                    .font(Theme.mono(10)).foregroundStyle(Theme.muted)
            }
            PreviewSettings()
            Section("Statusleiste") {
                Toggle("Last-Anzeigen (DSP, Latenz, Aussetzer, Speicher, CPU)", isOn: $mix.prefs.ui.showMeters)
                Text("dsp = rechenzeit des audio-blocks ÷ blockdauer, rot ab 70 %. aussetzer: blöcke über dem budget plus überlast-meldungen des geräts, klick setzt zurück. meldungen: klick zeigt die letzten 50.")
                    .settingsHint()
            }
            Section("Cover") {
                Toggle("Cover im Deck anzeigen", isOn: $mix.prefs.ui.showDeckCover)
                Toggle("Cover-Vorschau im Browser", isOn: $mix.prefs.ui.showCoverPreview)
                Text("vorschau unter dem baum (gewählter track). spalte „Cover“ in der liste: rechtsklick auf die spaltenköpfe. bild aus der datei, sonst cover / folder / front.jpg im ordner, zwischengespeichert in ~/Library/Caches/MINOS-741/artwork.")
                    .settingsHint()
            }
            Section("Analyse") {
                // genau eine Oktave: jede Grenze stellt die andere mit
                Stepper(value: Binding(get: { mix.prefs.ui.analysisBpmLow }, set: { mix.prefs.ui.analysisBpmLow = max(40, min(150, $0)) }),
                        in: 40...150, step: 1) {
                    Text("BPM-Bereich ab \(Int(mix.prefs.ui.analysisBpmLow))")
                }
                Stepper(value: Binding(get: { 2 * mix.prefs.ui.analysisBpmLow }, set: { mix.prefs.ui.analysisBpmLow = max(40, min(150, $0 / 2)) }),
                        in: 80...300, step: 2) {
                    Text("BPM-Bereich bis \(Int(2 * mix.prefs.ui.analysisBpmLow))")
                }
                Text("genau eine oktave: das tempo wird in den bereich gefaltet (z. b. 100–200: 96 -> 192). gilt für analysieren / neu analysieren.")
                    .settingsHint()
                KeyProfileSettings()
            }
            Section("Collection prüfen") {
                Toggle("Beim Start prüfen", isOn: $mix.prefs.ui.checkOnStart)
                Toggle("Musik-Ordner nach Dateien ohne Collection-Eintrag durchsuchen", isOn: $mix.prefs.ui.checkMusicFolders)
                Text("browser-menü -> collection prüfen … oder rechtsklick auf TRACK COLLECTION. nur lesen: dateien, audio-kopf, dauer, schreibweise, namen, doppelte, analyse, grid, playlist-einträge. abbrechen jederzeit.")
                    .settingsHint()
            }
            Section("Cue-Farben (Bildschirm und Controller-Pads)") {
                Picker("Start-Cue (Load / AutoGrid)", selection: $mix.prefs.controller.colorStartCue) { ForEach(PadColor.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) } }
                Picker("Cue", selection: $mix.prefs.controller.colorCue) { ForEach(PadColor.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) } }
                Picker("Loop", selection: $mix.prefs.controller.colorLoop) { ForEach(PadColor.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) } }
                Picker("Kurzer Loop", selection: $mix.prefs.controller.colorShortLoop) { ForEach(PadColor.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) } }
                Picker("Kurz = bis", selection: $mix.prefs.controller.shortLoopBars) {
                    ForEach([1.0, 2, 4, 8], id: \.self) { Text("\(Int($0)) \($0 == 1 ? "Takt" : "Takte")").tag($0) }
                }
            }
        }
    }
}

struct AudioSettings: View {
    @Environment(MixModel.self) private var mix

    var body: some View {
        Form {
            Section("Ausgabegerät") {
                LabeledContent("Gerät") {
                    HStack(spacing: 8) {
                        Picker("Gerät", selection: Binding(
                            get: { mix.deviceUID ?? "" },
                            set: { mix.deviceUID = $0.isEmpty ? nil : $0; mix.applyRouting() })) {
                            Text("Systemstandard").tag("")
                            ForEach(mix.outputDevices) { d in Text("\(d.name) – \(d.channels) Kanäle").tag(d.uid) }
                        }
                        .labelsHidden()
                        Button { mix.refreshDevices() } label: { Text("↻") }
                            .help("Geräteliste neu einlesen")
                    }
                }
                LabeledContent("Kanäle", value: "\(mix.deviceChannels)")
                Picker("Samplerate", selection: Binding(get: { mix.sampleRate }, set: { mix.setAudioFormat(rate: $0) })) {
                    Text("wie am Gerät").tag(0.0)
                    ForEach(MixEngine.availableRates(mix.currentDevice?.id ?? 0), id: \.self) { r in
                        Text(String(format: "%g kHz", r / 1000)).tag(r)
                    }
                }
                Picker("Puffer (Latenz)", selection: Binding(get: { mix.bufferSize }, set: { mix.setAudioFormat(buffer: $0) })) {
                    Text("wie am Gerät").tag(0)
                    ForEach([64, 128, 256, 512, 1024, 2048], id: \.self) { n in
                        Text(String(format: "%d · %.1f ms", n, Double(n) / max(mix.engine.outputRate, 1) * 1000)).tag(n)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Button("Neu verbinden") { mix.reconnect() }
                    Text("startet die Ausgabe neu, z. B. wenn das Interface nach einem USB-Aussetzer stumm bleibt")
                        .settingsHint()
                }
                .settingsControlColumn()
                Text("Eine neue Samplerate gilt am Gerät sofort, MINOS-741 rechnet ab dem nächsten Start damit.")
                    .settingsHint()
            }
            Section("Mixer") {
                Picker("Modus", selection: Binding(get: { mix.mixerMode }, set: { mix.mixerMode = $0; mix.applyRouting() })) {
                    Text("Intern – Mixer in MINOS-741").tag(MixerMode.internalMixer)
                    Text("Extern – Mischpult (jedes Deck auf eigenem Kanalpaar)").tag(MixerMode.external)
                }
                .pickerStyle(.radioGroup)
            }
            if mix.mixerMode == .internalMixer {
                Section("Ausgang (Master)") {
                    pairPicker("Master", value: Binding(get: { mix.internalPair }, set: { mix.internalPair = $0; mix.applyRouting() }))
                }
            } else {
                Section("Deck → Kanal") {
                    ForEach(0..<MixEngine.deckCount, id: \.self) { d in
                        pairPicker("Deck \(deckLetters[d])", value: Binding(
                            get: { mix.deckPairs[d] }, set: { mix.deckPairs[d] = $0; mix.applyRouting() }))
                    }
                    Button("Standard: A 1/2 · B 3/4 · C 5/6 · D 7/8") { mix.deckPairs = [0, 2, 4, 6]; mix.applyRouting() }
                        .settingsControlColumn()
                    Text("Am Mischpult die Kanal-Eingänge auf USB stellen. EQ, Fader, Crossfader und Kopfhörer-Cue macht dann das Pult; Filter, FX und Gain bleiben in MINOS-741.")
                        .settingsHint()
                }
            }
            PreviewOutputSettings()
            LoadCacheSettings()
            Section { Text(mix.engineStatus).settingsHint() }
        }
        .onAppear { mix.refreshDevices() }
    }

    private func pairPicker(_ title: String, value: Binding<Int>) -> some View {
        Picker(title, selection: value) {
            ForEach(Array(stride(from: 0, to: max(2, mix.deviceChannels - 1), by: 2)), id: \.self) { c in
                Text("\(c + 1)/\(c + 2)").tag(c)
            }
        }
    }
}

/// Vorhören im Browser: Kanalpaar am Ausgabegerät (nie der Systemausgang), Lautstärke
private struct PreviewOutputSettings: View {
    @Environment(MixModel.self) private var mix

    var body: some View {
        @Bindable var mix = mix
        let external = mix.mixerMode == .external
        Section("Vorhören") {
            Picker("Vorhören auf Kanalpaar", selection: Binding(get: { mix.previewPair }, set: { mix.previewPair = $0; mix.applyRouting() })) {
                Text(external ? "Automatisch – erstes freies Paar nach den Decks" : "Automatisch – Hauptausgang").tag(MixModel.previewAuto)
                ForEach(Array(stride(from: 0, to: max(2, mix.deviceChannels - 1), by: 2)), id: \.self) { c in
                    Text(verbatim: "\(c + 1)/\(c + 2)" + label(c)).tag(c)
                }
                Text("Aus").tag(MixModel.previewOff)
            }
            LabeledContent("Vorhören jetzt auf") {
                Text(verbatim: mix.previewRoute.map { "\($0 + 1)/\($0 + 2)" }
                     ?? (mix.previewPair == MixModel.previewOff ? String(localized: "aus") : String(localized: "aus – kein freies Kanalpaar")))
            }
            sliderRow(String(localized: "Lautstärke Vorhören"), $mix.prefs.ui.previewVolume, 0...1.5, format: "%.2f")
            Text(external
                 ? "am mischpult einen freien kanal auf dieses usb-paar stellen, fader zu, cue an -> vorhören nur im kopfhörer. ein deck-paar nur von hand wählbar."
                 : "läuft auf dem gewählten paar mit, unabhängig von main. ein paar fürs kopfhörer-signal des interfaces -> vorhören nur dort.")
                .settingsHint()
        }
    }

    /// Paar eines Decks (Extern) bzw. Hauptausgang (Intern) markieren
    private func label(_ c: Int) -> String {
        if mix.mixerMode == .internalMixer { return c == mix.internalPair ? " · Master" : "" }
        let decks = mix.deckPairs.indices.filter { mix.deckPairs[$0] == c }.map { "Deck \(deckLetters[$0])" }
        return decks.isEmpty ? "" : " · " + decks.joined(separator: " ")
    }
}

/// Laden über den Datei-Dienst: Grenzen ohne Audiodaten, Cache dekodierter Tracks
private struct LoadCacheSettings: View {
    @Environment(MixModel.self) private var mix
    @State private var usage: FileServiceClient.CacheUsage?

    var body: some View {
        @Bindable var mix = mix
        let service = mix.core.fileService
        Section("Laden & Cache") {
            LabeledContent("Dekodieren", value: service != nil ? String(localized: "Datei-Dienst (eigener Prozess)") : String(localized: "im Programm"))
            sliderRow("Hinweis nach (keine Audiodaten)", $mix.prefs.engine.loadTimeout, 2...15, step: 1, format: "%.0f", unit: "s")
            sliderRow("Laden abbrechen nach (keine Audiodaten)", $mix.prefs.engine.loadAbortTimeout, 15...300, step: 5, format: "%.0f", unit: "s")
                .disabled(service == nil)
            sliderRow("Cache dekodierter Tracks", $mix.prefs.engine.cacheLimitGB, 1...64, step: 1, format: "%.0f", unit: "GB")
                .disabled(service == nil)
            if let usage {
                LabeledContent("Belegt", value: String(format: "%.1f GB · %d Tracks", Double(usage.bytes) / 1e9, usage.files))
            }
            Text("datei-dienst: dateien werden in einem eigenen prozess gelesen und dekodiert. hängt eine cloud-datei, lädt das deck weiter (hinweis), abgebrochen wird erst nach der zweiten grenze. ohne datei-dienst: abbruch schon nach der ersten. cache: ~/Library/Application Support/MINOS-741/cache, älteste zuerst gelöscht, tracks in den decks bleiben.")
                .settingsHint()
        }
        .task(id: mix.prefs.engine.cacheLimitGB) {
            guard let service else { return }
            try? await Task.sleep(for: .milliseconds(300))   // Aufräumen nach einer neuen Grenze abwarten
            usage = await Task.detached(priority: .utility) { service.cacheUsage() }.value
        }
    }
}

/// Browser: Harmonie zum Master (Key-Farben) und Filter „passt zum Master“ (◆ PASST)
struct BrowserSettings: View {
    @Environment(MixModel.self) private var mix

    var body: some View {
        @Bindable var mix = mix
        Form {
            Section("Harmonie zum Master") {
                Toggle("Key-Spalte färben", isOn: $mix.prefs.ui.harmonyColors)
                Text("""
                bezug: hörbarer key des master-decks (mit key-shift, ohne keylock mit dem tempo), spielt kein master:                 fokus-deck. ◆ lila = gleich · ▲▼ hell = ±1 auf dem rad · ◇ hell = relativ dur/moll · grau = ±2 (energie) ·                 gedimmt = unpassend. spalte match: pitch in prozent, den der track bis zum master-tempo braucht
                """).settingsHint()
            }
            Section("◆ PASST (Matching)") {
                Toggle("±1 auf dem Rad (▲▼)", isOn: $mix.prefs.ui.match.adjacent)
                Toggle("Relativ Dur/Moll (◇)", isOn: $mix.prefs.ui.match.relative)
                Toggle("Energie-Wechsel ±2", isOn: $mix.prefs.ui.match.energy)
                sliderRow("BPM-Fenster", $mix.prefs.ui.match.bpmWindow, 1...10, step: 0.5, format: "±%.1f", unit: "%")
                Toggle("Halbes / doppeltes Tempo mitzählen", isOn: $mix.prefs.ui.match.halfDouble)
                Text("gleicher key zählt immer. track ohne key passt nicht, master ohne key: nur das tempo. an/aus: chip ◆ PASST im kopf des bereichs, tastatur (⌘, → tastatur) oder browse-taste am controller").settingsHint()
            }
        }
    }
}

struct ControllerSettings: View {
    @Environment(MixModel.self) private var mix
    @Environment(ControllerStatus.self) private var status

    var body: some View {
        @Bindable var mix = mix
        Form {
            Section("Controller (nativ, HID)") {
                if status.devices.isEmpty {
                    Text("Kein Controller gefunden. Andere DJ-Software beenden, falls sie läuft.").settingsHint()
                }
                ForEach(status.devices) { d in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Controller \(d.id)").font(Theme.mono(11, .medium))
                            Spacer()
                            Button("Blinken") { status.identify(d.id) }.help("Pads dieses Controllers leuchten kurz weiß")
                        }
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                            GridRow {
                                deviceLabel("Links")
                                Picker("Links", selection: Binding(get: { d.left }, set: { status.assign(d.id, left: $0, right: d.right) })) {
                                    ForEach(0..<4, id: \.self) { Text(deckLetters[$0]).tag($0) }
                                }
                                .labelsHidden().frame(width: 120)
                                deviceLabel("Rechts")
                                Picker("Rechts", selection: Binding(get: { d.right }, set: { status.assign(d.id, left: d.left, right: $0) })) {
                                    ForEach(0..<4, id: \.self) { Text(deckLetters[$0]).tag($0) }
                                }
                                .labelsHidden().frame(width: 120)
                            }
                            GridRow {
                                deviceLabel("Browser")
                                Picker("Browser", selection: Binding(get: { d.pane }, set: { status.assignPane(d.id, $0) })) {
                                    Text("links").tag(0)
                                    Text("rechts").tag(1)
                                }
                                .labelsHidden().frame(width: 120)
                                deviceLabel("FX")
                                Picker("FX", selection: Binding(get: { d.fxUnit }, set: { status.assignFX(d.id, $0) })) {
                                    Text(verbatim: "FX1 + FX3").tag(10)
                                    Text(verbatim: "FX2 + FX4").tag(11)
                                    Text(verbatim: "FX1 + FX2").tag(-1)
                                    Text(verbatim: "FX1").tag(0)
                                    Text(verbatim: "FX2").tag(1)
                                }
                                .labelsHidden().frame(width: 120)
                            }
                        }
                    }
                    .padding(12)
                    .background(Theme.void)
                    .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
                    .padding(.vertical, 3)
                }
            }
            Section("Belegung") {
                Picker("Cue-Taste", selection: $mix.prefs.controller.cueAction) { ForEach(ControllerCueAction.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) } }
                Picker("Flux-Taste", selection: $mix.prefs.controller.fluxButton) { ForEach(ControllerFluxButton.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) } }
                if mix.prefs.controller.fluxButton == .fluxMode {
                    Toggle("Flux antippen schaltet Flux-Modus", isOn: $mix.prefs.controller.fluxTapToggles)
                } else {
                    Text("antippen -> pads 1–4 spielen hotcues 5–8, flux-led an; nochmal -> zurück. shift + flux = flux-modus.").settingsHint()
                }
                Picker("Flux halten + Pads", selection: $mix.prefs.controller.fluxPads) { ForEach(ControllerFluxPads.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) } }
                Picker("Beatjump-Größe (Flux + Pad 3/4)", selection: $mix.prefs.controller.fluxBeatjumpBeats) {
                    ForEach(BeatSizes.jump, id: \.self) { Text("±\(BeatSizes.label($0)) Beat").tag($0) }
                }
                Picker("Touchstrip", selection: $mix.prefs.controller.stripMode) { ForEach(ControllerStripMode.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) } }
                sliderRow("Touchstrip-Empfindlichkeit", $mix.prefs.controller.stripSensitivity, 0.2...3, format: "%.1f")
                Stepper("Browse mit Shift: \(mix.prefs.controller.browseFastStep) Zeilen", value: $mix.prefs.controller.browseFastStep, in: 2...50)
                Picker("Shift + LOAD", selection: $mix.prefs.controller.shiftLoad) { ForEach(ControllerShiftLoad.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) } }
                Picker("Browse drücken", selection: $mix.prefs.controller.browsePush) { ForEach(ControllerBrowsePush.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) } }
                Text("shift + drücken = vorhören. matching: filter „passt zum master“ im browser-bereich des controllers").settingsHint()
            }
            Section("LEDs") {
                sliderRow("Helligkeit an", Binding(get: { Double(mix.prefs.controller.ledOn) }, set: { mix.prefs.controller.ledOn = Int($0) }),
                          10...127, step: 1, format: "%.0f")
                sliderRow("Helligkeit aus", Binding(get: { Double(mix.prefs.controller.ledOff) }, set: { mix.prefs.controller.ledOff = Int($0) }),
                          0...40, step: 1, format: "%.0f")
                Text("pad-farben: ⌘, -> anzeige -> cue-farben (gleich wie auf dem bildschirm)").settingsHint()
            }
            Section("Feste Belegung (Standard)") {
                Text("""
                Play (Shift: CUP) · Sync (Shift: Master) · Hotcues 1–4 (Shift: löschen) · Loop-Encoder drehen = Loopgröße, \
                drücken = Loop (Shift: drehen = Beatjump, drücken = Reloop) · Load (Shift: siehe Belegung) · Browse (drücken = Vorhören) · \
                FX: D/W, Regler 1–3, Tasten 1–3 nach FX-Belegung (Standard: Filter/Delay/Reverb + an/aus), Mode = alle aus bzw. Delay-Zeit · FX-Zuweisung.
                """)
                .settingsHint()
            }
            Section("Letztes Ereignis") { Text(status.lastEvent.isEmpty ? "—" : status.lastEvent).font(Theme.mono(11)) }
        }
    }

    /// Beschriftung über/neben einem Geräte-Picker (gleiche Spalten in jedem Block)
    private func deviceLabel(_ key: LocalizedStringKey) -> some View {
        Text(key).font(Theme.label(10, .bold)).textCase(.uppercase).foregroundStyle(Theme.muted)
            .frame(width: 70, alignment: .leading)
    }
}

func headroomPicker(_ title: String, _ v: Binding<Double>) -> some View {
    Picker(title, selection: v) {
        ForEach([0.0, -3, -6, -9, -12], id: \.self) { Text($0 == 0 ? "0 dB" : "\(Int($0)) dB").tag($0) }
    }
}

/// ⌘, -> Analyse: Key-Profile aus der Collection lernen / verwerfen, Stand
private struct KeyProfileSettings: View {
    var body: some View {
        let a = Analyses.shared
        HStack {
            Button("Key-Profile lernen") { a.learnProfiles(from: a.library?.tracks ?? []) }.disabled(a.learnTotal > 0 || a.library == nil)
            Button("Profile verwerfen") { a.discardProfiles() }.disabled(a.profiles == nil)
        }
        Text(a.profiles.map { Analyses.profilesText($0) + " · " + $0.learned.formatted(date: .numeric, time: .omitted) }
             ?? String(localized: "keine gelernten Profile: Krumhansl / Temperley"))
            .settingsHint()
        Text("lernt aus bis zu 300 lokalen tracks mit tonart aus der collection (keine downloads), im hintergrund wie die analyse. treffer auf jedem 5. track gemessen, der nicht gelernt wird. datei: key-profiles.json im MINOS-741-ordner. gilt für die nächste analyse.")
            .settingsHint()
    }
}
