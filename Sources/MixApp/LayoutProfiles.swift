import SwiftUI
import AppKit
import MixCore

/// Ansichts-Profil: benannter Satz von Ansichts-Einstellungen aus UIPrefs (Decks, Mixer, FX-Units, Deck-Zeilen,
/// Browser, Statusleiste, Wellenform-Mindesthöhe, Cover und Cover-Breite, Übersicht-Höhe, Vorschau). Nicht dabei: Audio, Controller,
/// Wellenform-Stil und -Farben, Tags, Tastatur
struct LayoutProfile: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var deckCount = 4
    var showMixer = true
    var showFXUnits = true
    var fxUnitCount = 2
    var deckRows = DeckRows()
    var showGridTools = true
    var browserLayout = BrowserLayout.sideBySide
    var browserHeight = 240.0
    var hideTreeWithDecks = false
    /// Browser groß (BrowserState.maximized)
    var browserMaximized = false
    var statusBar = StatusBarMode.always
    var waveformHeight = 60.0
    var showDeckCover = true
    var deckCoverSize = 32.0
    var overviewHeight = 18.0
    var showCoverPreview = true
    var previewMode = PreviewMode.fullRow
    var showMeters = true

    init(name: String, ui: UIPrefs = UIPrefs(), maximized: Bool = false) {
        self.name = name
        capture(from: ui, maximized: maximized)
    }

    mutating func capture(from ui: UIPrefs, maximized: Bool) {
        deckCount = ui.deckCount
        showMixer = ui.showMixer
        showFXUnits = ui.showFXUnits
        fxUnitCount = ui.fxUnitCount
        deckRows = ui.deckRows
        showGridTools = ui.showGridTools
        browserLayout = ui.browserLayout
        browserHeight = ui.browserHeight
        hideTreeWithDecks = ui.hideTreeWithDecks
        browserMaximized = maximized
        statusBar = ui.statusBar
        waveformHeight = ui.waveformHeight
        showDeckCover = ui.showDeckCover
        deckCoverSize = ui.deckCoverSize
        overviewHeight = ui.overviewHeight
        showCoverPreview = ui.showCoverPreview
        previewMode = ui.previewMode
        showMeters = ui.showMeters
    }

    @MainActor mutating func capture(from ui: UIPrefs, browser: BrowserState) { capture(from: ui, maximized: browser.maximized) }

    /// nur die Felder setzen; Browser groß getrennt (liegt im BrowserState)
    func apply(to ui: inout UIPrefs) {
        ui.deckCount = deckCount
        ui.showMixer = showMixer
        ui.showFXUnits = showFXUnits
        ui.fxUnitCount = fxUnitCount
        ui.deckRows = deckRows
        ui.showGridTools = showGridTools
        ui.browserLayout = browserLayout
        ui.browserHeight = browserHeight
        ui.hideTreeWithDecks = hideTreeWithDecks
        ui.statusBar = statusBar
        ui.waveformHeight = waveformHeight
        ui.showDeckCover = showDeckCover
        ui.deckCoverSize = deckCoverSize
        ui.overviewHeight = overviewHeight
        ui.showCoverPreview = showCoverPreview
        ui.previewMode = previewMode
        ui.showMeters = showMeters
    }

    @MainActor func apply(to ui: inout UIPrefs, browser: BrowserState) {
        apply(to: &ui)
        if browser.maximized != browserMaximized { browser.maximized = browserMaximized }
    }

    /// gleiche Ansicht (Name und ID egal)
    func sameView(as o: LayoutProfile) -> Bool {
        var a = self
        a.id = o.id
        a.name = o.name
        return a == o
    }

    func matches(_ ui: UIPrefs, maximized: Bool) -> Bool { sameView(as: LayoutProfile(name: name, ui: ui, maximized: maximized)) }

    static let defaultSetupID = UUID(uuidString: "741D0000-0000-4000-8000-000000000001")!
    static let searchID = UUID(uuidString: "741D0000-0000-4000-8000-000000000002")!
    static let prepareID = UUID(uuidString: "741D0000-0000-4000-8000-000000000003")!
    static let audioEditID = UUID(uuidString: "741D0000-0000-4000-8000-000000000004")!

    /// „Audio-Edit“ (nur während des Modus, nicht in der Profilliste): ein Deck, unten der Editor (Werkzeuge, Wellenform)
    /// und die Arbeitsliste, Deck = Kopf, Übersicht, Vorbereiten-Zeile, Hotcues
    static func audioEdit(from ui: UIPrefs) -> LayoutProfile {
        var p = LayoutProfile(name: String(localized: "Audio-Edit"), ui: ui)
        p.id = audioEditID
        p.deckCount = 1
        p.showMixer = false
        p.showFXUnits = false
        var r = DeckRows()
        r.comment = false; r.tags = false; r.phaseBar = false; r.transport = false
        r.loop = false; r.jump = false; r.tempo = false; r.groove = false
        r.hotcues = true; r.prepare = true
        p.deckRows = r
        p.showGridTools = false
        p.browserHeight = 540
        p.browserMaximized = false
        p.hideTreeWithDecks = false
        p.overviewHeight = max(ui.overviewHeight, 48)
        p.statusBar = .always
        return p
    }

    /// „Vorbereiten“: ein Deck über die volle Breite, Browser groß, Deck = Kopf, Wellenform, Übersicht und eine
    /// Werkzeugzeile (Play, Grid, Schnitt, Amp, Join, Split, Render); das Deck geht dabei in den EDIT-Modus
    static func prepare(from ui: UIPrefs) -> LayoutProfile {
        var p = LayoutProfile(name: String(localized: "Vorbereiten"), ui: ui)
        p.id = prepareID
        p.deckCount = 1
        p.showMixer = false
        p.showFXUnits = false
        var r = DeckRows()
        r.comment = false; r.tags = false; r.phaseBar = false; r.transport = false; r.hotcues = false
        r.loop = false; r.jump = false; r.tempo = false; r.groove = false
        r.prepare = true
        p.deckRows = r
        p.showGridTools = false
        p.browserHeight = max(ui.browserHeight, 520)
        p.hideTreeWithDecks = false
        p.previewMode = .fullRow
        p.showDeckCover = true
        p.statusBar = .always
        return p
    }

    /// erste Profile, aus der vorhandenen Ansicht abgeleitet (FX-Anzahl, Browser-Höhe … bleiben)
    static func defaults(from ui: UIPrefs) -> [LayoutProfile] {
        var live = LayoutProfile(name: String(localized: "Default Setup"), ui: ui)
        live.id = defaultSetupID
        live.deckCount = 4
        live.showMixer = false
        live.showFXUnits = false
        var r = DeckRows()
        r.comment = false; r.tags = false; r.overview = false; r.hotcues = false; r.jump = false; r.tempo = false
        live.deckRows = r
        live.showGridTools = false
        live.browserLayout = .sideBySide
        live.statusBar = .auto
        live.showDeckCover = false

        var search = LayoutProfile(name: String(localized: "Musik suchen"), ui: ui)
        search.id = searchID
        search.deckCount = 1
        search.showMixer = false
        search.showFXUnits = false
        var s = DeckRows()
        s.phaseBar = false; s.loop = false; s.jump = false; s.tempo = false
        search.deckRows = s
        search.showGridTools = false
        search.browserHeight = max(ui.browserHeight, 520)
        search.hideTreeWithDecks = false
        search.previewMode = .fullRow
        search.showCoverPreview = true
        search.showDeckCover = true
        search.statusBar = .always
        return [live, search, prepare(from: ui)]
    }
}

