import SwiftUI
import AppKit
import MixCore

/// Entwurf im Smartlist-Editor: neu (in Ordner `parent`) oder Bearbeiten eines Eintrags
@MainActor @Observable
final class SmartlistDraft: Identifiable {
    let id = UUID()
    var name: String
    var rules: SmartRules
    /// nil = neue Smartlist
    let itemID: UUID?
    let parent: UUID?
    /// Treffer mit den Regeln `countedRules` (nil = wird gerechnet)
    var count: Int?
    var countedRules: SmartRules?
    /// Treffer gelten für die Regeln, wie sie jetzt sind
    var countIsCurrent: Bool { count != nil && countedRules == rules }
    /// offener Editor (UI-Selbsttest)
    static weak var current: SmartlistDraft?

    init(new name: String, parent: UUID?, rules: SmartRules = SmartRules(rules: [SmartRule(.genre, .contains)])) {
        self.name = name
        self.rules = rules
        itemID = nil
        self.parent = parent
    }

    init(edit item: PlaylistItem) {
        name = item.name
        rules = item.rules
        itemID = item.id
        parent = nil
    }

    var isNew: Bool { itemID == nil }
    var canSave: Bool { rules.isValid && !name.trimmingCharacters(in: .whitespaces).isEmpty }

    func addRule() {
        let last = rules.rules.last
        rules.rules.append(SmartRule(last?.field ?? .genre, last.map { $0.field.ops[0] } ?? .contains))
    }

    /// übernehmen: neu einsetzen bzw. Name + Regeln ersetzen; getippte Texte ohne Treffer in der Collection werden
    /// eigene Werte (bleiben in den Vorschlägen). Ergebnis = der gespeicherte Eintrag
    @discardableResult
    func save(_ store: LibraryStore) -> PlaylistItem? {
        guard canSave else { return nil }
        let n = name.trimmingCharacters(in: .whitespaces)
        var known: [SmartField: Set<String>] = [:]
        for r in rules.rules where r.field.suggests && !r.op.unary && !r.value.trimmingCharacters(in: .whitespaces).isEmpty {
            if known[r.field] == nil { known[r.field] = Set(store.suggestions(for: r.field).map { Tags.key($0.value) }) }
        }
        var saved: PlaylistItem?
        let label = isNew ? String(localized: "Neue Smartlist") : String(localized: "Smartlist bearbeiten")
        store.editPlaylists(label) { t in
            if let id = itemID {
                t.update(id) { $0.name = n; $0.rules = rules }
                saved = t.item(id)
            } else {
                let it = PlaylistItem.smartlist(n, rules)
                if t.insert(it, into: parent) { saved = it }
            }
            for r in rules.rules where known[r.field].map({ !$0.contains(Tags.key(r.value.trimmingCharacters(in: .whitespaces))) }) ?? false {
                t.remember(r.value, for: r.field)
            }
        }
        return saved
    }
}

/// Beschriftungen der Felder und Operatoren
enum SmartLabels {
    static func field(_ f: SmartField) -> String {
        switch f {
        case .search: String(localized: "Suche (alle Felder)")
        case .artist: "Artist"
        case .title: String(localized: "Titel")
        case .release: "Release"
        case .mix: "Mix"
        case .remixer: "Remixer"
        case .producer: "Producer"
        case .label: "Label"
        case .genre: "Genre"
        case .catalog: String(localized: "Katalog-Nr.")
        case .comment: String(localized: "Kommentar")
        case .comment2: String(localized: "Kommentar 2")
        case .tag: String(localized: "Tag (Kommentar 2)")
        case .key: "Key"
        case .bpm: "BPM"
        case .rating: "Rating"
        case .year: String(localized: "Jahr")
        case .releaseDate: String(localized: "Release-Datum")
        case .duration: String(localized: "Spielzeit")
        case .loudness: String(localized: "Lautheit (dB)")
        case .bitrate: "Bitrate"
        case .color: String(localized: "Farbe")
        case .playCount: "Plays"
        case .fileType: String(localized: "Dateityp")
        case .path: String(localized: "Pfad / Ordner")
        case .importDate: String(localized: "Importdatum")
        case .played: String(localized: "Gespielt")
        case .lastPlayed: String(localized: "Zuletzt gespielt")
        case .cloud: String(localized: "Cloud-Status")
        case .analyzed: String(localized: "Analysiert")
        case .expression: String(localized: "Ausdruck (Regel-Text)")
        }
    }

