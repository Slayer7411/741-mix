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
            TagColorSettings().tabItem { Text("TAGS") }
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
                    ForEach(LoadPosition.allCases, id: \.self) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
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
                Picker("Sync-Modus", selection: $mix.prefs.engine.syncMode) {
                    ForEach(SyncMode.allCases, id: \.self) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                sliderRow("Pitch-Bend-Stärke", $mix.prefs.engine.bendAmount, 0.01...0.12, format: "%.2f")
                sliderRow("Link-Versatz (ms)", $mix.prefs.engine.linkOffsetMs, -50...50, step: 1, format: "%+.0f")
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
                Toggle("History zusätzlich in den History-Ordner der Collection schreiben", isOn: $mix.prefs.ui.historyToExternal)
                Text("history und preparation werden als nml gespeichert (~/Library/Application Support/MINOS-741) -> direkt in die collection importierbar. preparation wird bei jedem start archiviert und geleert.")
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
                sliderRow("Reverb-Pegel (dB)", $mix.prefs.engine.reverbLevelDb, -18...6, step: 1, format: "%+.0f")
                sliderRow("Reverb-Helligkeit", $mix.prefs.engine.reverbBrightness, 0...1)
                sliderRow("Reverb-Vorverzögerung (ms)", $mix.prefs.engine.reverbPreDelayMs, 0...120, step: 1, format: "%.0f")
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
                    ForEach(WaveformStyle.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                Picker("Farben", selection: $mix.prefs.ui.waveformPalette) {
                    ForEach(WaveformPalette.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
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
                Toggle("Marker alle 8 / 16 / 32 Takte (magenta)", isOn: $mix.prefs.ui.barMarkers)
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
                HStack {
                    Button("Neu verbinden") { mix.reconnect() }
                    Text("startet die Ausgabe neu, z. B. wenn das Interface nach einem USB-Aussetzer stumm bleibt")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Text("Eine neue Samplerate gilt am Gerät sofort, MINOS-741 rechnet ab dem nächsten Start damit.")
                    .font(.callout).foregroundStyle(.secondary)
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
    @Environment(ControllerStatus.self) private var status

    var body: some View {
        @Bindable var mix = mix
        Form {
            Section("Controller (nativ, HID)") {
                if status.devices.isEmpty {
                    Text("Kein Controller gefunden. Andere DJ-Software beenden, falls sie läuft.").foregroundStyle(.secondary)
                }
                ForEach(status.devices) { d in
                    HStack {
                        Text("Controller \(d.id)").font(.body.monospaced())
                        Spacer()
                        Picker("Links", selection: Binding(get: { d.left }, set: { status.assign(d.id, left: $0, right: d.right) })) {
                            ForEach(0..<4, id: \.self) { Text(deckLetters[$0]).tag($0) }
                        }
                        .frame(width: 110)
                        Picker("Rechts", selection: Binding(get: { d.right }, set: { status.assign(d.id, left: d.left, right: $0) })) {
                            ForEach(0..<4, id: \.self) { Text(deckLetters[$0]).tag($0) }
                        }
                        .frame(width: 120)
                        Picker("Browser", selection: Binding(get: { d.pane }, set: { status.assignPane(d.id, $0) })) {
                            Text("links").tag(0)
                            Text("rechts").tag(1)
                        }
                        .frame(width: 130)
                        Picker("FX", selection: Binding(get: { d.fxUnit }, set: { status.assignFX(d.id, $0) })) {
                            Text(verbatim: "FX1 + FX3").tag(10)
                            Text(verbatim: "FX2 + FX4").tag(11)
                            Text(verbatim: "FX1 + FX2").tag(-1)
                            Text(verbatim: "FX1").tag(0)
                            Text(verbatim: "FX2").tag(1)
                        }
                        .frame(width: 120)
                        Button("Blinken") { status.identify(d.id) }.help("Pads dieses Controllers leuchten kurz weiß")
                    }
                }
            }
            Section("Belegung") {
                Picker("Cue-Taste", selection: $mix.prefs.controller.cueAction) { ForEach(ControllerCueAction.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) } }
                Toggle("Flux antippen schaltet Flux-Modus", isOn: $mix.prefs.controller.fluxTapToggles)
                Picker("Flux halten + Pads", selection: $mix.prefs.controller.fluxPads) { ForEach(ControllerFluxPads.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) } }
                Picker("Beatjump-Größe (Flux + Pad 3/4)", selection: $mix.prefs.controller.fluxBeatjumpBeats) {
                    ForEach(BeatSizes.jump, id: \.self) { Text("±\(BeatSizes.label($0)) Beat").tag($0) }
                }
                Picker("Touchstrip", selection: $mix.prefs.controller.stripMode) { ForEach(ControllerStripMode.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) } }
                sliderRow("Touchstrip-Empfindlichkeit", $mix.prefs.controller.stripSensitivity, 0.2...3, format: "%.1f")
                Stepper("Browse mit Shift: \(mix.prefs.controller.browseFastStep) Zeilen", value: $mix.prefs.controller.browseFastStep, in: 2...50)
            }
            Section("LEDs") {
                sliderRow("Helligkeit an", Binding(get: { Double(mix.prefs.controller.ledOn) }, set: { mix.prefs.controller.ledOn = Int($0) }),
                          10...127, step: 1, format: "%.0f")
                sliderRow("Helligkeit aus", Binding(get: { Double(mix.prefs.controller.ledOff) }, set: { mix.prefs.controller.ledOff = Int($0) }),
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
            Section("Letztes Ereignis") { Text(status.lastEvent.isEmpty ? "—" : status.lastEvent).font(.callout.monospaced()) }
        }
        .formStyle(.grouped)
    }
}

func headroomPicker(_ title: String, _ v: Binding<Double>) -> some View {
    Picker(title, selection: v) {
        ForEach([0.0, -3, -6, -9, -12], id: \.self) { Text($0 == 0 ? "0 dB" : "\(Int($0)) dB").tag($0) }
    }
}