extension LayoutProfile {
    /// fehlende oder unlesbare Felder (älteres / neueres Profil) -> Standard statt das ganze Profil zu verwerfen
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(name: "")
        func v<T: Decodable>(_ k: CodingKeys, _ cur: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: k)) ?? nil) ?? cur }
        id = v(.id, id); name = v(.name, name); deckCount = v(.deckCount, deckCount); showMixer = v(.showMixer, showMixer)
        showFXUnits = v(.showFXUnits, showFXUnits); fxUnitCount = v(.fxUnitCount, fxUnitCount); deckRows = v(.deckRows, deckRows)
        showGridTools = v(.showGridTools, showGridTools); browserLayout = v(.browserLayout, browserLayout)
        browserHeight = v(.browserHeight, browserHeight); hideTreeWithDecks = v(.hideTreeWithDecks, hideTreeWithDecks)
        browserMaximized = v(.browserMaximized, browserMaximized); statusBar = v(.statusBar, statusBar)
        waveformHeight = v(.waveformHeight, waveformHeight); showDeckCover = v(.showDeckCover, showDeckCover)
        showCoverPreview = v(.showCoverPreview, showCoverPreview); previewMode = v(.previewMode, previewMode)
        showMeters = v(.showMeters, showMeters)
        deckCoverSize = v(.deckCoverSize, deckCoverSize); overviewHeight = v(.overviewHeight, overviewHeight)
    }
}

