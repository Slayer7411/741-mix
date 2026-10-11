import SwiftUI
import MixCore

/// Rollen aus dem Mix-Steckbrief (Kommentar 2, „» BASIS“ usw.) als Schnellfilter.
enum RoleFilter: String, CaseIterable, Identifiable {
    case basis = "BASIS", synth = "SYNTH", drums = "DRUMS", voll = "VOLL", atmo = "ATMO"
    var id: String { rawValue }
}

/// Zustand eines Browser-Bereichs – jeder Bereich hat eigene Quelle, Suche, Sortierung, Auswahl, Tag-Filter.
@MainActor @Observable
final class BrowserPaneModel: Identifiable {
    let id = UUID()
    var name: String
    var source: BrowserSource = .collection
    var search = ""
    var roles: Set<RoleFilter> = []
    /// gewählte Tags aus Kommentar 2 (alle müssen passen)
    var tags: Set<String> = []
    var sortOrder: [KeyPathComparator<Track>] = [KeyPathComparator(\Track.artist)]
    var selection: Set<Track.ID> = []
    var showTree = true
    /// MUSIC FOLDERS: Dateien aus allen Unterordnern zeigen
    var subfolders = false
    /// nur lokale Dateien (Cloud: ohne ☁ nur online / fehlend)
    var localOnly = false
    /// Inline-Bearbeitung: Zelle (Track + Feld) und der Text im Feld
    var inline: InlineEdit?
    var inlineText = ""
    /// offenes Bearbeiten-Fenster (⌘E, Rechtsklick -> Bearbeiten …)
    var editSession: TrackEditSession?

    init(name: String, source: BrowserSource = .collection) {
        self.name = name
        self.source = source
    }

