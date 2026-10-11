import Foundation

/// Größe einer Listenänderung ohne Diff: gleichen Anfang und gleiches Ende (gleiche IDs in gleicher Reihenfolge)
/// abziehen, was dazwischen bleibt, ist eine obere Grenze für Einfügungen + Löschungen.
public enum ListChange {
    /// höchstens `limit` Einträge zwischen gleichem Anfang und gleichem Ende (geänderte Werte bei gleicher ID zählen nicht)
    public static func isSmall<T: Identifiable>(from old: [T], to new: [T], limit: Int) -> Bool {
        guard abs(old.count - new.count) <= limit else { return false }
        let n = min(old.count, new.count)
        var head = 0
        while head < n, old[head].id == new[head].id { head += 1 }
        var tail = 0
        while tail < n - head, old[old.count - 1 - tail].id == new[new.count - 1 - tail].id { tail += 1 }
        return (old.count - head - tail) + (new.count - head - tail) <= limit
    }
}
