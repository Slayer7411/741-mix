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
    /// ausgeschlossene Tags (⌥-Klick): keiner darf vorkommen
    var excludedTags: Set<String> = []
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
    /// Favoritenleiste (6 Plätze, BrowserFavorites.swift)
    var favorites: [BrowserFavorite?] = BrowserFavorite.normalized(nil)

    init(name: String, source: BrowserSource = .collection) {
        self.name = name
        self.source = source
    }

    /// Tags eines Tracks: Kommentar 2 an den eingestellten Trennzeichen zerlegt (einmal je Text, dann aus dem Speicher)
    static func tags(of t: Track, separators: String) -> [String] { tagIndex.entry(t.comment2, separators: separators).tags }
    static let tagIndex = TagIndex()

    @ObservationIgnored private var filterMemo = TagFilter()
    /// Tag-Filter aus `tags` + `excludedTags` (Vergleichsformen gemerkt)
    var tagFilter: TagFilter {
        let inc = tags, exc = excludedTags
        if filterMemo.include != inc || filterMemo.exclude != exc { filterMemo = TagFilter(include: inc, exclude: exc) }
        return filterMemo
    }

    /// Klick auf einen Tag: einschließen/lösen, ⌥ (`exclude`): ausschließen/lösen
    func toggleTag(_ tag: String, exclude: Bool) { setTagFilter(tagFilter.toggling(tag, exclude: exclude)) }
    func removeTag(_ tag: String) { setTagFilter(tagFilter.removing(tag)) }
    func clearTags() { tags = []; excludedTags = [] }
    private func setTagFilter(_ f: TagFilter) {
        if tags != f.include { tags = f.include }
        if excludedTags != f.exclude { excludedTags = f.exclude }
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
    /// Neuaufbau-Zähler: neu, wenn sich die Zeilen stark ändern (Quelle, Sortierung, Filter, Suche) – die Tabelle
    /// springt dann zur Auswahl bzw. nach oben, kleine Änderungen (neue Werte, ein paar Tracks) behalten die Position
    @ObservationIgnored private(set) var tableGeneration = 0
    /// Hintergrund-Liste fertig (beobachtet nur von der Anzahl im Kopf; die Tabelle bekommt sie über `onList`,
    /// ohne SwiftUI-Durchlauf)
    private(set) var listRevision = 0
    @ObservationIgnored var onList: (() -> Void)?
    /// laufende Hintergrund-Liste: Schlüssel + Nummer (ältere Ergebnisse verfallen)
    @ObservationIgnored private var jobKey: [AnyHashable] = []
    @ObservationIgnored private var jobSerial = 0

    /// zuletzt angezeigte Liste (Tabelle, Browse-Encoder) – nie neu sortiert
    var shown: [Track] { cachedRows }

    private func keys(_ store: LibraryStore, _ separators: String) -> (base: [AnyHashable], all: [AnyHashable]) {
        let base: [AnyHashable] = [source, "\(sortOrder)", store.revision, store.sourceRevision(source, subfolders: subfolders), subfolders]
        return (base, base + [search, roles, tags, excludedTags, separators, localOnly, localOnly ? CloudLibrary.shared.revision : 0] as [AnyHashable])
    }

    /// Gefilterte + sortierte Liste, sofort (Selbsttest, Messung). Die Quelle wird einmal sortiert (14k Tracks ≈ 80 ms,
    /// TrackSort) und bei Suche, Tags und Rollen nur noch gefiltert.
    func rows(from store: LibraryStore, history: HistoryStore?, separators: String) -> [Track] {
        let (baseKey, key) = keys(store, separators)
        if baseKey != sortedKey {
            // nach dem Laden liegt die Liste meist schon sortiert vor (im Hintergrund, siehe LibraryStore.load)
            Self.dropLater(sortedBase)
            sortedBase = store.presorted(source, order: sortOrder) ?? TrackSort.sorted(base(from: store, history: history), using: sortOrder)
            sortedKey = baseKey
        }
        if key == cacheKey { return cachedRows }
        let list = Self.filtered(sortedBase, criteria(separators), index: Self.tagIndex)
        apply(localOnly ? Self.local(list) : list, key: key)
        return cachedRows
    }

    /// Liste für die Tabelle: Sortieren und Filtern im Hintergrund (Collection sortieren ~80 ms, Rollen filtern
    /// ~18 ms), bis dahin bleibt die angezeigte Liste stehen. Auch kleine Listen: die neue Liste kommt so in einem
    /// eigenen Durchlauf an, nicht zusammen mit Kopf, Baum und Favoriten (je Durchlauf < 1 Bild). Nur die erste sofort
    func list(from store: LibraryStore, history: HistoryStore?, separators: String) -> [Track] {
        let (baseKey, key) = keys(store, separators)
        if key == cacheKey || key == jobKey { return cachedRows }
        if baseKey != sortedKey, let pre = store.presorted(source, order: sortOrder) {
            Self.dropLater(sortedBase)
            sortedBase = pre
            sortedKey = baseKey
        }
        if cacheKey.isEmpty { return rows(from: store, history: history, separators: separators) }
        let sorted = baseKey == sortedKey
        let base = sorted ? sortedBase : self.base(from: store, history: history)
        jobSerial += 1
        jobKey = key
        let serial = jobSerial
        let job = ListJob(base: base, order: sorted ? nil : sortOrder, criteria: criteria(separators))
        Task.detached(priority: .userInitiated) {
            let done = job.run()
            await MainActor.run { self.deliver(done, serial: serial, baseKey: baseKey, key: key) }
        }
        return cachedRows
    }

    /// neue Liste unterwegs (die Tabelle zeichnet für geänderte Tag-Markierungen erst mit ihr neu)
    var listPending: Bool { !jobKey.isEmpty }

    private func deliver(_ job: ListJob, serial: Int, baseKey: [AnyHashable], key: [AnyHashable]) {
        // verworfene Ergebnisse nicht hier freigeben
        defer { Self.dropLater(job.rows); if job.order != nil { Self.dropLater(job.base) } }
        guard serial == jobSerial else { return }
        jobKey = []
        guard key != cacheKey else { return }
        if job.order != nil {
            Self.dropLater(sortedBase)
            sortedBase = job.base
            sortedKey = baseKey
        }
        apply(localOnly ? Self.local(job.rows) : job.rows, key: key)
    }

    @ObservationIgnored private var notifyPending = false

    /// neue Liste: Tabelle (`onList`) und Anzahl im Kopf (`listRevision`) danach, nie während einer Auswertung
    private func apply(_ rows: [Track], key: [AnyHashable]) {
        if !ListChange.isSmall(from: cachedRows, to: rows, limit: 64) { tableGeneration += 1 }
        Self.dropLater(cachedRows)
        cachedRows = rows
        cacheKey = key
        guard !notifyPending else { return }
        notifyPending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.notifyPending = false
                self.listRevision += 1
                self.onList?()
            }
        }
    }

    /// alte Listen nicht auf dem Hauptthread freigeben (6k Tracks: ~3 ms). Verzögert, damit die Tabelle ihre
    /// Kopie vorher losgelassen hat und die letzte Referenz im Hintergrund fällt
    nonisolated static func dropLater(_ old: [Track]) {
        guard old.count > 500 else { return }
        let box = ListJob(base: old, order: nil, criteria: Criteria())
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 1) { _ = box }
    }

    /// Bearbeiten-Fenster für die gewählten Tracks (Reihenfolge der Liste); ein Track -> PREV/NEXT durch die Liste
    func openEditor(_ ids: Set<Track.ID>, rows: [Track], store: LibraryStore) {
        let keys = rows.map(\.key)
        var sel = keys.filter { ids.contains($0) }
        if sel.isEmpty { sel = ids.sorted() }
        guard !sel.isEmpty, inline == nil else { return }
        editSession = TrackEditSession(selection: sel, list: keys, store: store)
    }

    /// Filter ohne Hauptthread-Zustand (Rollen, Tags, Suche); „nur lokal“ danach auf dem Hauptthread (`local`)
    struct Criteria: @unchecked Sendable {
        var roles: Set<RoleFilter> = []
        var tags = TagFilter()
        var words: [[UInt8]] = []
        var separators = ""
        var isEmpty: Bool { roles.isEmpty && tags.isEmpty && words.isEmpty }
    }

    private func criteria(_ separators: String) -> Criteria {
        Criteria(roles: roles, tags: tagFilter, words: search.split(separator: " ").map { Track.fold(String($0)) }, separators: separators)
    }

    /// Sortieren (falls `order`) und Filtern im Hintergrund, eigener Tag-Index (der geteilte gehört dem Hauptthread)
    final class ListJob: @unchecked Sendable {
        private(set) var base: [Track]
        let order: [KeyPathComparator<Track>]?
        let criteria: Criteria
        private(set) var rows: [Track] = []
        init(base: [Track], order: [KeyPathComparator<Track>]?, criteria: Criteria) {
            self.base = base
            self.order = order
            self.criteria = criteria
        }
        func run() -> ListJob {
            if let order { base = TrackSort.sorted(base, using: order) }
            rows = BrowserPaneModel.filtered(base, criteria, index: TagIndex())
            return self
        }
    }

    nonisolated static func filtered(_ base: [Track], _ c: Criteria, index: TagIndex) -> [Track] {
        var list = base
        if !c.roles.isEmpty {
            let needles = c.roles.map { "» " + $0.rawValue }
            list = list.filter { t in needles.contains { t.comment2.localizedCaseInsensitiveContains($0) } }
        }
        if !c.tags.isEmpty {
            list = list.filter { c.tags.matches(keys: index.entry($0.comment2, separators: c.separators).keys) }
        }
        if !c.words.isEmpty { list = list.filter { $0.matches(words: c.words) } }
        return list
    }

    private static func local(_ list: [Track]) -> [Track] {
        let c = CloudLibrary.shared
        return list.filter { c.isLocal($0.path) }
    }
}