    /// Tags eines Tracks: Kommentar 2 an den eingestellten Trennzeichen zerlegt
    static func tags(of t: Track, separators: String) -> [String] {
        let seps = Set(separators.isEmpty ? " " : separators)
        return t.comment2.split(whereSeparator: { seps.contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Tracks der Quelle vor Tag-Filter/Suche (für die Tag-Auswahl)
    func base(from store: LibraryStore, history: HistoryStore?) -> [Track] {
        if case let .prepArchive(s) = source { return (history?.prepKeys(s) ?? []).compactMap { store.byKey[$0] } }
        if case let .folder(p) = source { return store.folders.tracks(in: p, recursive: subfolders, library: store) }
        return store.tracks(for: source)
    }

    @ObservationIgnored private var sortedKey: [AnyHashable] = []
    @ObservationIgnored private var sortedBase: [Track] = []
    @ObservationIgnored private var cacheKey: [AnyHashable] = []
    @ObservationIgnored private var cachedRows: [Track] = []

    /// Gefilterte + sortierte Liste. Die Quelle wird einmal sortiert (14k Tracks lokalisiert ≈ 100 ms) und bei
    /// Suche, Tags und Rollen nur noch gefiltert – ein Tastendruck im Suchfeld kostet so ~5 ms statt der Sortierung.
    func rows(from store: LibraryStore, history: HistoryStore?, separators: String) -> [Track] {
        let baseKey: [AnyHashable] = [source, "\(sortOrder)", store.revision, store.sourceRevision(source, subfolders: subfolders), subfolders]
        if baseKey != sortedKey {
            // nach dem Laden liegt die Liste meist schon sortiert vor (im Hintergrund, siehe LibraryStore.load)
            sortedBase = store.presorted(source, order: sortOrder) ?? base(from: store, history: history).sorted(using: sortOrder)
            sortedKey = baseKey
        }
        let key = baseKey + [search, roles, tags, separators, localOnly, localOnly ? CloudLibrary.shared.revision : 0] as [AnyHashable]
        if key == cacheKey { return cachedRows }
        cachedRows = filtered(sortedBase, separators: separators)
        cacheKey = key
        return cachedRows
    }

    /// Bearbeiten-Fenster für die gewählten Tracks (Reihenfolge der Liste); ein Track -> PREV/NEXT durch die Liste
    func openEditor(_ ids: Set<Track.ID>, rows: [Track], store: LibraryStore) {
        let keys = rows.map(\.key)
        var sel = keys.filter { ids.contains($0) }
        if sel.isEmpty { sel = ids.sorted() }
        guard !sel.isEmpty, inline == nil else { return }
        editSession = TrackEditSession(selection: sel, list: keys, store: store)
    }

    private func filtered(_ base: [Track], separators: String) -> [Track] {
        var list = base
        if !roles.isEmpty {
            list = list.filter { t in roles.contains { t.comment2.localizedCaseInsensitiveContains("» " + $0.rawValue) } }
        }
        if !tags.isEmpty {
            list = list.filter { t in tags.isSubset(of: Set(Self.tags(of: t, separators: separators))) }
        }
        let words = search.split(separator: " ").map { Track.fold(String($0)) }
        if !words.isEmpty { list = list.filter { $0.matches(words: words) } }
        if localOnly {
            let c = CloudLibrary.shared
            list = list.filter { c.isLocal($0.path) }
        }
        return list
    }
}

struct BrowserPane: View {
    @Environment(LibraryStore.self) private var store
    @Environment(HistoryStore.self) private var history
    @Environment(MixModel.self) private var decks
    @Bindable var model: BrowserPaneModel
    @State private var showTags = false
    @Environment(BrowserState.self) private var browserState

    var body: some View {
        let seps = decks.prefs.ui.tagSeparators
        let rows = model.source.isHistory ? [] : model.rows(from: store, history: history, separators: seps)
        // Baum bleibt im Split, ausgeblendet = Breite 0 (nur der 1-pt-Trenner bleibt): Entfernen/Einsetzen des
        // Split-Elements hängte jede Zeile aus dem Fenster aus und wieder ein (~850 ms beim Umschalten Browser groß ⇄ Decks)
        let tree = model.showTree && !(decks.prefs.ui.hideTreeWithDecks && !browserState.maximized)
        HSplitView {
            SourceTree(selection: $model.source)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if tree && decks.prefs.ui.showCoverPreview { CoverPreview(model: model) }   // Cover des gewählten Tracks
                }
                .frame(minWidth: tree ? 170 : 0, idealWidth: tree ? 210 : 0, maxWidth: tree ? 320 : 0)
            VStack(spacing: 0) {
                header(count: model.source.isHistory ? historyEntries.count : rows.count, separators: seps)
                if model.source.isHistory {
                    HistoryTable(entries: historyEntries, model: model)
                } else {
                    TrackTable(rows: rows, model: model)
                }
            }
            .frame(minWidth: 380)
        }
        .background {
            // ⌘E: Bearbeiten-Fenster für die Auswahl (nur der zuletzt benutzte Bereich reagiert)
            if browserState.activePane.id == model.id, !model.source.isHistory {
                Button("") { model.openEditor(model.selection, rows: rows, store: store) }
                    .keyboardShortcut("e", modifiers: .command)
                    .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
            }
        }
        .sheet(item: $model.editSession) { session in
            TrackEditPanel(session: session) { key in
                model.selection = [key]
                browserState.scrollRequest = (model.id, key)
            }
        }
        .onChange(of: decks.prefs.ui.writeCollection) { _, on in if on { store.scheduleWriteBack() } }
    }

    private var historyEntries: [HistoryEntry] {
        switch model.source {
        case .historyLive: history.live
        case let .history(s): history.entries(s)
        default: []
        }
    }

    private func header(count: Int, separators: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button { model.showTree.toggle() } label: { Text("◧").font(Theme.mono(13)).foregroundStyle(Theme.bone) }
                    .buttonStyle(.borderless)
                    .help("Baum ein/aus")
                Text(model.source.title.uppercased()).font(Theme.label(13, .bold)).lineLimit(1)
                Text("\(count)").font(Theme.mono(11)).foregroundStyle(Theme.muted).fixedSize()
                if case .folder = model.source {
                    DeckButton(title: "UNTERORDNER", active: model.subfolders) { model.subfolders.toggle() }
                        .help("Dateien aus allen Unterordnern zeigen")
                }
                Spacer(minLength: 8)
                TextField("SUCHEN", text: $model.search)
                    .textFieldStyle(.plain)
                    .font(Theme.mono(11))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Theme.void)
                    .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
                    .frame(minWidth: 120, maxWidth: 220)
            }
            HStack(spacing: 4) {
                ForEach(RoleFilter.allCases) { r in
                    DeckButton(title: r.rawValue, active: model.roles.contains(r)) {
                        if model.roles.contains(r) { model.roles.remove(r) } else { model.roles.insert(r) }
                    }
                }
                Text("│").foregroundStyle(Theme.hairline)
                DeckButton(title: "TAGS ▾", active: showTags) { showTags.toggle() }
                    .popover(isPresented: $showTags, arrowEdge: .bottom) {
                        TagPicker(model: model, separators: separators)
                    }
                if CloudLibrary.shared.hasCloudTracks {
                    Text("│").foregroundStyle(Theme.hairline)
                    DeckButton(title: "● LOKAL", active: model.localOnly) { model.localOnly.toggle() }
                        .help("Nur lokale Tracks (ohne ☁ nur online)")
                    SetCheckButton(model: model)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(model.tags.sorted(), id: \.self) { t in
                            DeckButton(title: t + " ✕", active: true) { model.tags.remove(t) }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Theme.panelHeader)
    }
}

/// Alle Tags der aktuellen Quelle (aus Kommentar 2) mit Anzahl – Klick filtert.
struct TagPicker: View {
    @Environment(LibraryStore.self) private var store
    @Environment(HistoryStore.self) private var history
    @Bindable var model: BrowserPaneModel
    let separators: String
    @State private var filter = ""
    @Environment(MixModel.self) private var mix
    private var ui: UIPrefs { mix.prefs.ui }

    var body: some View {
        let counts = Dictionary(model.base(from: store, history: history)
            .flatMap { BrowserPaneModel.tags(of: $0, separators: separators) }.map { ($0, 1) }, uniquingKeysWith: +)
        let list = counts.filter { filter.isEmpty || $0.key.localizedCaseInsensitiveContains(filter) }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        VStack(alignment: .leading, spacing: 6) {
            Text("TAGS · KOMMENTAR 2").font(Theme.label(12, .bold))
            Text("trennzeichen: '\(separators)' (einstellbar unter ⌘, → anzeige)").font(Theme.mono(10)).foregroundStyle(Theme.muted)
            TextField("FILTERN", text: $filter).textFieldStyle(.plain).font(Theme.mono(11))
                .padding(4).overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(list, id: \.key) { k, n in
                        Button {
                            if model.tags.contains(k) { model.tags.remove(k) } else { model.tags.insert(k) }
                        } label: {
                            HStack {
                                Text(model.tags.contains(k) ? "■" : "□").foregroundStyle(model.tags.contains(k) ? Theme.state : Theme.muted)
                                Text(k).foregroundStyle(Theme.bone).padding(.horizontal, 3)
                                    .background(ui.tagHighlight ? TagColors.color(k, ui) : .clear)
                                Spacer()
                                Text("\(n)").foregroundStyle(Theme.muted)
                            }
                            .font(Theme.mono(11))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 320)
            if !model.tags.isEmpty {
                HStack {
                    DeckButton(title: "ALLE TAGS LÖSEN") { model.tags.removeAll() }
                    DeckButton(title: "ALS SMARTLIST") {
                        let tags = model.tags.sorted()
                        let q = tags.map { "$COMMENT2 % \"\($0.replacingOccurrences(of: "\"", with: ""))\"" }.joined(separator: " & ")
                        store.customSmartlists.append(CustomSmartlist(name: tags.joined(separator: " + "), query: q))
                    }
                    .help("Smartlist aus den gewählten Tags anlegen (alle müssen passen)")
                }
            }
        }
        .padding(10)
        .frame(width: 320)
        .background(Theme.chitin)
    }
}

/// Baum: Collection, Preparation (+ Archiv), History (+ Archiv), eigene Smartlists, Playlists.
struct SourceTree: View {
    @Environment(LibraryStore.self) private var store
    @Environment(HistoryStore.self) private var history
    @Binding var selection: BrowserSource
    @State private var editing: CustomSmartlist?

