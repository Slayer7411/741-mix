import Foundation
import Testing
@testable import MixApp

// Wellenform greifen: Ziehen in Sekunden und Geschwindigkeit (ohne Zustand), Zoom über die Sekunden je Seite

@Test func waveGrabDragMovesContentWithTheHandAtZoom() {
    // 4 s je Seite auf 800 pt: 0,01 s je Punkt
    #expect(abs(WaveGrabMath.secPerPt(span: 4, width: 800) - 0.01) < 1e-12)
    // nach rechts ziehen = Inhalt folgt der Hand = zurück in der Zeit
    #expect(abs(WaveGrabMath.seconds(dragPx: 100, span: 4, width: 800) + 1) < 1e-12)
    #expect(abs(WaveGrabMath.seconds(dragPx: -100, span: 4, width: 800) - 1) < 1e-12)
    // Zoom: doppelt so viele Sekunden je Seite -> derselbe Zug ist doppelt so weit in der Zeit
    #expect(abs(WaveGrabMath.seconds(dragPx: 100, span: 8, width: 800) + 2) < 1e-12)
    // eine ganze Breite zieht 2 × span, unabhängig von der Breite
    #expect(abs(WaveGrabMath.seconds(dragPx: 1200, span: 4, width: 1200) + 8) < 1e-9)
    #expect(WaveGrabMath.secPerPt(span: 4, width: 0) > 0)   // keine Division durch 0
}

@Test func waveGrabSpeedIsTrackSecondsPerSecondForwardPositive() {
    // nach links ziehen = vorwärts: positiv; 5 pt in 0,1 s bei 0,01 s je Punkt = 0,5 Track-Sekunden je Sekunde
    #expect(abs(WaveGrabMath.speed(dragPx: -5, dt: 0.1, span: 4, width: 800) - 0.5) < 1e-9)
    #expect(abs(WaveGrabMath.speed(dragPx: 5, dt: 0.1, span: 4, width: 800) + 0.5) < 1e-9)
    // schneller Zug wird auf ±1 begrenzt, Stillstand und dt 0 ergeben 0
    #expect(WaveGrabMath.speed(dragPx: -500, dt: 0.1, span: 4, width: 800) == 1)
    #expect(WaveGrabMath.speed(dragPx: 0, dt: 0.1, span: 4, width: 800) == 0)
    #expect(WaveGrabMath.speed(dragPx: -5, dt: 0, span: 4, width: 800) == 0)
}

@Test func waveGrabSpeedBecomesBendAmountClamped() {
    // Bend −1…1 wie der Pitch-Bend-Eingang (× Bend-Stärke der Einstellung)
    #expect(WaveGrabMath.bend(speed: 0) == 0)
    #expect(WaveGrabMath.bend(speed: 0.4) == 0.4)
    #expect(WaveGrabMath.bend(speed: -0.4) == -0.4)
    #expect(WaveGrabMath.bend(speed: 3) == 1)
    #expect(WaveGrabMath.bend(speed: -3) == -1)
    // Zug mit der Spielgeschwindigkeit (1 s je s) ergibt den vollen Bend
    #expect(WaveGrabMath.bend(speed: WaveGrabMath.speed(dragPx: -10, dt: 0.1, span: 4, width: 800)) == 1)
}

@MainActor @Test func waveGrabDefaultsAndRawValues() {
    #expect(UIPrefs().waveGrab == .jog)
    #expect(WaveGrab.allCases.map(\.rawValue) == ["aus", "Vinyl", "Jog"])
    let p = AppPrefs.decode(Data(#"{"ui": {"waveGrab": "Vinyl"}}"#.utf8))
    #expect(p.ui.waveGrab == .vinyl)
}
