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

/// Umschalter der Unterseite ERWEITERT: an = die Unterseite des Bereichs (sonst die Hauptseite)
extension EnvironmentValues {
    @Entry var settingsAdvancedPage: Bool = false
    @Entry var settingsSetAdvanced: ((String, Bool) -> Void)? = nil
}

/// Zeile „Erweitert ›“ am Ende der Hauptseite: wechselt auf die Unterseite des Bereichs
struct SettingsAdvancedLink: View {
    let tab: String
    @Environment(\.settingsSetAdvanced) private var setAdvanced

    var body: some View {
        Section {
            EmptyView()
        } header: {
            Button { setAdvanced?(tab, true) } label: {
                HStack(spacing: 8) {
                    Text("Erweitert")
                    Spacer(minLength: 0)
                    Text(verbatim: "›")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
        }
    }
}

/// Kopf der Unterseite ERWEITERT: „‹ BEREICH · ERWEITERT“, zurück zur Hauptseite
struct SettingsAdvancedBack: View {
    let tab: String
    @Environment(\.settingsSetAdvanced) private var setAdvanced

    var body: some View {
        Section {
            EmptyView()
        } header: {
            Button { setAdvanced?(tab, false) } label: {
                HStack(spacing: 6) {
                    Text(verbatim: "‹ " + tab + " · ")
                    Text("Erweitert")
                }
            }
            .buttonStyle(.plain)
        }
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