extension ShortcutID {
    static let profiles: [ShortcutID] = [.profile1, .profile2, .profile3, .profile4]
}

/// Profil-Liste in UIPrefs: anwenden, speichern, aktualisieren, löschen, verschieben
extension UIPrefs {
    var activeProfile: LayoutProfile? {
        activeLayoutProfile.isEmpty ? nil : layoutProfiles.first { $0.id.uuidString == activeLayoutProfile }
    }

    /// aktives Profil, Ansicht seitdem geändert
    func profileModified(maximized: Bool) -> Bool {
        guard let p = activeProfile else { return false }
        return !p.matches(self, maximized: maximized)
    }

    /// Felder setzen, Profil wird aktiv (Browser groß: LayoutProfile.apply(to:browser:))
    mutating func applyProfile(_ p: LayoutProfile) {
        p.apply(to: &self)
        activeLayoutProfile = p.id.uuidString
    }

    /// aktuelle Ansicht unter dem Namen speichern; gleicher Name -> dieses Profil überschreiben. Wird aktiv
    @discardableResult
    mutating func saveProfile(name: String, maximized: Bool) -> LayoutProfile {
        var p = LayoutProfile(name: name, ui: self, maximized: maximized)
        if let i = layoutProfiles.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            p.id = layoutProfiles[i].id
            layoutProfiles[i] = p
        } else {
            layoutProfiles.append(p)
        }
        activeLayoutProfile = p.id.uuidString
        return p
    }

    /// Profil (nil = das aktive) mit der aktuellen Ansicht überschreiben; wird aktiv
    mutating func updateProfile(_ id: UUID?, maximized: Bool) {
        guard let id = id ?? activeProfile?.id, let i = layoutProfiles.firstIndex(where: { $0.id == id }) else { return }
        layoutProfiles[i].capture(from: self, maximized: maximized)
        activeLayoutProfile = id.uuidString
    }

    mutating func deleteProfile(_ id: UUID) {
        layoutProfiles.removeAll { $0.id == id }
        if activeLayoutProfile == id.uuidString { activeLayoutProfile = "" }
    }

    mutating func moveProfile(_ id: UUID, by delta: Int) {
        guard let i = layoutProfiles.firstIndex(where: { $0.id == id }), layoutProfiles.indices.contains(i + delta) else { return }
        layoutProfiles.swapAt(i, i + delta)
    }

    /// Index nach dem aktiven (am Ende wieder das erste)
    var nextProfileIndex: Int? {
        guard !layoutProfiles.isEmpty else { return nil }
        let i = layoutProfiles.firstIndex { $0.id.uuidString == activeLayoutProfile } ?? -1
        return (i + 1) % layoutProfiles.count
    }
}

