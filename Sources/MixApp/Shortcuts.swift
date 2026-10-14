import SwiftUI
import AppKit
import MixCore

/// Tastenkürzel: Titel, Umrechnung NSEvent / SwiftUI, Ausführung und Tasten-Monitor.
/// Belegung: ShortcutID (MixCore) mit Standard, eigene Werte in AppPrefs.shortcuts.
extension ShortcutID: Identifiable {
    public var id: String { rawValue }

    var title: String {
        switch self {
        case .focusDeckA, .focusDeckB, .focusDeckC, .focusDeckD: String(localized: "Deck \(deckLetters[index ?? 0]) fokussieren")
        case .play: String(localized: "Play/Pause (Fokus-Deck)")
        case .cue: String(localized: "Cue (Fokus-Deck, halten)")
        case .cup: String(localized: "CUP (Fokus-Deck)")
        case .sync: String(localized: "Sync (Fokus-Deck)")
        case .master: String(localized: "Master (Fokus-Deck)")
        case .keylock: String(localized: "Keylock (Fokus-Deck)")
        case .loop: String(localized: "Loop (Fokus-Deck)")
        case .reloop: String(localized: "Reloop (Fokus-Deck)")
        case .beatjumpBack: String(localized: "Beatjump zurück")
        case .beatjumpForward: String(localized: "Beatjump vor")
        case .hotcue1, .hotcue2, .hotcue3, .hotcue4, .hotcue5, .hotcue6, .hotcue7, .hotcue8:
            String(localized: "Hotcue \((index ?? 0) + 1) (Fokus-Deck)")
        case .editMode: String(localized: "EDIT-Modus (Fokus-Deck)")
        case .cutIn: String(localized: "Schnitt-Anfang hier (Fokus-Deck)")
        case .cutOut: String(localized: "Schnitt-Ende hier (Fokus-Deck)")
        case .gridSet: String(localized: "Grid: Beat 1 hier (Fokus-Deck)")
        case .rangeRemove: String(localized: "Bereich entfernen, neue Datei (Fokus-Deck)")
        case .rangeKeep: String(localized: "Auf Bereich kürzen, neue Datei (Fokus-Deck)")
        case .rangeTrim: String(localized: "Schnitt IN/OUT aus Bereich (Fokus-Deck)")
        case .rangeLoop: String(localized: "Loop aus Bereich (Fokus-Deck)")
        case .rangeClear: String(localized: "Bereich aufheben (Fokus-Deck)")
        case .editRemove: String(localized: "EDIT: Bereich entfernen (Fokus-Deck)")
        case .editKeep: String(localized: "EDIT: nur Bereich behalten (Fokus-Deck)")
        case .editDuplicate: String(localized: "EDIT: Bereich duplizieren (Fokus-Deck)")
        case .editMute: String(localized: "EDIT: Bereich stumm (Fokus-Deck)")
        case .editLeft: String(localized: "EDIT: Segment nach links (Fokus-Deck)")
        case .editRight: String(localized: "EDIT: Segment nach rechts (Fokus-Deck)")
        case .editMark: String(localized: "EDIT: Schnittmarke am Spielkopf (Fokus-Deck)")
        case .editSnap: String(localized: "EDIT: nächstes Raster")
        case .editRender: String(localized: "EDIT: Schnittliste in die Datei rendern (Fokus-Deck)")
        case .toolLoop2, .toolLoop4, .toolLoop8, .toolLoop16: String(localized: "Tool-Loop \(index ?? 0) Beats exportieren (Fokus-Deck)")
        case .prepBIn: String(localized: "Vorbereiten: B IN an der Position (Fokus-Deck)")
        case .prepBOut: String(localized: "Vorbereiten: B OUT an der Position (Fokus-Deck)")
        case .prepABA: String(localized: "Vorbereiten: A-B-A, B heraus (Fokus-Deck)")
        case .prepAnalyse: String(localized: "Vorbereiten: Spitze messen (Fokus-Deck)")
        case .prepAmpUp: String(localized: "Vorbereiten: AMP +1 dB (Fokus-Deck)")
        case .prepNorm: String(localized: "Vorbereiten: AMP NORM −0.3 dBFS (Fokus-Deck)")
        case .prepAmpReset: String(localized: "Vorbereiten: AMP 0 dB (Fokus-Deck)")
        case .prepJoin: String(localized: "Vorbereiten: JOIN mit dem gewählten Track (Fokus-Deck)")
        case .prepSplit: String(localized: "Vorbereiten: SPLIT in zwei Dateien (Fokus-Deck)")
        case .prepRender: String(localized: "Vorbereiten: RENDER Schnittliste + AMP (Fokus-Deck)")
        case .keySync: String(localized: "Key Sync (Fokus-Deck)")
        case .instantDouble: String(localized: "Instant Double ins Fokus-Deck (vom Nachbardeck A↔B, C↔D)")
        case .masterFX: String(localized: "Master-FX an/aus")
        case .resetPlayed: String(localized: "Reset Played State")
        case .loadSelected: String(localized: "Auswahl ins Fokus-Deck laden")
        case .loadSelectedForce: String(localized: "Auswahl ins Fokus-Deck laden (auch wenn es spielt)")
        case .previewSelected: String(localized: "Auswahl vorhören")
        case .reloadCollection: String(localized: "Collection neu laden")
        case .matching: String(localized: "Browser: Matching an/aus (passt zum Master)")
        case .favorite1, .favorite2, .favorite3, .favorite4, .favorite5, .favorite6:
            String(localized: "Favorit \((index ?? 0) + 1) (Fokus-Bereich)")
        case .toggleMixer: String(localized: "Mixer ein/aus")
        case .toggleFourDecks: String(localized: "2 / 4 Decks")
        case .bigBrowser: String(localized: "Browser groß")
        case .bigBrowserKey: String(localized: "Browser groß (zweite Taste, nicht im Suchfeld)")
        case .compactDecks: String(localized: "Kompakte Decks (ohne Pitch-Fader, Hotcues, Grid-Werkzeuge)")
        case .profile1, .profile2, .profile3, .profile4: String(localized: "Profil \((index ?? 0) + 1)")
        case .profileNext: String(localized: "Nächstes Profil")
        case .zoomIn: String(localized: "Vergrößern")
        case .zoomOut: String(localized: "Verkleinern")
        case .zoomReset: String(localized: "Originalgröße")
        case .openCollection: String(localized: "Collection öffnen …")
        case .settings: String(localized: "Einstellungen …")
        case .closeWindow: String(localized: "Fenster schließen (Hauptfenster: beenden)")
        case .reconnectAudio: String(localized: "Audio-Interface neu verbinden")
        case .undo: String(localized: "Rückgängig")
        case .redo: String(localized: "Wiederherstellen")
        }
    }
}