    /// Gruppen im Feld-Menü
    static let groups: [(String, [SmartField])] = [
        ("SUCHE", [.search]),
        ("TEXT", [.artist, .title, .release, .mix, .remixer, .producer, .label, .genre, .catalog, .comment, .comment2, .tag]),
        ("MUSIK", [.key, .bpm, .rating, .duration, .loudness, .year]),
        ("DATUM + STATUS", [.importDate, .releaseDate, .played, .lastPlayed, .playCount, .analyzed]),
        ("DATEI", [.fileType, .bitrate, .path, .cloud, .color]),
        ("ERWEITERT", [.expression]),
    ]

    static func op(_ o: SmartOp, _ f: SmartField) -> String {
        switch (f.kind, o) {
        case (.tag, .contains): String(localized: "hat Tag")
        case (.tag, .notContains): String(localized: "hat Tag nicht")
        case (.tag, .isEmpty): String(localized: "ohne Tags")
        case (.tag, .notEmpty): String(localized: "mit Tags")
        case (.key, .isEmpty): String(localized: "ohne Key")
        case (.key, .notEmpty): String(localized: "mit Key")
        case (.date, .isEmpty), (.number, .isEmpty): String(localized: "ohne Wert")
        case (.date, .notEmpty), (.number, .notEmpty): String(localized: "mit Wert")
        default:
            switch o {
            case .equals: String(localized: "ist")
            case .isNot: String(localized: "ist nicht")
            case .contains: String(localized: "enthält")
            case .notContains: String(localized: "enthält nicht")
            case .startsWith: String(localized: "beginnt mit")
            case .endsWith: String(localized: "endet mit")
            case .isEmpty: String(localized: "ist leer")
            case .notEmpty: String(localized: "ist nicht leer")
            case .less: String(localized: "kleiner als")
            case .greater: String(localized: "größer als")
            case .atLeast: String(localized: "mindestens")
            case .atMost: String(localized: "höchstens")
            case .between: String(localized: "zwischen")
            case .before: String(localized: "vor")
            case .after: String(localized: "nach")
            case .inLast: String(localized: "in den letzten")
            case .notInLast: String(localized: "nicht in den letzten")
            case .yes: String(localized: "ja")
            case .no: String(localized: "nein")
            case .matches: String(localized: "passt auf")
            }
        }
    }

    static let units: [(String, String)] = [("d", String(localized: "Tagen")), ("w", String(localized: "Wochen")),
                                            ("m", String(localized: "Monaten")), ("y", String(localized: "Jahren"))]

    static func availability(_ a: SmartAvailability) -> String {
        switch a {
        case .local: String(localized: "lokal")
        case .cloud: String(localized: "nur online")
        case .missing: String(localized: "fehlt")
        }
    }

    /// 24 Keys in Open-Key-Reihenfolge: (Code, „1d · C · 8B“)
    static let keys: [(code: Int, label: String)] = {
        let names = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]
        return (1...12).flatMap { n in ["d", "m"].compactMap { m -> (Int, String)? in
            guard let c = Harmony.code(text: "\(n)\(m)") else { return nil }
            let camelot = "\((n + 6) % 12 + 1)\(m == "d" ? "B" : "A")"
            return (c, "\(n)\(m) · \(names[c % 12])\(c >= 12 ? "m" : "") · \(camelot)")
        } }
    }()
}