struct BrowserPane: View {
    @Environment(LibraryStore.self) private var store
    @Environment(HistoryStore.self) private var history
    @Environment(MixModel.self) private var decks
    @Bindable var model: BrowserPaneModel
    @Environment(BrowserState.self) private var browserState

    var body: some View {
        // Zeilen liest nur die Tabelle (TrackTable) und die Anzahl im Kopf: eine neue Liste aus dem Hintergrund wertet
        // nicht den ganzen Bereich neu aus (Favoriten, Baum, Kopf)
        // Baum bleibt im Split, ausgeblendet = Breite 0 (nur der 1-pt-Trenner bleibt): Entfernen/Einsetzen des
        // Split-Elements hängte jede Zeile aus dem Fenster aus und wieder ein (~850 ms beim Umschalten Browser groß ⇄ Decks)
        let tree = model.showTree && !(decks.prefs.ui.hideTreeWithDecks && !browserState.maximized)
        VStack(spacing: 0) {
        FavoritesBar(model: model, keys: decks.prefs.keys)
        HSplitView {
            SourceTree(selection: $model.source)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if tree && decks.prefs.ui.showCoverPreview { CoverPreview(model: model) }   // Cover des gewählten Tracks
                }
                .frame(minWidth: tree ? 170.z : 0, idealWidth: tree ? 210.z : 0, maxWidth: tree ? 320.z : 0)
            VStack(spacing: 0) {
                PaneHeader(model: model)
                if model.source.isHistory {
                    HistoryTable(entries: Self.historyEntries(model.source, history), model: model)
                } else {
                    TrackTable(model: model)
                }
            }
            .frame(minWidth: 380.z)
        }
        }
        .background {
            // ⌘E: Bearbeiten-Fenster für die Auswahl (nur der zuletzt benutzte Bereich reagiert)
            if browserState.activePane.id == model.id, !model.source.isHistory {
                Button("") { model.openEditor(model.selection, rows: model.shown, store: store) }
                    .keyboardShortcut("e", modifiers: .command)
                    .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
            }
        }
        .sheet(item: $model.editSession) { session in
            TrackEditPanel(session: session) { key in
                model.selection = [key]
                browserState.scrollRequest = (model.id, key)
            }
            .zoomExempt()   // Dialog bleibt bei 100 %
        }
        .onChange(of: decks.prefs.ui.writeCollection) { _, on in if on { store.scheduleWriteBack() } }
    }

    static func historyEntries(_ source: BrowserSource, _ history: HistoryStore) -> [HistoryEntry] {
        switch source {
        case .historyLive: history.live
        case let .history(s): history.entries(s)
        default: []
        }
    }
}

