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
        return store.tracks(for: source)
    }

    @ObservationIgnored private var cacheKey: [AnyHashable] = []
    @ObservationIgnored private var cachedRows: [Track] = []

    /// Gefilterte + sortierte Liste – zwischengespeichert, Neuberechnung nur wenn sich etwas ändert
    /// (14k Tracks lokalisiert zu sortieren dauert ~100 ms → bei jedem Encoder-Schritt hing sonst die Oberfläche).
    func rows(from store: LibraryStore, history: HistoryStore?, separators: String) -> [Track] {
        let key: [AnyHashable] = [source, search, roles, tags, "\(sortOrder)", store.revision, separators]
        if key == cacheKey { return cachedRows }
        let r = computeRows(from: store, history: history, separators: separators)
        cacheKey = key
        cachedRows = r
        return r
    }

    private func computeRows(from store: LibraryStore, history: HistoryStore?, separators: String) -> [Track] {
        var list = base(from: store, history: history)
        if !roles.isEmpty {
            list = list.filter { t in roles.contains { t.comment2.localizedCaseInsensitiveContains("» " + $0.rawValue) } }
        }
        if !tags.isEmpty {
            list = list.filter { t in tags.isSubset(of: Set(Self.tags(of: t, separators: separators))) }
        }
        let words = search.split(separator: " ").map(String.init)
        if !words.isEmpty {
            list = list.filter { t in
                let hay = [t.artist, t.title, t.comment, t.comment2, t.label, t.genre, t.album, t.openKey].joined(separator: " ")
                return words.allSatisfy { hay.localizedCaseInsensitiveContains($0) }
            }
        }
        return list.sorted(using: sortOrder)
    }
}

struct BrowserPane: View {
    @Environment(LibraryStore.self) private var store
    @Environment(HistoryStore.self) private var history
    @Environment(MixModel.self) private var decks
    @Bindable var model: BrowserPaneModel
    @State private var showTags = false

    var body: some View {
        let seps = decks.prefs.ui.tagSeparators
        let rows = model.source.isHistory ? [] : model.rows(from: store, history: history, separators: seps)
        HSplitView {
            if model.showTree {
                SourceTree(selection: $model.source)
                    .frame(minWidth: 170, idealWidth: 210, maxWidth: 320)
            }
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
                                Text(k).foregroundStyle(Theme.bone)
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
            if !model.tags.isEmpty { DeckButton(title: "ALLE TAGS LÖSEN") { model.tags.removeAll() } }
        }
        .padding(10)
        .frame(width: 320)
        .background(Theme.chitin)
    }
}

/// Baum wie in Traktor: Collection, Preparation (+ Archiv), History (+ Archiv), eigene Smartlists, Playlists.
struct SourceTree: View {
    @Environment(LibraryStore.self) private var store
    @Environment(HistoryStore.self) private var history
    @Binding var selection: BrowserSource
    @State private var editing: CustomSmartlist?