/// Smartlist anlegen / bearbeiten: Tabelle Feld | Operator | Wert, alle / eine der Regeln, Sortierung + Limit,
/// Treffer live (im Hintergrund). Fenster zoomt mit (`.z`)
struct SmartlistEditor: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Bindable var draft: SmartlistDraft
    var onSave: (PlaylistItem) -> Void = { _ in }

    private struct CountKey: Equatable { var rules: SmartRules; var revision: Int }

    var body: some View {
        VStack(alignment: .leading, spacing: 10.z) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: "\(OwnGlyph.smartlist) SMARTLIST").font(Theme.label(16.z, .bold)).foregroundStyle(Theme.bone)
                Spacer()
                Text(draft.isNew ? "NEU" : "BEARBEITEN").font(Theme.label(11.z, .bold)).foregroundStyle(Theme.muted)
            }
            HStack(spacing: 8.z) {
                Text("NAME").font(Theme.label(11.z, .bold)).foregroundStyle(Theme.muted).frame(width: 90.z, alignment: .leading)
                TextField("NAME", text: $draft.name).textFieldStyle(.plain).font(Theme.mono(13.z))
                    .padding(6.z).background(Theme.void).overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
            }
            HStack(spacing: 8.z) {
                Text("TREFFER BEI").font(Theme.label(11.z, .bold)).foregroundStyle(Theme.muted).frame(width: 90.z, alignment: .leading)
                DeckButton(title: "ALLEN REGELN", active: draft.rules.match == .all) { draft.rules.match = .all }
                DeckButton(title: "EINER DER REGELN", active: draft.rules.match == .any) { draft.rules.match = .any }
                Spacer()
            }
            table
            HStack(spacing: 8.z) {
                DeckButton(title: "+ REGEL") { draft.addRule() }
                    .help("Zeile anhängen")
                Spacer()
            }
            Rectangle().fill(Theme.hairline).frame(height: 1)
            sortRow
            HStack(spacing: 10.z) {
                countText
                Spacer()
                DeckButton(title: "ABBRECHEN") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                DeckButton(title: "SPEICHERN", active: draft.canSave) {
                    if let it = draft.save(store) { onSave(it); dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.canSave)
            }
        }
        .padding(16.z)
        .frame(width: 820.z)
        .background(Theme.chitin)
        .onAppear { SmartlistDraft.current = draft }
        .onDisappear { if SmartlistDraft.current === draft { SmartlistDraft.current = nil } }
        .task(id: CountKey(rules: draft.rules, revision: store.revision)) { await recount() }
    }

    private var table: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8.z) {
                Text("FELD").frame(width: 200.z, alignment: .leading)
                Text("OPERATOR").frame(width: 170.z, alignment: .leading)
                Text("WERT").frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(width: 26.z, height: 1)
            }
            .font(Theme.label(10.z, .bold)).foregroundStyle(Theme.muted)
            .padding(.horizontal, 8.z).padding(.vertical, 5.z)
            .background(Theme.chitinRaised)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach($draft.rules.rules) { $rule in
                        RuleRow(rule: $rule, canRemove: draft.rules.rules.count > 1) {
                            draft.rules.rules.removeAll { $0.id == rule.id }
                        }
                    }
                    if draft.rules.rules.isEmpty {
                        Text("keine regel – die smartlist zeigt die ganze collection").font(Theme.mono(11.z)).foregroundStyle(Theme.muted)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(8.z)
                    }
                }
            }
            .frame(minHeight: 130.z, maxHeight: 330.z)
        }
        .background(Theme.void)
        .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
    }

    private var sortRow: some View {
        let sortable = SmartField.allCases.filter { ![.search, .tag, .expression, .played, .analyzed, .cloud].contains($0) }
        return HStack(spacing: 8.z) {
            Text("SORTIEREN").font(Theme.label(11.z, .bold)).foregroundStyle(Theme.muted).frame(width: 90.z, alignment: .leading)
            Picker("", selection: Binding<SmartField?>(get: { draft.rules.sort?.field },
                                                       set: { f in draft.rules.sort = f.map { SmartSort($0, ascending: draft.rules.sort?.ascending ?? false) } })) {
                Text("ohne").tag(SmartField?.none)
                ForEach(sortable, id: \.self) { f in Text(SmartLabels.field(f)).tag(SmartField?.some(f)) }
            }
            .labelsHidden().frame(width: 200.z)
            if let s = draft.rules.sort {
                DeckButton(title: s.ascending ? "↑ AUFSTEIGEND" : "↓ ABSTEIGEND") { draft.rules.sort?.ascending.toggle() }
            }
            Text("LIMIT").font(Theme.label(11.z, .bold)).foregroundStyle(Theme.muted).padding(.leading, 12.z)
            TextField("–", text: Binding(get: { draft.rules.limit.map(String.init) ?? "" },
                                         set: { draft.rules.limit = Int($0.trimmingCharacters(in: .whitespaces)).map { max(0, $0) } }))
                .textFieldStyle(.plain).font(Theme.mono(12.z)).frame(width: 60.z)
                .padding(4.z).background(Theme.void).overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
            Text("TRACKS").font(Theme.mono(11.z)).foregroundStyle(Theme.muted)
            Spacer()
        }
        .help("Sortierung wählt mit dem Limit die ersten n Treffer (z. B. die 50 neuesten); die Liste im Browser sortiert danach wie eingestellt")
    }

    @ViewBuilder private var countText: some View {
        if let p = draft.rules.problem {
            Text(verbatim: "✕ " + p).font(Theme.mono(11.z)).foregroundStyle(Theme.state)
        } else if let n = draft.count {
            Text(verbatim: "\(n) " + String(localized: "TREFFER")).font(Theme.mono(12.z, .medium))
                .foregroundStyle(draft.countIsCurrent ? Theme.bone : Theme.muted)
        } else {
            Text(verbatim: "…").font(Theme.mono(12.z)).foregroundStyle(Theme.muted)
        }
    }

    /// Treffer im Hintergrund (Regeln vorbereitet auf dem Hauptthread, Cloud-Zustand als Tabelle)
    private func recount() async {
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled else { return }
        let rules = draft.rules
        let compiled = rules.compile(store.smartContext(for: rules))
        let tracks = store.tracks
        let n = await Task.detached(priority: .userInitiated) { compiled.apply(tracks).count }.value
        guard !Task.isCancelled else { return }
        draft.count = n
        draft.countedRules = rules
    }
}

