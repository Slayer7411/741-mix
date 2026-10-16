import Foundation

/// Doppelte Einträge der Collection: gleiche Datei (Pfad ohne Groß/klein, Unicode-Form) oder gleicher Artist + Titel
/// mit Länge ±1 s und gleicher Dateigröße. Zusammenführen: ein Eintrag (Behalter) übernimmt die anderen, die anderen
/// fallen aus der Collection. Rein: kein Dateizugriff, kein Schreiben – geschrieben wird über `job(for:)`.
public enum CollectionMerge {
    /// Toleranz für gleiche Positionen (ms)
    public static let positionTolerance = 5.0

    /// Gruppe gleicher Einträge: Schlüssel sortiert, Grund für die Anzeige
    public struct Group: Sendable, Hashable {
        public var keys: [String]
        public var reason: String
        public init(keys: [String], reason: String) { self.keys = keys; self.reason = reason }
    }

    /// Plan einer Gruppe: was der Behalter bekommt, was entfällt. `result` ist der Behalter nach dem Zusammenführen
    /// (Vorschau); nur geänderte Felder stehen in den übrigen Teilen (nil = unverändert).
    public struct Plan: Sendable {
        public var keeper: Track
        public var removed: [Track]
        public var result: Track
        /// geänderte Textfelder: comment2 (Tags), comment, rating
        public var changes: [TrackField: String]
        public var color: Int?
        public var plays: Int?
        /// Grid des Behalters, wenn er keins hat und ein anderer eines hat
        public var grid: TrackEdit?
        /// vollständige Hotcue-Liste (Slots 0–7, ohne Grid), nur wenn sie sich ändert
        public var hotcues: [Cue]?
        /// neue Memory-Cues (Hotcue -1): Loops und Cues, deren Slot schon anders belegt ist
        public var memoryCues: [Cue]
        /// entfallene Schlüssel -> Behalter
        public var redirects: [String: String]
        /// Zeilen für die Vorschau
        public var notes: [String]
    }

    // MARK: - Gruppen

    /// Gruppen doppelter Einträge (nur Gruppen mit mindestens zwei Einträgen), deterministisch sortiert
    public static func groups(_ tracks: [Track]) -> [Group] {
        var parent = Array(tracks.indices)
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        // (a, b, gleiche Datei?)
        var pairs: [(Int, Int, Bool)] = []
        var byPath: [String: Int] = [:]
        for (i, t) in tracks.enumerated() where !t.path.isEmpty {
            let m = MusicFolder.match(t.path)
            if let f = byPath[m] { pairs.append((f, i, true)) } else { byPath[m] = i }
        }
        var byName: [String: [Int]] = [:]
        for (i, t) in tracks.enumerated() where t.fileSizeKB > 0 {
            let a = ConsistencyCheck.normalize(t.artist), ti = ConsistencyCheck.titleCore(t.title)   // ohne Klammerzusätze
            guard !a.isEmpty, !ti.isEmpty else { continue }
            byName[a + "|" + ti, default: []].append(i)
        }
        for list in byName.values where list.count > 1 {
            for x in list.indices {
                for y in list.indices where y > x {
                    let a = tracks[list[x]], b = tracks[list[y]]
                    if abs(a.duration - b.duration) <= 1, a.fileSizeKB == b.fileSizeKB { pairs.append((list[x], list[y], false)) }
                }
            }
        }
        for (a, b, _) in pairs {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
        }
        var members: [Int: [Int]] = [:]
        for i in tracks.indices { members[find(i), default: []].append(i) }
        var samePath = Set<Int>()
        for (a, _, same) in pairs where same { samePath.insert(find(a)) }
        var out: [Group] = []
        for (root, list) in members where list.count > 1 {
            let keys = list.map { tracks[$0].key }.sorted()
            let reason = samePath.contains(root) ? "same file path" : "same artist + title, length ±1 s, same size"
            out.append(Group(keys: keys, reason: reason))
        }
        return out.sorted { ($0.keys.first ?? "") < ($1.keys.first ?? "") }
    }