extension ShortcutGroup {
    var title: String {
        switch self {
        case .decks: String(localized: "DECKS")
        case .browser: String(localized: "BROWSER")
        case .view: String(localized: "DARSTELLUNG")
        case .general: String(localized: "ALLGEMEIN")
        }
    }
}

extension KeyCombo {
    /// feste Tasten nach keyCode (unabhängig vom Tastaturlayout)
    static let keyCodes: [UInt16: String] = [
        49: "space", 123: "left", 124: "right", 125: "down", 126: "up", 36: "return", 76: "return", 48: "tab",
        53: "escape", 51: "delete", 117: "forwarddelete", 115: "home", 119: "end", 116: "pageup", 121: "pagedown",
        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12",
    ]

    /// gedrückte Taste -> Kombination; Zeichen wie bei Menü-Kürzeln (ohne Shift-Ebene, ⌘-Ebene des Layouts)
    init?(event e: NSEvent) {
        let f = e.modifierFlags
        var m: Mods = []
        if f.contains(.control) { m.insert(.control) }
        if f.contains(.option) { m.insert(.option) }
        if f.contains(.shift) { m.insert(.shift) }
        if f.contains(.command) { m.insert(.command) }
        if let n = Self.keyCodes[e.keyCode] { self.init(n, m); return }
        let chars = m.contains(.shift) ? e.characters(byApplyingModifiers: m.contains(.command) ? [.command] : [])
                                       : e.charactersIgnoringModifiers
        guard let c = chars?.lowercased(), c.count == 1, let s = c.unicodeScalars.first, !CharacterSet.controlCharacters.contains(s) else { return nil }
        self.init(c, m)
    }

    var keyEquivalent: KeyEquivalent {
        switch key {
        case "space": .space
        case "left": .leftArrow
        case "right": .rightArrow
        case "up": .upArrow
        case "down": .downArrow
        case "return": .return
        case "tab": .tab
        case "escape": .escape
        case "delete": .delete
        case "forwarddelete": .deleteForward
        case "home": .home
        case "end": .end
        case "pageup": .pageUp
        case "pagedown": .pageDown
        default:
            if key.hasPrefix("f"), let n = Int(key.dropFirst()), (1...12).contains(n), let u = UnicodeScalar(NSF1FunctionKey + n - 1) {
                KeyEquivalent(Character(u))
            } else {
                KeyEquivalent(Character(key))
            }
        }
    }

    var eventModifiers: EventModifiers {
        var m: EventModifiers = []
        if mods.contains(.control) { m.insert(.control) }
        if mods.contains(.option) { m.insert(.option) }
        if mods.contains(.shift) { m.insert(.shift) }
        if mods.contains(.command) { m.insert(.command) }
        return m
    }
}