    var body: some View {
        List(selection: Binding<BrowserSource?>(get: { selection }, set: { if let s = $0 { selection = s } })) {
            row("≣", "TRACK COLLECTION").tag(BrowserSource.collection)
                .contextMenu {
                    exportMenu(.collection)
                    Button("Collection prüfen …") { ConsistencyWindow.show(store: store) }
                    Button("Reset Played State") { history.resetPlayed() }
                    OverviewMenuButton { store.tracks }
                    CloudMenuButton(label: "Track Collection") { store.tracks }
                }
            row("▶", "RUNNING TRACKS").tag(BrowserSource.running)
            row("▤", "PREPARATION").tag(BrowserSource.preparation)
                .contextMenu {
                    exportMenu(.preparation)
                    OverviewMenuButton { store.tracks(for: .preparation) }
                    CloudMenuButton(label: "Preparation") { store.tracks(for: .preparation) }
                }
            DisclosureGroup {
                ForEach(history.prepArchive) { s in
                    row("▤", Theme.dateTimeFormat.string(from: s.date)).tag(BrowserSource.prepArchive(s))
                        .contextMenu { exportMenu(.prepArchive(s)) }
                }
            } label: { row("▸", "PREPARATION ARCHIV") }
            row("◷", "HISTORY").tag(BrowserSource.historyLive)
                .contextMenu { exportMenu(.historyLive) }
            DisclosureGroup {
                ForEach(history.archive) { s in
                    row(s.source == .external ? "◷" : "◴", s.label ?? Theme.dateTimeFormat.string(from: s.date)).tag(BrowserSource.history(s))
                        .contextMenu { exportMenu(.history(s)) }
                }
            } label: { row("▸", "HISTORY ARCHIV") }
            DisclosureGroup {
                ForEach(store.customSmartlists) { sl in
                    row("◆", sl.name).tag(BrowserSource.custom(sl))
                        .contextMenu {
                            exportMenu(.custom(sl))
                            OverviewMenuButton { store.tracks(for: .custom(sl)) }
                            CloudMenuButton(label: sl.name) { store.tracks(for: .custom(sl)) }
                            Button("Bearbeiten …") { editing = sl }
                            Button("Löschen") { store.customSmartlists.removeAll { $0.id == sl.id } }
                        }
                }
                Button { editing = CustomSmartlist(name: "Neue Smartlist", query: "$COMMENT2 % \"BASIS\"") } label: {
                    row("+", "NEUE SMARTLIST")
                }
                .buttonStyle(.plain)
            } label: { row("▸", "SMARTLISTS 741") }
            MusicFolderTree(selection: $selection)
            Section {
                OutlineGroup(store.root.children, children: \.childrenOrNil) { node in
                    row(icon(node), node.name)
                        .tag(BrowserSource.node(node))
                        .lineLimit(1)
                        .contextMenu {
                            if node.kind != .folder { exportMenu(.node(node)) }
                            OverviewMenuButton { nodeTracks(node) }
                            CloudMenuButton(label: node.name) { nodeTracks(node) }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Theme.chitin)
        .sheet(item: $editing) { sl in
            SmartlistEditor(smartlist: sl) { saved in
                if let i = store.customSmartlists.firstIndex(where: { $0.id == saved.id }) { store.customSmartlists[i] = saved }
                else { store.customSmartlists.append(saved) }
                selection = .custom(saved)
            }
        }
    }

    /// Kontextmenü „Exportieren“ für eine Quelle
    @ViewBuilder private func exportMenu(_ src: BrowserSource) -> some View {
        Menu("Exportieren") {
            Button("NML …") { export(.nml, src) }
            Button("M3U …") { export(.m3u, src) }
            Button("Ordner mit Audiodateien …") { export(.folder, src) }
        }
    }

    private func export(_ f: PlaylistExport.Format, _ src: BrowserSource) {
        let tracks: [Track]
        switch src {
        case .historyLive: tracks = history.live.compactMap { store.byKey[$0.key] }
        case let .history(s): tracks = history.entries(s).compactMap { store.byKey[$0.key] }
        case let .prepArchive(s): tracks = history.prepKeys(s).compactMap { store.byKey[$0] }
        default: tracks = store.tracks(for: src)
        }
        PlaylistExport.run(f, name: src.title, tracks: tracks, store: store)
    }

    /// Tracks eines Knotens, Ordner mit allen Unterknoten
    private func nodeTracks(_ n: PlaylistNode) -> [Track] {
        n.kind == .folder ? n.children.flatMap(nodeTracks) : store.tracks(for: .node(n))
    }

    private func icon(_ n: PlaylistNode) -> String {
        switch n.kind {
        case .folder: "▸"
        case .playlist: "▤"
        case .smartlist: "◇"
        }
    }

    private func row(_ glyph: String, _ name: String) -> some View {
        HStack(spacing: 6) {
            Text(glyph).font(Theme.mono(11)).foregroundStyle(Theme.muted).frame(width: 12)
            Text(name).font(Theme.mono(11)).foregroundStyle(Theme.bone).lineLimit(1)
        }
    }
}

/// Smartlist anlegen/bearbeiten: Regel in Smartlist-Syntax, Live-Anzahl und Fehleranzeige.
struct SmartlistEditor: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var smartlist: CustomSmartlist
    let onSave: (CustomSmartlist) -> Void

    var body: some View {
        let parsed = Result { try SmartQuery.parse(smartlist.query) }
        let count: Int? = (try? parsed.get()).map { q in store.tracks.filter { q.matches($0) }.count }
        VStack(alignment: .leading, spacing: 10) {
            Text("SMARTLIST").font(Theme.label(16, .bold))
            TextField("NAME", text: $smartlist.name).textFieldStyle(.plain).font(Theme.mono(13))
                .padding(6).overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
            TextEditor(text: $smartlist.query).font(Theme.mono(12)).frame(height: 90)
                .scrollContentBackground(.hidden).background(Theme.void)
                .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
            if case let .failure(e) = parsed {
                Text("fehler: \(String(describing: e))").font(Theme.mono(11)).foregroundStyle(Theme.state)
            } else if let count {
                Text("\(count) tracks").font(Theme.mono(11)).foregroundStyle(Theme.muted)
            }
            Text("""
            felder: $ARTIST $TITLE $COMMENT $COMMENT2 $LABEL $GENRE $KEY $BPM $COLOR $RATING $PLAYCOUNT $IMPORTDATE $FILEPATH
            operatoren: % enthält · !% enthält nicht · == · != · >= · <= · > · < · STARTS_WITH · & und · | oder · ! nicht · ( )
            beispiel: $COMMENT2 % "BASIS" & $BPM >= 128 & $IMPORTDATE >= MONTHS_AGO(6)
            """).font(Theme.mono(10)).foregroundStyle(Theme.muted)
            HStack {
                Spacer()
                DeckButton(title: "ABBRECHEN") { dismiss() }
                DeckButton(title: "SPEICHERN", active: true) { onSave(smartlist); dismiss() }
            }
        }
        .padding(16)
        .frame(width: 560)
        .background(Theme.chitin)
    }
}

/// History-Ansicht: Startzeit, Deck, Dauer.
struct HistoryTable: View {
    @Environment(LibraryStore.self) private var store
    @Environment(MixModel.self) private var mix
    let entries: [HistoryEntry]
    @Bindable var model: BrowserPaneModel
    @State private var selection: Set<Int> = []

    struct Row: Identifiable {
        let id: Int
        let e: HistoryEntry
    }

    var body: some View {
        let rows = entries.enumerated().map { Row(id: $0.offset, e: $0.element) }
        Table(rows, selection: $selection) {
            TableColumn("#") { (r: Row) in Text("\(r.id + 1)") }.width(28)
            TableColumn("Start") { (r: Row) in Text(Theme.timeFormat.string(from: r.e.start)) }.width(64)
            TableColumn("Deck") { (r: Row) in Text(deckLetters[max(0, min(3, r.e.deck))]) }.width(36)
            TableColumn("Artist") { (r: Row) in Text(r.e.artist) }
            TableColumn("Title") { (r: Row) in Text(r.e.title) }
            TableColumn("BPM") { (r: Row) in Text(r.e.bpm > 0 ? String(format: "%.1f", r.e.bpm) : "") }.width(48)
            TableColumn("Key") { (r: Row) in Text(r.e.keyText) }.width(36)
            TableColumn("Dauer") { (r: Row) in Text(Theme.time(r.e.duration)) }.width(48)
        }
        .font(Theme.mono(11))
        .scrollContentBackground(.hidden)
        .background(Theme.void)
        .contextMenu(forSelectionType: Int.self) { ids in
            ForEach(0..<4, id: \.self) { n in
                Button("In Deck \(deckLetters[n]) laden") { load(ids, n) }
            }
            Button("An Preparation anhängen") {
                for i in ids.sorted() where i < entries.count && !store.preparation.contains(entries[i].key) {
                    store.preparation.append(entries[i].key)
                }
            }
        } primaryAction: { ids in load(ids, mix.focusedDeck) }
    }

    private func load(_ ids: Set<Int>, _ d: Int) {
        guard let i = ids.first, i < entries.count, let t = store.byKey[entries[i].key] else { return }
        mix.load(t, deck: d)
    }
}

struct TrackTable: View {
    @Environment(LibraryStore.self) private var store
    @Environment(BrowserState.self) private var browser
    @Environment(MixModel.self) private var decks
    @Environment(HistoryStore.self) private var history
    let rows: [Track]
    @Bindable var model: BrowserPaneModel
    @State private var columns = TableColumnCustomization<Track>()
    @State private var inlineCtl = InlineEditController()
    @State private var rowBand = PreviewRowController()
    /// Vorschau „ganze Zeile“: Zellen zweizeilig, Inhalt oben
    private var twoLine: Bool { decks.prefs.ui.previewMode == .fullRow }
    private var previewText: Double { decks.prefs.ui.previewTextSize }

    /// Zelle: im Inline-Modus ein Eingabefeld, sonst die normale Anzeige
    @ViewBuilder private func cell(_ t: Track, _ f: TrackField, @ViewBuilder _ display: () -> some View) -> some View {
        if let e = model.inline, e.key == t.key, e.field == f {
            InlineEditor(model: model, edit: e) { commit, move in inlineCtl.finish(e, commit: commit, move: move) }
        } else {
            display()
        }
    }

    private func text(_ t: Track, _ f: TrackField) -> some View { cell(t, f) { Text(f.value(of: t)) } }

    /// gespeicherte Spaltenreihenfolge: neue Spalten (z. B. „played“) vorne einsetzen statt hinten anhängen
    private static func withNewColumnsFirst(_ data: Data) -> Data {
        guard var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var order = obj["columnOrder"] as? [Any] else { return data }
        let id = { (e: Any) in ((e as? [String: Any])?["base"] as? [String: Any]).flatMap { ($0["explicit"] as? [String: Any])?["_0"] as? String } }
        let ids = order.compactMap(id)
        guard !ids.contains("played") || !ids.contains("cover") || !ids.contains("cloud") else { return data }
        if !ids.contains("played") { order.insert(["base": ["explicit": ["_0": "played"]]], at: 0) }
        // Cloud-Spalte hinter „played“
        if !ids.contains("cloud") {
            let at = order.firstIndex { id($0) == "played" }.map { $0 + 1 } ?? 0
            order.insert(["base": ["explicit": ["_0": "cloud"]]], at: at)
        }
        // Cover-Spalte neben die Farbe statt ans Ende
        if !ids.contains("cover") {
            order.insert(["base": ["explicit": ["_0": "cover"]]], at: order.firstIndex { id($0) == "color" }.map { $0 + 1 } ?? min(3, order.count))
        }
        obj["columnOrder"] = order
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? data
    }

    @TableColumnBuilder<Track, KeyPathComparator<Track>>
    private var cols0: some TableColumnContent<Track, KeyPathComparator<Track>> {
        TableColumn("▶") { (t: Track) in Text(history.played.contains(t.key) ? "✓" : "").foregroundStyle(Theme.secondary).modifier(PreviewRowCell(on: twoLine, textSize: previewText)) }
            .width(16).customizationID("played")
        TableColumn(Text(verbatim: "☁").font(.system(size: 13))) { (t: Track) in CloudCell(path: t.path).modifier(PreviewRowCell(on: twoLine, textSize: previewText)) }
            .width(16).customizationID("cloud")
        TableColumn("✓", value: \Track.analyzedSort) { (t: Track) in Text(t.analyzed ? "✓" : "").foregroundStyle(Theme.muted).modifier(PreviewRowCell(on: twoLine, textSize: previewText)) }
            .width(16).customizationID("analyzed")
        TableColumn("", value: \Track.color) { (t: Track) in Theme.trackColor(t.color).frame(width: 4).modifier(PreviewRowCell(on: twoLine, textSize: previewText)) }
            .width(6).customizationID("color")
        TableColumn("Cover") { (t: Track) in CoverThumb(path: t.path).modifier(PreviewRowCell(on: twoLine, textSize: previewText)) }
            .width(min: 22, ideal: 44).customizationID("cover").defaultVisibility(.hidden)
        TableColumn("Artist", value: \Track.artist) { (t: Track) in
                cell(t, .artist) { Text(t.artist).foregroundStyle(t.loose ? Theme.muted : t.fileExists ? Theme.bone : Theme.state) }.modifier(PreviewRowCell(on: twoLine, textSize: previewText))
            }
            .width(min: 80, ideal: 150).customizationID("artist")
    }

    @TableColumnBuilder<Track, KeyPathComparator<Track>>
    private var cols1: some TableColumnContent<Track, KeyPathComparator<Track>> {
        TableColumn("Title", value: \Track.title) { (t: Track) in
                cell(t, .title) { Text(t.title).foregroundStyle(t.loose ? Theme.muted : Theme.bone) }.modifier(PreviewBehindTitle(mix: decks, track: t)).modifier(PreviewRowCell(on: twoLine, textSize: previewText))
            }
            .width(min: 80, ideal: 200).customizationID("title")
        // Mini-Übersicht (Wellenform, Phrasen, Cues) – ⌘, → Anzeige → Browser-Vorschau
        TableColumn("Preview") { (t: Track) in TrackPreviewCell(mix: decks, track: t).modifier(PreviewRowCell(on: twoLine, textSize: previewText)) }
            .width(min: 60, ideal: 150, max: 400).customizationID("preview")
        TableColumn("Remixer", value: \Track.remixer) { (t: Track) in text(t, .remixer).modifier(PreviewRowCell(on: twoLine, textSize: previewText)) }
            .width(min: 60, ideal: 110).customizationID("remixer").defaultVisibility(.hidden)
        TableColumn("Producer", value: \Track.producer) { (t: Track) in text(t, .producer).modifier(PreviewRowCell(on: twoLine, textSize: previewText)) }
            .width(min: 60, ideal: 110).customizationID("producer").defaultVisibility(.hidden)
    }

    @TableColumnBuilder<Track, KeyPathComparator<Track>>
    private var cols2: some TableColumnContent<Track, KeyPathComparator<Track>> {
        TableColumn("Release", value: \Track.album) { (t: Track) in text(t, .album).modifier(PreviewRowCell(on: twoLine, textSize: previewText)) }
            .width(min: 60, ideal: 130).customizationID("release").defaultVisibility(.hidden)
        TableColumn("Track #", value: \Track.trackNumber) { (t: Track) in text(t, .trackNumber).modifier(PreviewRowCell(on: twoLine, textSize: previewText)) }
            .width(40).customizationID("trackno").defaultVisibility(.hidden)
        TableColumn("BPM", value: \Track.bpm) { (t: Track) in
                cell(t, .bpm) { Text(t.bpm > 0 ? String(format: "%.2f", t.bpm) : "").monospacedDigit() }.modifier(PreviewRowCell(on: twoLine, textSize: previewText))
            }
            .width(56).customizationID("bpm")
    }

    @TableColumnBuilder<Track, KeyPathComparator<Track>>
    private var cols3: some TableColumnContent<Track, KeyPathComparator<Track>> {
        TableColumn("Key", value: \Track.openKey) { (t: Track) in Text(t.openKey).modifier(PreviewRowCell(on: twoLine, textSize: previewText)) }
            .width(36).customizationID("key")
        TableColumn("Key Text", value: \Track.keyText) { (t: Track) in text(t, .keyText).modifier(PreviewRowCell(on: twoLine, textSize: previewText)) }
            .width(40).customizationID("keytext").defaultVisibility(.hidden)
        TableColumn("Time", value: \Track.duration) { (t: Track) in Text(Theme.time(t.duration)).monospacedDigit().modifier(PreviewRowCell(on: twoLine, textSize: previewText)) }
            .width(44).customizationID("time")
    }

    @TableColumnBuilder<Track, KeyPathComparator<Track>>
    private var cols4: some TableColumnContent<Track, KeyPathComparator<Track>> {
        TableColumn("Gain", value: \Track.gainSort) { (t: Track) in Text(t.perceivedDb.map { String(format: "%+.1f", $0) } ?? "").monospacedDigit().modifier(PreviewRowCell(on: twoLine, textSize: previewText)) }
            .width(42).customizationID("gain").defaultVisibility(.hidden)
        TableColumn("Rating", value: \Track.rating) { (t: Track) in
                cell(t, .rating) { Text(String(repeating: "★", count: max(0, min(5, t.rating)))) }.modifier(PreviewRowCell(on: twoLine, textSize: previewText))
            }
            .width(56).customizationID("rating").defaultVisibility(.hidden)
        TableColumn("Comment", value: \Track.comment) { (t: Track) in text(t, .comment).modifier(PreviewRowCell(on: twoLine, textSize: previewText)) }
            .width(min: 80, ideal: 170).customizationID("comment")
    }

    @TableColumnBuilder<Track, KeyPathComparator<Track>>
    private var cols5: some TableColumnContent<Track, KeyPathComparator<Track>> {
        TableColumn("Comment 2", value: \Track.comment2) { (t: Track) in
                cell(t, .comment2) { TagChips(tags: BrowserPaneModel.tags(of: t, separators: decks.prefs.ui.tagSeparators), ui: decks.prefs.ui) }.modifier(PreviewRowCell(on: twoLine, textSize: previewText))
            }
            .width(min: 80, ideal: 260).customizationID("comment2")
        TableColumn("Label", value: \Track.label) { (t: Track) in text(t, .label).modifier(PreviewRowCell(on: twoLine, textSize: previewText)) }
            .width(min: 60, ideal: 110).customizationID("label")
        TableColumn("Catalog No", value: \Track.catalogNo) { (t: Track) in text(t, .catalogNo).modifier(PreviewRowCell(on: twoLine, textSize: previewText)) }
            .width(min: 50, ideal: 90).customizationID("catalog").defaultVisibility(.hidden)
    }

    @TableColumnBuilder<Track, KeyPathComparator<Track>>
    private var cols6: some TableColumnContent<Track, KeyPathComparator<Track>> {
        TableColumn("Genre", value: \Track.genre) { (t: Track) in text(t, .genre).modifier(PreviewRowCell(on: twoLine, textSize: previewText)) }
            .width(min: 50, ideal: 100).customizationID("genre").defaultVisibility(.hidden)
        TableColumn("Plays", value: \Track.playCount) { (t: Track) in Text(t.playsText).modifier(PreviewRowCell(on: twoLine, textSize: previewText)) }
            .width(38).customizationID("plays")
        TableColumn("Last Played", value: \Track.lastPlayedSort) { (t: Track) in Text(Track.dateText(t.lastPlayed)).modifier(PreviewRowCell(on: twoLine, textSize: previewText)) }
            .width(74).customizationID("lastplayed").defaultVisibility(.hidden)
    }

    @TableColumnBuilder<Track, KeyPathComparator<Track>>
    private var cols7: some TableColumnContent<Track, KeyPathComparator<Track>> {
        TableColumn("Import", value: \Track.importSort) { (t: Track) in Text(t.importText).modifier(PreviewRowCell(on: twoLine, textSize: previewText)) }
            .width(74).customizationID("import")
        TableColumn("Release Date", value: \Track.releaseSort) { (t: Track) in text(t, .releaseDate).modifier(PreviewRowCell(on: twoLine, textSize: previewText)) }
            .width(74).customizationID("releasedate").defaultVisibility(.hidden)
        TableColumn("Bitrate", value: \Track.bitrate) { (t: Track) in Text(t.bitrate > 0 ? "\(t.bitrate)" : "").modifier(PreviewRowCell(on: twoLine, textSize: previewText)) }
            .width(44).customizationID("bitrate").defaultVisibility(.hidden)
    }

    @TableColumnBuilder<Track, KeyPathComparator<Track>>
    private var cols8: some TableColumnContent<Track, KeyPathComparator<Track>> {
        TableColumn("File Name", value: \Track.fileName) { (t: Track) in Text(t.fileName).modifier(PreviewRowCell(on: twoLine, textSize: previewText)) }
            .width(min: 80, ideal: 220).customizationID("file").defaultVisibility(.hidden)
        TableColumn("Mix", value: \Track.mix) { (t: Track) in text(t, .mix).modifier(PreviewRowCell(on: twoLine, textSize: previewText)) }
            .width(min: 60, ideal: 110).customizationID("mix").defaultVisibility(.hidden)
    }

    var body: some View {
        ScrollViewReader { proxy in
        Table(rows, selection: $model.selection, sortOrder: $model.sortOrder, columnCustomization: $columns) {
            cols0
            cols1
            cols2
            cols3
            cols4
            cols5
            cols6
            cols7
            cols8
        }
        .onAppear {
            if let d = UserDefaults.standard.data(forKey: "columns.\(model.name)"),
               let c = try? JSONDecoder().decode(TableColumnCustomization<Track>.self, from: Self.withNewColumnsFirst(PreviewColumn.placed(d))) { columns = c }
            columns[visibility: "preview"] = decks.prefs.ui.previewMode == .column ? .visible : .hidden
        }
        .onChange(of: decks.prefs.ui.previewMode) { _, m in columns[visibility: "preview"] = m == .column ? .visible : .hidden }
        .onChange(of: columns) {
            if let d = try? JSONEncoder().encode(columns) { UserDefaults.standard.set(d, forKey: "columns.\(model.name)") }
        }
        .font(twoLine ? Theme.mono(decks.prefs.ui.previewTextSize, decks.prefs.ui.previewTextBold ? .semibold : .regular) : Theme.mono(11))
        .scrollContentBackground(.hidden)
        .background(Theme.void)
        .background(TableViewFinder(controller: inlineCtl))
        .background(PreviewRowLayer(controller: rowBand, rows: rows, mix: decks, on: twoLine))
        .onAppear {
            inlineCtl.model = model
            inlineCtl.store = store
            inlineCtl.rows = { [model, store, history, decks] in
                model.rows(from: store, history: history, separators: decks.prefs.ui.tagSeparators)
            }
            inlineCtl.writeBack = { [decks] in decks.prefs.ui.writeCollection }
            inlineCtl.install()
            rowBand.inline = inlineCtl
        }
        .onDisappear { inlineCtl.uninstall(); rowBand.remove() }
        .contextMenu(forSelectionType: Track.ID.self) { ids in
            ForEach(0..<4, id: \.self) { n in
                Button("In Deck \(["A", "B", "C", "D"][n]) laden") { load(ids, n) }
            }
            Divider()
            Button("Bearbeiten …") { model.openEditor(ids, rows: rows, store: store) }
                .keyboardShortcut("e", modifiers: .command)
            if store.hasEdits(ids) {
                Button("Eigene Änderungen verwerfen") { store.revertEdits(Array(ids)) }
            }
            Divider()
            Button("An Preparation anhängen") { store.preparation.append(contentsOf: ids.filter { !store.preparation.contains($0) }) }
            if case .preparation = model.source {
                Button("Aus Preparation entfernen") { store.preparation.removeAll { ids.contains($0) } }
            }
            Divider()
            CloudMenuButton(label: String(localized: "Auswahl")) { ids.compactMap { store.track($0) } }
            Button("Vorhören") { if let id = ids.first, let t = store.track(id) { decks.preview(t) } }
            Button("Im Finder zeigen") {
                let urls = ids.compactMap { store.track($0) }.map { URL(fileURLWithPath: $0.path) }
                NSWorkspace.shared.activateFileViewerSelecting(urls)
            }
            Divider()
            Button("Reset Played State") { history.resetPlayed() }
        } primaryAction: { ids in
            // Return = Inline-Bearbeitung der gewählten Zeile, Doppelklick = ins Fokus-Deck laden
            if NSApp.currentEvent?.type == .keyDown { inlineCtl.beginFromKeyboard(ids) } else { load(ids, decks.focusedDeck) }
        }
        .onChange(of: model.selection) { browser.activePaneID = model.id }
        .onChange(of: browser.scrollRequest?.track) {
            if let r = browser.scrollRequest, r.pane == model.id { proxy.scrollTo(r.track) }
        }
        }
    }

    private func load(_ ids: Set<Track.ID>, _ deck: Int) {
        guard let id = ids.first, let t = store.track(id) else { return }
        decks.load(t, deck: deck)
    }
}