    // MARK: - Behalter

    /// Behalter einer Gruppe: Datei liegt lokal vor > höhere Bitrate > analysiert > mehr Cues > neuerer Import;
    /// bei Gleichstand der kleinere Schlüssel. nil für eine leere Gruppe
    public static func keeper(_ group: [Track]) -> Track? {
        group.min { a, b in
            let sa = score(a), sb = score(b)
            if sa != sb { return sb.lexicographicallyPrecedes(sa) }
            return a.key < b.key
        }
    }

    /// Rangfolge der Einträge (absteigend): zuerst der Behalter, dann die übrigen in ihrer Reihenfolge
    public static func ranked(_ group: [Track]) -> [Track] {
        group.sorted { a, b in
            let sa = score(a), sb = score(b)
            if sa != sb { return sb.lexicographicallyPrecedes(sa) }
            return a.key < b.key
        }
    }

    private static func score(_ t: Track) -> [Double] {
        [t.fileExists ? 1 : 0, Double(t.bitrate), t.analyzed ? 1 : 0, Double(t.cues.count), t.importSort.timeIntervalSince1970]
    }

    // MARK: - Zusammenführen

    /// Plan für eine Gruppe. `separators`: Trennzeichen der Tags (Einstellung „Tags trennen mit“)
    public static func plan(keeper k: Track, others: [Track], separators: String) -> Plan {
        var notes: [String] = []
        var r = k
        var changes: [TrackField: String] = [:]

        // Tags: Vereinigung in Reihenfolge, der Behalter zuerst; Trennzeichen wie in den Einstellungen
        let sep = separators.first.map(String.init) ?? " "
        var tags = Tags.split(k.comment2, separators: separators)
        var seen = Set(tags.map(Tags.key))
        var addedTags = 0
        for o in others {
            for t in Tags.split(o.comment2, separators: separators) where seen.insert(Tags.key(t)).inserted {
                tags.append(t)
                addedTags += 1
            }
        }
        let tagText = tags.joined(separator: sep)
        if addedTags > 0 {
            changes[.comment2] = tagText
            r.comment2 = tagText
            notes.append("tags +\(addedTags)")
        }

        // Kommentar: nur wenn der Behalter keinen hat
        if k.comment.isEmpty, let c = others.first(where: { !$0.comment.isEmpty })?.comment {
            changes[.comment] = c
            r.comment = c
            notes.append("comment")
        }

        // Bewertung: höchste
        let best = ([k] + others).map(\.rating).max() ?? 0
        if best > k.rating {
            changes[.rating] = String(best)
            r.rating = best
            notes.append("rating \(k.rating) → \(best)")
        }

        // Abspielungen: Summe
        let sum = ([k] + others).reduce(0) { $0 + $1.playCount }
        var plays: Int?
        if sum != k.playCount {
            plays = sum
            r.playCount = sum
            notes.append("plays \(k.playCount) → \(sum)")
        }

        // Farbe: wenn der Behalter keine hat
        var color: Int?
        if k.color == 0, let c = others.first(where: { $0.color != 0 })?.color {
            color = c
            r.color = c
            notes.append("color \(c)")
        }

        // Grid: des Behalters, sonst das erste eines anderen
        var grid: TrackEdit?
        if k.gridAnchorMs == nil, let o = others.first(where: { $0.gridAnchorMs != nil }), let anchor = o.gridAnchorMs {
            grid = TrackEdit(bpm: o.bpm > 0 ? o.bpm : nil, gridAnchorMs: anchor)
            if r.bpm <= 0, o.bpm > 0 { r.bpm = o.bpm }
            notes.append("grid from " + String(format: "%.1f s", anchor / 1000))
        }

        // Cues: Hotcues der anderen zuerst in freie Slots, Konflikte und übrige als Memory-Cues; gleiche Stelle
        // (±5 ms, Loops mit gleicher Länge) nur einmal
        let tol = positionTolerance
        func sameSpot(_ a: Cue, _ b: Cue) -> Bool {
            a.kind == b.kind && abs(a.startMs - b.startMs) <= tol && (a.kind != .loop || abs(a.lengthMs - b.lengthMs) <= tol)
        }
        let base = k.cues.count
        var cues = k.cues
        let candidates = others.flatMap { o in o.cues.filter { $0.kind != .grid && $0.kind != .load } }
        var conflicts: [Cue] = []
        for c in candidates where c.hotcue >= 0 {
            if cues.contains(where: { sameSpot($0, c) }) { continue }
            if cues.contains(where: { $0.hotcue == c.hotcue }) { conflicts.append(c) } else { cues.append(c) }
        }
        for c in conflicts where !cues.contains(where: { sameSpot($0, c) }) {
            cues.append(Cue(name: c.name, kind: c.kind, startMs: c.startMs, lengthMs: c.lengthMs, hotcue: -1))
        }
        for c in candidates where c.hotcue < 0 && !cues.contains(where: { sameSpot($0, c) }) {
            cues.append(c)
        }
        let added = Array(cues[base...])
        let memory = added.filter { $0.hotcue < 0 }
        let hotNow = k.cues.filter { $0.hotcue >= 0 && $0.kind != .grid }.sorted { $0.hotcue < $1.hotcue }
        let hotAll = cues.filter { $0.hotcue >= 0 && $0.kind != .grid }.sorted { $0.hotcue < $1.hotcue }
        let hotChanged = hotAll != hotNow
        if !added.isEmpty {
            let hotAdded = added.filter { $0.hotcue >= 0 }.count
            notes.append("hotcues +\(hotAdded) · memory +\(memory.count)")
        }
        // Grid-Marker vorn (des Behalters, oder der übernommene), dann die übrigen Cues
        let gridCue = grid?.gridAnchorMs.map { Cue(name: "Grid", kind: .grid, startMs: $0, lengthMs: 0, hotcue: -1) }
            ?? k.cues.first { $0.kind == .grid }
        r.cues = (gridCue.map { [$0] } ?? []) + cues.filter { $0.kind != .grid }

        return Plan(keeper: k, removed: others, result: r, changes: changes, color: color, plays: plays, grid: grid,
                    hotcues: hotChanged ? hotAll : nil, memoryCues: memory,
                    redirects: Dictionary(others.map { ($0.key, k.key) }, uniquingKeysWith: { a, _ in a }), notes: notes)
    }

