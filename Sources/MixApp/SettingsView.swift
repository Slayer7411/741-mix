import SwiftUI
import AppKit
import MixCore
import MixEngine

/// Einstellungen (⌘,) – jede Option der App ist hier einstellbar.
/// Links die Bereiche (neuer Bereich = eine Zeile in `tabs`), rechts der Inhalt scrollbar.
/// Reihenfolge: allgemein -> speziell; per Ziehen in der Seitenleiste änderbar (`ui.settingsTabOrder`).
struct SettingsView: View {
    static let tabs: [SettingsTab] = [
        SettingsTab("AUDIO") { AudioSettings() },
        SettingsTab("ANZEIGE") { DisplaySettings() },
        SettingsTab("DECKS") { DeckSettings() },
        SettingsTab("MIXER & FX") { MixerFXSettings() },
        SettingsTab("PLUGINS") { PluginSettingsView() },
        SettingsTab("BROWSER") { BrowserSettings() },
        SettingsTab("TAGS") { TagColorSettings() },
        SettingsTab("CLOUD") { CloudSettings() },
        SettingsTab("TASTATUR") { ShortcutSettings() },
        SettingsTab("CONTROLLER") { ControllerSettings() },
    ]

    @Environment(MixModel.self) private var mix
    @State private var nav: SettingsNav

    /// `selection`: Titel-Schlüssel des Bereichs beim Öffnen; `nav` von außen nur im UI-Test
    init(selection: String = "AUDIO", nav: SettingsNav? = nil) {
        _nav = State(initialValue: nav ?? SettingsNav(tab: selection))
    }

    /// Bereiche in der gespeicherten Reihenfolge
    static func ordered(_ saved: [String]) -> [SettingsTab] {
        let byID = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        return SettingsTabOrder.merged(saved, defaults: tabs.map(\.id)).compactMap { byID[$0] }
    }

    var body: some View {
        let tabs = Self.ordered(mix.prefs.ui.settingsTabOrder)
        let current = tabs.first { $0.id == nav.tab } ?? tabs[0]
        let hits = nav.query.isEmpty ? [] : SettingsSearch.shared.search(nav.query)
        HStack(spacing: 0) {
            SettingsSidebar(tabs: tabs, selection: Binding(get: { nav.showResults ? "" : nav.tab }, set: { nav.select(tab: $0) })) { id, target in
                let order = SettingsTabOrder.moved(tabs.map(\.id), id, before: target)
                mix.prefs.ui.settingsTabOrder = order == Self.tabs.map(\.id) ? [] : order
            } reset: {
                mix.prefs.ui.settingsTabOrder = []
            } search: {
                SettingsSearchField(nav: nav, hits: hits)
            }
            Rectangle().fill(Theme.hairline).frame(width: 1)
            if nav.showResults {
                SettingsResults(nav: nav, hits: hits)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        SettingsPage { current.content() }
                    }
                    .id(current.id)
                    .background(Theme.chitin)
                    .task(id: nav.jump) { await jump(proxy, tab: current.id) }
                }
                .environment(\.settingsFlash, nav.flash)
            }
        }
        .frame(minWidth: 720, idealWidth: 820, maxWidth: .infinity, minHeight: 520, idealHeight: 640, maxHeight: .infinity)
        .background(Theme.void)
        .background(ResizableWindow { nav.window = $0 })
        .preferredColorScheme(.dark)
        .onAppear { SettingsNav.active = nav; takeRequest() }
        // Sprung aus der Effekt-Auswahl (gesperrtes Plugin → PLUGINS)
        .onChange(of: mix.settingsRequest) { takeRequest() }
    }

    private func takeRequest() {
        // nur das zuletzt geöffnete Einstellungs-Fenster (ein älteres, noch nicht abgebautes nähme die Anfrage sonst weg)
        guard let t = mix.settingsRequest, SettingsNav.active === nav else { return }
        if Self.tabs.contains(where: { $0.id == t }) { nav.select(tab: t) }
        mix.settingsRequest = nil
    }

    /// zur Zeile des Treffers scrollen (ausgeblendet: zur Ersatzzeile), ~1,5 s lila
    private func jump(_ proxy: ScrollViewProxy, tab: String) async {
        guard let j = nav.jump, j.entry.tab == tab else { return }
        try? await Task.sleep(for: .milliseconds(80))   // Bereich aufgebaut, Anker gemeldet
        guard !Task.isCancelled else { return }
        let e = j.entry
        let anchor = SettingsAnchors.present.contains(e.anchor) ? e.anchor : (e.alt ?? e.anchor)
        proxy.scrollTo(anchor, anchor: .center)
        nav.flash = anchor
        try? await Task.sleep(for: .seconds(1.5))
        if nav.flash == anchor { nav.flash = nil }
    }
}

/// Reihenfolge der Bereiche: gespeicherte Schlüssel, unbekannte fallen weg, neue Bereiche stehen hinter ihrem
/// Vorgänger aus der Standardreihenfolge
enum SettingsTabOrder {
    static func merged(_ saved: [String], defaults: [String]) -> [String] {
        var out: [String] = []
        for id in saved where defaults.contains(id) && !out.contains(id) { out.append(id) }
        for (i, id) in defaults.enumerated() where !out.contains(id) {
            let at = defaults[..<i].reversed().lazy.compactMap { p in out.firstIndex(of: p) }.first.map { $0 + 1 } ?? 0
            out.insert(id, at: at)
        }
        return out
    }

