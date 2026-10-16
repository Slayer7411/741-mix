import Testing
@testable import MixApp

/// Trenner Decks/Browser: Höhe = Starthöhe − Verschiebung, gerastet, begrenzt – nur aus Start und Verschiebung
@Test func browserDragGrowsMonotonicallyUpAndBack() {
    let snap = { BrowserSnap.height($0, chrome: 60, row: 24) }
    var last = -Double.infinity
    for step in 0...100 {   // nach oben ziehen: Verschiebung wird negativ, Höhe steigt ohne Umkehr
        let h = BrowserDrag.height(start: 300, translation: -Double(step) * 3, snap: snap)
        #expect(h >= last)
        last = h
    }
    #expect(last > 300)
    var back = last
    for step in stride(from: 100, through: 0, by: -1) {   // zurück: nie wieder größer
        let h = BrowserDrag.height(start: 300, translation: -Double(step) * 3, snap: snap)
        #expect(h <= back)
        back = h
    }
    #expect(back == snap(300))   // ohne Verschiebung wieder die gerastete Starthöhe
}

@Test func browserDragDependsOnlyOnStartAndTranslation() {
    let snap = { BrowserSnap.height($0, chrome: 60, row: 24) }
    let first = BrowserDrag.height(start: 300, translation: -57, snap: snap)
    _ = BrowserDrag.height(start: 300, translation: -200, snap: snap)   // Zwischenschritte ändern nichts
    #expect(BrowserDrag.height(start: 300, translation: -57, snap: snap) == first)
    #expect(BrowserDrag.height(start: 300, translation: 0, snap: { $0 }) == 300)
    #expect(BrowserDrag.height(start: 300, translation: -1000, snap: { $0 }) == 900)   // oben begrenzt
    #expect(BrowserDrag.height(start: 300, translation: 1000, snap: { $0 }) == 120)    // unten begrenzt
}
