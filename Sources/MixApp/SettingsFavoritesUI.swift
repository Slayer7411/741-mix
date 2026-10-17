import SwiftUI
import MixCore

/// ☆ / ★ an jeder Einstellung (`settingsAnchor`): gedämpft, bei Hover oder wenn markiert deutlich
struct SettingsStar: View {
    let id: String
    var hovered: Bool
    @Environment(MixModel.self) private var mix: MixModel?

    var body: some View {
        let on = mix?.prefs.ui.settingsFavorites.contains(id) ?? false
        Button {
            guard let mix else { return }
            mix.prefs.ui.settingsFavorites = SettingsFavorites.toggled(mix.prefs.ui.settingsFavorites, id)
        } label: {
            Text(verbatim: on ? "★" : "☆")
                .font(Theme.mono(12))
                .foregroundStyle(on ? Theme.state : Theme.bone)
                .frame(width: 16, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(on ? 1 : (hovered ? 0.7 : 0.22))
        .help(on ? "Aus den Favoriten entfernen" : "Zu den Favoriten")
        .accessibilityLabel(on ? "Favorit entfernen" : "Als Favorit markieren")
    }
}

/// Die Favoriten in der Reihenfolge, in der sie markiert wurden: jede Zeile als echtes Bedienelement ihres Bereichs
/// (derselbe Code, nur die Zeile dieses Ankers sichtbar). Genutzt im Bereich FAVORITEN und im Popover der Hauptleiste
struct SettingsFavoritesList: View {
    let ids: [String]

    var body: some View {
        ForEach(ids, id: \.self) { id in
            if let entry = SettingsIndex.entries.first(where: { $0.anchor == id }),
               let tab = SettingsView.tabs.first(where: { $0.id == entry.tab }) {
                tab.content().environment(\.settingsFilter, [id])
            }
        }
    }
}

/// Kopf „ERWEITERT“ am Seitenende (zugeklappt): ein Sprung der Suche auf einen Eintrag darin klappt ihn auf.
/// Die Abschnitte selbst stehen danach im Bereich unter `open`
struct SettingsAdvancedHeader: View {
    @Binding var open: Bool

    var body: some View {
        Section {
            EmptyView()
        } header: {
            Button { open.toggle() } label: {
                HStack(spacing: 8) {
                    Text(verbatim: open ? "▾" : "▸")
                    Text("Erweitert")
                }
            }
            .buttonStyle(.plain)
        }
    }
}

/// Auf der Form (nicht am Kopf): ein Sprung der Suche auf einen Eintrag in ERWEITERT dieses Bereichs klappt ihn auf.
/// Modifier am Section-Kopf gingen verloren, weil der FormStyle die Abschnitte zerlegt
struct SettingsAdvancedReveal: ViewModifier {
    let tab: String
    @Binding var open: Bool
    @Environment(\.settingsJump) private var jump

    func body(content: Content) -> some View {
        content
            .onAppear { reveal() }
            .onChange(of: jump) { reveal() }
    }

    private func reveal() {
        if let j = jump, j.tab == tab, j.advanced { open = true }
    }
}

extension View {
    func settingsAdvancedReveal(_ tab: String, open: Binding<Bool>) -> some View {
        modifier(SettingsAdvancedReveal(tab: tab, open: open))
    }
}

/// Popover der Hauptleiste (★): dieselben Favoriten wie im Bereich FAVORITEN, ohne ⌘,. Esc schließt
struct FavoritesPopover: View {
    let ids: [String]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            SettingsPage { SettingsFavoritesList(ids: ids) }
        }
        .frame(width: 470)
        .frame(maxHeight: 520)
        .background(Theme.chitin)
        .preferredColorScheme(.dark)
        .onExitCommand { dismiss() }
    }
}