    var body: some View {
        List(selection: Binding<BrowserSource?>(get: { selection }, set: { if let s = $0 { selection = s } })) {
            row("≣", "TRACK COLLECTION").tag(BrowserSource.collection)
            row("▤", "PREPARATION").tag(BrowserSource.preparation)
            DisclosureGroup {
                ForEach(history.prepArchive) { s in
                    row("▤", Theme.dateTimeFormat.string(from: s.date)).tag(BrowserSource.prepArchive(s))
                }
            } label: { row("▸", "PREPARATION ARCHIV") }
            row("◷", "HISTORY").tag(BrowserSource.historyLive)
            DisclosureGroup {
                ForEach(history.archive) { s in
                    row(s.source == .traktor ? "◷" : "◴", Theme.dateTimeFormat.string(from: s.date)).tag(BrowserSource.history(s))
                }
            } label: { row("▸", "HISTORY ARCHIV") }
            DisclosureGroup {
                ForEach(store.customSmartlists) { sl in
                    row("◆", sl.name).tag(BrowserSource.custom(sl))
                        .contextMenu {
                            Button("Bearbeiten …") { editing = sl }
                            Button("Löschen") { store.customSmartlists.removeAll { $0.id == sl.id } }
                        }
                }
                Button { editing = CustomSmartlist(name: "Neue Smartlist", query: "$COMMENT2 % \"BASIS\"") } label: {
                    row("+", "NEUE SMARTLIST")
                }
                .buttonStyle(.plain)
            } label: { row("▸", "SMARTLISTS 741") }
            Section {
                OutlineGroup(store.root.children, children: \.childrenOrNil) { node in
                    row(icon(node), node.name)
                        .tag(BrowserSource.node(node))
                        .lineLimit(1)
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

/// Smartlist anlegen/bearbeiten: Regel im Traktor-Syntax, Live-Anzahl und Fehleranzeige.
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

/// History-Ansicht wie Traktor: Startzeit, Deck, Dauer.
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
    let rows: [Track]
    @Bindable var model: BrowserPaneModel

    var body: some View {
        ScrollViewReader { proxy in
        Table(rows, selection: $model.selection, sortOrder: $model.sortOrder) {
          Group {
            TableColumn("", value: \Track.color) { (t: Track) in Theme.trackColor(t.color).frame(width: 4) }
                .width(6)
            TableColumn("Artist", value: \Track.artist) { (t: Track) in Text(t.artist).foregroundStyle(t.fileExists ? Theme.bone : Theme.state) }
                .width(min: 80, ideal: 150)
            TableColumn("Title", value: \Track.title)
                .width(min: 80, ideal: 200)
            TableColumn("BPM", value: \Track.bpm) { (t: Track) in Text(t.bpm > 0 ? String(format: "%.2f", t.bpm) : "").monospacedDigit() }
                .width(56)
            TableColumn("Key", value: \Track.openKey) { (t: Track) in Text(t.openKey) }
                .width(36)
            TableColumn("Time", value: \Track.duration) { (t: Track) in Text(Theme.time(t.duration)).monospacedDigit() }
                .width(44)
          }
          Group {
            TableColumn("Comment", value: \Track.comment)
                .width(min: 80, ideal: 170)
            TableColumn("Comment 2", value: \Track.comment2)
                .width(min: 80, ideal: 230)
            TableColumn("Label", value: \Track.label)
                .width(min: 60, ideal: 110)
          }
          Group {
            TableColumn("Import", value: \Track.importSort) { (t: Track) in Text(t.importText) }
                .width(74)
            TableColumn("Plays", value: \Track.playCount) { (t: Track) in Text(t.playsText) }
                .width(38)
          }
        }
        .font(Theme.mono(11))
        .scrollContentBackground(.hidden)
        .background(Theme.void)
        .contextMenu(forSelectionType: Track.ID.self) { ids in
            ForEach(0..<4, id: \.self) { n in
                Button("In Deck \(["A", "B", "C", "D"][n]) laden") { load(ids, n) }
            }
            Divider()
            Button("An Preparation anhängen") { store.preparation.append(contentsOf: ids.filter { !store.preparation.contains($0) }) }
            if case .preparation = model.source {
                Button("Aus Preparation entfernen") { store.preparation.removeAll { ids.contains($0) } }
            }
            Divider()
            Button("Vorhören") { if let id = ids.first, let t = store.byKey[id] { decks.preview(t) } }
            Button("Im Finder zeigen") {
                let urls = ids.compactMap { store.byKey[$0] }.map { URL(fileURLWithPath: $0.path) }
                NSWorkspace.shared.activateFileViewerSelecting(urls)
            }
        } primaryAction: { ids in
            load(ids, decks.focusedDeck)
        }
        .onChange(of: model.selection) { browser.activePaneID = model.id }
        .onChange(of: browser.scrollRequest?.track) {
            if let r = browser.scrollRequest, r.pane == model.id { proxy.scrollTo(r.track) }
        }
        }
    }

    private func load(_ ids: Set<Track.ID>, _ deck: Int) {
        guard let id = ids.first, let t = store.byKey[id] else { return }
        decks.load(t, deck: deck)
    }
}