/// Zeile Feld | Operator | Wert | −
private struct RuleRow: View {
    @Binding var rule: SmartRule
    let canRemove: Bool
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2.z) {
            HStack(spacing: 8.z) {
                Picker("", selection: Binding(get: { rule.field }, set: { rule.setField($0) })) {
                    ForEach(SmartLabels.groups, id: \.0) { g in
                        Section(g.0) {
                            ForEach(g.1, id: \.self) { f in Text(SmartLabels.field(f)).tag(f) }
                        }
                    }
                }
                .labelsHidden().frame(width: 200.z)
                .accessibilityIdentifier("smart.field")
                Picker("", selection: Binding(get: { rule.op }, set: { rule.setOp($0) })) {
                    ForEach(rule.field.ops, id: \.self) { o in Text(SmartLabels.op(o, rule.field)).tag(o) }
                }
                .labelsHidden().frame(width: 170.z)
                RuleValue(rule: $rule).frame(maxWidth: .infinity, alignment: .leading)
                DeckButton(title: "−", width: 26.z) { remove() }
                    .disabled(!canRemove)
                    .help("Zeile entfernen")
            }
            if let p = rule.problem, !(rule.field.kind == .number && rule.value.isEmpty) {
                Text(verbatim: p).font(Theme.mono(10.z)).foregroundStyle(Theme.state).padding(.leading, 386.z)
            }
        }
        .padding(.horizontal, 8.z).padding(.vertical, 5.z)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline.opacity(0.6)).frame(height: 1) }
    }
}

/// Werteingabe passend zum Feld: Text mit Vorschlägen (wählen oder frei tippen), Key-Menü, Zahl, Datum, Status
private struct RuleValue: View {
    @Binding var rule: SmartRule

