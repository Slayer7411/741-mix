import Testing
@testable import MixCore

@Test func zoomStepsUpDown() {
    #expect(ZoomSteps.larger(than: 1) == 1.1)
    #expect(ZoomSteps.larger(than: 1.1) == 1.25)
    #expect(ZoomSteps.larger(than: 1.75) == 2)
    #expect(ZoomSteps.larger(than: 2) == 2)
    #expect(ZoomSteps.smaller(than: 1) == 0.9)
    #expect(ZoomSteps.smaller(than: 0.67) == 0.5)
    #expect(ZoomSteps.smaller(than: 0.5) == 0.5)
    // zwischen zwei Stufen: zur nächsten Stufe
    #expect(ZoomSteps.larger(than: 1.38) == 1.5)
    #expect(ZoomSteps.smaller(than: 1.38) == 1.25)
}

@Test func zoomStepsLimit() {
    // Bildschirm erlaubt höchstens 138 %: 125 -> 138, dann bleibt es
    #expect(ZoomSteps.larger(than: 1.25, limit: 1.38) == 1.38)
    #expect(ZoomSteps.larger(than: 1.38, limit: 1.38) == 1.38)
    // Grenze unter dem aktuellen Wert: nicht kleiner werden
    #expect(ZoomSteps.larger(than: 1.5, limit: 1.2) == 1.5)
}

@Test func zoomStepsClampAndText() {
    #expect(ZoomSteps.clamp(3) == 2)
    #expect(ZoomSteps.clamp(0.1) == 0.5)
    #expect(ZoomSteps.clamp(.nan) == 1)
    #expect(ZoomSteps.clamp(1.2549) == 1.25)
    #expect(ZoomSteps.percent(1.25) == "125 %")
    #expect(ZoomSteps.percent(0.67) == "67 %")
}