    // MARK: - Schreibauftrag

    /// Ein Schreibvorgang für alle Pläne: Behalter bekommt Tags, Kommentar, Bewertung, Abspielungen, Farbe, Grid,
    /// Hotcues und Memory-Cues; die übrigen Einträge fallen aus der Collection, Verweise in den Playlists zeigen auf
    /// den Behalter
    public static func job(for plans: [Plan]) -> CollectionWriter.Job {
        var job = CollectionWriter.Job()
        for p in plans {
            let k = p.keeper.key
            if !p.changes.isEmpty { job.changes[k] = p.changes }
            var info: [String: String] = [:]
            if let c = p.color { info["COLOR"] = String(c) }
            if let n = p.plays { info["PLAYCOUNT"] = String(n) }
            if !info.isEmpty { job.info[k] = info }
            if p.grid != nil || p.hotcues != nil {
                var e = p.grid ?? TrackEdit()
                e.hotcues = p.hotcues
                job.cues[k] = e
            }
            if !p.memoryCues.isEmpty { job.cueAdds[k] = p.memoryCues }
            for t in p.removed { job.remove.insert(t.key) }
            job.redirects.merge(p.redirects) { a, _ in a }
        }
        return job
    }

    /// Schreibauftrag nur zum Entfernen (ohne Umbiegen): Einträge weg, Playlist-Verweise weg
    public static func removalJob(keys: [String]) -> CollectionWriter.Job {
        var job = CollectionWriter.Job()
        job.remove = Set(keys)
        return job
    }
}