/// Profile über Menü, Werkzeugleiste, Tasten, Einstellungen: ein Prefs-Wechsel je Aktion (ein Speichern)
@MainActor
enum LayoutProfiles {
    /// Name für Menüs: „Name“, geändert „Name *“
    static func title(_ ui: UIPrefs, maximized: Bool) -> String? {
        ui.activeProfile.map { $0.name + (ui.profileModified(maximized: maximized) ? " *" : "") }
    }

    static func apply(_ p: LayoutProfile, mix: MixModel, browser: BrowserState) {
        var ui = mix.prefs.ui
        ui.applyProfile(p)
        mix.prefs.ui = ui
        if browser.maximized != p.browserMaximized { browser.maximized = p.browserMaximized }
    }


    static func apply(at i: Int, mix: MixModel, browser: BrowserState, announce: Bool = true) {
        let list = mix.prefs.ui.layoutProfiles
        guard list.indices.contains(i) else { return }
        apply(list[i], mix: mix, browser: browser)
        if announce { StatusCenter.shared.post(.info, String(localized: "Profil: \(list[i].name)"), key: "profile") }
    }

    static func next(mix: MixModel, browser: BrowserState) {
        if let i = mix.prefs.ui.nextProfileIndex { apply(at: i, mix: mix, browser: browser) }
    }

    static func update(_ id: UUID? = nil, mix: MixModel, browser: BrowserState) {
        mix.prefs.ui.updateProfile(id, maximized: browser.maximized)
    }

    static func move(_ id: UUID, by delta: Int, mix: MixModel) { mix.prefs.ui.moveProfile(id, by: delta) }

    static func rename(_ id: UUID, to name: String, mix: MixModel) {
        guard let i = mix.prefs.ui.layoutProfiles.firstIndex(where: { $0.id == id }) else { return }
        mix.prefs.ui.layoutProfiles[i].name = name
    }

    // MARK: Rückfragen

    /// Name abfragen und speichern
    static func saveAsking(mix: MixModel, browser: BrowserState) {
        let a = NSAlert()
        a.messageText = String(localized: "Aktuelle Ansicht als Profil speichern")
        a.informativeText = String(localized: "Gibt es den Namen schon, wird dieses Profil überschrieben.")
        let field = NSTextField(string: String(localized: "Profil \(mix.prefs.ui.layoutProfiles.count + 1)"))
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        a.accessoryView = field
        a.addButton(withTitle: String(localized: "Speichern"))
        a.addButton(withTitle: String(localized: "Abbrechen"))
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        mix.prefs.ui.saveProfile(name: name, maximized: browser.maximized)
    }

