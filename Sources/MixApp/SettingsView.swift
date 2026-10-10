import SwiftUI
import MixCore
import MixEngine

/// Einstellungen (⌘,) – jede Option der App ist hier einstellbar.
struct SettingsView: View {
    var body: some View {
        TabView {
            DeckSettings().tabItem { Text("DECKS") }
            MixerFXSettings().tabItem { Text("MIXER & FX") }
            WaveformSettings().tabItem { Text("ANZEIGE") }
            AudioSettings().tabItem { Text("AUDIO") }
            ControllerSettings().tabItem { Text("CONTROLLER") }
        }
        .frame(width: 600, height: 560)
        .preferredColorScheme(.dark)
    }
}

/// kleine Helfer für Zeilen
private func sliderRow(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, step: Double? = nil,
                       format: String = "%.2f") -> some View {
    LabeledContent(title) {
        HStack {
            if let step { Slider(value: value, in: range, step: step) } else { Slider(value: value, in: range) }
            Text(String(format: format, value.wrappedValue)).monospacedDigit().frame(width: 52, alignment: .trailing)
        }
        .frame(width: 280)
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
                    ForEach(LoadPosition.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                sliderRow("Track-Ende-Warnung (s, 0 = aus)", $mix.prefs.engine.trackEndWarning, 0...90, step: 5, format: "%.0f")
            }
            Section("Master-Clock & Metronom") {
                Picker("Metronom auf Kanalpaar", selection: $mix.prefs.engine.metronomeChannel) {
                    ForEach(Array(stride(from: 0, to: max(2, mix.deviceChannels - 1), by: 2)), id: \.self) { c in
                        Text("\(c + 1)/\(c + 2)").tag(c)
                    }
                }
                Text("im extern-modus z. b. auf das paar vom kopfhörer-cue legen -> klick nur auf dem kopfhörer").font(Theme.mono(10)).foregroundStyle(Theme.muted)
            }
            Section("Tempo & Sync") {
                Toggle("Keylock beim ersten Laden an", isOn: $mix.prefs.engine.keylockDefault)
                Picker("Tempo-Bereich (Standard)", selection: $mix.prefs.engine.tempoRangeDefault) {
                    ForEach([6.0, 8, 10, 16, 50, 100], id: \.self) { Text(String(format: "±%g %%", $0)).tag($0) }
                }
                Toggle("Phase laufend nachführen (Beat-Sync)", isOn: $mix.prefs.engine.phaseLock)
                sliderRow("Pitch-Bend-Stärke", $mix.prefs.engine.bendAmount, 0.01...0.12, format: "%.2f")
            }
            Section("Loops & Beatjump") {
                Picker("Loopgröße (Standard)", selection: $mix.prefs.engine.defaultLoopSize) {
                    ForEach(BeatSizes.loop, id: \.self) { Text(BeatSizes.label($0)).tag($0) }
                }
                Picker("Beatjump-Größe (Standard)", selection: $mix.prefs.engine.defaultJumpSize) {
                    ForEach(BeatSizes.jump, id: \.self) { Text(BeatSizes.label($0)).tag($0) }
                }
            }
            Section("History & Preparation") {
                sliderRow("Als gespielt nach (s hörbar)", $mix.prefs.engine.historyThreshold, 5...120, step: 5, format: "%.0f")
                Toggle("History zusätzlich in Traktors History-Ordner schreiben", isOn: $mix.prefs.ui.historyToTraktor)
                Text("history und preparation werden als traktor-nml gespeichert (~/Library/Application Support/MINOS-741) -> in traktor direkt importierbar. preparation wird bei jedem start archiviert und geleert.")
                    .font(Theme.mono(10)).foregroundStyle(Theme.muted)
            }
            Section("Ansicht") {
                Toggle("4 Decks anzeigen", isOn: $mix.prefs.ui.showFourDecks)
                sliderRow("Vorhören im Browser ab (Anteil)", $mix.prefs.ui.previewStart, 0...0.9, format: "%.1f")
            }
        }
        .formStyle(.grouped)
    }
}

struct MixerFXSettings: View {
    @Environment(MixModel.self) private var mix

