import Foundation

/// Browser-Listen sortieren: gleiche Reihenfolge wie `sorted(using:)` mit `KeyPathComparator` (Text: localizedStandard,
/// gleiche Werte in der Reihenfolge der Quelle), aber schneller. `sorted(using:)` überbrückt bei Text je Vergleich beide
/// Strings nach NSString und rechnet berechnete Werte (Open Key) je Vergleich neu – 14k Tracks nach Titel ~850 ms
/// auf dem Hauptthread. Hier: Textschlüssel einmal je Track als NSString, sortiert werden nur die Indizes (~60 ms).
/// Text-Spalten müssen den Standard-Vergleich haben (`KeyPathComparator(\.title)`, so in Table und Sitzung).
public enum TrackSort {
    public static func sorted(_ tracks: [Track], using order: [KeyPathComparator<Track>]) -> [Track] {
        guard !order.isEmpty, tracks.count > 1 else { return tracks }
        let keys = order.map { Key($0, tracks) }
        let idx = Array(tracks.indices).sorted { i, j in
            for k in keys {
                let r = k.compare(i, j, tracks)
                if r != .orderedSame { return r == .orderedAscending }
            }
            return i < j
        }
        return idx.map { tracks[$0] }
    }

    private enum Key {
        case text([NSString], SortOrder)
        case value(KeyPathComparator<Track>)

        init(_ c: KeyPathComparator<Track>, _ tracks: [Track]) {
            if let kp = c.keyPath as? KeyPath<Track, String> {
                self = .text(tracks.map { NSString(string: $0[keyPath: kp]) }, c.order)
            } else {
                self = .value(c)
            }
        }

        func compare(_ i: Int, _ j: Int, _ tracks: [Track]) -> ComparisonResult {
            switch self {
            case let .text(s, order):
                // absteigend: Ergebnis umdrehen, nicht die Seiten tauschen – wie KeyPathComparator (der Textvergleich ist
                // nicht in jedem Fall symmetrisch, z. B. volle Breite gegen Akzent)
                let r = s[i].localizedStandardCompare(s[j] as String)
                return order == .forward || r == .orderedSame ? r : r == .orderedAscending ? .orderedDescending : .orderedAscending
            case let .value(c):
                return c.compare(tracks[i], tracks[j])
            }
        }
    }
}