    static func deleteAsking(_ id: UUID? = nil, mix: MixModel) {
        guard let p = id.flatMap({ id in mix.prefs.ui.layoutProfiles.first { $0.id == id } }) ?? mix.prefs.ui.activeProfile else { return }
        let a = NSAlert()
        a.messageText = String(localized: "Profil „\(p.name)“ löschen?")
        a.addButton(withTitle: String(localized: "Löschen"))
        a.addButton(withTitle: String(localized: "Abbrechen"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        mix.prefs.ui.deleteProfile(p.id)
    }
}

/// Werkzeugleiste links: aktives Profil, Auswahl schaltet um
struct LayoutProfileMenu: View {
    @Environment(MixModel.self) private var mix
    @Environment(BrowserState.self) private var browser

    var body: some View {
        let ui = mix.prefs.ui
        let title = LayoutProfiles.title(ui, maximized: browser.maximized)
        Menu {
            ForEach(Array(ui.layoutProfiles.enumerated()), id: \.element.id) { i, p in
                Toggle(isOn: Binding(get: { p.id.uuidString == ui.activeLayoutProfile },
                                     set: { _ in LayoutProfiles.apply(at: i, mix: mix, browser: browser, announce: false) })) {
                    Text(verbatim: p.name)
                }
            }
            Divider()
            Button("Aktuelle Ansicht als Profil speichern …") { LayoutProfiles.saveAsking(mix: mix, browser: browser) }
            Button("Profil aktualisieren") { LayoutProfiles.update(mix: mix, browser: browser) }
                .disabled(ui.activeProfile == nil)
        } label: {
            // Chip wie DeckButton: aktives Profil in Versalien (DEFAULT SETUP *)
            Text(verbatim: (title?.uppercased() ?? String(localized: "PROFIL")) + " ▾")
                .font(Theme.label(10, .bold)).foregroundStyle(Theme.bone).lineLimit(1)
                .padding(.horizontal, 6)
                .frame(height: 18)
                .background(Rectangle().fill(Theme.void))
                .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Ansichts-Profil (⌃⌥⌘1–4, ⌃⌥⇥ nächstes; * = Ansicht geändert)")
    }
}

/// ⌘, -> ANZEIGE -> Profile
struct LayoutProfileSettings: View {
    @Environment(MixModel.self) private var mix
    @Environment(BrowserState.self) private var browser

    var body: some View {
        let ui = mix.prefs.ui
        let list = ui.layoutProfiles
        let modified = ui.profileModified(maximized: browser.maximized)
        let keys = mix.prefs.keys
        Section("Profile") {
            ForEach(Array(list.enumerated()), id: \.element.id) { i, p in
                let active = p.id.uuidString == ui.activeLayoutProfile
                let combo = i < ShortcutID.profiles.count ? keys.combo(ShortcutID.profiles[i]) : nil
                let buttons = HStack(spacing: 4) {
                    Button("Anwenden") { LayoutProfiles.apply(p, mix: mix, browser: browser) }
                    Button("Aktualisieren") { LayoutProfiles.update(p.id, mix: mix, browser: browser) }
                    Button { LayoutProfiles.move(p.id, by: -1, mix: mix) } label: { Text(verbatim: "↑") }.disabled(i == 0)
                    Button { LayoutProfiles.move(p.id, by: 1, mix: mix) } label: { Text(verbatim: "↓") }.disabled(i == list.count - 1)
                }
                LabeledContent {
                    // Taste nur, wenn Platz ist (schmales Fenster: ohne)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) {
                            buttons
                            if let combo { Text(verbatim: combo.symbols).font(Theme.mono(10)).foregroundStyle(Theme.muted).fixedSize() }
                        }
                        buttons
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(verbatim: active ? (modified ? "◆*" : "◆") : "◇")
                            .font(Theme.label(10)).foregroundStyle(active ? Theme.state : Theme.muted)
                            .frame(width: 16, alignment: .leading)
                        TextField("Name", text: Binding(get: { p.name }, set: { LayoutProfiles.rename(p.id, to: $0, mix: mix) }))
                            .settingsField()
                        Button { LayoutProfiles.deleteAsking(p.id, mix: mix) } label: { Text(verbatim: "✕") }
                            .help("Profil löschen")
                    }
                }
            }
            Button("Aktuelle Ansicht speichern …") { LayoutProfiles.saveAsking(mix: mix, browser: browser) }
                .settingsControlColumn()
                .settingsAnchor("display.profiles")
            Text("was ein profil speichert: decks, mixer, fx-units, zeilen, browser, statusleiste.")
                .settingsHint()
                .help("profil = decks (1 / 2 / 4), mixer, fx-units, zeilen je deck, browser (anordnung, höhe, baum, groß), statusleiste, last-anzeigen, wellenform-mindesthöhe, cover und cover-breite, übersicht-höhe, vorschau. nicht: audio, controller, wellenform-stil und farben, tags, tastatur. umschalten: profil-menü links in der werkzeugleiste, menü darstellung -> profil, die ersten vier per taste (⌘, -> tastatur), nächstes ⌃⌥⇥. ◆ = aktiv, * = ansicht seitdem geändert -> aktualisieren übernimmt sie.")
        }
    }
}