extension View {
    /// Kürzel am Menüpunkt; Tasten ohne ⌘/⌥/⌃ nie ins Menü (würden das Tippen im Suchfeld stören), die übernimmt der Monitor
    func shortcut(_ c: KeyCombo?) -> some View {
        keyboardShortcut(c.flatMap { $0.isPlain ? nil : KeyboardShortcut($0.keyEquivalent, modifiers: $0.eventModifiers) })
    }
}

/// führt eine Aktion aus (Menü und Tasten-Monitor)
@MainActor
struct AppActions {
    let mix: MixModel
    let browser: BrowserState
    let store: LibraryStore
    let history: HistoryStore

    func callAsFunction(_ a: ShortcutID) {
        let d = mix.focusedDeck
        switch a {
        case .focusDeckA, .focusDeckB, .focusDeckC, .focusDeckD: mix.focusedDeck = a.index ?? 0
        case .play: mix.togglePlay(d)
        case .cue: mix.cueDown(d); mix.cueUp(d)   // aus dem Menü: antippen; halten nur per Taste (Monitor)
        case .cup: mix.cup(d)
        case .sync: mix.toggleSync(d)
        case .master: mix.toggleMaster(d)
        case .keylock: mix.toggleKeylock(d)
        case .loop: mix.autoLoop(d)
        case .reloop: mix.reloop(d)
        case .beatjumpBack: mix.beatjump(d, beats: -mix.deck(d).jumpSize)
        case .beatjumpForward: mix.beatjump(d, beats: mix.deck(d).jumpSize)
        case .hotcue1, .hotcue2, .hotcue3, .hotcue4, .hotcue5, .hotcue6, .hotcue7, .hotcue8: mix.hotcue(d, a.index ?? 0)
        case .editMode: mix.toggleEdit(d)
        case .cutIn: mix.trimHere(d, end: false)
        case .cutOut: mix.trimHere(d, end: true)
        case .gridSet: mix.setGridAnchorHere(d)
        case .rangeRemove: mix.cutRange(d, mode: .remove)
        case .rangeKeep: mix.cutRange(d, mode: .keep)
        case .rangeTrim: mix.rangeToTrim(d)
        case .rangeLoop: mix.rangeToLoop(d)
        case .rangeClear: mix.clearRange(d)
        case .editRemove: mix.editAction(d, .remove)
        case .editKeep: mix.editAction(d, .keep)
        case .editDuplicate: mix.editAction(d, .duplicate)
        case .editMute: mix.editAction(d, .mute)
        case .editLeft: mix.editAction(d, .left)
        case .editRight: mix.editAction(d, .right)
        case .editMark: mix.editMarkHere(d)
        case .editSnap: mix.setEditSnap(mix.prefs.ui.editSnap.next)
        case .editRender: mix.editRenderFile(d)
        case .toolLoop2, .toolLoop4, .toolLoop8, .toolLoop16: mix.exportToolLoop(d, beats: a.index ?? 4)
        case .prepBIn: mix.prepareMark(d, end: false)
        case .prepBOut: mix.prepareMark(d, end: true)
        case .prepABA: mix.prepareABA(d)
        case .prepAnalyse: mix.prepareAnalyse(d)
        case .prepAmpUp: mix.prepareAmp(d, add: 1)
        case .prepNorm: mix.prepareNorm(d)
        case .prepAmpReset: mix.prepareAmpReset(d)
        case .prepJoin: mix.prepareJoinAsking(d, browser: browser, store: store)
        case .prepSplit: mix.prepareSplit(d)
        case .prepRender: mix.prepareRender(d)
        case .keySync: mix.keySync(d)
        case .instantDouble: mix.instantDouble(from: d ^ 1, to: d, force: false)
        case .masterFX: mix.toggleMasterFX()
        case .resetPlayed: history.resetPlayed()
        case .loadSelected: if let t = browser.selectedTrack() { mix.load(t, deck: d, force: false) }
        case .loadSelectedForce: if let t = browser.selectedTrack() { mix.load(t, deck: d, force: true) }
        case .previewSelected: if let t = browser.selectedTrack() { mix.togglePreview(t) }
        case .reloadCollection: store.load(store.sourceURL ?? LibraryStore.defaultNML)
        case .matching: (mix.prefs.ui.browserLayout == .single ? browser.paneA : browser.activePane).matching.toggle()
        case .favorite1, .favorite2, .favorite3, .favorite4, .favorite5, .favorite6:
            (mix.prefs.ui.browserLayout == .single ? browser.paneA : browser.activePane).applyFavorite(a.index ?? 0, store: store)
        case .toggleMixer: mix.prefs.ui.showMixer.toggle()
        case .toggleFourDecks: mix.prefs.ui.showFourDecks.toggle()
        case .bigBrowser, .bigBrowserKey: browser.maximized.toggle()
        case .compactDecks: mix.prefs.ui.compactDecks.toggle()
        case .profile1, .profile2, .profile3, .profile4: LayoutProfiles.apply(at: a.index ?? 0, mix: mix, browser: browser)
        case .profileNext: LayoutProfiles.next(mix: mix, browser: browser)
        case .zoomIn, .zoomOut, .zoomReset: ZoomControl.step(a, mix: mix)
        case .openCollection:
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.init(filenameExtension: "nml")!]
            if panel.runModal() == .OK, let url = panel.url { store.load(url) }
        case .settings: break   // nur über das Menü (SettingsLink)
        case .closeWindow: MainWindow.close()
        case .reconnectAudio: mix.reconnect()
        case .undo: UndoStack.shared.perform(redo: false)
        case .redo: UndoStack.shared.perform(redo: true)
        }
    }
}

