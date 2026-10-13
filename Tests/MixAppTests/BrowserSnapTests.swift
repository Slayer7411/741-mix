import Testing
@testable import MixApp

/// Browser-Höhe rastet auf ganze Zeilen: Rahmen + n × Zeilenhöhe, mindestens eine Zeile
@Test func browserHeightSnapsToWholeRows() {
    #expect(BrowserSnap.height(300, chrome: 60, row: 24) == 60 + 10 * 24)
    #expect(BrowserSnap.height(310, chrome: 60, row: 24) == 60 + 10 * 24)   // 250 / 24 = 10,4 -> 10
    #expect(BrowserSnap.height(313, chrome: 60, row: 24) == 60 + 11 * 24)   // 10,5 -> 11
    #expect(BrowserSnap.height(70, chrome: 60, row: 24) == 84)              // mindestens eine Zeile
    #expect(BrowserSnap.height(50, chrome: 60, row: 24) == 50)              // kleiner als der Rahmen: unverändert
    #expect(BrowserSnap.height(300, chrome: 60, row: 0) == 300)
}