    var body: some View {
        @Bindable var mix = mix
        Form {
            Section("Mixer") {
                Toggle("Internen Mixer anzeigen", isOn: $mix.prefs.ui.showMixer)
                Toggle("Auto-Gain (Lautheit aus der Collection)", isOn: $mix.prefs.engine.autoGain)
                Toggle("EQ-Kill (ganz links = aus)", isOn: $mix.prefs.engine.eqKill)
                Picker("Crossfader-Kurve", selection: $mix.prefs.engine.crossfaderCurve) {
                    ForEach(CrossfaderCurve.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                sliderRow("Kanalfilter-Resonanz", $mix.prefs.engine.channelFilterResonance, 0.2...1.5)
            }
            Section("FX-Units (Gruppenmodus: Filter · Delay · Reverb)") {
                Toggle("FX-Units anzeigen", isOn: $mix.prefs.ui.showFXUnits)
                sliderRow("Delay-Feedback", $mix.prefs.engine.delayFeedback, 0...1)
                sliderRow("FX-Filter-Resonanz", $mix.prefs.engine.fxFilterResonance, 0...1)
            }
        }
        .formStyle(.grouped)
    }
}

struct WaveformSettings: View {
    @Environment(MixModel.self) private var mix

    var body: some View {
        @Bindable var mix = mix
        Form {
            Section("Wellenform") {
                Picker("Stil", selection: $mix.prefs.ui.waveformStyle) {
                    ForEach(WaveformStyle.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Farben", selection: $mix.prefs.ui.waveformPalette) {
                    ForEach(WaveformPalette.allCases) { Text($0.rawValue).tag($0) }
                }
                sliderRow("Sichtbare Sekunden je Seite (Zoom)", $mix.prefs.ui.waveformSeconds, 1...16, step: 0.5, format: "%.1f")
                sliderRow("Mindesthöhe (pt, wächst mit dem Fenster)", $mix.prefs.ui.waveformHeight, 30...200, step: 5, format: "%.0f")
                Toggle("Gespielten Teil abdunkeln", isOn: $mix.prefs.ui.dimPlayed)
            }
            Section("Beatgrid") {
                Toggle("Beatgrid anzeigen", isOn: $mix.prefs.ui.showBeatgrid)
                Toggle("Farbig (Phrasen, Takte, Beats)", isOn: $mix.prefs.ui.colorfulGrid)
                Picker("Phrase", selection: $mix.prefs.ui.phraseBeats) {
                    ForEach([16, 32, 64, 128], id: \.self) { Text("\($0) Beats (\($0 / 4) Takte)").tag($0) }
                }
                Toggle("Taktnummern", isOn: $mix.prefs.ui.showBarNumbers)
            }
            Section("Tags (Kommentar 2)") {
                LabeledContent("Trennzeichen") {
                    TextField("", text: $mix.prefs.ui.tagSeparators).font(Theme.mono(13)).frame(width: 80)
                }
                Text("jedes zeichen trennt -> z. b. '·' oder '·»'. leer = leerzeichen.").font(Theme.mono(10)).foregroundStyle(Theme.muted)
            }
            Section("Cue-Farben (Bildschirm und X1-Pads)") {
                Picker("Start-Cue (Load / AutoGrid)", selection: $mix.prefs.x1.colorStartCue) { ForEach(PadColor.allCases) { Text($0.rawValue).tag($0) } }
                Picker("Cue", selection: $mix.prefs.x1.colorCue) { ForEach(PadColor.allCases) { Text($0.rawValue).tag($0) } }
                Picker("Loop", selection: $mix.prefs.x1.colorLoop) { ForEach(PadColor.allCases) { Text($0.rawValue).tag($0) } }
                Picker("Kurzer Loop", selection: $mix.prefs.x1.colorShortLoop) { ForEach(PadColor.allCases) { Text($0.rawValue).tag($0) } }
                Picker("Kurz = bis", selection: $mix.prefs.x1.shortLoopBars) {
                    ForEach([1.0, 2, 4, 8], id: \.self) { Text("\(Int($0)) \($0 == 1 ? "Takt" : "Takte")").tag($0) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct AudioSettings: View {
    @Environment(MixModel.self) private var mix

    var body: some View {
        Form {
            Section("Ausgabegerät") {
                HStack {
                    Picker("Gerät", selection: Binding(
                        get: { mix.deviceUID ?? "" },
                        set: { mix.deviceUID = $0.isEmpty ? nil : $0; mix.applyRouting() })) {
                        Text("Systemstandard").tag("")
                        ForEach(mix.outputDevices) { d in Text("\(d.name) – \(d.channels) Kanäle").tag(d.uid) }
                    }
                    Button { mix.refreshDevices() } label: { Text("↻") }
                        .help("Geräteliste neu einlesen")
                }
                LabeledContent("Kanäle", value: "\(mix.deviceChannels)")
            }
            Section("Mixer") {
                Picker("Modus", selection: Binding(get: { mix.mixerMode }, set: { mix.mixerMode = $0; mix.applyRouting() })) {
                    Text("Intern – Mixer in MINOS-741").tag(MixerMode.internalMixer)
                    Text("Extern – Mischpult (z. B. Xone:96)").tag(MixerMode.external)
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
                    Text("Am Mischpult die Kanal-Eingänge auf USB stellen. EQ, Fader, Crossfader und Kopfhörer-Cue macht dann das Pult; Filter, FX und Gain bleiben in MINOS-741.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Section { Text(mix.engineStatus).font(.callout).foregroundStyle(.secondary) }
        }
        .formStyle(.grouped)
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

struct ControllerSettings: View {
    @Environment(MixModel.self) private var mix
    @Environment(X1Status.self) private var x1

    var body: some View {
        @Bindable var mix = mix
        Form {
            Section("Traktor Kontrol X1 MK2 (nativ, HID)") {
                if x1.devices.isEmpty {
                    Text("Kein X1 MK2 gefunden. Traktor beenden, falls es läuft.").foregroundStyle(.secondary)
                }
                ForEach(x1.devices) { d in
                    HStack {
                        Text("X1 \(d.id)").font(.body.monospaced())
                        Spacer()
                        Picker("Links", selection: Binding(get: { d.left }, set: { x1.assign(d.id, left: $0, right: d.right) })) {
                            ForEach(0..<4, id: \.self) { Text(deckLetters[$0]).tag($0) }
                        }
                        .frame(width: 110)
                        Picker("Rechts", selection: Binding(get: { d.right }, set: { x1.assign(d.id, left: d.left, right: $0) })) {
                            ForEach(0..<4, id: \.self) { Text(deckLetters[$0]).tag($0) }
                        }
                        .frame(width: 120)
                        Picker("Browser", selection: Binding(get: { d.pane }, set: { x1.assignPane(d.id, $0) })) {
                            Text("links").tag(0)
                            Text("rechts").tag(1)
                        }
                        .frame(width: 130)
                        Button("Blinken") { x1.identify(d.id) }.help("Pads dieses X1 leuchten kurz weiß")
                    }
                }
            }
            Section("Belegung") {
                Picker("Cue-Taste", selection: $mix.prefs.x1.cueAction) { ForEach(X1CueAction.allCases) { Text($0.rawValue).tag($0) } }
                Toggle("Flux antippen schaltet Flux-Modus", isOn: $mix.prefs.x1.fluxTapToggles)
                Picker("Flux halten + Hotcue 3/4 = Beatjump", selection: $mix.prefs.x1.fluxBeatjumpBeats) {
                    ForEach(BeatSizes.jump, id: \.self) { Text("±\(BeatSizes.label($0)) Beat").tag($0) }
                }
                Picker("Touchstrip", selection: $mix.prefs.x1.stripMode) { ForEach(X1StripMode.allCases) { Text($0.rawValue).tag($0) } }
                sliderRow("Touchstrip-Empfindlichkeit", $mix.prefs.x1.stripSensitivity, 0.2...3, format: "%.1f")
                Stepper("Browse mit Shift: \(mix.prefs.x1.browseFastStep) Zeilen", value: $mix.prefs.x1.browseFastStep, in: 2...50)
            }
            Section("LEDs") {
                sliderRow("Helligkeit an", Binding(get: { Double(mix.prefs.x1.ledOn) }, set: { mix.prefs.x1.ledOn = Int($0) }),
                          10...127, step: 1, format: "%.0f")
                sliderRow("Helligkeit aus", Binding(get: { Double(mix.prefs.x1.ledOff) }, set: { mix.prefs.x1.ledOff = Int($0) }),
                          0...40, step: 1, format: "%.0f")
                Text("pad-farben: ⌘, -> anzeige -> cue-farben (gleich wie auf dem bildschirm)").font(Theme.mono(10)).foregroundStyle(Theme.muted)
            }
            Section("Feste Belegung (NI-Standard)") {
                Text("""
                Play (Shift: CUP) · Sync (Shift: Master) · Hotcues 1–4 (Shift: löschen) · Loop-Encoder drehen = Loopgröße, \
                drücken = Loop (Shift: drehen = Beatjump, drücken = Reloop) · Load · Browse (drücken = Vorhören) · \
                FX: D/W, Regler 1–3 = Filter/Delay/Reverb, Tasten 1–3 = an/aus, Mode = alle aus bzw. Delay-Zeit · FX-Zuweisung.
                """)
                .font(.callout).foregroundStyle(.secondary)
            }
            Section("Letztes Ereignis") { Text(x1.lastEvent.isEmpty ? "—" : x1.lastEvent).font(.callout.monospaced()) }
        }
        .formStyle(.grouped)
    }
}
