import AppKit
import SwiftUI
import MixCore

/// Übersicht „Tastenkürzel“: alle Aktionen mit der jeweils eingestellten Belegung, nach Gruppen, mit Suche.
/// Reine Auswahl (`sections`), damit sie ohne Fenster prüfbar ist
enum ShortcutReference {
    struct Row: Identifiable, Equatable {
        let action: ShortcutID
        let title: String
        /// Belegung mit Symbolen („⌘P“), leer wenn keine
        let combo: String
        var id: String { action.rawValue }
    }

    struct Section: Identifiable, Equatable {
        let group: ShortcutGroup
        let rows: [Row]
        var id: String { group.rawValue }
    }

    /// Gruppen in Reihenfolge der Einstellungen; Filter: Text in Name oder Belegung (ohne Groß-/Kleinschreibung).
    /// Gruppen ohne Treffer fallen weg
    static func sections(keys: ShortcutMap, query: String = "") -> [Section] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return ShortcutGroup.allCases.compactMap { g in
            let rows = ShortcutID.allCases.filter { $0.group == g }.map { a in
                Row(action: a, title: a.title, combo: keys.combo(a)?.symbols ?? "")
            }
            let hit = q.isEmpty ? rows : rows.filter { $0.title.lowercased().contains(q) || $0.combo.lowercased().contains(q) }
            return hit.isEmpty ? nil : Section(group: g, rows: hit)
        }
    }

    /// Anzahl Aktionen mit eigener Belegung (für die Kopfzeile)
    static func customCount(_ keys: ShortcutMap) -> Int {
        ShortcutID.allCases.filter { !keys.isDefault($0) }.count
    }
}

@MainActor
enum ShortcutWindow {
    /// `keys`: die jeweils aktuelle Belegung (Fenster bleibt aktuell, wenn sie sich ändert)
    static func show(keys: @escaping @MainActor () -> ShortcutMap) {
        BasicWindows.show("shortcuts", title: "MINOS-741 Tastenkürzel", size: NSSize(width: 600, height: 680)) {
            AnyView(ShortcutReferenceView(source: keys))
        }
    }
}

struct ShortcutReferenceView: View {
    let source: @MainActor () -> ShortcutMap
    @State private var query = ""

    var body: some View {
        let keys = source()
        let sections = ShortcutReference.sections(keys: keys, query: query)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Tastenkürzel").font(Theme.label(16)).textCase(.uppercase)
                Spacer()
                Text("\(ShortcutReference.customCount(keys)) eigene Belegungen")
                    .font(Theme.mono(10)).foregroundStyle(Theme.muted)
            }
            TextField(String(localized: "Suchen nach Aktion oder Taste"), text: $query)
                .textFieldStyle(.plain)
                .font(Theme.mono(12))
                .padding(7)
                .background(Theme.chitin)
                .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if sections.isEmpty {
                        Text("Kein Treffer").font(Theme.mono(12)).foregroundStyle(Theme.muted).padding(.top, 8)
                    }
                    ForEach(sections) { s in
                        Text(s.group.title).font(Theme.label(12)).textCase(.uppercase)
                            .padding(.top, 12).padding(.bottom, 2)
                        ForEach(s.rows) { r in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(verbatim: r.title).font(Theme.mono(11))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(verbatim: r.combo.isEmpty ? "—" : r.combo)
                                    .font(Theme.mono(11, .medium))
                                    .foregroundStyle(r.combo.isEmpty ? Theme.muted : Theme.bone)
                                    .frame(minWidth: 90, alignment: .trailing)
                            }
                            .padding(.vertical, 3)
                            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.void)
        .foregroundStyle(Theme.bone)
        .tint(Theme.state)
    }
}