    var body: some View {
        if rule.op.unary {
            Text(verbatim: "—").font(Theme.mono(12.z)).foregroundStyle(Theme.muted)
        } else {
            switch rule.field.kind {
            case .search:
                SmartTextField(text: $rule.value, placeholder: String(localized: "WÖRTER"), bad: false)
            case .text, .tag:
                ValueCombo(text: $rule.value, field: rule.field)
            case .key:
                Picker("", selection: Binding(get: { Int(rule.value) ?? 0 }, set: { rule.value = String($0) })) {
                    ForEach(SmartLabels.keys, id: \.code) { k in Text(verbatim: k.label).tag(k.code) }
                }
                .labelsHidden().frame(width: 190.z)
            case .number:
                HStack(spacing: 6.z) {
                    SmartTextField(text: $rule.value, placeholder: SmartRules.numberHint(rule.field),
                                   bad: !rule.value.isEmpty && SmartRules.number(rule.value, rule.field) == nil)
                        .frame(width: 130.z)
                    if rule.op == .between {
                        Text(verbatim: "–").font(Theme.mono(12.z)).foregroundStyle(Theme.muted)
                        SmartTextField(text: $rule.value2, placeholder: SmartRules.numberHint(rule.field),
                                       bad: !rule.value2.isEmpty && SmartRules.number(rule.value2, rule.field) == nil)
                            .frame(width: 130.z)
                    }
                }
            case .date:
                switch rule.op {
                case .inLast, .notInLast:
                    HStack(spacing: 6.z) {
                        SmartTextField(text: $rule.value, placeholder: "30", bad: Int(rule.value) == nil).frame(width: 60.z)
                        Picker("", selection: $rule.value2) {
                            ForEach(SmartLabels.units, id: \.0) { u in Text(u.1).tag(u.0) }
                        }
                        .labelsHidden().frame(width: 110.z)
                    }
                case .between:
                    HStack(spacing: 6.z) {
                        DayField(text: $rule.value)
                        Text(verbatim: "–").font(Theme.mono(12.z)).foregroundStyle(Theme.muted)
                        DayField(text: $rule.value2)
                    }
                default:
                    DayField(text: $rule.value)
                }
            case .flag:
                Text(verbatim: "—").font(Theme.mono(12.z)).foregroundStyle(Theme.muted)
            case .cloud:
                Picker("", selection: $rule.value) {
                    ForEach(SmartAvailability.allCases, id: \.self) { a in Text(SmartLabels.availability(a)).tag(a.rawValue) }
                }
                .labelsHidden().frame(width: 150.z)
            case .expression:
                SmartTextField(text: $rule.value, placeholder: #"$GENRE % "techno" & $BPM >= 128"#, bad: rule.problem != nil)
            }
        }
    }
}

/// Textfeld im Stil des Editors, rot umrandet bei ungültiger Eingabe
private struct SmartTextField: View {
    @Binding var text: String
    let placeholder: String
    let bad: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain).font(Theme.mono(12.z))
            .padding(.horizontal, 6.z).padding(.vertical, 4.z)
            .background(Theme.void)
            .overlay(Rectangle().stroke(bad ? Theme.state : Theme.hairline, lineWidth: 1))
    }
}

/// Datum JJJJ-MM-TT über den Datumswähler (leer = heute)
private struct DayField: View {
    @Binding var text: String

    var body: some View {
        DatePicker("", selection: Binding(get: { SmartRules.day(text) ?? Calendar.current.startOfDay(for: Date()) },
                                          set: { text = SmartRules.dayText($0) }),
                   displayedComponents: .date)
            .datePickerStyle(.field).labelsHidden().frame(width: 130.z)
            .onAppear { if SmartRules.day(text) == nil { text = SmartRules.dayText(Date()) } }
    }
}

/// Wert wählen oder frei tippen: Feld + ▾ mit den Werten der Collection (häufigste zuerst) und den eigenen Werten.
/// Getippte Werte ohne Treffer bleiben nach dem Speichern als eigene Werte in der Liste (✕ entfernt sie wieder)
struct ValueCombo: View {
    @Environment(LibraryStore.self) private var store
    @Binding var text: String
    let field: SmartField
    @State private var open = false