/// Anzahl der Zeilen im Kopf (eigene Ansicht: hängt an der Liste, der Kopf nicht)
struct RowCount: View {
    @Environment(LibraryStore.self) private var store
    @Environment(HistoryStore.self) private var history
    @Environment(MixModel.self) private var decks
    let model: BrowserPaneModel

    var body: some View {
        let _ = model.listRevision
        let n = model.source.isHistory ? BrowserPane.historyEntries(model.source, history).count
            : model.list(from: store, history: history, separators: decks.prefs.ui.tagSeparators).count
        Text("\(n)").font(Theme.mono(11.z)).foregroundStyle(Theme.muted).fixedSize()
    }
}

/// Kopf eines Bereichs: Quelle, Anzahl, Suche, Rollen, Tags, Lokal
struct PaneHeader: View {
    @Environment(MixModel.self) private var decks
    @Bindable var model: BrowserPaneModel
    @State private var showTags = false

    var body: some View {
        let separators = decks.prefs.ui.tagSeparators
        VStack(alignment: .leading, spacing: 4.z) {
            HStack(spacing: 8.z) {
                Button { model.showTree.toggle() } label: { Text("◧").font(Theme.mono(13.z)).foregroundStyle(Theme.bone) }
                    .buttonStyle(.borderless)
                    .help("Baum ein/aus")
                Text(model.source.title.uppercased()).font(Theme.label(13.z, .bold)).lineLimit(1)
                RowCount(model: model)
                if case .folder = model.source {
                    DeckButton(title: "UNTERORDNER", active: model.subfolders) { model.subfolders.toggle() }
                        .help("Dateien aus allen Unterordnern zeigen")
                }
                Spacer(minLength: 8.z)
                SearchField(model: model)
                    .textFieldStyle(.plain)
                    .font(Theme.mono(11.z))
                    .padding(.horizontal, 6.z).padding(.vertical, 3.z)
                    .background(Theme.void)
                    .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
                    .frame(minWidth: 120.z, maxWidth: 220.z)
            }
            HStack(spacing: 4.z) {
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
                // aktiver Tag-Filter: eingeschlossene gefüllt, ausgeschlossene durchgestrichen – Klick löst den Tag
                if !model.tagFilter.isEmpty {
                    if CloudLibrary.shared.hasCloudTracks { Text("│").foregroundStyle(Theme.hairline) }
                    DeckButton(title: "✕ TAGS") { model.clearTags() }
                        .help("Tag-Filter löschen")
                    ScrollView(.horizontal, showsIndicators: false) {
                        TagChips(tags: model.tags.sorted() + model.excludedTags.sorted(), ui: decks.prefs.ui,
                                 filter: model.tagFilter) { t, _ in model.removeTag(t) }
                            .font(Theme.mono(11.z))
                    }
                }
            }
        }
        .padding(.horizontal, 8.z)
        .padding(.vertical, 5.z)
        .background(Theme.panelHeader)
    }
}

