import SwiftUI
import AppKit
import MixCore
import MixEngine

/// Anordnung der Browser-Bereiche.
enum BrowserLayout: String, CaseIterable, Identifiable, Codable {
    case single = "Einzeln", sideBySide = "Nebeneinander", stacked = "Übereinander"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .single: "▭"
        case .sideBySide: "◫"
        case .stacked: "⬒"
        }
    }
}

struct ContentView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(MixModel.self) private var mix
    private var layout: BrowserLayout { mix.prefs.ui.browserLayout }
    @Environment(BrowserState.self) private var browserState
    private var paneA: BrowserPaneModel { browserState.paneA }
    private var paneB: BrowserPaneModel { browserState.paneB }
    /// Höhe der Deck-Fläche vor dem Zuklappen – ohne Beobachtung, Messen löst kein neues Layout aus
    private final class Height { var value: CGFloat = 0 }
    @State private var deckAreaHeight = Height()
    /// Browser-Höhe während des Ziehens am Trenner; gespeichert wird sie erst beim Loslassen
    @State private var dragHeight: Double?
    @State private var donate = false

    var body: some View {
        VStack(spacing: 0) {
            PhraseLine()   // Phrasen-Fortschritt direkt unter der Werkzeugleiste
            // Decks oben, Browser unten – Trenner verschiebbar. Browser groß: Decks nur zusammengeklappt,
            // nicht neu aufgebaut (sonst dauert das Umschalten mit 14k Zeilen spürbar). Zugeklappt behalten sie
            // ihre letzte Höhe: kein neues Deck-Layout, keine neuen Wellenform-Kacheln
            let big = browserState.maximized
            deckArea
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if !browserState.maximized { deckAreaHeight.value = $0 } }
                .frame(height: big && deckAreaHeight.value > 0 ? deckAreaHeight.value : nil)
                .frame(maxHeight: big ? 0 : .infinity, alignment: .top)
                .opacity(big ? 0 : 1)
                .allowsHitTesting(!big)
                .clipped()
                .layoutPriority(big ? 0 : 1)
            if !big {
                SplitHandle(height: Binding(get: { dragHeight ?? mix.prefs.ui.browserHeight }, set: { dragHeight = $0 }),
                            snap: snapBrowserHeight, onEnd: endSplitDrag)
                    .onDisappear { endSplitDrag() }   // Browser groß mitten im Ziehen: Höhe trotzdem speichern
            }
            browsers
                .frame(height: big ? nil : (dragHeight ?? mix.prefs.ui.browserHeight).z)
                .frame(maxHeight: big ? .infinity : nil)
                .layoutPriority(big ? 1 : 0)
            if mix.prefs.ui.statusBar == .always { statusBar }
        }
        .overlay(alignment: .bottom) { if mix.prefs.ui.statusBar == .auto { AutoStatusBar() } }
        .background(Theme.background)
        .foregroundStyle(Theme.bone)
        .tint(Theme.state)
        .preferredColorScheme(.dark)
        .toolbar {
            // Marke + Profil links, Statuszeile in der Mitte, Schalter rechts (WindowBar.swift)
            ToolbarItem(placement: .navigation) { WindowBrand() }.flat()
            ToolbarItem(placement: .principal) { WindowStatus() }.flat()
            ToolbarItem(placement: .primaryAction) { WindowSwitches() }.flat()
        }
        .toolbar(removing: .title)   // Titel steht als ◆ MINOS-741 + Version in der Leiste (Fenstertitel bleibt)
        .toolbarBackground(Theme.void, for: .windowToolbar)
        .windowToolbarFullScreenVisibility(.onHover)
        .background(MainWindowHook())
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeScreenNotification)) { n in
            if (n.object as? NSWindow) === MainWindow.window { ZoomControl.fit(mix: mix) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeMainNotification)) { n in
            if (n.object as? NSWindow) === MainWindow.window { ZoomControl.fit(mix: mix) }   // gespeicherter Zoom zu groß für den Bildschirm
        }
        .background(RunningTracks())
        .background(DAWBridgeHook())   // DAW-Brücke: Empfänger nach Einstellung, Clip je Deck
        .background(OverviewHook())   // Browser-Vorschau: Deck-Tracks, Pause-Regel, Leerlauf
        .background(CloudHook())      // Cloud-Library: Prüfen, Lokal-halten, Pause beim Laden
        .onChange(of: mix.prefs.ui.musicFolders, initial: true) { _, f in store.folders.configured = f }
        .onAppear {
            // Collection-Datei: eigene Hotcues / Grid schreiben und beim Laden auf Konflikte prüfen
            store.edits = mix.edits
            store.uiPrefs = { [mix] in mix.prefs.ui }
            store.updateUIPrefs = { [mix] change in change(&mix.prefs.ui) }
            store.onRefreshed = { [mix] t in mix.collectionUpdated(t) }
            if store.tracks.isEmpty { store.load() }
            // MIX741_LAYOUT=nomixer,1deck,2decks,nobrowser: Teile der Oberfläche für Layout-Messungen abschalten (nur Selbsttest)
            if Session.isSelfTest, let l = ProcessInfo.processInfo.environment["MIX741_LAYOUT"] {
                if l.contains("nomixer") { mix.prefs.ui.showMixer = false }
                if l.contains("2decks") { mix.prefs.ui.deckCount = 2 }
                if l.contains("1deck") { mix.prefs.ui.deckCount = 1 }
                if l.contains("nobrowser") { mix.prefs.ui.browserLayout = .single; mix.prefs.ui.browserHeight = 120 }
            }
            mix.library = store   // Schneiden trägt neue Dateien in CUTS ein
            AudioEditMode.shared.attach(mix: mix, browser: browserState)
            RipChecks.shared.mix = mix
            RipChecks.shared.library = store
            SelfTest.run(store: store, mix: mix, browser: browserState)
            if DonateHint.dueNow { DonateHint.lastShown = Date(); donate = true }
        }
        .sheet(isPresented: $donate) { DonateView(shown: $donate) }
        .onReceive(NotificationCenter.default.publisher(for: .showDonate)) { _ in donate = true }
    }

    /// RUNNING TRACKS im Browser nachführen – eigene leere Ansicht: liest alle vier Decks, ohne dass
    /// ContentView bei jeder Deck-Änderung neu ausgewertet wird
    struct RunningTracks: View {
        @Environment(LibraryStore.self) private var store
        @Environment(MixModel.self) private var mix
        var body: some View {
            Color.clear
                .onChange(of: mix.decks.map(\.trackKey), initial: true) { _, keys in
                    store.running = keys.filter { !$0.isEmpty }.compactMap { store.track($0) }
                }
        }
    }

    /// Browser-Höhe (unskaliert) auf ganze Tabellenzeilen rasten: Rahmen = Bereich ohne Tabelle plus Spaltenkopf
    /// (⌘, -> BROWSER „Höhe rastet auf ganze Zeilen“; nicht bei Browsern übereinander, dort teilt der Split die Höhe)
    private func snapBrowserHeight(_ h: Double) -> Double {
        let ui = mix.prefs.ui, m = paneA
        guard ui.browserSnapRows, layout != .stacked, m.paneHeight > 0, m.tableHeight > 0 else { return h }
        let chrome = (m.paneHeight - m.tableHeight + (24.z).rounded()) / 1.z
        return BrowserSnap.height(h, chrome: chrome, row: TableStyle.rowHeight(ui, twoText: m.twoText(ui)) / 1.z)
    }

    /// Ende des Ziehens am Trenner: Höhe speichern (einmal, nicht bei jeder Bewegung)
    private func endSplitDrag() {
        guard let h = dragHeight else { return }
        mix.prefs.ui.browserHeight = h
        dragHeight = nil
    }

    /// Ziehbarer Trenner zwischen Decks und Browser; `snap` rundet die Höhe beim Ziehen, `onEnd` beim Loslassen.
    /// Sichtbar 3 pt (Linie + 1 pt Luft), greifbar 9 pt: die Griff-Fläche ragt nach oben in den Deck-Rand (unten gewinnt der Browser)
    struct SplitHandle: View {
        @Binding var height: Double
        var snap: (Double) -> Double = { $0 }
        var onEnd: () -> Void = {}
        @State private var start: Double?
        var body: some View {
            Rectangle().fill(Theme.hairline).frame(height: 1)
                .padding(.vertical, 1.z)
                .overlay {
                    Color.clear.frame(height: 9.z)
                        .contentShape(Rectangle())
                        .background(UITestMark(name: "split handle"))
                        .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
                        // Fensterkoordinaten: der Griff wandert mit der Höhe, lokal gemessen würde die Verschiebung gegen die
                        // Bewegung zurückgedreht (Zittern). Höhe = Starthöhe − Verschiebung seit dem Griff
                        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { g in
                                let s = start ?? height
                                start = s
                                height = BrowserDrag.height(start: s, translation: g.translation.height / 1.z, snap: snap)
                            }
                            .onEnded { _ in start = nil; onEnd() })
                }
        }
    }

    private var deckArea: some View {
        let gap = max(0, min(12, mix.prefs.ui.deckGap)).z
        return VStack(spacing: 2.z) {
            TopBarHost()
            // Decks mit fester Höhe: zwei flexible Decks übereinander ließen SwiftUI jede Zustandsänderung
            // ~200 ms lang Layout rechnen (kombinatorische Messungen verschachtelter Stacks); jedes Deck in eigener
            // Hosting-View (DeckHost), damit eine Deck-Änderung nicht das ganze Fenster neu misst
            // 1 Deck: nur A über die volle Breite, B–D spielen unsichtbar weiter
            GeometryReader { geo in
                let n = mix.deckCount
                let rows: CGFloat = n >= 4 ? 2 : 1
                let deckH = max(120.z, (geo.size.height - (rows - 1) * gap) / rows)
                HStack(alignment: .top, spacing: gap) {
                    VStack(spacing: gap) {
                        DeckHost(d: 0).frame(height: deckH)
                        if n >= 4 { DeckHost(d: 2).frame(height: deckH) }
                    }
                    if mix.prefs.ui.showMixer { MixerView().fixedSize(horizontal: true, vertical: false) }
                    if n >= 2 {
                        VStack(spacing: gap) {
                            DeckHost(d: 1).frame(height: deckH)
                            if n >= 4 { DeckHost(d: 3).frame(height: deckH) }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, gap)
        .padding(.top, max(gap, 2.z))
        .padding(.bottom, gap)
    }

    /// Audio-Edit: Arbeitsliste und Vorschläge statt der Browser-Bereiche
    @ViewBuilder private var browsers: some View {
        if AudioEditMode.shared.active {
            AudioEditArea()
        } else {
            switch layout {
            case .single:
                BrowserPane(model: paneA)
            case .sideBySide:
                HSplitView {
                    BrowserPane(model: paneA)
                    BrowserPane(model: paneB)
                }
            case .stacked:
                VSplitView {
                    BrowserPane(model: paneA)
                    BrowserPane(model: paneB)
                }
            }
        }
    }

    /// Statusleiste: Meldungen, Audio-Status, Last-Anzeigen (StatusBar.swift)
    private var statusBar: some View { StatusBar() }
}

/// Beenden nur nach Rückfrage (Sicherheit im Set); davor Sitzung und History schreiben
final class AppDelegate: NSObject, NSApplicationDelegate {
    var onQuit: (@MainActor () -> Void)?

    /// Fenster weg (auf welchem Weg auch immer) -> Beenden mit Rückfrage statt App ohne Fenster
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !Session.isSelfTest else { return .terminateNow }
        let a = NSAlert()
        a.messageText = String(localized: "MINOS-741 beenden?")
        a.informativeText = String(localized: "Sitzung und History werden gespeichert.")
        let pending = MainActor.assumeIsolated { CloudLibrary.shared.pendingCount }
        if pending > 0 {
            let handOff = MainActor.assumeIsolated { CloudLibrary.shared.handOffOnQuit }
            a.informativeText += "\n" + (handOff
                ? String(localized: "\(pending) Cloud-Downloads offen: der Anbieter lädt sie nach dem Beenden weiter.")
                : String(localized: "\(pending) Cloud-Downloads offen: sie werden abgebrochen."))
        }
        a.addButton(withTitle: String(localized: "Beenden"))
        a.addButton(withTitle: String(localized: "Abbrechen"))
        guard a.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        MainActor.assumeIsolated { onQuit?() }
        return .terminateNow
    }
}

struct MixApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = LibraryStore()
    @State private var mix = MixModel()
    @State private var browser = BrowserState()
    @State private var controllerStatus = ControllerStatus()
    @State private var waveforms = WaveformCache()
    @State private var history = HistoryStore()
    @State private var controller: ControllerManager?
    @State private var sessionTimer: Timer?

    /// Version und Build für die Marke in der Leiste („0.8.1 · db052b1“), gleiche Quelle wie der Fenstertitel
    static var versionLine: String {
        let info = Bundle.main.infoDictionary
        guard let v = info?["CFBundleShortVersionString"] as? String else { return "dev" }
        let b = info?["CFBundleVersion"] as? String ?? ""
        return b.isEmpty || b == v ? v : "\(v) · \(b)"
    }

    static var appTitle: String {
        let info = Bundle.main.infoDictionary
        guard let v = info?["CFBundleShortVersionString"] as? String else { return "MINOS-741 dev" }
        let b = info?["CFBundleVersion"] as? String ?? ""
        return "MINOS-741 \(v)" + (b.isEmpty || b == v ? "" : " (\(b))")
    }

    var body: some Scene {
        WindowGroup(Self.appTitle) {
            MinSize(width: ZoomControl.minContent.width.z, height: ZoomControl.minContent.height.z) {
                ContentView()
                    .environment(store)
                    .environment(mix)
                    .environment(browser)
                    .environment(controllerStatus)
                    .environment(waveforms)
                    .environment(history)
            }
                .onAppear { startControllers() }
                .onChange(of: mix.prefs.controller) { controller?.prefs = mix.prefs.controller }
                .onChange(of: mix.prefs.ui.fxUnitCount) { controller?.fxUnits = mix.prefs.ui.fxUnitCount }
                .onChange(of: mix.prefs.ui.zoom) { ZoomControl.apply(mix.prefs.ui.zoom) }
        }
        Settings {
            SettingsView()
                .zoomExempt()
                .environment(mix)
                .environment(browser)
                .environment(store)
                .environment(controllerStatus)
        }
        .windowResizability(.contentMinSize)
        .commands {
            // alle Kürzel aus den Einstellungen (⌘, -> Tastatur); ausgelöst werden sie vom KeyMonitor
            let keys = mix.prefs.keys
            let run = actions
            CommandGroup(after: .newItem) {
                Button(ShortcutID.openCollection.title) { run(.openCollection) }
                    .shortcut(keys.combo(.openCollection))
            }
            CommandGroup(replacing: .appSettings) {
                SettingsLink { Text(ShortcutID.settings.title) }
                    .shortcut(keys.combo(.settings))
            }
            CommandGroup(after: .help) {
                Button(String(localized: "Kauf mir einen Kaffee …")) { NotificationCenter.default.post(name: .showDonate, object: nil) }
            }
            CommandGroup(replacing: .saveItem) {
                Button(String(localized: "Fenster schließen")) { run(.closeWindow) }
                    .shortcut(keys.combo(.closeWindow))
            }
            // Rückgängig der App (Deck, Browser); in Textfeldern bleibt die Taste das Text-Undo (KeyMonitor)
            CommandGroup(replacing: .undoRedo) {
                let u = UndoStack.shared
                Button(u.undoLabel.map { String(localized: "Rückgängig: \($0)") } ?? ShortcutID.undo.title) { run(.undo) }
                    .shortcut(keys.combo(.undo)).disabled(u.undoLabel == nil)
                Button(u.redoLabel.map { String(localized: "Wiederherstellen: \($0)") } ?? ShortcutID.redo.title) { run(.redo) }
                    .shortcut(keys.combo(.redo)).disabled(u.redoLabel == nil)
            }
            CommandGroup(before: .toolbar) {
                Toggle(String(localized: "Hilfe-Modus"), isOn: Binding(get: { HelpMode.shared.enabled }, set: { HelpMode.shared.enabled = $0 }))
                Divider()
                Toggle("Mixer", isOn: Binding(get: { mix.prefs.ui.showMixer }, set: { mix.prefs.ui.showMixer = $0 }))
                    .shortcut(keys.combo(.toggleMixer))
                Toggle("AUTO-MIX", isOn: Binding(get: { mix.autoMix.isOn }, set: { on in
                    if on { mix.autoMix.startFromPanes() } else { mix.autoMix.stop(String(localized: "Auto-Mix aus")) }
                }))
                .disabled(mix.mixerMode != .internalMixer)
                Picker("Decks", selection: Binding(get: { mix.prefs.ui.deckCount }, set: { mix.prefs.ui.deckCount = $0 })) {
                    Text("1 Deck").tag(1)
                    Text("2 Decks").tag(2)
                    Text("4 Decks").tag(4)
                }
                Button(ShortcutID.toggleFourDecks.title) { run(.toggleFourDecks) }
                    .shortcut(keys.combo(.toggleFourDecks))
                Toggle("Browser groß", isOn: Binding(get: { browser.maximized }, set: { browser.maximized = $0 }))
                    .shortcut(keys.combo(.bigBrowser))
                Picker("Browser-Anordnung", selection: Binding(get: { mix.prefs.ui.browserLayout }, set: { mix.prefs.ui.browserLayout = $0 })) {
                    ForEach(BrowserLayout.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                Picker("Statusleiste", selection: Binding(get: { mix.prefs.ui.statusBar }, set: { mix.prefs.ui.statusBar = $0 })) {
                    ForEach(StatusBarMode.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                Divider()
                Menu("Profil") {
                    let ui = mix.prefs.ui
                    ForEach(Array(ui.layoutProfiles.enumerated()), id: \.element.id) { i, p in
                        Toggle(isOn: Binding(get: { p.id.uuidString == ui.activeLayoutProfile },
                                             set: { _ in LayoutProfiles.apply(at: i, mix: mix, browser: browser, announce: false) })) {
                            Text(verbatim: p.name)
                        }
                        .shortcut(i < ShortcutID.profiles.count ? keys.combo(ShortcutID.profiles[i]) : nil)
                    }
                    Button(ShortcutID.profileNext.title) { run(.profileNext) }
                        .shortcut(keys.combo(.profileNext))
                        .disabled(ui.layoutProfiles.isEmpty)
                    Divider()
                    Button("Aktuelle Ansicht als Profil speichern …") { LayoutProfiles.saveAsking(mix: mix, browser: browser) }
                    Button("Profil aktualisieren") { LayoutProfiles.update(mix: mix, browser: browser) }
                        .disabled(ui.activeProfile == nil)
                    Button("Profil löschen …") { LayoutProfiles.deleteAsking(mix: mix) }
                        .disabled(ui.activeProfile == nil)
                }
                Button(ShortcutID.audioEdit.title) { run(.audioEdit) }
                    .shortcut(keys.combo(.audioEdit))
                Divider()
                ForEach([ShortcutID.zoomIn, .zoomOut, .zoomReset]) { a in
                    Button(a.title) { run(a) }.shortcut(keys.combo(a))
                }
                Divider()
            }
            CommandMenu("Decks") {
                ForEach([ShortcutID.focusDeckA, .focusDeckB, .focusDeckC, .focusDeckD]) { a in
                    Button(a.title) { run(a) }.shortcut(keys.combo(a))
                }
                Divider()
                ForEach([ShortcutID.play, .cue, .cup, .sync, .master, .keylock, .keySync, .instantDouble, .loop, .reloop, .beatjumpBack, .beatjumpForward]) { a in
                    Button(a.title) { run(a) }.shortcut(keys.combo(a))
                }
                Button(ShortcutID.masterFX.title) { run(.masterFX) }.shortcut(keys.combo(.masterFX))
                Button(ShortcutID.record.title) { run(.record) }.shortcut(keys.combo(.record))
                Divider()
                ForEach([ShortcutID.hotcue1, .hotcue2, .hotcue3, .hotcue4, .hotcue5, .hotcue6, .hotcue7, .hotcue8]) { a in
                    Button(a.title) { run(a) }.shortcut(keys.combo(a))
                }
                Divider()
                ForEach([ShortcutID.editMode, .cutIn, .cutOut, .gridSet]) { a in
                    Button(a.title) { run(a) }.shortcut(keys.combo(a))
                }
                Divider()
                ForEach([ShortcutID.rangeRemove, .rangeKeep, .rangeTrim, .rangeLoop, .rangeClear]) { a in
                    Button(a.title) { run(a) }.shortcut(keys.combo(a))
                }
                Toggle("Schneiden: Ergebnis ins Deck laden", isOn: Binding(get: { mix.prefs.ui.cutLoadsResult },
                                                                            set: { mix.prefs.ui.cutLoadsResult = $0 }))
                Divider()
                ForEach([ShortcutID.editRemove, .editKeep, .editDuplicate, .editMute, .editLeft, .editRight, .editMark, .editSnap,
                         .editRender, .toolLoop2, .toolLoop4, .toolLoop8, .toolLoop16]) { a in
                    Button(a.title) { run(a) }.shortcut(keys.combo(a))
                }
                Menu("Vorbereiten") {
                    ForEach([ShortcutID.prepBIn, .prepBOut, .prepABA, .prepAnalyse, .prepAmpUp, .prepNorm, .prepAmpReset, .prepJoin,
                             .prepSplit, .prepRender]) { a in
                        Button(a.title) { run(a) }.shortcut(keys.combo(a))
                    }
                }
                Divider()
                Menu("Zeilen") {
                    ForEach(Array(DeckRows.all.enumerated()), id: \.offset) { _, row in
                        Toggle(LocalizedStringKey(row.1), isOn: Binding(get: { mix.prefs.ui[keyPath: row.0] },
                                                                      set: { mix.prefs.ui[keyPath: row.0] = $0 }))
                    }
                    Divider()
                    Button("Alle Zeilen") { mix.prefs.ui.showAllDeckRows() }
                }
                Toggle("Kompakte Decks", isOn: Binding(get: { mix.prefs.ui.compactDecks }, set: { mix.prefs.ui.compactDecks = $0 }))
                    .shortcut(keys.combo(.compactDecks))
            }
            CommandMenu("Browser") {
                ForEach([ShortcutID.resetPlayed, .loadSelected, .loadSelectedForce, .previewSelected, .reloadCollection, .matching]) { a in
                    Button(a.title) { run(a) }.shortcut(keys.combo(a))
                }
                Toggle(String(localized: "Gespielte Tracks ausblenden"), isOn: Binding(get: { mix.prefs.ui.hidePlayedTracks }, set: { mix.prefs.ui.hidePlayedTracks = $0 }))
                    .shortcut(keys.combo(.hidePlayed))
                Button(String(localized: "Collection prüfen …")) { ConsistencyWindow.show(store: store) }
                Divider()
                ForEach(ShortcutID.favorites) { a in
                    Button(a.title) { run(a) }.shortcut(keys.combo(a))
                }
                Divider()
                Button(ShortcutID.reconnectAudio.title) { run(.reconnectAudio) }.shortcut(keys.combo(.reconnectAudio))
            }
        }
    }

    private var actions: AppActions { AppActions(mix: mix, browser: browser, store: store, history: history) }
}

extension MixApp {
    /// Controller auf der Steuer-Queue starten; Browser-Aktionen kommen auf dem Hauptthread zurück.
    @MainActor func startControllers() {
        browser.store = store
        browser.history = history
        browser.separators = { [mix] in mix.prefs.ui.tagSeparators }
        history.start(store: store, mix: mix)
        store.history = history
        mix.autoMix.store = store
        mix.autoMix.history = history
        mix.autoMix.browser = browser
        appDelegate.onQuit = { [mix, browser, history] in
            mix.recorder.stopNow()   // laufende Aufnahme sauber schließen (Tracklist dabei)
            Session.saveNow(mix: mix, browser: browser)
            mix.flushEdits()
            history.finish()
            CloudLibrary.shared.handOff()
        }
        let session = Session.load()
        session?.applyEngine(to: mix)
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [mix, browser] _ in
            MainActor.assumeIsolated { Session.saveIfChanged(mix: mix, browser: browser) }
        }
        // Preparation der letzten Session archivieren und leeren (einmal pro Start, nach dem Laden der Collection)
        store.onLoaded = { [store, history, browser] in
            guard !store.preparationArchived else { return }
            store.preparationArchived = true
            session?.applyBrowser(browser, store: store, history: history)
            if !store.preparation.isEmpty {
                history.archivePreparation(keys: store.preparation, date: store.preparationDate)
                store.preparation = []
            }
        }
        // Selbsttest: keine Controller anfassen (sonst steuert ein angeschlossener Controller die Test-Decks und umgekehrt)
        guard controller == nil, !Session.isSelfTest else { return }
        let m = ControllerManager(core: mix.core, status: controllerStatus)
        m.prefs = mix.prefs.controller
        m.fxUnits = mix.prefs.ui.fxUnitCount
        m.onBrowse = { [browser] pane, step in browser.moveSelection(by: step, pane: pane) }
        m.onLoad = { [browser, mix] pane, d, force in if let t = browser.selectedTrack(pane: pane) { mix.load(t, deck: d, force: force) } }
        m.onPreview = { [browser, mix] pane in if let t = browser.selectedTrack(pane: pane) { mix.togglePreview(t) } }
        m.onToggleBrowser = { [browser] in browser.maximized.toggle() }
        m.onMatching = { [browser] pane in browser.pane(pane).matching.toggle() }
        m.onSide = { [mix] key, side in mix.prefs.controller.sides[key] = side.rawValue }
        // alle Tastenkürzel (Belegung unter ⌘, -> Tastatur); Leertaste = Browser groß/klein, nicht beim Tippen in Suchfeldern
        KeyMonitor.install(actions)
        m.start()
        controller = m
    }
}

/// App-Icon: Lobster (Christians lobster2.png) – im Bundle als AppIcon.icns, beim Direktstart aus der Ressource
func setAppIcon() {
    if let url = AppResources.url("AppIcon", "png"),
       let img = NSImage(contentsOf: url) {
        NSApplication.shared.applicationIconImage = img
    }
}

// VST3-Selbsttest im eigenen Prozess (Einstellungen → PLUGINS → Prüfen): `<exe> --vst3-check <bundle> <klasse>`
if CommandLine.arguments.count >= 4, CommandLine.arguments[1] == PluginSelfCheck.argument {
    let info = PluginInfo.vst3(classID: CommandLine.arguments[3], name: URL(fileURLWithPath: CommandLine.arguments[2]).lastPathComponent,
                               vendor: "", version: "", path: CommandLine.arguments[2])
    let r = PluginSelfCheck.run(info)
    print(r.log)
    exit(r.passed ? 0 : 1)
}

AppResources.migrateDefaults()
// Sprache aus den Einstellungen (vor dem ersten Fenster)
switch AppPrefs.load().ui.language {
case "de", "en": UserDefaults.standard.set([AppPrefs.load().ui.language], forKey: "AppleLanguages")
default: UserDefaults.standard.removeObject(forKey: "AppleLanguages")
}
Theme.registerFonts()
if !Session.isSelfTest { MainActor.assumeIsolated { ZoomControl.apply(AppPrefs.load().ui.zoom) } }   // Zoom vor dem ersten Layout, Selbsttest 100 %
MainActor.assumeIsolated { DeckShot.runIfRequested() }   // nur Selbsttest mit MIX741_SHOT=deck:…, kehrt dann nicht zurück
MainActor.assumeIsolated { GrooveShot.runIfRequested() }   // nur Selbsttest mit MIX741_SHOT=groove:…

// Selbsttest, nur Bild: MIX741_SHOT=wave:<png> | header:<png> rendert offscreen und beendet – kein Fenster
if Session.isSelfTest, let shot = ProcessInfo.processInfo.environment["MIX741_SHOT"], shot.hasPrefix("header:") {
    MainActor.assumeIsolated { HeaderShot.run(shot) }
}
if Session.isSelfTest, let shot = ProcessInfo.processInfo.environment["MIX741_SHOT"], shot.hasPrefix("wave:") {
    MainActor.assumeIsolated { WaveShot.run(path: String(shot.dropFirst(5))) }
}

// Selbsttest-Bild des Tastatur-Tabs: offscreen rendern und beenden (kein Fenster, keine Aktivierung, kein Audio)
if Session.isSelfTest, let shot = ProcessInfo.processInfo.environment["MIX741_SHOT"], shot.hasPrefix("keys:") {
    exit(MainActor.assumeIsolated { ShortcutShot.render(to: String(shot.dropFirst(5))) } ? 0 : 1)
}
// Selbsttest-Bild offscreen (kein Fenster, kein Audio): MIX741_SELFTEST=1 MIX741_SHOT=browser:<png>
if Session.isSelfTest, let shot = ProcessInfo.processInfo.environment["MIX741_SHOT"], shot.hasPrefix("browser:") {
    MainActor.assumeIsolated { BrowserShot.run(shot) }
}
// Browser-Vorschau offscreen: Bilder + Messung (MIX741_SELFTEST=1 MIX741_SHOT=preview:<ordner>)
if Session.isSelfTest, let shot = ProcessInfo.processInfo.environment["MIX741_SHOT"], shot.hasPrefix("preview:") {
    MainActor.assumeIsolated { PreviewShot.run(shot) }
}
MainActor.assumeIsolated { PreviewColorShot.runIfRequested() }   // nur Selbsttest mit MIX741_SHOT=previewcolors:<ordner>, kein Fenster
MainActor.assumeIsolated { CoverShot.runIfRequested() }   // nur Selbsttest mit MIX741_SHOT=cover:<ordner>, endet mit exit
MainActor.assumeIsolated { TagShot.runIfRequested() }   // nur Selbsttest mit MIX741_SHOT=tags:<ordner>, endet mit exit
MainActor.assumeIsolated { TableShot.runIfRequested() }   // nur Selbsttest mit MIX741_SHOT=table:<ordner>, endet mit exit
MainActor.assumeIsolated { SettingsShot.runPluginsIfRequested() }   // nur PLUGINS-Tab, ohne Audio: MIX741_SHOT=plugins:<ordner>
MainActor.assumeIsolated { SettingsShot.runIfRequested() }   // nur Selbsttest mit MIX741_SHOT=settings:<ordner>, endet mit exit(0)
MainActor.assumeIsolated { StatusShot.runIfRequested() }   // nur Selbsttest mit MIX741_SHOT=status:<ordner>, endet mit exit(0)
MainActor.assumeIsolated { CloudShot.runIfRequested() }   // nur Selbsttest mit MIX741_SHOT=cloud:<ordner>, endet mit exit(0)
MainActor.assumeIsolated { ZoomShot.runIfRequested() }   // nur Selbsttest mit MIX741_SHOT=zoom:<ordner>, endet mit exit(0)
MainActor.assumeIsolated { FXShot.runIfRequested() }   // nur Selbsttest mit MIX741_SHOT=fx:<ordner>, endet mit exit(0)
MainActor.assumeIsolated { WindowShot.runIfRequested() }   // nur Selbsttest mit MIX741_SHOT=window:<png>, endet mit exit
MainActor.assumeIsolated { PlaylistShot.runIfRequested() }   // nur Selbsttest mit MIX741_SHOT=playlists:<ordner>, endet mit exit
MainActor.assumeIsolated { UISelfTest.runIfRequested() }   // nur Selbsttest mit MIX741_UITEST=1, endet mit exit

if ToggleBench.requested { MainActor.assumeIsolated { ToggleBench.run() } }   // Messung offscreen, ohne Fenster
if ReloadBench.requested { MainActor.assumeIsolated { ReloadBench.run() } }   // Neu-Laden der Collection messen, offscreen
if ConsistencyCLI.requested { MainActor.assumeIsolated { ConsistencyCLI.run() } }   // Collection prüfen ohne Fenster, nur lesen
if Session.isSelfTest, let shot = ProcessInfo.processInfo.environment["MIX741_SHOT"], shot.hasPrefix("consistency:") {
    MainActor.assumeIsolated { ConsistencyShot.run(shot) }
}
// Als SwiftPM-Executable ohne Bundle: als normale App im Dock starten.
NSApplication.shared.setActivationPolicy(.regular)
if ProcessInfo.processInfo.environment["MIX741_SHOT"] == nil { NSApplication.shared.activate(ignoringOtherApps: true) }
setAppIcon()
MixApp.main()

/// Browser-Höhe auf ganze Zeilen: `chrome` = alles außer den Zeilen (Kopf, Favoriten, Spaltenkopf), `row` = Zeilenhöhe
enum BrowserSnap {
    static func height(_ h: Double, chrome: Double, row: Double) -> Double {
        guard row > 0, h > chrome else { return h }
        let rows = max(1, ((h - chrome) / row).rounded())
        return chrome + rows * row
    }
}

/// Browser-Höhe beim Ziehen am Trenner: nur Starthöhe und Verschiebung seit dem Griff (unskaliert), nie die laufende Höhe.
/// Damit ist jede Verschiebung genau einer Höhe zugeordnet – das Einrasten wirkt nicht gegen die Bewegung
enum BrowserDrag {
    static func height(start: Double, translation: Double, snap: (Double) -> Double) -> Double {
        snap(max(120, min(900, start - translation)))
    }
}

extension Notification.Name {
    /// Spenden-Hinweis aus dem Hilfe-Menü öffnen
    static let showDonate = Notification.Name("minos741.showDonate")
}