    /// `id` vor `target` setzen (target nil = ans Ende)
    static func moved(_ order: [String], _ id: String, before target: String?) -> [String] {
        guard id != target, order.contains(id) else { return order }
        var out = order.filter { $0 != id }
        out.insert(id, at: target.flatMap { out.firstIndex(of: $0) } ?? out.count)
        return out
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

/// Seitenleiste: Cinzel versal, roter Balken am aktiven Eintrag; Einträge per Ziehen umsortieren
private struct SettingsSidebar<Search: View>: View {
    let tabs: [SettingsTab]
    @Binding var selection: String
    /// gezogener Bereich, Ziel (davor; nil = ans Ende)
    let move: (String, String?) -> Void
    let reset: () -> Void
    @ViewBuilder let search: Search
    @State private var target: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: "MINOS-741").font(Theme.label(11, .bold)).foregroundStyle(Theme.muted)
                .padding(.leading, 18).padding(.top, 20).padding(.bottom, 14)
            search
            ForEach(tabs) { tab in
                let active = tab.id == selection
                Button { selection = tab.id } label: {
                    HStack(spacing: 0) {
                        Rectangle().fill(active ? Theme.state : .clear).frame(width: 3)
                        Text(tab.title).font(Theme.label(12, .bold))
                            .foregroundStyle(active ? Theme.bone : Theme.bone.opacity(0.6))
                            .lineLimit(1)
                            .padding(.leading, 15)
                        Spacer(minLength: 0)
                    }
                    .frame(height: 32)
                    .background(active ? Theme.chitinRaised : .clear)
                    .overlay(alignment: .top) { if target == tab.id { Rectangle().fill(Theme.state).frame(height: 2) } }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .draggable(tab.id)
                .dropDestination(for: String.self) { ids, _ in
                    guard let id = ids.first else { return false }
                    move(id, tab.id)
                    return true
                } isTargeted: { on in
                    if on { target = tab.id } else if target == tab.id { target = nil }
                }
                .contextMenu { Button("Standard-Reihenfolge") { reset() } }
            }
            // unter dem letzten Eintrag: ans Ende
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .top) { if target == "" { Rectangle().fill(Theme.state).frame(height: 2) } }
                .contentShape(Rectangle())
                .dropDestination(for: String.self) { ids, _ in
                    guard let id = ids.first else { return false }
                    move(id, nil)
                    return true
                } isTargeted: { on in
                    if on { target = "" } else if target == "" { target = nil }
                }
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
    private func rows(_ content: SubviewsCollection) -> some View {
        ForEach(subviews: content) { row in
            if row.containerValues.settingsHint {
                row.padding(.top, 1).padding(.bottom, 6)
            } else {
                row.padding(.vertical, 5)
            }
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 30) {
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
                    // eager, damit jeder Anker für den Sprung der Suche existiert; lange Listen (Plugins, Tags) lazy
                    if section.content.count > 40 {
                        LazyVStack(alignment: .leading, spacing: 0) { rows(section.content) }
                    } else {
                        VStack(alignment: .leading, spacing: 0) { rows(section.content) }
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
    let found: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView { let p = Probe(); p.found = found; return p }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Probe: NSView {
        var found: ((NSWindow) -> Void)?
        /// erster Responder beim Öffnen statt des Suchfelds: Tasten ohne ⌘ lösen weiter App-Kürzel aus, bis ⌘F oder Klick
        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let w = window else { return }
            found?(w)
            w.initialFirstResponder = self
            w.makeFirstResponder(self)
            w.styleMask.insert(.resizable)
            // Hauptfenster im Vollbild (auch auf einem anderen Bildschirm): Einstellungen in dessen Space und auf
            // dessen Bildschirm, nicht auf dem Schreibtisch nebenan
            w.collectionBehavior.insert([.fullScreenAuxiliary, .moveToActiveSpace])
            if let main = NSApp.windows.first(where: { $0.styleMask.contains(.fullScreen) || $0.isMainWindow }),
               main !== w, let screen = main.screen, w.screen !== screen {
                let f = screen.visibleFrame, size = w.frame.size
                w.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.midY - size.height / 2))
            }
            DispatchQueue.main.async { w.makeKeyAndOrderFront(nil) }
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
                    .settingsAnchor("decks.snap")
                Toggle("Quant (Sprünge halten die Beat-Phase)", isOn: $mix.prefs.engine.quantize)
                    .settingsAnchor("decks.quant")
                Toggle("Hotcue-Sprung hält die Beat-Phase", isOn: $mix.prefs.engine.hotcueKeepsPhase)
                    .settingsAnchor("decks.hotcuephase")
                Picker("Beim Laden springen zu", selection: $mix.prefs.engine.loadPosition) {
                    ForEach(LoadPosition.allCases, id: \.self) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                .settingsAnchor("decks.loadpos")
                sliderRow("Track-Ende-Warnung (s, 0 = aus)", $mix.prefs.engine.trackEndWarning, 0...90, step: 5, format: "%.0f", unit: "s")
                    .settingsAnchor("decks.endwarning")
                Toggle("Lade-Schutz bei laufendem Deck", isOn: $mix.prefs.engine.loadProtection)
                    .settingsAnchor("decks.loadprotect")
                Text("spielt das deck, wird nicht geladen (doppelklick, taste, controller-load) -> hinweis in der statusleiste. trotzdem laden: ⌥-doppelklick, shift + load, taste „auswahl ins fokus-deck laden (auch wenn es spielt)“.")
                    .settingsHint()
            }
            Section("Tempo & Sync") {
                Toggle("Keylock beim ersten Laden an", isOn: $mix.prefs.engine.keylockDefault)
                    .settingsAnchor("decks.keylock")
                Picker("Tempo-Bereich (Standard)", selection: $mix.prefs.engine.tempoRangeDefault) {
                    ForEach([6.0, 8, 10, 16, 50, 100], id: \.self) { Text(String(format: "±%g %%", $0)).tag($0) }
                }
                .settingsAnchor("decks.temporange")
                Toggle("Phase laufend nachführen (Beat-Sync)", isOn: $mix.prefs.engine.phaseLock)
                    .settingsAnchor("decks.phaselock")
                Picker("Sync-Modus", selection: $mix.prefs.engine.syncMode) {
                    ForEach(SyncMode.allCases, id: \.self) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                .settingsAnchor("decks.syncmode")
                sliderRow("Pitch-Bend-Stärke", $mix.prefs.engine.bendAmount, 0.01...0.12, format: "%.2f")
                    .settingsAnchor("decks.bend")
                Picker("Wellenform greifen", selection: $mix.prefs.ui.waveGrab) {
                    ForEach(WaveGrab.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                .settingsAnchor("decks.wavegrab")
                sliderRow("Link-Versatz (ms)", $mix.prefs.engine.linkOffsetMs, -50...50, step: 1, format: "%+.0f", unit: "ms")
                    .settingsAnchor("decks.linkoffset")
            }
            Section("Loops & Beatjump") {
                Picker("Loopgröße (Standard)", selection: $mix.prefs.engine.defaultLoopSize) {
                    ForEach(BeatSizes.loop, id: \.self) { Text(BeatSizes.label($0)).tag($0) }
                }
                .settingsAnchor("decks.loopsize")
                Picker("Beatjump-Größe (Standard)", selection: $mix.prefs.engine.defaultJumpSize) {
                    ForEach(BeatSizes.jump, id: \.self) { Text(BeatSizes.label($0)).tag($0) }
                }
                .settingsAnchor("decks.jumpsize")
                Group {
                    Toggle("Loop-Snap auf Loop-Cues", isOn: $mix.prefs.engine.loopSnapCues)
                        .settingsAnchor("decks.loopsnap.cues")
                    Stepper("Fenster (Beats): \(Int(mix.prefs.engine.loopSnapCueBeats))", value: $mix.prefs.engine.loopSnapCueBeats, in: 1...8, step: 1)
                        .disabled(!mix.prefs.engine.loopSnapCues)
                        .settingsAnchor("decks.loopsnap.window")
                    Toggle("Loop-Snap auf 4-Bar-Raster", isOn: $mix.prefs.engine.loopSnapPhrase)
                        .settingsAnchor("decks.loopsnap.phrase")
                    Stepper("Toleranz (Beats): \(Int(mix.prefs.engine.loopSnapPhraseBeats))", value: $mix.prefs.engine.loopSnapPhraseBeats, in: 1...8, step: 1)
                        .disabled(!mix.prefs.engine.loopSnapPhrase)
                        .settingsAnchor("decks.loopsnap.tolerance")
                    Text("nur mit snap. loop, loop in: ein loop-cue, der bis zum fenster vor der position beginnt oder gerade überspielt wird, wird übernommen; sonst beginnt der loop auf der nächsten 4-takt-grenze (ab grid-anker) innerhalb der toleranz; sonst normaler snap. kein sprung: die position läuft in den loop hinein oder ist schon drin.")
                        .settingsHint()
                }
                .disabled(!mix.prefs.engine.snap)
                Picker("Active Loop greift", selection: $mix.prefs.engine.activeLoopMode) {
                    ForEach(ActiveLoopMode.allCases, id: \.self) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                .settingsAnchor("decks.activeloop")
                Text("rechtsklick auf einen loop-hotcue -> active loop (punkt auf der taste, gestrichelter rahmen in der wellenform). erreicht die position den loop-anfang, rastet der loop ein, die loop-taste verlässt ihn. gespeichert je track in den eigenen änderungen.")
                    .settingsHint()
                Picker("Auto-Loop beim Laden", selection: $mix.prefs.engine.autoLoopBars) {
                    Text("Aus").tag(0)
                    ForEach([4, 8, 16, 32], id: \.self) { Text("\($0) Takte").tag($0) }
                }
                .background(UITestMark(name: "auto loop"))
                .settingsAnchor("decks.autoloop")
                Text("nur wenn der track keinen loop hat (loop-hotcue, loop-memory-cue). beginnt am ersten phrasenanfang (phrasen-anker, sonst grid-anker) im schnitt, nicht aktiv, rahmen mit AUTO in der wellenform. reloop springt hinein, loop übernimmt ihn ohne sprung, wenn die position darin oder kurz davor liegt. nicht gespeichert.")
                    .settingsHint()
            }
            Section("Zeilen je Deck") {
                ForEach(Array(DeckRows.all.enumerated()), id: \.offset) { _, row in
                    Toggle(LocalizedStringKey(row.1), isOn: Binding(get: { mix.prefs.ui[keyPath: row.0] },
                                                                  set: { mix.prefs.ui[keyPath: row.0] = $0 }))
                }
                .settingsAnchor("decks.rows")
                Toggle("Kompakte Decks (ohne Pitch-Fader, Hotcues, Grid-Werkzeuge)", isOn: $mix.prefs.ui.compactDecks)
                    .settingsAnchor("decks.compact")
                Text("auch im menü decks -> zeilen / kompakte decks. ohne pitch-fader nimmt die wellenform die breite. wellenform und kopfzeile bleiben immer.").settingsHint()
            }
            Section("Größen") {
                sliderRow("Cover-Breite (pt)", $mix.prefs.ui.deckCoverSize, UIPrefs.deckCoverRange, step: 4, format: "%.0f", unit: "pt")
                    .disabled(!mix.prefs.ui.showDeckCover)
                    .background(UITestMark(name: "cover size"))
                    .settingsAnchor("decks.coversize")
                sliderRow("Übersicht Höhe (pt)", $mix.prefs.ui.overviewHeight, UIPrefs.overviewHeightRange, step: 2, format: "%.0f", unit: "pt")
                    .disabled(!mix.prefs.ui.deckRows.overview)
                    .background(UITestMark(name: "overview height"))
                    .settingsAnchor("decks.overviewheight")
                Text("für alle decks, wächst mit dem zoom. cover bis 40 pt im kopf, darüber eigene spalte links über kopf und wellenform; rechts bleiben mindestens 360 pt für titel und anzeigen, sonst wird das cover schmaler. cover an/aus: ⌘, -> browser -> cover. beide werte gehören zum ansichts-profil.").settingsHint()
            }
            Section("Master-Clock & Metronom") {
                Picker("Metronom auf Kanalpaar", selection: $mix.prefs.engine.metronomeChannel) {
                    ForEach(Array(stride(from: 0, to: max(2, mix.deviceChannels - 1), by: 2)), id: \.self) { c in
                        Text("\(c + 1)/\(c + 2)").tag(c)
                    }
                }
                .settingsAnchor("decks.metronome")
                Text("im extern-modus z. b. auf das paar vom kopfhörer-cue legen -> klick nur auf dem kopfhörer").settingsHint()
            }
            Section("Phrasen-Anker") {
                Picker("Grid-Anker auf Phrasen ausrichten", selection: $mix.prefs.engine.phraseAnchor) {
                    ForEach(PhraseAnchorMode.allCases, id: \.self) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                .settingsAnchor("decks.phraseanchor")
                Text("beim laden prüft minos, ob die strukturwechsel des tracks auf 8-takt-grenzen ab dem grid-anker liegen. vorschlagen -> roter phrase-knopf in der grid-zeile, automatisch -> anker wird um ganze beats verschoben. bpm und raster bleiben, gespeichert in den eigenen änderungen, nie in der collection.")
                    .font(Theme.mono(10)).foregroundStyle(Theme.muted)
            }
            Section("EDIT-Modus & Tool-Loops") {
                Picker("Raster beim Markieren", selection: $mix.prefs.ui.editSnap) {
                    ForEach(EditSnap.allCases, id: \.self) { Text(verbatim: $0.label).tag($0) }
                }
                .settingsAnchor("decks.edit.snap")
                Toggle("Schneiden: Ergebnis ins Deck laden", isOn: $mix.prefs.ui.cutLoadsResult)
                    .settingsAnchor("decks.edit.cutload")
                HStack {
                    Text("Tool-Loops in Ordner …")
                    Spacer()
                    Text(mix.prefs.ui.toolLoopFolder.isEmpty ? String(localized: "neben dem Original") : (mix.prefs.ui.toolLoopFolder as NSString).abbreviatingWithTildeInPath)
                        .font(Theme.mono(10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Button("Wählen …") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.canCreateDirectories = true
                        if panel.runModal() == .OK, let u = panel.url { mix.prefs.ui.toolLoopFolder = u.path }
                    }
                    if !mix.prefs.ui.toolLoopFolder.isEmpty { Button("Neben dem Original") { mix.prefs.ui.toolLoopFolder = "" } }
                }
                .settingsAnchor("decks.edit.toolfolder")
                Text("edit-modus: ziehen markiert auf dem raster, klick setzt eine schnittmarke, die zeile bearbeitet die schnittliste, das deck spielt sie. render schreibt <name> [cut].m4a, tool 2 · 4 · 8 · 16 schreibt <name> [tool-loop n].m4a.")
                    .settingsHint()
                Toggle("Vorbereiten AMP: Clipping erlauben (über 0 dBFS, Spitzen hart begrenzt)", isOn: $mix.prefs.ui.prepAllowClipping)
                    .settingsAnchor("decks.prep.clip")
                Toggle("Vorbereiten JOIN: Tempo der zweiten angleichen (bis ±0,5 %)", isOn: $mix.prefs.ui.prepJoinMatchTempo)
                    .settingsAnchor("decks.prep.jointempo")
                Text("vorbereiten (profil oder deck-zeile): amp hebt nur an (samples × faktor, kein limiter), ohne clipping höchstens bis 0 dbfs, norm = spitze −0.3 dbfs. join hängt die zweite datei am nächsten taktanfang an, split teilt am takt. alles als neue datei neben dem original.")
                    .settingsHint()
            }
            GrooveSettingsSection()
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
                    .settingsAnchor("mixer.show")
                Toggle("Auto-Gain (Lautheit aus der Collection)", isOn: $mix.prefs.engine.autoGain)
                    .settingsAnchor("mixer.autogain")
                headroomPicker("Headroom", $mix.prefs.engine.headroomInternal)
                    .settingsAnchor("mixer.headroom")
            }
            Section("Mixer-Optionen") {
                Toggle("EQ-Kill (ganz links = aus)", isOn: $mix.prefs.engine.eqKill)
                    .settingsAnchor("mixer.eqkill")
                Picker("Crossfader-Kurve", selection: $mix.prefs.engine.crossfaderCurve) {
                    ForEach(CrossfaderCurve.allCases, id: \.self) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                .settingsAnchor("mixer.xfader")
                sliderRow("Kanalfilter-Resonanz", $mix.prefs.engine.channelFilterResonance, 0.2...1.5)
                    .settingsAnchor("mixer.filterres")
            }
            Section("Externer Mixer") {
                headroomPicker("Headroom", $mix.prefs.engine.headroomExternal)
                    .settingsAnchor("mixer.ext.headroom")
                Toggle("Auto-Gain", isOn: $mix.prefs.engine.autoGainExternal)
                    .settingsAnchor("mixer.ext.autogain")
                Toggle("Main-Volume wirkt auch extern", isOn: $mix.prefs.engine.masterVolumeExternal)
                    .settingsAnchor("mixer.ext.mainvol")
            }
            Section("FX-Units (Insert-Slots)") {
                Toggle("FX-Units anzeigen", isOn: $mix.prefs.ui.showFXUnits)
                    .settingsAnchor("fx.show")
                Picker("Anzahl FX-Units", selection: $mix.prefs.ui.fxUnitCount) {
                    Text(verbatim: "2").tag(2)
                    Text(verbatim: "4").tag(4)
                }
                .pickerStyle(.segmented)
                .settingsAnchor("fx.count")
                sliderRow("Delay-Feedback", $mix.prefs.engine.delayFeedback, 0...1)
                    .settingsAnchor("fx.delayfb")
                sliderRow("FX-Filter-Resonanz", $mix.prefs.engine.fxFilterResonance, 0...1)
                    .settingsAnchor("fx.filterres")
                Text("delay-feedback und filter-resonanz gelten für slots ohne eigenen wert (vorlage gruppe, neue delays) und für die filter in delay und roll.")
                    .settingsHint()
                Picker("Reverb-Typ", selection: $mix.prefs.engine.reverbType) {
                    ForEach(ReverbType.allCases, id: \.self) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                .settingsAnchor("fx.reverbtype")
                sliderRow("Reverb-Pegel (dB)", $mix.prefs.engine.reverbLevelDb, -18...6, step: 1, format: "%+.0f")
                    .settingsAnchor("fx.reverblevel")
                sliderRow("Reverb-Helligkeit", $mix.prefs.engine.reverbBrightness, 0...1)
                    .settingsAnchor("fx.reverbbright")
                sliderRow("Reverb-Vorverzögerung (ms)", $mix.prefs.engine.reverbPreDelayMs, 0...120, step: 1, format: "%.0f")
                    .settingsAnchor("fx.reverbpredelay")
            }
            Section("FX-Belegung (D/W · Regler · Tasten)") {
                LabeledContent("Parameter suchen") {
                    TextField("", text: $search, prompt: Text("Name oder Gruppe")).settingsField()
                }
                .settingsAnchor("fx.mapping")
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
                Text("rechtsklick auf einen regler oder eine taste der fx-unit wählt den parameter direkt – jeder parameter jedes slots. gilt für die unit und wird je rack gemerkt (effekte in reihenfolge): hat eine unit dieselben slots wieder, ist die belegung wieder da. die sitzung behält die belegung jeder unit. tasten: schalter um, listen eine stufe weiter, stufenlose zwischen min und max. d/w der unit wirkt nur, solange ein bedienelement darauf liegt.")
                    .settingsHint()
            }
            Section("Gemerkte Belegungen") {
                let stored = mix.prefs.engine.fxMappings
                Group {
                    if stored.isEmpty { Text("keine – alle racks in standardbelegung").settingsHint() }
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
                .settingsAnchor("fx.mappings")
            }
            Section("Gemerkte Racks") {
                let chains = mix.prefs.engine.pluginChains
                Group {
                    if chains.isEmpty { Text("keine – fx-unit oder master -> rack -> racks -> rack speichern …").settingsHint() }
                    ForEach(chains.keys.sorted(), id: \.self) { k in
                        LabeledContent {
                            HStack(spacing: 10) {
                                Text(verbatim: mix.effectName((chains[k] ?? []).map(\.id).joined(separator: FXCatalog.rackSeparator)))
                                    .foregroundStyle(Theme.muted).lineLimit(1)
                                Button("Vergessen") { mix.deleteRack(k) }
                            }
                        } label: {
                            Text(verbatim: k)
                        }
                    }
                }
                .settingsAnchor("fx.racks")
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

/// ⌘, -> ANZEIGE: Sprache, Zoom, Layout, Profile, Statusleiste, Wellenform, Beatgrid, Cue-Farben
struct DisplaySettings: View {
    @Environment(MixModel.self) private var mix

    var body: some View {
        @Bindable var mix = mix
        Form {
            Section("Sprache") {
                Picker("Sprache (wirkt nach Neustart)", selection: $mix.prefs.ui.language) {
                    Text("Systemstandard").tag("system")
                    Text(verbatim: "Deutsch").tag("de")
                    Text(verbatim: "English").tag("en")
                }
                .settingsAnchor("display.language")
            }
            Section("Zoom") {
                Picker("Hauptfenster (⌘+ / ⌘− / ⌘0)", selection: Binding(get: { mix.prefs.ui.zoom }, set: { ZoomControl.set($0, mix: mix) })) {
                    ForEach(Set(ZoomSteps.levels + [mix.prefs.ui.zoom]).sorted(), id: \.self) { Text(verbatim: ZoomSteps.percent($0)).tag($0) }
                }
                .settingsAnchor("display.zoom")
            }
            Section("Layout") {
                Picker("Decks anzeigen", selection: $mix.prefs.ui.deckCount) {
                    Text("1 Deck").tag(1)
                    Text("2 Decks").tag(2)
                    Text("4 Decks").tag(4)
                }
                .settingsAnchor("display.deckcount")
                sliderRow("Abstand zwischen Decks (pt)", $mix.prefs.ui.deckGap, 0...12, step: 1, format: "%.0f")
                    .settingsAnchor("display.deckgap")
                Text("0 = die Wellenformen enden an den Deck-Rändern und am Fensterrand, nur die Rahmenlinie dazwischen.").settingsHint()
                Picker("Browser-Anordnung", selection: $mix.prefs.ui.browserLayout) { ForEach(BrowserLayout.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) } }
                    .settingsAnchor("display.browserlayout")
                Toggle("Ordner-Baum ausblenden, solange Decks sichtbar sind", isOn: $mix.prefs.ui.hideTreeWithDecks)
                    .settingsAnchor("display.hidetree")
            }
            LayoutProfileSettings()
            Section("Statusleiste") {
                Picker("Anzeigen", selection: $mix.prefs.ui.statusBar) { ForEach(StatusBarMode.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) } }
                    .settingsAnchor("display.statusbar")
                Text("automatisch: die leiste fährt hoch, wenn die maus am unteren fensterrand steht oder eine warnung kommt, und liegt dann über dem browser. aus: keine leiste, auch keine meldungen. auch im menü darstellung.")
                    .settingsHint()
                Toggle("Last-Anzeigen (DSP, Latenz, Aussetzer, Speicher, CPU)", isOn: $mix.prefs.ui.showMeters)
                    .settingsAnchor("display.meters")
                Text("dsp = rechenzeit des audio-blocks ÷ blockdauer, rot ab 70 %. aussetzer: blöcke über dem budget plus überlast-meldungen des geräts, klick setzt zurück. meldungen: klick zeigt die letzten 50.")
                    .settingsHint()
            }
            Section("Wellenform") {
                Picker("Stil", selection: $mix.prefs.ui.waveformStyle) {
                    ForEach(WaveformStyle.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                .settingsAnchor("display.wave.style")
                let fine = mix.prefs.ui.waveformStyle == .spectrum, blend = mix.prefs.ui.waveformStyle == .blend
                if blend {
                    WavePresetSettings()
                    Text("je pixelzeile gemischt: tiefen als körper von der mitte, mitten als ring, höhen außen an den spitzen, helligkeit nach oben weich auslaufend. gehaltener bass / sub-ausklang orange, gehaltene höhen (offene hats, ride) hellblau. höhen-betonung 1 = standard, 3 = höhen ×4.")
                        .settingsHint()
                } else {
                    Picker("Farben", selection: $mix.prefs.ui.waveformPalette) {
                        ForEach(WaveformPalette.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                    }
                    .disabled(fine)
                    .settingsAnchor("display.wave.palette")
                    if fine {
                        sliderRow("Höhen-Betonung", $mix.prefs.ui.waveformHighBoost, 0...3, step: 0.25, format: "%.2f")
                            .settingsAnchor("display.wave.highboost")
                    }
                }
                if fine {
                    Text("Sub orange · Bass/Kick rot · Mitten grün, obere Mitten gelbgrün · kurze Höhen (geschlossene Hats) blau · gehaltene Höhen (offene Hats, Ride) hellblau. Jedes Band gegen den eigenen Track normiert, Höhe = echter Pegel.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                sliderRow("Sichtbare Sekunden je Seite (Zoom)", $mix.prefs.ui.waveformSeconds, 1...16, step: 0.5, format: "%.1f", unit: "s")
                    .settingsAnchor("display.wave.seconds")
                sliderRow("Mindesthöhe (pt, wächst mit dem Fenster)", $mix.prefs.ui.waveformHeight, 30...200, step: 5, format: "%.0f", unit: "pt")
                    .settingsAnchor("display.wave.height")
                Toggle("Gespielten Teil abdunkeln", isOn: $mix.prefs.ui.dimPlayed)
                    .settingsAnchor("display.wave.dim")
            }
            Section("Beatgrid") {
                Toggle("Beatgrid anzeigen", isOn: $mix.prefs.ui.showBeatgrid)
                    .settingsAnchor("display.grid.show")
                Toggle("Farbig (Phrasen, Takte, Beats)", isOn: $mix.prefs.ui.colorfulGrid)
                    .settingsAnchor("display.grid.colorful")
                Picker("Phrase", selection: $mix.prefs.ui.phraseBeats) {
                    ForEach([16, 32, 64, 128], id: \.self) { Text("\($0) Beats (\($0 / 4) Takte)").tag($0) }
                }
                .settingsAnchor("display.grid.phrase")
                Toggle("Taktnummern", isOn: $mix.prefs.ui.showBarNumbers)
                    .settingsAnchor("display.grid.barnumbers")
                Toggle("Marker alle 8 / 16 / 32 Takte (magenta)", isOn: $mix.prefs.ui.barMarkers)
                    .settingsAnchor("display.grid.markers")
                Picker("Linien", selection: $mix.prefs.ui.gridLineWeight) {
                    ForEach(GridLineWeight.allCases) { Text(LocalizedStringKey($0 == .fine ? "fein (Standard)" : $0.rawValue)).tag($0) }
                }
                .background(UITestMark(name: "grid lines"))
                .settingsAnchor("display.grid.lines")
            }
            Section("Cue-Farben (Bildschirm und Controller-Pads)") {
                Picker("Start-Cue (Load / AutoGrid)", selection: $mix.prefs.controller.colorStartCue) { ForEach(PadColor.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) } }
                    .settingsAnchor("display.cue.start")
                Picker("Cue", selection: $mix.prefs.controller.colorCue) { ForEach(PadColor.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) } }
                    .settingsAnchor("display.cue.cue")
                Picker("Loop", selection: $mix.prefs.controller.colorLoop) { ForEach(PadColor.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) } }
                    .settingsAnchor("display.cue.loop")
                Picker("Kurzer Loop", selection: $mix.prefs.controller.colorShortLoop) { ForEach(PadColor.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) } }
                    .settingsAnchor("display.cue.shortloop")
                Picker("Kurz = bis", selection: $mix.prefs.controller.shortLoopBars) {
                    ForEach([1.0, 2, 4, 8], id: \.self) { Text("\(Int($0)) \($0 == 1 ? "Takt" : "Takte")").tag($0) }
                }
                .settingsAnchor("display.cue.shortbars")
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
                .settingsAnchor("audio.device")
                LabeledContent("Kanäle", value: "\(mix.deviceChannels)")
                    .settingsAnchor("audio.channels")
                Picker("Samplerate", selection: Binding(get: { mix.sampleRate }, set: { mix.setAudioFormat(rate: $0) })) {
                    Text("wie am Gerät").tag(0.0)
                    ForEach(MixEngine.availableRates(mix.currentDevice?.id ?? 0), id: \.self) { r in
                        Text(String(format: "%g kHz", r / 1000)).tag(r)
                    }
                }
                .settingsAnchor("audio.samplerate")
                Picker("Puffer (Latenz)", selection: Binding(get: { mix.bufferSize }, set: { mix.setAudioFormat(buffer: $0) })) {
                    Text("wie am Gerät").tag(0)
                    ForEach([64, 128, 256, 512, 1024, 2048], id: \.self) { n in
                        Text(String(format: "%d · %.1f ms", n, Double(n) / max(mix.engine.outputRate, 1) * 1000)).tag(n)
                    }
                }
                .settingsAnchor("audio.buffer")
                VStack(alignment: .leading, spacing: 6) {
                    Button("Neu verbinden") { mix.reconnect() }
                    Text("startet die Ausgabe neu, z. B. wenn das Interface nach einem USB-Aussetzer stumm bleibt")
                        .settingsHint()
                }
                .settingsControlColumn()
                .settingsAnchor("audio.reconnect")
                Text("Eine neue Samplerate gilt am Gerät sofort, MINOS-741 rechnet ab dem nächsten Start damit.")
                    .settingsHint()
            }
            Section("Mixer") {
                Picker("Modus", selection: Binding(get: { mix.mixerMode }, set: { mix.mixerMode = $0; mix.applyRouting() })) {
                    Text("Intern – Mixer in MINOS-741").tag(MixerMode.internalMixer)
                    Text("Extern – Mischpult (jedes Deck auf eigenem Kanalpaar)").tag(MixerMode.external)
                }
                .pickerStyle(.radioGroup)
                .settingsAnchor("audio.mixermode")
            }
            if mix.mixerMode == .internalMixer {
                Section("Ausgang (Master)") {
                    pairPicker("Master", value: Binding(get: { mix.internalPair }, set: { mix.internalPair = $0; mix.applyRouting() }))
                        .settingsAnchor("audio.masterpair")
                }
            } else {
                Section("Deck → Kanal") {
                    ForEach(0..<MixEngine.deckCount, id: \.self) { d in
                        pairPicker("Deck \(deckLetters[d])", value: Binding(
                            get: { mix.deckPairs[d] }, set: { mix.deckPairs[d] = $0; mix.applyRouting() }))
                    }
                    Button("Standard: A 1/2 · B 3/4 · C 5/6 · D 7/8") { mix.deckPairs = [0, 2, 4, 6]; mix.applyRouting() }
                        .settingsControlColumn()
                        .settingsAnchor("audio.deckpairs")
                    Text("Am Mischpult die Kanal-Eingänge auf USB stellen. EQ, Fader, Crossfader und Kopfhörer-Cue macht dann das Pult; Filter, FX und Gain bleiben in MINOS-741.")
                        .settingsHint()
                }
            }
            PreviewOutputSettings()
            RecordSettings()
            LoadCacheSettings()
            Section("Rechenkern") {
                Toggle("Decks parallel rechnen", isOn: Binding(get: { mix.parallelDecks }, set: { mix.parallelDecks = $0 }))
                    .settingsAnchor("audio.parallel")
                Text("Deck A im Audio-Thread, B–D auf eigenen Echtzeit-Threads neben dem Gerät (gleicher Klang, Summe danach). Zum Vergleich im Lasttest; bei kleinen Puffern mit 4 Decks Keylock + FX niedrigere Spitzenlast je Kern.")
                    .settingsHint()
                if let f = mix.parallelFallback {
                    let w = mix.engine.parallelWatchdog
                    Text(String(format: String(localized: "Aus seit %@: Worker hing (%.0f ms) → seriell, Fristabläufe %lld. Einschalten versucht es erneut."),
                                f.at.formatted(date: .omitted, time: .standard), max(f.hangMs, w.lastHang * 1000), Int64(w.timeouts)))
                        .settingsHint().foregroundStyle(Theme.state)
                }
            }
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
            .settingsAnchor("audio.preview.pair")
            LabeledContent("Vorhören jetzt auf") {
                Text(verbatim: mix.previewRoute.map { "\($0 + 1)/\($0 + 2)" }
                     ?? (mix.previewPair == MixModel.previewOff ? String(localized: "aus") : String(localized: "aus – kein freies Kanalpaar")))
            }
            .settingsAnchor("audio.preview.now")
            sliderRow(String(localized: "Lautstärke Vorhören"), $mix.prefs.ui.previewVolume, 0...1.5, format: "%.2f")
                .settingsAnchor("audio.preview.volume")
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

/// Aufnahme: Quelle (Eingang vom Pult / interner Master), Eingangsgerät und -paar, Pegel, Ordner, Format
private struct RecordSettings: View {
    @Environment(MixModel.self) private var mix
    @State private var inputs: [MixEngine.OutputDevice] = []

    var body: some View {
        @Bindable var mix = mix
        let rec = mix.recorder, src = rec.source(mix)
        Section("Aufnahme") {
            Picker("Quelle", selection: $mix.prefs.record.source) {
                Text(mix.mixerMode == .external ? "Automatisch – Eingang vom Pult" : "Automatisch – interner Master").tag(RecordSource.auto)
                Text("Eingang vom Pult").tag(RecordSource.input)
                Text("Interner Master").tag(RecordSource.master)
            }
            .settingsAnchor("audio.record.source")
            if src == .input {
                Picker("Eingangsgerät", selection: $mix.prefs.record.inputUID) {
                    Text(verbatim: String(localized: "wie Ausgabegerät") + (mix.currentDevice.map { " – \($0.name)" } ?? "")).tag("")
                    ForEach(inputs) { d in Text(verbatim: "\(d.name) – \(d.channels) " + String(localized: "Eingänge")).tag(d.uid) }
                }
                .settingsAnchor("audio.record.inputdevice")
                Picker("Eingangspaar", selection: $mix.prefs.record.inputFirstChannel) {
                    ForEach(Array(stride(from: 0, to: max(2, inputChannels - 1), by: 2)), id: \.self) { c in
                        Text(verbatim: "\(c + 1)/\(c + 2)").tag(c)
                    }
                }
                .settingsAnchor("audio.record.inputpair")
                LabeledContent("Eingangspegel anzeigen") {
                    HStack(spacing: 8) {
                        if rec.monitoring || rec.recording { RecordMeter(width: 120).environment(\.zoomExempt, true) }
                        Toggle("", isOn: $mix.prefs.record.showInputLevel).labelsHidden()
                    }
                }
                .settingsAnchor("audio.record.inputlevel")
            }
            Picker("Format", selection: $mix.prefs.record.format) {
                ForEach(RecordingFile.Kind.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
            }
            .settingsAnchor("audio.record.format")
            HStack {
                Text("Ordner")
                Spacer()
                Text(verbatim: (mix.prefs.record.folderURL.path as NSString).abbreviatingWithTildeInPath)
                    .font(Theme.mono(10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Button("Wählen …") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.canCreateDirectories = true
                    if panel.runModal() == .OK, let u = panel.url { mix.prefs.record.folder = u.path }
                }
                if !mix.prefs.record.folder.isEmpty { Button("Standard") { mix.prefs.record.folder = "" } }
            }
            .settingsAnchor("audio.record.folder")
            Text("rec in der oberen leiste oder im mixer (zeile master): klick = start, noch mal = stopp. interner master = das main-paar nach fadern, crossfader, master-fx, main und begrenzung, ohne metronom und vorhören. eingang vom pult = das gewählte eingangspaar der soundkarte (pult-summe auf usb legen). datei: jjjj-mm-tt hh.mm set.m4a mit der rate des kerns bzw. des eingangs, daneben .txt und .cue mit den tracks aus der history (alle 60 s und beim stopp). gerät weg: datei wird geschlossen, keine automatische fortsetzung.")
                .settingsHint()
        }
        .onAppear { inputs = MixEngine.inputDevices() }
    }

    private var inputChannels: Int {
        let uid = mix.prefs.record.inputUID
        if !uid.isEmpty { return inputs.first { $0.uid == uid }?.channels ?? 2 }
        return mix.recorder.inputDevice(mix).map { MixEngine.inputChannels($0) } ?? 2
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
                .settingsAnchor("audio.load.decoder")
            sliderRow("Hinweis nach (keine Audiodaten)", $mix.prefs.engine.loadTimeout, 2...15, step: 1, format: "%.0f", unit: "s")
                .settingsAnchor("audio.load.notice")
            sliderRow("Laden abbrechen nach (keine Audiodaten)", $mix.prefs.engine.loadAbortTimeout, 15...300, step: 5, format: "%.0f", unit: "s")
                .disabled(service == nil)
                .settingsAnchor("audio.load.abort")
            sliderRow("Cache dekodierter Tracks", $mix.prefs.engine.cacheLimitGB, 1...64, step: 1, format: "%.0f", unit: "GB")
                .disabled(service == nil)
                .settingsAnchor("audio.load.cache")
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
            Section("Zeilen") {
                sliderRow("Luft um den Text", $mix.prefs.ui.browserRowPadding, 3...16, step: 1, format: "%.0f", unit: "pt")
                    .settingsAnchor("browser.rowpadding")
                Toggle("Trennlinie zwischen den Zeilen", isOn: $mix.prefs.ui.browserRowLines)
                    .settingsAnchor("browser.rowlines")
                Toggle("Höhe rastet auf ganze Zeilen", isOn: $mix.prefs.ui.browserSnapRows)
                    .settingsAnchor("browser.snaprows")
                Text("zeilenhöhe = schrift + luft (11 pt = bisher, 5 pt = eng). gilt für alle listen, auch mit vorschau.")
                    .settingsHint()
            }
            BrowserRowsSettings()
            Section("Gespielte Tracks") {
                Toggle("Gespielte Tracks dimmen", isOn: $mix.prefs.ui.dimPlayedTracks)
                    .settingsAnchor("browser.dimplayed")
                Toggle("Gespielte Tracks ausblenden", isOn: $mix.prefs.ui.hidePlayedTracks)
                    .settingsAnchor("browser.hideplayed")
                Toggle("Played-Status beim Start zurücksetzen", isOn: $mix.prefs.ui.resetPlayedOnStart)
                    .settingsAnchor("browser.resetplayed")
                Text("gespielt = in der history (ab der schwelle unter history & preparation), bis zum zurücksetzen. ausblenden (auch ◆ UNGESPIELT im kopf des bereichs, menü browser) gilt für collection, playlists, smartlists, ordner und suche; history, running tracks und preparation zeigen sie weiter. zurücksetzen jederzeit: rechtsklick auf track collection (alles), auf playlist, smartlist, ordner, music folder, preparation oder auf markierte tracks (nur diese) -> reset played state. im baum mehrere einträge mit ⌘ / ⇧ markieren").settingsHint()
            }
            Section("History & Preparation") {
                sliderRow("Als gespielt nach (s hörbar)", $mix.prefs.engine.historyThreshold, 5...120, step: 5, format: "%.0f", unit: "s")
                    .settingsAnchor("browser.historythreshold")
                Toggle("History zusätzlich in den History-Ordner der Collection schreiben", isOn: $mix.prefs.ui.historyToExternal)
                    .settingsAnchor("browser.historyexternal")
                Text("history und preparation werden als nml gespeichert (~/Library/Application Support/MINOS-741) -> direkt in die collection importierbar. preparation wird bei jedem start archiviert und geleert.")
                    .settingsHint()
            }
            Section("Vorhören") {
                sliderRow("Vorhören im Browser ab (Anteil)", $mix.prefs.ui.previewStart, 0...0.9, format: "%.1f")
                    .settingsAnchor("browser.previewstart")
            }
            Section("Harmonie zum Master") {
                Toggle("Key-Spalte färben", isOn: $mix.prefs.ui.harmonyColors)
                    .settingsAnchor("browser.harmony")
                Text("""
                bezug: hörbarer key des master-decks (mit key-shift, ohne keylock mit dem tempo), spielt kein master:                 fokus-deck. ◆ lila = gleich · ▲▼ hell = ±1 auf dem rad · ◇ hell = relativ dur/moll · grau = ±2 (energie) ·                 gedimmt = unpassend. spalte match: pitch in prozent, den der track bis zum master-tempo braucht
                """).settingsHint()
            }
            Section("◆ PASST (Matching)") {
                Toggle("±1 auf dem Rad (▲▼)", isOn: $mix.prefs.ui.match.adjacent)
                    .settingsAnchor("browser.match.adjacent")
                Toggle("Relativ Dur/Moll (◇)", isOn: $mix.prefs.ui.match.relative)
                    .settingsAnchor("browser.match.relative")
                Toggle("Energie-Wechsel ±2", isOn: $mix.prefs.ui.match.energy)
                    .settingsAnchor("browser.match.energy")
                sliderRow("BPM-Fenster", $mix.prefs.ui.match.bpmWindow, 1...10, step: 0.5, format: "±%.1f", unit: "%")
                    .settingsAnchor("browser.match.bpm")
                Toggle("Halbes / doppeltes Tempo mitzählen", isOn: $mix.prefs.ui.match.halfDouble)
                    .settingsAnchor("browser.match.halfdouble")
                Text("gleicher key zählt immer. track ohne key passt nicht, master ohne key: nur das tempo. an/aus: chip ◆ PASST im kopf des bereichs, tastatur (⌘, → tastatur) oder browse-taste am controller").settingsHint()
                Picker("Tag-Gruppen (Kommentar 2)", selection: $mix.prefs.ui.match.groove) {
                    Text("aus").tag(MatchRule.Groove.off)
                    Text("ähnlich").tag(MatchRule.Groove.similar)
                    Text("ergänzend").tag(MatchRule.Groove.complement)
                }
                .settingsAnchor("browser.match.groove")
                if mix.prefs.ui.match.groove == .similar {
                    LabeledContent("gleich") { TextField("", text: $mix.prefs.ui.match.similar).settingsField().frame(width: 120) }
                }
                if mix.prefs.ui.match.groove == .complement {
                    LabeledContent("gleich") { TextField("", text: $mix.prefs.ui.match.keep).settingsField().frame(width: 120) }
                    LabeledContent("anders") { TextField("", text: $mix.prefs.ui.match.change).settingsField().frame(width: 120) }
                }
                Text("gruppen-marker mit leerzeichen, es zählt das erste wort der gruppe (K tief, B sub, H off). ähnlich: diese gruppen gleich wie beim master. ergänzend: „gleich“ gleich, „anders“ anders, keine gemeinsame rolle (BASIS, SYNTH …). master ohne gruppen: egal, track ohne gruppen: passt nicht").settingsHint()
            }
            PreviewSettings()
            Section("Cover") {
                Toggle("Cover im Deck anzeigen", isOn: $mix.prefs.ui.showDeckCover)
                    .settingsAnchor("browser.cover.deck")
                Toggle("Cover-Vorschau im Browser", isOn: $mix.prefs.ui.showCoverPreview)
                    .settingsAnchor("browser.cover.preview")
                Text("vorschau unter dem baum (gewählter track). spalte „Cover“ in der liste: rechtsklick auf die spaltenköpfe. bild aus der datei, sonst cover / folder / front.jpg im ordner, zwischengespeichert in ~/Library/Caches/MINOS-741/artwork.")
                    .settingsHint()
            }
            Section("Collection") {
                MusicFolderSettings()
                Toggle("Änderungen in die Collection-Datei schreiben (Backup davor)", isOn: $mix.prefs.ui.writeCollection)
                    .settingsAnchor("browser.writecollection")
                Text("aus: änderungen (inline, ⌘E, hotcues, loops, grid) liegen nur in MINOS-741 (metadata.json, edits.json). an: gesammelt in die collection.nml, sicherung höchstens stündlich in „Backup MINOS-741“ neben der datei. nicht, solange die collection-software läuft. schnitt und active loops bleiben in MINOS-741.")
                    .font(Theme.mono(10)).foregroundStyle(Theme.muted)
                Toggle("Cuts und Tool-Loops als neue Einträge anlegen", isOn: $mix.prefs.ui.writeCuts)
                    .disabled(!mix.prefs.ui.writeCollection)
                    .settingsAnchor("browser.writecuts")
                Toggle("Preparation, History und eigene Playlists als Playlists (Ordner MINOS-741)", isOn: $mix.prefs.ui.writePlaylists)
                    .disabled(!mix.prefs.ui.writeCollection)
                    .settingsAnchor("browser.writeplaylists")
                Text("eigene playlists stehen nur im ordner MINOS-741 und werden bei jedem schreiben ersetzt, andere playlists bleiben unberührt.")
                    .font(Theme.mono(10)).foregroundStyle(Theme.muted)
            }
            Section("Collection prüfen") {
                Toggle("Beim Start prüfen", isOn: $mix.prefs.ui.checkOnStart)
                    .settingsAnchor("browser.checkonstart")
                Toggle("Musik-Ordner nach Dateien ohne Collection-Eintrag durchsuchen", isOn: $mix.prefs.ui.checkMusicFolders)
                    .settingsAnchor("browser.checkfolders")
                Text("browser-menü -> collection prüfen … oder rechtsklick auf TRACK COLLECTION. nur lesen: dateien, audio-kopf, dauer, schreibweise, namen, doppelte, analyse, grid, playlist-einträge. abbrechen jederzeit.")
                    .settingsHint()
            }
            Section("Analyse") {
                // genau eine Oktave: jede Grenze stellt die andere mit
                Stepper(value: Binding(get: { mix.prefs.ui.analysisBpmLow }, set: { mix.prefs.ui.analysisBpmLow = max(40, min(150, $0)) }),
                        in: 40...150, step: 1) {
                    Text("BPM-Bereich ab \(Int(mix.prefs.ui.analysisBpmLow))")
                }
                .settingsAnchor("browser.bpmlow")
                Stepper(value: Binding(get: { 2 * mix.prefs.ui.analysisBpmLow }, set: { mix.prefs.ui.analysisBpmLow = max(40, min(150, $0 / 2)) }),
                        in: 80...300, step: 2) {
                    Text("BPM-Bereich bis \(Int(2 * mix.prefs.ui.analysisBpmLow))")
                }
                .settingsAnchor("browser.bpmhigh")
                Text("genau eine oktave: das tempo wird in den bereich gefaltet (z. b. 100–200: 96 -> 192). gilt für analysieren / neu analysieren.")
                    .settingsHint()
                Toggle("Rip-Prüfung bei der Analyse mit", isOn: $mix.prefs.ui.ripWithAnalysis)
                    .settingsAnchor("browser.rip")
                Text("prüft anfang und ende: stille, rest eines anderen tracks (tonart, tempo), grid. ergebnis: spalte rip, ◆ RIP, ZU BEARBEITEN. rechtsklick -> rip prüfen geht immer.")
                    .settingsHint()
                Toggle("Rip-Befund beim Laden markieren", isOn: $mix.prefs.ui.ripMarkOnLoad)
                    .settingsAnchor("browser.ripmark")
                Text("lädt ein deck einen track mit offenem befund, wird der vorgeschlagene teil als bereich markiert (RIP · …). geschnitten wird nichts: rechtsklick -> markierten bereich entfernen.")
                    .settingsHint()
                KeyProfileSettings()
            }
            DAWBridgeSettings()
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
                Group {
                    if status.devices.isEmpty {
                        Text("Kein Controller gefunden. Andere DJ-Software beenden, falls sie läuft.").settingsHint()
                    }
                    ForEach(status.devices) { d in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: d.name.isEmpty ? "Controller" : d.name).font(Theme.mono(11, .medium))
                                    Text(d.serial.isEmpty ? String(localized: "ohne Seriennummer · \(d.id)") : "SN \(d.serial)")
                                        .font(Theme.mono(10)).foregroundStyle(Theme.muted)
                                }
                                Spacer()
                                Button("Startsequenz") { status.playShow(d.id) }.help("Lichtsequenz auf diesem Controller abspielen")
                                Button("Blinken") { status.identify(d.id) }.help("Pads dieses Controllers leuchten kurz weiß")
                            }
                            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                                if let side = d.side {
                                    GridRow {
                                        deviceLabel("Seite")
                                        Picker("Seite", selection: Binding(get: { side }, set: { status.setSide(d.id, $0) })) {
                                            Text("Links (A / C)").tag(ControllerSide.left)
                                            Text("Rechts (B / D)").tag(ControllerSide.right)
                                        }
                                        .labelsHidden().frame(width: 120)
                                        .help("Fest für dieses Gerät gespeichert; der andere Controller wechselt auf die freie Seite")
                                    }
                                }
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
                .settingsAnchor("controller.devices")
            }
            Section("Belegung") {
                Picker("Cue-Taste", selection: $mix.prefs.controller.cueAction) { ForEach(ControllerCueAction.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) } }
                    .settingsAnchor("controller.cue")
                Picker("Flux-Taste", selection: $mix.prefs.controller.fluxButton) { ForEach(ControllerFluxButton.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) } }
                    .settingsAnchor("controller.flux")
                if mix.prefs.controller.fluxButton == .fluxMode {
                    Toggle("Flux antippen schaltet Flux-Modus", isOn: $mix.prefs.controller.fluxTapToggles)
                        .settingsAnchor("controller.fluxtap")
                } else {
                    Text("antippen -> pads 1–4 spielen hotcues 5–8, flux-led an; nochmal -> zurück.").settingsHint()
                }
                Picker("Shift + Flux", selection: $mix.prefs.controller.shiftFlux) { ForEach(ControllerShiftFlux.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) } }
                    .settingsAnchor("controller.shiftflux")
                if mix.prefs.controller.shiftFlux == .tap {
                    Text("auf die beats tippen: ab 4 taps bpm des grids aus dem mittleren abstand, pause > 2 s beginnt neu; ohne grid entsteht eines mit beat 1 am letzten tap.").settingsHint()
                }
                Picker("Flux halten + Pads", selection: $mix.prefs.controller.fluxPads) { ForEach(ControllerFluxPads.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) } }
                    .settingsAnchor("controller.fluxpads")
                Picker("Beatjump-Größe (Flux + Pad 3/4)", selection: $mix.prefs.controller.fluxBeatjumpBeats) {
                    ForEach(BeatSizes.jump, id: \.self) { Text("±\(BeatSizes.label($0)) Beat").tag($0) }
                }
                .settingsAnchor("controller.fluxjump")
                Picker("Touchstrip", selection: $mix.prefs.controller.stripMode) { ForEach(ControllerStripMode.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) } }
                    .settingsAnchor("controller.strip")
                sliderRow("Touchstrip-Empfindlichkeit", $mix.prefs.controller.stripSensitivity, 0.2...3, format: "%.1f")
                    .settingsAnchor("controller.stripsens")
                Stepper("Browse mit Shift: \(mix.prefs.controller.browseFastStep) Zeilen", value: $mix.prefs.controller.browseFastStep, in: 2...50)
                    .settingsAnchor("controller.browsefast")
                Picker("Shift + LOAD", selection: $mix.prefs.controller.shiftLoad) { ForEach(ControllerShiftLoad.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) } }
                    .settingsAnchor("controller.shiftload")
                Picker("Browse drücken", selection: $mix.prefs.controller.browsePush) { ForEach(ControllerBrowsePush.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) } }
                    .settingsAnchor("controller.browsepush")
                Text("shift + drücken = vorhören. matching: filter „passt zum master“ im browser-bereich des controllers").settingsHint()
            }
            Section("LEDs") {
                sliderRow("Helligkeit an", Binding(get: { Double(mix.prefs.controller.ledOn) }, set: { mix.prefs.controller.ledOn = Int($0) }),
                          10...127, step: 1, format: "%.0f")
                .settingsAnchor("controller.ledon")
                sliderRow("Helligkeit aus", Binding(get: { Double(mix.prefs.controller.ledOff) }, set: { mix.prefs.controller.ledOff = Int($0) }),
                          0...40, step: 1, format: "%.0f")
                .settingsAnchor("controller.ledoff")
                Text("pad-farben: ⌘, -> anzeige -> cue-farben (gleich wie auf dem bildschirm)").settingsHint()
                Toggle("Startsequenz beim Verbinden", isOn: $mix.prefs.controller.startShow)
                    .settingsAnchor("controller.startshow")
                Text("rot / weiß / lila, dann die decks der seite auf der 7-segment-anzeige, weißer blitz, bereit (3,4 s). eine eingabe bricht ab.").settingsHint()
            }
            Section("Feste Belegung (Standard)") {
                Text("""
                Play (Shift: CUP) · Sync (Shift: Master) · Hotcues 1–4 (Shift: löschen) · Loop-Encoder drehen = Loopgröße, \
                drücken = Loop (Shift: drehen = Beatjump, drücken = Reloop) · Load (Shift: siehe Belegung) · Browse (drücken = Vorhören) · \
                FX: D/W, Regler 1–3, Tasten 1–3 nach FX-Belegung (Standard: Filter/Delay/Reverb + an/aus), Mode = alle aus bzw. Delay-Zeit · FX-Zuweisung.
                """)
                .settingsHint()
                .settingsAnchor("controller.fixed")
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

/// ⌘, -> BROWSER -> Analyse: Key-Profile aus der Collection lernen / verwerfen, Stand
private struct KeyProfileSettings: View {
    var body: some View {
        let a = Analyses.shared
        HStack {
            Button("Key-Profile lernen") { a.learnProfiles(from: a.library?.tracks ?? []) }.disabled(a.learnTotal > 0 || a.library == nil)
            Button("Profile verwerfen") { a.discardProfiles() }.disabled(a.profiles == nil)
        }
        .settingsAnchor("browser.keyprofiles")
        Text(a.profiles.map { Analyses.profilesText($0) + " · " + $0.learned.formatted(date: .numeric, time: .omitted) }
             ?? String(localized: "keine gelernten Profile: Krumhansl / Temperley"))
            .settingsHint()
        Text("lernt aus bis zu 300 lokalen tracks mit tonart aus der collection (keine downloads), im hintergrund wie die analyse. treffer auf jedem 5. track gemessen, der nicht gelernt wird. datei: key-profiles.json im MINOS-741-ordner. gilt für die nächste analyse.")
            .settingsHint()
    }
}
