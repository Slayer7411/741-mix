import Foundation

/// Favoriten der Einstellungen (☆ an jeder Zeile, ★ im Bereich FAVORITEN und im Popover der Hauptleiste).
/// Reine Logik: gespeichert wird die Liste der Anker-IDs in Markier-Reihenfolge (`ui.settingsFavorites`)
enum SettingsFavorites {
    /// markiert -> ans Ende; schon markiert -> wieder frei
    static func toggled(_ list: [String], _ id: String) -> [String] {
        list.contains(id) ? list.filter { $0 != id } : list + [id]
    }

    /// gespeicherte Reihenfolge, ohne doppelte und ohne unbekannte (entfernte) IDs
    static func resolved(_ list: [String], known: Set<String>) -> [String] {
        var out: [String] = []
        for id in list where known.contains(id) && !out.contains(id) { out.append(id) }
        return out
    }
}