/// Suchfeld eines Bereichs: Text sofort im Feld, in die Liste nach 0,15 s Tipp-Pause (leer und ⏎ sofort). Jede neue
/// Suche filtert im Hintergrund und lädt die Tabelle neu (~7 ms Hauptthread) – schnelles Tippen kostet so einen
/// Neuaufbau statt einen je Taste
struct SearchField: View {
    @Bindable var model: BrowserPaneModel
    @State private var text = ""
    @State private var pending: DispatchWorkItem?

    var body: some View {
        TextField("SUCHEN", text: $text)
            .onSubmit { apply(text) }
            .onAppear { text = model.search }
            // von außen gesetzt (Favoriten, Sitzung): ins Feld
            .onChange(of: model.search) { _, s in if s != text { pending?.cancel(); text = s } }
            .onChange(of: text) { _, s in
                pending?.cancel()
                guard s != model.search else { return }
                if s.isEmpty { apply(s); return }
                let w = DispatchWorkItem { MainActor.assumeIsolated { apply(s) } }
                pending = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: w)
            }
    }

    private func apply(_ s: String) {
        pending?.cancel()
        if model.search != s { model.search = s }
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
        let tf = model.tagFilter
        VStack(alignment: .leading, spacing: 6.z) {
            Text("TAGS · KOMMENTAR 2").font(Theme.label(12.z, .bold))
            Text("trennzeichen: '\(separators)' (einstellbar unter ⌘, → anzeige)").font(Theme.mono(10.z)).foregroundStyle(Theme.muted)
            Text("klick = filter · ⌥-klick = ausschließen · auch in der liste").font(Theme.mono(10.z)).foregroundStyle(Theme.muted)
            TextField("FILTERN", text: $filter).textFieldStyle(.plain).font(Theme.mono(11.z))
                .padding(4.z).overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
            ScrollView {
                VStack(alignment: .leading, spacing: 2.z) {
                    ForEach(list, id: \.key) { k, n in
                        let mark = tf.mark(k)
                        Button {
                            model.toggleTag(k, exclude: NSApp.currentEvent?.modifierFlags.contains(.option) == true)
                        } label: {
                            HStack {
                                Text(mark == .include ? "■" : mark == .exclude ? "⊘" : "□")
                                    .foregroundStyle(mark == .none ? Theme.muted : Theme.state)
                                TagChip(tag: k, mark: mark, style: TagChipStyle.of(k, ui))
                                Spacer()
                                Text("\(n)").foregroundStyle(Theme.muted)
                            }
                            .font(Theme.mono(11.z))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 320.z)
            if !tf.isEmpty {
                HStack {
                    DeckButton(title: "✕ TAGS") { model.clearTags() }
                    DeckButton(title: "ALS SMARTLIST") {
                        let inc = model.tags.sorted(), exc = model.excludedTags.sorted()
                        let quote = { (t: String) in "\"\(t.replacingOccurrences(of: "\"", with: ""))\"" }
                        let q = (inc.map { "$COMMENT2 % \(quote($0))" } + exc.map { "$COMMENT2 !% \(quote($0))" }).joined(separator: " & ")
                        store.customSmartlists.append(CustomSmartlist(name: (inc + exc.map { "!" + $0 }).joined(separator: " + "), query: q))
                    }
                    .help("Smartlist aus den gewählten Tags anlegen (alle müssen passen, ausgeschlossene nicht)")
                }
            }
        }
        .padding(10.z)
        .frame(width: 320.z)
        .background(Theme.chitin)
    }
}

