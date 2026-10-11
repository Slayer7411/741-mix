import Testing
@testable import MixCore

@Test func listChangeSmallOrLarge() {
    struct R: Identifiable { var id: Int; var v = 0 }
    let base = (0..<1000).map { R(id: $0) }
    #expect(ListChange.isSmall(from: base, to: base, limit: 4))
    // gleiche IDs, neue Werte
    #expect(ListChange.isSmall(from: base, to: base.map { R(id: $0.id, v: 1) }, limit: 0))
    // einer dazu / weg / ersetzt, irgendwo
    var add = base; add.insert(R(id: -1), at: 500)
    #expect(ListChange.isSmall(from: base, to: add, limit: 1))
    var del = base; del.remove(at: 0)
    #expect(ListChange.isSmall(from: base, to: del, limit: 1))
    #expect(ListChange.isSmall(from: base, to: base + [R(id: 1000)], limit: 1))
    var rep = base; rep[999] = R(id: -2)
    #expect(ListChange.isSmall(from: base, to: rep, limit: 2) && !ListChange.isSmall(from: base, to: rep, limit: 1))
    // weit auseinander: der Bereich dazwischen zählt
    var two = base; two.remove(at: 900); two.remove(at: 10)
    #expect(!ListChange.isSmall(from: base, to: two, limit: 64))
    // Filter, andere Sortierung, leer
    #expect(!ListChange.isSmall(from: base, to: base.filter { $0.id % 2 == 0 }, limit: 64))
    #expect(!ListChange.isSmall(from: base, to: base.reversed(), limit: 64))
    #expect(ListChange.isSmall(from: [R](), to: Array(base.prefix(3)), limit: 3))
    #expect(!ListChange.isSmall(from: [R](), to: base, limit: 64))
}