    var body: some View {
        HStack(spacing: 0) {
            TextField("WERT", text: $text)
                .textFieldStyle(.plain).font(Theme.mono(12.z))
                .padding(.horizontal, 6.z).padding(.vertical, 4.z)
            Button { open.toggle() } label: {
                Text(verbatim: "▾").font(Theme.mono(12.z)).foregroundStyle(Theme.bone)
                    .frame(width: 22.z).frame(maxHeight: .infinity).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Werte aus der Collection und eigene Werte")
            .overlay(alignment: .leading) { Rectangle().fill(Theme.hairline).frame(width: 1) }
            .popover(isPresented: $open, arrowEdge: .bottom) { list }
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.void)
        .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
    }

    private var list: some View {
        let typed = text.trimmingCharacters(in: .whitespaces)
        let needle = Track.fold(typed)
        let own = store.playlists.values(for: field)
        let fromCollection = store.suggestions(for: field)
        let ownKeys = Set(own.map(Tags.key))
        func hit(_ v: String) -> Bool { needle.isEmpty || SmartRules.contains(Track.fold(v), needle) }
        let mine = own.filter(hit)
        let theirs = fromCollection.lazy.filter { !ownKeys.contains(Tags.key($0.value)) && hit($0.value) }.prefix(300)
        let exists = !typed.isEmpty && (ownKeys.contains(Tags.key(typed)) || fromCollection.contains { Tags.key($0.value) == Tags.key(typed) })
        return VStack(alignment: .leading, spacing: 6.z) {
            Text(verbatim: SmartLabels.field(field).uppercased()).font(Theme.label(12.z, .bold))
            Text("wählen oder frei tippen · getippte werte bleiben als eigene werte").font(Theme.mono(10.z)).foregroundStyle(Theme.muted)
            if !typed.isEmpty, !exists {
                Button {
                    store.playlists.remember(typed, for: field)
                } label: {
                    Text(verbatim: "+ „\(typed)“ " + String(localized: "als eigenen Wert merken")).font(Theme.mono(11.z)).foregroundStyle(Theme.bone)
                }
                .buttonStyle(.plain)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1.z) {
                    if !mine.isEmpty {
                        Text("EIGENE WERTE").font(Theme.label(10.z, .bold)).foregroundStyle(Theme.muted).padding(.top, 2.z)
                        ForEach(mine, id: \.self) { v in
                            HStack {
                                pick(v, count: nil)
                                Button { store.playlists.forget(v, for: field) } label: {
                                    Text(verbatim: "✕").font(Theme.mono(10.z)).foregroundStyle(Theme.muted)
                                }
                                .buttonStyle(.plain).help("Eigenen Wert entfernen")
                            }
                        }
                    }
                    if !theirs.isEmpty {
                        Text("AUS DER COLLECTION").font(Theme.label(10.z, .bold)).foregroundStyle(Theme.muted).padding(.top, 4.z)
                        ForEach(Array(theirs), id: \.value) { v in pick(v.value, count: v.count) }
                    }
                }
            }
            .frame(height: 300.z)
        }
        .padding(10.z)
        .frame(width: 340.z)
        .background(Theme.chitin)
    }

    private func pick(_ v: String, count: Int?) -> some View {
        Button {
            text = v
            open = false
        } label: {
            HStack {
                Text(verbatim: v).font(Theme.mono(11.z)).foregroundStyle(Theme.bone).lineLimit(1)
                Spacer()
                if let count { Text(verbatim: "\(count)").font(Theme.mono(10.z)).foregroundStyle(Theme.muted) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Kopf eines Bereichs mit eigener Smartlist: Regeln bearbeiten; eigene Playlist: Playlist-Reihenfolge
struct OwnSmartlistEditButton: View {
    @Environment(LibraryStore.self) private var store
    let model: BrowserPaneModel
    @State private var draft: SmartlistDraft?

    var body: some View {
        if case let .own(r) = model.source, r.kind == .smartlist {
            DeckButton(title: "✎ REGELN") { if let it = store.playlists.item(r.id) { draft = SmartlistDraft(edit: it) } }
                .help("Smartlist bearbeiten")
                .sheet(item: $draft) { d in SmartlistEditor(draft: d) }
        } else if model.ownPlaylistID != nil {
            DeckButton(title: "# REIHENFOLGE", active: model.sortOrder.isEmpty) { model.sortOrder = [] }
                .help("In Playlist-Reihenfolge zeigen (Ziehen in der Liste ändert sie, ⌫ entfernt)")
        }
    }
}
