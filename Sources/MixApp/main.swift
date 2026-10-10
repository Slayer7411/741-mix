import SwiftUI
import AppKit
import MixCore

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

    var body: some View {
        VStack(spacing: 0) {
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
                SplitHandle(height: Binding(get: { mix.prefs.ui.browserHeight }, set: { mix.prefs.ui.browserHeight = $0 }))
            }
            browsers
                .frame(height: big ? nil : mix.prefs.ui.browserHeight)
                .frame(maxHeight: big ? .infinity : nil)
                .layoutPriority(big ? 1 : 0)
            statusBar
        }
        .background(Theme.background)
        .foregroundStyle(Theme.bone)
        .tint(Theme.state)
        .preferredColorScheme(.dark)
        .toolbar {
            ToolbarItemGroup {
                Toggle(isOn: Binding(get: { mix.prefs.ui.showMixer }, set: { mix.prefs.ui.showMixer = $0 })) {
                    Text("MIXER").font(Theme.label(11))
                }
                .help("Internen Mixer ein-/ausblenden")
                Picker("Decks", selection: Binding(get: { mix.prefs.ui.showFourDecks }, set: { mix.prefs.ui.showFourDecks = $0 })) {
                    Text("2 Decks").tag(false)
                    Text("4 Decks").tag(true)
                }
                .pickerStyle(.segmented)
                Picker("Browser", selection: Binding(get: { mix.prefs.ui.browserLayout }, set: { mix.prefs.ui.browserLayout = $0 })) {
                    ForEach(BrowserLayout.allCases) { Text($0.icon).help($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("Browser-Anordnung")
                Toggle(isOn: Binding(get: { !browserState.maximized }, set: { browserState.maximized = !$0 })) {
                    Text("DECKS").font(Theme.label(11))
                }
                    .help("Decks ein-/ausblenden (Browser groß)")
                Button { store.load(store.sourceURL ?? LibraryStore.defaultNML) } label: {
                    Text("↻")
                }
                .help("Collection neu laden")
            }
        }
        .windowToolbarFullScreenVisibility(.onHover)
        .background(MainWindowHook())
        .background(RunningTracks())
        .onChange(of: mix.prefs.ui.musicFolders, initial: true) { _, f in store.folders.configured = f }
        .onAppear {
            if store.tracks.isEmpty { store.load() }
            // MIX741_LAYOUT=nomixer,2decks,nobrowser: Teile der Oberfläche für Layout-Messungen abschalten (nur Selbsttest)
            if Session.isSelfTest, let l = ProcessInfo.processInfo.environment["MIX741_LAYOUT"] {
                if l.contains("nomixer") { mix.prefs.ui.showMixer = false }
                if l.contains("2decks") { mix.prefs.ui.showFourDecks = false }
                if l.contains("nobrowser") { mix.prefs.ui.browserLayout = .single; mix.prefs.ui.browserHeight = 120 }
            }
            SelfTest.run(store: store, mix: mix)
        }
    }

    /// RUNNING TRACKS im Browser nachführen – eigene leere Ansicht: liest alle vier Decks, ohne dass
    /// ContentView bei jeder Deck-Änderung neu ausgewertet wird
    struct RunningTracks: View {
        @Environment(LibraryStore.self) private var store
        @Environment(MixModel.self) private var mix
        var body: some View {
            Color.clear
                .onChange(of: (0..<4).map { mix.deck($0).track?.key ?? "" }, initial: true) { _, keys in
                    store.running = keys.filter { !$0.isEmpty }.compactMap { store.track($0) }
                }
        }
    }

    /// Ziehbarer Trenner zwischen Decks und Browser; Höhe wird gespeichert
    struct SplitHandle: View {
        @Binding var height: Double
        @State private var start: Double?
        var body: some View {
            Rectangle().fill(Theme.hairline).frame(height: 1)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
                .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { g in
                        if start == nil { start = height }
                        height = max(120, min(900, (start ?? height) - g.translation.height))
                    }
                    .onEnded { _ in start = nil })
        }
    }

    private var deckArea: some View {
        VStack(spacing: 6) {
            TopBar()
            // Decks mit fester Höhe: zwei flexible Decks übereinander ließen SwiftUI jede Zustandsänderung
            // ~200 ms lang Layout rechnen (kombinatorische Messungen verschachtelter Stacks)
            GeometryReader { geo in
                let rows: CGFloat = mix.showFourDecks ? 2 : 1
                let deckH = max(120, (geo.size.height - (rows - 1) * 6) / rows)
                HStack(alignment: .top, spacing: 6) {
                    VStack(spacing: 6) {
                        DeckView(d: 0).frame(height: deckH)
                        if mix.showFourDecks { DeckView(d: 2).frame(height: deckH) }
                    }
                    if mix.prefs.ui.showMixer { MixerView().fixedSize(horizontal: true, vertical: false) }
                    VStack(spacing: 6) {
                        DeckView(d: 1).frame(height: deckH)
                        if mix.showFourDecks { DeckView(d: 3).frame(height: deckH) }
                    }
                }
            }
        }
        .padding(6)
    }

    @ViewBuilder private var browsers: some View {
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

    private var statusBar: some View {
        HStack {
            Text(store.status).lineLimit(1)
            Spacer()
            Text(mix.engineStatus)
            Button("↻") { mix.reconnect() }
                .buttonStyle(.plain)
                .help("Audio-Interface neu verbinden")
            Text("· Preparation: \(store.preparation.count)")
        }
        .font(Theme.mono(11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }
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

    private var appTitle: String {
        let info = Bundle.main.infoDictionary
        guard let v = info?["CFBundleShortVersionString"] as? String else { return "MINOS-741 dev" }
        let b = info?["CFBundleVersion"] as? String ?? ""
        return "MINOS-741 \(v)" + (b.isEmpty || b == v ? "" : " (\(b))")
    }

    var body: some Scene {
        WindowGroup(appTitle) {
            ContentView()
                .environment(store)
                .environment(mix)
                .environment(browser)
                .environment(controllerStatus)
                .environment(waveforms)
                .environment(history)
                .frame(minWidth: 1280, minHeight: 860)
                .onAppear { startControllers() }
                .onChange(of: mix.prefs.controller) { controller?.prefs = mix.prefs.controller }
                .onChange(of: mix.prefs.ui.fxUnitCount) { controller?.fxUnits = mix.prefs.ui.fxUnitCount }
        }
        Settings {
            SettingsView()
                .environment(mix)
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
            CommandGroup(replacing: .saveItem) {
                Button(String(localized: "Fenster schließen")) { run(.closeWindow) }
                    .shortcut(keys.combo(.closeWindow))
            }
            CommandGroup(before: .toolbar) {
                Toggle("Mixer", isOn: Binding(get: { mix.prefs.ui.showMixer }, set: { mix.prefs.ui.showMixer = $0 }))
                    .shortcut(keys.combo(.toggleMixer))
                Toggle("4 Decks", isOn: Binding(get: { mix.prefs.ui.showFourDecks }, set: { mix.prefs.ui.showFourDecks = $0 }))
                    .shortcut(keys.combo(.toggleFourDecks))
                Toggle("Browser groß", isOn: Binding(get: { browser.maximized }, set: { browser.maximized = $0 }))
                    .shortcut(keys.combo(.bigBrowser))
                Picker("Browser-Anordnung", selection: Binding(get: { mix.prefs.ui.browserLayout }, set: { mix.prefs.ui.browserLayout = $0 })) {
                    ForEach(BrowserLayout.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                Divider()
            }
            CommandMenu("Decks") {
                ForEach([ShortcutID.focusDeckA, .focusDeckB, .focusDeckC, .focusDeckD]) { a in
                    Button(a.title) { run(a) }.shortcut(keys.combo(a))
                }
                Divider()
                ForEach([ShortcutID.play, .cue, .cup, .sync, .master, .keylock, .loop, .reloop, .beatjumpBack, .beatjumpForward]) { a in
                    Button(a.title) { run(a) }.shortcut(keys.combo(a))
                }
                Divider()
                ForEach([ShortcutID.hotcue1, .hotcue2, .hotcue3, .hotcue4, .hotcue5, .hotcue6, .hotcue7, .hotcue8]) { a in
                    Button(a.title) { run(a) }.shortcut(keys.combo(a))
                }
            }
            CommandMenu("Browser") {
                ForEach([ShortcutID.resetPlayed, .loadSelected, .previewSelected, .reloadCollection]) { a in
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
        appDelegate.onQuit = { [mix, browser, history] in
            Session.saveNow(mix: mix, browser: browser)
            history.finish()
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
        m.onLoad = { [browser, mix] pane, d in if let t = browser.selectedTrack(pane: pane) { mix.load(t, deck: d) } }
        m.onPreview = { [browser, mix] pane in if let t = browser.selectedTrack(pane: pane) { mix.togglePreview(t) } }
        m.onToggleBrowser = { [browser] in browser.maximized.toggle() }
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

AppResources.migrateDefaults()
// Sprache aus den Einstellungen (vor dem ersten Fenster)
switch AppPrefs.load().ui.language {
case "de", "en": UserDefaults.standard.set([AppPrefs.load().ui.language], forKey: "AppleLanguages")
default: UserDefaults.standard.removeObject(forKey: "AppleLanguages")
}
Theme.registerFonts()
MainActor.assumeIsolated { DeckShot.runIfRequested() }   // nur Selbsttest mit MIX741_SHOT=deck:…, kehrt dann nicht zurück

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
MainActor.assumeIsolated { SettingsShot.runIfRequested() }   // nur Selbsttest mit MIX741_SHOT=settings:<ordner>, endet mit exit(0)

if ToggleBench.requested { MainActor.assumeIsolated { ToggleBench.run() } }   // Messung offscreen, ohne Fenster
// Als SwiftPM-Executable ohne Bundle: als normale App im Dock starten.
NSApplication.shared.setActivationPolicy(.regular)
if ProcessInfo.processInfo.environment["MIX741_SHOT"] == nil { NSApplication.shared.activate(ignoringOtherApps: true) }
setAppIcon()
MixApp.main()