/// Tasten-Monitor: alle Kürzel laufen hier durch (Menüs zeigen sie nur an).
/// Tasten ohne ⌘/⌥/⌃ nur außerhalb von Textfeldern; Cue: Taste halten = Cue halten.
@MainActor
enum KeyMonitor {
    /// Aufnahme in den Einstellungen läuft -> nichts auslösen
    static var recording = false
    private static var cueKey: UInt16?
    private static var cueDeck = 0
    private static var token: Any?

    static func install(_ actions: AppActions) {
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { e in
            nonisolated(unsafe) let ev = e   // Monitor läuft auf dem Hauptthread
            return MainActor.assumeIsolated { handle(ev, actions) } ? nil : e
        }
    }

    /// true = Taste verbraucht
    private static func handle(_ e: NSEvent, _ actions: AppActions) -> Bool {
        if e.type == .keyUp {
            guard let k = cueKey, e.keyCode == k else { return false }
            cueKey = nil
            actions.mix.cueUp(cueDeck)
            return true
        }
        guard !recording, NSApp.modalWindow == nil, let c = KeyCombo(event: e) else { return false }
        let keys = actions.mix.prefs.keys
        var a = keys.action(for: c)
        // Taste ohne ⌘/⌥/⌃: Shift egal, solange Shift + Taste nicht eigens belegt ist (wie bisher bei der Leertaste)
        if a == nil, c.isPlain, c.mods == .shift { a = keys.action(for: KeyCombo(c.key, [])) }
        guard let a, a != .settings else { return false }
        if c.isPlain, NSApp.keyWindow?.firstResponder is NSText { return false }
        // Rückgängig im Textfeld: Text-Undo des Felds (das Menü Bearbeiten führt sonst die App-Schritte aus)
        if a == .undo || a == .redo, NSApp.keyWindow?.firstResponder is NSText {
            _ = NSApp.sendAction(Selector((a == .undo ? "undo:" : "redo:")), to: nil, from: nil)
            return true
        }
        // Esc: nur verbraucht, wenn ein Bereich markiert war
        if a == .rangeClear { return actions.mix.clearRange(actions.mix.focusedDeck) }
        if a == .cue {
            if !e.isARepeat, cueKey == nil {
                cueKey = e.keyCode
                cueDeck = actions.mix.focusedDeck
                actions.mix.cueDown(cueDeck)
            }
            return true
        }
        if a == .openCollection || a == .closeWindow {
            DispatchQueue.main.async { actions(a) }   // Dialog nicht im Monitor öffnen
        } else {
            actions(a)
        }
        return true
    }
}

/// Hauptfenster: roter Knopf und ⌘W beenden die App (mit Rückfrage) statt nur das Fenster zu schließen
@MainActor
enum MainWindow {
    static weak var window: NSWindow?

    final class Quit: NSObject {
        @objc func quit(_ sender: Any?) { NSApp.terminate(sender) }
    }
    static let quitter = Quit()

    /// ⌘W: Nebenfenster (Einstellungen) normal schließen, Hauptfenster -> Beenden mit Rückfrage
    static func close() {
        if let k = NSApp.keyWindow, k !== window { k.performClose(nil) } else { NSApp.terminate(nil) }
    }

    static func attach(_ w: NSWindow) {
        window = w
        guard let b = w.standardWindowButton(.closeButton), b.target !== quitter else { return }
        b.target = quitter
        b.action = #selector(Quit.quit(_:))
    }
}

/// hängt sich ins Hauptfenster (unsichtbar)
struct MainWindowHook: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { if let w = v.window { MainWindow.attach(w) } }
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async { if let w = v.window { MainWindow.attach(w) } }
    }

    /// nimmt den angebotenen Platz, ohne Auto-Layout-Messung (fittingSize) bei jedem Layout
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}
