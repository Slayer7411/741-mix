import Foundation
import Testing
@testable import MixCore

/// Tracks mit schwierigen Texten: Zahlen, Groß-/Kleinschreibung, Akzente (zusammengesetzt / zerlegt), volle Breite,
/// leer, doppelte Werte (Reihenfolge der Quelle muss bleiben)
private func tricky() -> [Track] {
    let words = ["Track 10", "track 2", "Track 2", "", "Émile", "E\u{301}mile", "Emile", "eric", "ＡＢＣ", "abc", "ABC",
                 "Zoë", "zoe", "Ångström", "angstrom", "1999", "200", "Ä", "a", "_under", "-dash", "(paren)", "Øre", "ß", "ss"]
    var out: [Track] = []
    for (i, w) in words.enumerated() {
        for k in 0..<3 {
            var t = Track(key: "k\(i)-\(k)", path: "/m/\(i)-\(k).mp3")
            t.artist = w
            t.title = words[(i * 7 + k) % words.count]
            t.comment2 = k == 1 ? w : ""
            t.label = words[(i + k * 5) % words.count]
            t.bpm = Double((i * 13 + k) % 9) + 120
            t.musicalKey = (i + k) % 25 - 1
            t.playCount = k
            out.append(t)
        }
    }
    return out
}

@Test func trackSortMatchesKeyPathComparator() {
    let tracks = tricky()
    let text: [(String, (SortOrder) -> KeyPathComparator<Track>)] = [
        ("artist", { KeyPathComparator(\.artist, order: $0) }), ("title", { KeyPathComparator(\.title, order: $0) }),
        ("comment2", { KeyPathComparator(\.comment2, order: $0) }), ("label", { KeyPathComparator(\.label, order: $0) }),
        ("openKey", { KeyPathComparator(\.openKey, order: $0) }), ("remixer", { KeyPathComparator(\.remixer, order: $0) }),
    ]
    for (name, make) in text {
        for order in [SortOrder.forward, .reverse] {
            let c = [make(order)]
            let fast = TrackSort.sorted(tracks, using: c).map(\.key), plain = tracks.sorted(using: c).map(\.key)
            #expect(fast == plain, "\(name) \(order == .forward ? "auf" : "ab")")
        }
    }
    let values: [[KeyPathComparator<Track>]] = [[KeyPathComparator(\.bpm)], [KeyPathComparator(\.playCount, order: .reverse)],
                                                [KeyPathComparator(\.bpm), KeyPathComparator(\.artist, order: .reverse)],
                                                [KeyPathComparator(\.label), KeyPathComparator(\.playCount)]]
    for c in values {
        let fast = TrackSort.sorted(tracks, using: c).map(\.key), plain = tracks.sorted(using: c).map(\.key)
        #expect(fast == plain)
    }
}

@Test func trackSortKeepsSourceOrderAndEdgeCases() {
    let tracks = tricky()
    #expect(TrackSort.sorted(tracks, using: []).map(\.key) == tracks.map(\.key))
    #expect(TrackSort.sorted([], using: [KeyPathComparator(\.artist)]).isEmpty)
    // gleiche Werte: Reihenfolge der Quelle, auch absteigend
    let same = tracks.filter { $0.artist == "abc" }
    #expect(same.count == 3)
    let sorted = TrackSort.sorted(tracks, using: [KeyPathComparator(\.artist, order: .reverse)]).filter { $0.artist == "abc" }
    #expect(sorted.map(\.key) == same.map(\.key))
}
