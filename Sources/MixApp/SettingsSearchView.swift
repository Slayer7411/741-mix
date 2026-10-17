import SwiftUI
import AppKit

/// Zustand der Einstellungen: Bereich, Suche, Sprung zu einer Zeile
@MainActor @Observable
final class SettingsNav {
    struct Jump: Equatable {
        let entry: SettingsEntry
        let n: Int
    }

    var tab: String
    var query = ""
    /// Trefferliste statt Bereich (nach einem Sprung aus, Suche bleibt stehen)
    var showResults = false
    var selected = 0
    /// Anker, der gerade lila hervorgehoben ist
    var flash: String?
    var jump: Jump?
    /// hochzählen = Suchfeld fokussieren (⌘F)
    var focus = 0
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored private var jumps = 0
    /// zuletzt gezeigte Einstellungen (⌘F im KeyMonitor)
    @ObservationIgnored static weak var active: SettingsNav?

    init(tab: String) { self.tab = tab }

    func open(_ e: SettingsEntry) {
        tab = e.tab
        showResults = false
        jumps += 1
        jump = Jump(entry: e, n: jumps)
    }

    /// Bereich in der Seitenleiste angeklickt: Suche weg
    func select(tab id: String) {
        query = ""
        showResults = false
        tab = id
    }

    func move(_ by: Int, count: Int) {
        guard count > 0 else { return }
        selected = min(count - 1, max(0, selected + by))
    }

    /// ⌘F im Einstellungsfenster
    static func handleFind() -> Bool {
        guard let nav = active, let w = nav.window, NSApp.keyWindow === w else { return false }
        nav.focus += 1
        return true
    }
}

/// gerade aufgebaute Anker (ausgeblendete Zeilen fehlen -> Sprung auf `alt`)
@MainActor
enum SettingsAnchors {
    static var present: Set<String> = []
}

extension EnvironmentValues {
    @Entry var settingsFlash: String? = nil
    /// Favoriten-Modus: nur diese Anker zeigen (nil = alle Zeilen)
    @Entry var settingsFilter: Set<String>? = nil
    /// Eintrag des Sprungs der Suche (klappt ERWEITERT auf)
    @Entry var settingsJump: SettingsEntry? = nil
}

extension View {
    /// Zeile der Einstellungen als Sprungziel der Suche; die ID steht im `SettingsIndex`
    func settingsAnchor(_ id: String) -> some View { modifier(SettingsAnchor(id: id)) }
}

private struct SettingsAnchor: ViewModifier {
    let id: String
    @Environment(\.settingsFlash) private var flash
    @State private var hovered = false

    func body(content: Content) -> some View {
        let on = flash == id
        content
            .background {
                Rectangle().fill(Theme.secondary.opacity(on ? 0.22 : 0))
                    .overlay(alignment: .leading) { Rectangle().fill(Theme.secondary.opacity(on ? 1 : 0)).frame(width: 2) }
                    .padding(.horizontal, -8).padding(.vertical, -3)
                    .animation(.easeOut(duration: on ? 0.15 : 0.6), value: on)
                    .allowsHitTesting(false)
                if on { UITestMark(name: "settings flash") }
            }
            // ☆ / ★: einmal hier für alle Zeilen (Favoriten), in eigener Randspalte neben den Bedienelementen
            .padding(.trailing, 24)
            .overlay(alignment: .trailing) { SettingsStar(id: id, hovered: hovered) }
            .onHover { hovered = $0 }
            .containerValue(\.settingsAnchorId, id)
            .id(id)
            .onAppear { SettingsAnchors.present.insert(id) }
            .onDisappear { SettingsAnchors.present.remove(id) }
    }
}

