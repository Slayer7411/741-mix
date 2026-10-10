import SwiftUI
import AppKit

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
    @State private var fullScreen = false
    private var layout: BrowserLayout { mix.prefs.ui.browserLayout }
    @Environment(BrowserState.self) private var browserState
    private var paneA: BrowserPaneModel { browserState.paneA }
    private var paneB: BrowserPaneModel { browserState.paneB }

    var body: some View {
        VStack(spacing: 0) {
            if !browserState.maximized {
                // Decks oben, Browser unten – Trenner verschiebbar; die Wellenformen bekommen den ganzen Platz
                deckArea
                    .frame(maxHeight: .infinity)
                    .layoutPriority(1)
                SplitHandle(height: Binding(get: { mix.prefs.ui.browserHeight }, set: { mix.prefs.ui.browserHeight = $0 }))
                browsers
                    .frame(height: mix.prefs.ui.browserHeight)
            } else {
                browsers
            }
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
        .toolbar(fullScreen ? .hidden : .visible, for: .windowToolbar)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { _ in fullScreen = true }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { _ in fullScreen = false }
        .onAppear {
            if store.tracks.isEmpty { store.load() }
            SelfTest.run(store: store, mix: mix)
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
            HStack(alignment: .top, spacing: 6) {
                VStack(spacing: 6) {
                    DeckView(d: 0)
                    if mix.showFourDecks { DeckView(d: 2) }
                }
                if mix.prefs.ui.showMixer { MixerView().fixedSize(horizontal: true, vertical: false) }
                VStack(spacing: 6) {
                    DeckView(d: 1)
                    if mix.showFourDecks { DeckView(d: 3) }
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
            Text("· Preparation: \(store.preparation.count)")
        }
        .font(Theme.mono(11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }
}

struct MixApp: App {
    @State private var store = LibraryStore()
    @State private var mix = MixModel()
    @State private var browser = BrowserState()
    @State private var x1Status = X1Status()
    @State private var waveforms = WaveformCache()
    @State private var history = HistoryStore()
    @State private var x1: X1Manager?

    var body: some Scene {
        WindowGroup("MINOS-741") {
            ContentView()
                .environment(store)
                .environment(mix)
                .environment(browser)
                .environment(x1Status)
                .environment(waveforms)
                .environment(history)
                .frame(minWidth: 1280, minHeight: 860)
                .onAppear { startControllers() }
                .onChange(of: mix.prefs.x1) { x1?.prefs = mix.prefs.x1 }
        }
        Settings {
            SettingsView()
                .environment(mix)
                .environment(x1Status)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Collection öffnen …") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.init(filenameExtension: "nml")!]
                    if panel.runModal() == .OK, let url = panel.url { store.load(url) }
                }
                .keyboardShortcut("o")
            }
            CommandGroup(before: .toolbar) {
                Toggle("Mixer", isOn: Binding(get: { mix.prefs.ui.showMixer }, set: { mix.prefs.ui.showMixer = $0 }))
                    .keyboardShortcut("m", modifiers: [.command, .option])
                Toggle("4 Decks", isOn: Binding(get: { mix.prefs.ui.showFourDecks }, set: { mix.prefs.ui.showFourDecks = $0 }))
                    .keyboardShortcut("4", modifiers: [.command, .option])
                Toggle("Browser groß", isOn: Binding(get: { browser.maximized }, set: { browser.maximized = $0 }))
                    .keyboardShortcut("b", modifiers: [.command, .option])
                Picker("Browser-Anordnung", selection: Binding(get: { mix.prefs.ui.browserLayout }, set: { mix.prefs.ui.browserLayout = $0 })) {
                    ForEach(BrowserLayout.allCases) { Text($0.rawValue).tag($0) }
                }
                Divider()
            }
            CommandMenu("Decks") {
                ForEach(0..<4, id: \.self) { n in
                    Button("Deck \(["A", "B", "C", "D"][n]) fokussieren") { mix.focusedDeck = n }
                        .keyboardShortcut(KeyEquivalent(Character(String(n + 1))))
                }
                Divider()
                Button("Play/Pause (Fokus-Deck)") { mix.togglePlay(mix.focusedDeck) }
                    .keyboardShortcut(.space, modifiers: [.command])
                Button("Sync (Fokus-Deck)") { mix.toggleSync(mix.focusedDeck) }
                    .keyboardShortcut("y", modifiers: [.command])
                Button("Loop (Fokus-Deck)") { mix.autoLoop(mix.focusedDeck) }
                    .keyboardShortcut("l", modifiers: [.command])
                Button("Beatjump zurück") { mix.beatjump(mix.focusedDeck, beats: -mix.deck(mix.focusedDeck).jumpSize) }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                Button("Beatjump vor") { mix.beatjump(mix.focusedDeck, beats: mix.deck(mix.focusedDeck).jumpSize) }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            }
        }
    }
}

extension MixApp {
    /// X1 auf der Steuer-Queue starten; Browser-Aktionen kommen auf dem Hauptthread zurück.
    @MainActor func startControllers() {
        browser.store = store
        browser.history = history
        browser.separators = { [mix] in mix.prefs.ui.tagSeparators }
        history.start(store: store, mix: mix)
        // Preparation der letzten Session archivieren und leeren (einmal pro Start, nach dem Laden der Collection)
        store.onLoaded = { [store, history] in
            guard !store.preparationArchived else { return }
            store.preparationArchived = true
            if !store.preparation.isEmpty {
                history.archivePreparation(keys: store.preparation, date: store.preparationDate)
                store.preparation = []
            }
        }
        guard x1 == nil else { return }
        let m = X1Manager(core: mix.core, status: x1Status)
        m.prefs = mix.prefs.x1
        m.onBrowse = { [browser] pane, step in browser.moveSelection(by: step, pane: pane) }
        m.onLoad = { [browser, mix] pane, d in if let t = browser.selectedTrack(pane: pane) { mix.load(t, deck: d) } }
        m.onPreview = { [browser, mix] pane in if let t = browser.selectedTrack(pane: pane) { mix.togglePreview(t) } }
        m.onToggleBrowser = { [browser] in browser.maximized.toggle() }
        // Leertaste = Browser groß/klein (nicht beim Tippen in Suchfeldern)
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [browser] e in
            guard e.keyCode == 49, e.modifierFlags.intersection([.command, .option, .control]).isEmpty,
                  !(NSApp.keyWindow?.firstResponder is NSText) else { return e }
            browser.maximized.toggle()
            return nil
        }
        m.start()
        x1 = m
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
Theme.registerFonts()

// Als SwiftPM-Executable ohne Bundle: als normale App im Dock starten.
NSApplication.shared.setActivationPolicy(.regular)
NSApplication.shared.activate(ignoringOtherApps: true)
setAppIcon()
MixApp.main()