/// Baum: Collection, Preparation (+ Archiv), History (+ Archiv), eigene Smartlists, Playlists.
struct SourceTree: View {
    @Environment(LibraryStore.self) private var store
    @Binding var selection: BrowserSource
    @State private var editing: CustomSmartlist?

    // Zeilen in eigenen Ansichten: ein Quellenwechsel wertet nur die Auswahl der Liste neu aus, nicht alle Zeilen
    // (Baum bleibt auch ausgeblendet in der Ansicht, siehe BrowserPane)
    var body: some View {
        List(selection: Binding<BrowserSource?>(get: { selection }, set: { if let s = $0 { selection = s } })) {
            SourceTreeFixed(editing: $editing)
            MusicFolderTree(selection: $selection)
            SourceTreePlaylists()
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
            .zoomExempt()
        }
    }
}

/// Collection, Preparation, History, eigene Smartlists
struct SourceTreeFixed: View, SourceMenus {
    @Environment(LibraryStore.self) var store
    @Environment(HistoryStore.self) var history
    @Binding var editing: CustomSmartlist?

    var body: some View {
        row("≣", "TRACK COLLECTION").tag(BrowserSource.collection)
            .favoriteDrag { BrowserFavorite.source(.collection, store: store) }
            .contextMenu {
                exportMenu(.collection)
                Button("Collection prüfen …") { ConsistencyWindow.show(store: store) }
                Button("Reset Played State") { history.resetPlayed() }
                OverviewMenuButton { store.tracks }
                AnalysisMenuButtons { store.tracks }
                CloudMenuButton(label: "Track Collection") { store.tracks }
            }
        row("▶", "RUNNING TRACKS").tag(BrowserSource.running)
            .favoriteDrag { BrowserFavorite.source(.running, store: store) }
        row("▤", "PREPARATION").tag(BrowserSource.preparation)
            .favoriteDrag { BrowserFavorite.source(.preparation, store: store) }
            .contextMenu {
                exportMenu(.preparation)
                OverviewMenuButton { store.tracks(for: .preparation) }
                AnalysisMenuButtons { store.tracks(for: .preparation) }
                CloudMenuButton(label: "Preparation") { store.tracks(for: .preparation) }
            }
        DisclosureGroup {
            ForEach(history.prepArchive) { s in
                row("▤", Theme.dateTimeFormat.string(from: s.date)).tag(BrowserSource.prepArchive(s))
                    .contextMenu { exportMenu(.prepArchive(s)) }
            }
        } label: { row("▸", String(localized: "PREPARATION ARCHIV")) }
        row("◷", "HISTORY").tag(BrowserSource.historyLive)
            .favoriteDrag { BrowserFavorite.source(.historyLive, store: store) }
            .contextMenu { exportMenu(.historyLive) }
        DisclosureGroup {
            ForEach(history.archive) { s in
                row(s.source == .external ? "◷" : "◴", s.label ?? Theme.dateTimeFormat.string(from: s.date)).tag(BrowserSource.history(s))
                    .contextMenu { exportMenu(.history(s)) }
            }
        } label: { row("▸", String(localized: "HISTORY ARCHIV")) }
        DisclosureGroup {
            ForEach(store.customSmartlists) { sl in
                row("◆", sl.name).tag(BrowserSource.custom(sl))
                    .favoriteDrag { BrowserFavorite.source(.custom(sl), store: store) }
                    .contextMenu {
                        exportMenu(.custom(sl))
                        OverviewMenuButton { store.tracks(for: .custom(sl)) }
                        AnalysisMenuButtons { store.tracks(for: .custom(sl)) }
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
    }
}

/// Playlists und Smartlists der Collection
struct SourceTreePlaylists: View, SourceMenus {
    @Environment(LibraryStore.self) var store
    @Environment(HistoryStore.self) var history

    var body: some View {
        Section {
            OutlineGroup(store.root.children, children: \.childrenOrNil) { node in
                row(icon(node), node.name)
                    .tag(BrowserSource.node(node))
                    .lineLimit(1)
                    .favoriteDrag { BrowserFavorite.source(.node(node), store: store) }
                    .contextMenu {
                        if node.kind != .folder { exportMenu(.node(node)) }
                        OverviewMenuButton { nodeTracks(node) }
                        AnalysisMenuButtons { nodeTracks(node) }
                        CloudMenuButton(label: node.name) { nodeTracks(node) }
                    }
            }
        }
    }
}

/// Zeilen und Kontextmenüs des Baums
@MainActor
protocol SourceMenus {
    var store: LibraryStore { get }
    var history: HistoryStore { get }
}

extension SourceMenus {
    /// Kontextmenü „Exportieren“ für eine Quelle
    @ViewBuilder func exportMenu(_ src: BrowserSource) -> some View {
        Menu("Exportieren") {
            Button("NML …") { export(.nml, src) }
            Button("M3U …") { export(.m3u, src) }
            Button("Ordner mit Audiodateien …") { export(.folder, src) }
        }
    }

    func export(_ f: PlaylistExport.Format, _ src: BrowserSource) {
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
    func nodeTracks(_ n: PlaylistNode) -> [Track] {
        n.kind == .folder ? n.children.flatMap(nodeTracks) : store.tracks(for: .node(n))
    }

    func icon(_ n: PlaylistNode) -> String {
        switch n.kind {
        case .folder: "▸"
        case .playlist: "▤"
        case .smartlist: "◇"
        }
    }

    func row(_ glyph: String, _ name: String) -> some View {
        HStack(spacing: 6.z) {
            Text(glyph).font(Theme.mono(11.z)).foregroundStyle(Theme.muted).frame(width: 12.z)
            Text(name).font(Theme.mono(11.z)).foregroundStyle(Theme.bone).lineLimit(1)
        }
        .frame(minHeight: 20.z)   // Zeilenhöhe der Seitenleiste mit dem Zoom (100 %: 28 pt)
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
            TableColumn("#") { (r: Row) in Text("\(r.id + 1)") }.width(28.z)
            TableColumn("Start") { (r: Row) in Text(Theme.timeFormat.string(from: r.e.start)) }.width(64.z)
            TableColumn("Deck") { (r: Row) in Text(deckLetters[max(0, min(3, r.e.deck))]) }.width(36.z)
            TableColumn("Artist") { (r: Row) in Text(r.e.artist) }
            TableColumn("Title") { (r: Row) in Text(r.e.title) }
            TableColumn("BPM") { (r: Row) in Text(r.e.bpm > 0 ? String(format: "%.1f", r.e.bpm) : "") }.width(48.z)
            TableColumn("Key") { (r: Row) in Text(r.e.keyText) }.width(36.z)
            TableColumn("Dauer") { (r: Row) in Text(Theme.time(r.e.duration)) }.width(48.z)
        }
        .font(Theme.mono(11.z))
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
    @Bindable var model: BrowserPaneModel
    /// nur Selbsttest-Bilder: feste Zeilen statt der Liste des Bereichs
    var rows: [Track]? = nil
    @State private var table = TrackTableController()
    @State private var inlineCtl = InlineEditController()
    @State private var rowBand = PreviewRowController()

    var body: some View {
        let ui = decks.prefs.ui
        // stößt die Liste an (Hintergrund); die Tabelle zeigt immer `model.shown`, neue Listen kommen über `onList`
        let _ = rows == nil ? model.list(from: store, history: history, separators: ui.tagSeparators) : []
        // Vorschau-Bilder in Zellen hängen am Übersichten-Zähler, das Band (ganze Zeile) zeichnet PreviewRowLayer
        let tick = ui.previewMode == .column || ui.previewMode == .behindTitle ? Overviews.shared.tick : 0
        let look = TrackTableController.Look(ui: ui, zoom: UIZoom.shared.factor, filter: model.tagFilter, inline: model.inline,
                                             played: history.played, cloud: CloudLibrary.shared.revision, tick: tick)
        TrackTableView(controller: table, look: look, selection: model.selection, sort: model.sortOrder) { table in
                table.model = model
                table.fixedRows = rows
                model.onList = { [weak table] in table?.listArrived() }
                table.store = store
                table.history = history
                table.mix = decks
                table.inline = inlineCtl
                inlineCtl.model = model
                inlineCtl.store = store
                inlineCtl.tableView = table.table
                inlineCtl.rows = { [table] in table.shownRows }
                inlineCtl.writeBack = { [decks] in decks.prefs.ui.writeCollection }
                // Tag-Chip unter dem Klick, nur ganz sichtbare (abgeschnittene enden in „…“)
                inlineCtl.chipAt = { [decks] t, x, width in
                    let tags = BrowserPaneModel.tagIndex.entry(t.comment2, separators: decks.prefs.ui.tagSeparators).tags
                    return TagChipsText.spans(tags: tags, .of(decks.prefs.ui)).firstIndex { $0.contains(x) && $0.upperBound <= width }.map { tags[$0] }
                }
                inlineCtl.twoLine = { [decks] in decks.prefs.ui.previewMode == .fullRow }
                rowBand.inline = inlineCtl
                rowBand.rows = { [weak table] in table?.shownRows ?? [] }
                table.onReload = { [rowBand] in rowBand.refresh() }
            }
            .background(PreviewRowLayer(controller: rowBand, mix: decks, on: ui.previewMode == .fullRow))
            .onAppear { inlineCtl.install() }
            .onDisappear { inlineCtl.uninstall(); rowBand.remove() }
            .onChange(of: model.selection) { browser.activePaneID = model.id }
            .onChange(of: browser.scrollRequest?.track) {
                if let r = browser.scrollRequest, r.pane == model.id { table.scroll(to: r.track) }
            }
    }
}