/// Suchfeld oben in der Seitenleiste: Tippen zeigt Treffer, Enter springt zum gewählten, ↑↓ wählt, esc leert
struct SettingsSearchField: View {
    @Bindable var nav: SettingsNav
    let hits: [SettingsSearch.Hit]
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                TextField("", text: $nav.query, prompt: Text("Suchen (⌘F)"))
                    .textFieldStyle(.plain)
                    .font(Theme.mono(11))
                    .focused($focused)
                    .onSubmit { if nav.selected < hits.count { nav.open(hits[nav.selected].entry) } }
                    .onExitCommand { nav.query = "" }
                    .onKeyPress(.downArrow) { nav.move(1, count: hits.count); return nav.showResults ? .handled : .ignored }
                    .onKeyPress(.upArrow) { nav.move(-1, count: hits.count); return nav.showResults ? .handled : .ignored }
                if !nav.query.isEmpty {
                    Button { nav.query = "" } label: { Text(verbatim: "✕").font(Theme.mono(10)).foregroundStyle(Theme.muted) }
                        .buttonStyle(.plain)
                        .help("Suche leeren (esc)")
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(Theme.chitin)
            .overlay(Rectangle().stroke(focused ? Theme.secondary : Theme.hairline, lineWidth: 1))
            .background(UITestMark(name: "settings search"))
            if !nav.query.isEmpty, !nav.showResults {
                Button { nav.showResults = true } label: {
                    Text("◆ \(hits.count) Treffer").font(Theme.label(10, .bold)).textCase(.uppercase).foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 12)
        .onChange(of: nav.focus) { focused = true }
        .onChange(of: nav.query) {
            nav.showResults = !nav.query.isEmpty
            nav.selected = 0
        }
    }
}

/// Trefferliste: Bereich · Abschnitt, Name, Hinweis-Ausschnitt; Suchwörter lila
struct SettingsResults: View {
    @Bindable var nav: SettingsNav
    let hits: [SettingsSearch.Hit]

    var body: some View {
        let terms = Self.terms(nav.query)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: "◆").font(Theme.label(9)).foregroundStyle(Theme.muted)
                        Text(hits.isEmpty ? "Keine Treffer" : "\(hits.count) Treffer")
                            .font(Theme.label(12, .bold)).textCase(.uppercase).foregroundStyle(Theme.bone)
                    }
                    .padding(.bottom, 7)
                    Rectangle().fill(Theme.hairline).frame(height: 1).padding(.bottom, 4)
                    ForEach(Array(hits.enumerated()), id: \.offset) { i, h in
                        Button { nav.selected = i; nav.open(h.entry) } label: {
                            SettingsHitRow(entry: h.entry, terms: terms, selected: i == nav.selected)
                        }
                        .buttonStyle(.plain)
                        .background { if i == 0 { UITestMark(name: "settings hit") } }
                        .id(i)
                    }
                }
                .padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: nav.selected) { proxy.scrollTo(nav.selected) }
        }
        .background(Theme.chitin)
    }

    /// Wörter zum Hervorheben: Suchwörter und ihre Synonyme
    static func terms(_ query: String) -> [String] {
        let raw = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return raw + SettingsSearch.tokens(query).flatMap { SettingsSearch.synonyms[$0] ?? [] }
    }
}

private struct SettingsHitRow: View {
    let entry: SettingsEntry
    let terms: [String]
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: "\(Self.l(entry.tab)) · \(Self.l(entry.section))")
                .font(Theme.label(10, .bold)).textCase(.uppercase).foregroundStyle(Theme.muted).lineLimit(1)
            Text(Self.marked(Self.l(entry.label), terms)).font(Theme.mono(12)).foregroundStyle(Theme.bone)
            if let hint = entry.hint {
                Text(Self.marked(Self.snippet(Self.l(hint), terms), terms))
                    .font(Theme.mono(10)).foregroundStyle(Theme.muted).lineLimit(2)
            }
        }
        .padding(.vertical, 7).padding(.leading, 12).padding(.trailing, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .trailing) { SettingsStar(id: entry.anchor, hovered: true).padding(.trailing, 6) }
        .background(selected ? Theme.chitinRaised : .clear)
        .overlay(alignment: .leading) { if selected { Rectangle().fill(Theme.secondary).frame(width: 3) } }
        .contentShape(Rectangle())
    }

    static func l(_ key: String) -> String { Bundle.main.localizedString(forKey: key, value: nil, table: nil) }

    private static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// Fundstellen lila
    static func marked(_ s: String, _ terms: [String]) -> AttributedString {
        var a = AttributedString(s)
        for t in terms where !t.isEmpty {
            var from = s.startIndex
            while let r = s.range(of: t, options: options, range: from..<s.endIndex) {
                if let ar = Range(r, in: a) {
                    a[ar].foregroundColor = Theme.secondary
                }
                from = r.upperBound
            }
        }
        return a
    }

    /// Hinweis ab kurz vor der ersten Fundstelle
    static func snippet(_ s: String, _ terms: [String]) -> String {
        guard let first = terms.compactMap({ s.range(of: $0, options: options)?.lowerBound }).min(),
              s.distance(from: s.startIndex, to: first) > 50 else { return s }
        var start = s.index(first, offsetBy: -36)
        while start > s.startIndex, !s[s.index(before: start)].isWhitespace { start = s.index(before: start) }
        return "… " + s[start...]
    }
}
