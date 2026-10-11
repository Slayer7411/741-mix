import Foundation
import Testing
@testable import MixCore

@Test func tagSplit() {
    let c2 = "K tief kurz · B sub leicht roll · H off » BASIS"
    #expect(Tags.split(c2, separators: "·") == ["K tief kurz", "B sub leicht roll", "H off » BASIS"])
    #expect(Tags.split(c2, separators: "·»") == ["K tief kurz", "B sub leicht roll", "H off", "BASIS"])
    // leer = Leerzeichen
    #expect(Tags.split("a  b\tc", separators: "") == ["a", "b\tc"])
    #expect(Tags.split(" a b ", separators: " ") == ["a", "b"])
    // leere Stücke fallen weg
    #expect(Tags.split("·· a ·  · b ··", separators: "·") == ["a", "b"])
    #expect(Tags.split("", separators: "·").isEmpty)
}

@Test func tagKeyFoldsCaseAccentsSpace() {
    #expect(Tags.key("Kühl") == Tags.key("KUHL"))
    #expect(Tags.key("Café  Noir") == "cafe noir")
    #expect(Tags.key("BASIS") != Tags.key("BASS"))
}

@Test func tagFilterIncludeExclude() {
    let seps = "·"
    let a = "Kühl · dunkel · BASIS", b = "kuhl · hell", c = "dunkel · hell"
    var f = TagFilter()
    #expect(f.isEmpty)
    #expect([a, b, c].allSatisfy { f.matches($0, separators: seps) })

    f = f.toggling("KÜHL", exclude: false)
    #expect(f.include == ["KÜHL"])
    #expect(f.matches(a, separators: seps) && f.matches(b, separators: seps) && !f.matches(c, separators: seps))
    #expect(f.mark("kuhl") == .include)

    // alle eingeschlossenen müssen passen
    f = f.toggling("dunkel", exclude: false)
    #expect(f.matches(a, separators: seps) && !f.matches(b, separators: seps))

    // ausgeschlossen: keiner darf vorkommen
    f = TagFilter().toggling("hell", exclude: true)
    #expect(f.mark("HELL") == .exclude)
    #expect(f.matches(a, separators: seps) && !f.matches(b, separators: seps) && !f.matches(c, separators: seps))

    // ganze Tags, keine Teilstücke
    #expect(TagFilter(include: ["dunk"]).matches(a, separators: seps) == false)
}

@Test func tagFilterToggle() {
    var f = TagFilter()
    f = f.toggling("A", exclude: false)
    #expect(f.include == ["A"] && f.exclude.isEmpty)
    // Klick auf gewählten Tag (andere Schreibweise) löst ihn
    f = f.toggling("a", exclude: false)
    #expect(f.isEmpty)
    // ⌥-Klick: ausschließen, nochmal: lösen
    f = f.toggling("A", exclude: true)
    #expect(f.exclude == ["A"] && f.include.isEmpty)
    f = f.toggling("A", exclude: true)
    #expect(f.isEmpty)
    // ausgeschlossen -> Klick schließt ein, eingeschlossen -> ⌥-Klick schließt aus
    f = TagFilter(exclude: ["A"]).toggling("A", exclude: false)
    #expect(f.include == ["A"] && f.exclude.isEmpty)
    f = f.toggling("A", exclude: true)
    #expect(f.exclude == ["A"] && f.include.isEmpty)
    #expect(TagFilter(include: ["A", "B"], exclude: ["C"]).removing("c") == TagFilter(include: ["A", "B"]))
}

@Test func tagIndexCachesPerSeparators() {
    let idx = TagIndex()
    let e = idx.entry("Kühl · Dunkel", separators: "·")
    #expect(e.tags == ["Kühl", "Dunkel"])
    #expect(e.keys == ["kuhl", "dunkel"])
    _ = idx.entry("Kühl · Dunkel", separators: "·")
    #expect(idx.count == 1)
    #expect(idx.entry("Kühl · Dunkel", separators: " ").tags == ["Kühl", "·", "Dunkel"])
    #expect(idx.count == 1)
}

@Test func favoriteFilterKeepsExcludedTags() throws {
    #expect(BrowserFavorite.filter(tags: [], excluded: ["hell"], roles: [], search: "") != nil)
    let f = try #require(BrowserFavorite.filter(tags: ["dunkel"], excluded: ["hell", "BASIS"], roles: [], search: ""))
    #expect(f.name == "dunkel + !BASIS + !hell")
    #expect(f.excludedTags == ["BASIS", "hell"])
    #expect(f.matchesFilter(tags: ["dunkel"], excluded: ["hell", "BASIS"], roles: [], search: ""))
    #expect(!f.matchesFilter(tags: ["dunkel"], roles: [], search: ""))
    // ohne ausgeschlossene Tags: Schlüssel fehlt, ältere Sitzungen laden weiter
    let g = try #require(BrowserFavorite.filter(tags: ["dunkel"], roles: [], search: ""))
    #expect(g.excludedTags == nil)
    let data = try JSONEncoder().encode([f, g])
    #expect(try JSONDecoder().decode([BrowserFavorite].self, from: data) == [f, g])
    #expect(!String(decoding: try JSONEncoder().encode(g), as: UTF8.self).contains("excludedTags"))
}
