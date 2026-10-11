import Testing
@testable import MixEngine

/// Zustand der Ausgabe gegenüber dem Gerät (ohne CoreAudio): Gerät weg -> warten -> zurück, Rate, Puffer, Ruhezustand

private func running(_ uid: String = "usb-1", rate: Double = 96000, buffer: UInt32 = 512) -> OutputWatch {
    var w = OutputWatch()
    _ = w.handle(.started(uid: uid, rate: rate, buffer: buffer))
    return w
}

@Test func deviceLostWaitsForSameDeviceAndReconnects() {
    var w = running()
    #expect(w.phase == .running && w.wanted)
    #expect(w.handle(.alive(false)) == .stop)
    #expect(w.phase == .waiting && w.wanted && w.uid == "usb-1")
    // zweite Meldung (Geräteliste) ändert nichts
    #expect(w.handle(.present(false)) == .none)
    #expect(w.handle(.present(true)) == .reopen)
    // Gerät noch nicht bereit: weiter warten
    #expect(w.handle(.startFailed) == .none)
    #expect(w.phase == .waiting)
    #expect(w.handle(.present(true)) == .reopen)
    #expect(w.handle(.started(uid: "usb-1", rate: 96000, buffer: 512)) == .none)
    #expect(w.phase == .running && w.reconnects == 1)
}

@Test func deviceListRemovalCountsAsLost() {
    var w = running()
    #expect(w.handle(.present(false)) == .stop)
    #expect(w.handle(.alive(false)) == .none)
    #expect(w.handle(.alive(true)) == .reopen)
}

@Test func rateChangeReopensWithoutSettingRate() {
    var w = running(rate: 96000)
    #expect(w.handle(.rate(96000)) == .none)   // gleiche Rate (Meldung doppelt)
    #expect(w.handle(.rate(48000)) == .reopen)
    #expect(w.rate == 48000 && w.rateChanges == 1)
    #expect(w.handle(.started(uid: "usb-1", rate: 48000, buffer: 512)) == .none)
    #expect(w.phase == .running && w.reconnects == 0)
    // Neustart scheitert: warten statt aufgeben
    #expect(w.handle(.rate(44100)) == .reopen)
    #expect(w.handle(.startFailed) == .none)
    #expect(w.phase == .waiting)
    #expect(w.handle(.present(true)) == .reopen)
}

@Test func bufferChangeOnlyRereads() {
    var w = running(buffer: 512)
    #expect(w.handle(.buffer(512)) == .none)
    #expect(w.handle(.buffer(256)) == .reread)
    #expect(w.buffer == 256 && w.bufferChanges == 1 && w.phase == .running)
}

@Test func sleepStopsAndWakeReopens() {
    var w = running()
    #expect(w.handle(.willSleep) == .stop)
    #expect(w.phase == .sleeping && !w.wanted)
    #expect(w.handle(.alive(false)) == .none)
    #expect(w.handle(.didWake) == .reopen)
    #expect(w.phase == .waiting)
    #expect(w.handle(.started(uid: "usb-1", rate: 96000, buffer: 512)) == .none)
    #expect(w.phase == .running && w.reconnects == 1)
    // auch während des Wartens auf das Gerät
    _ = w.handle(.alive(false))
    #expect(w.handle(.willSleep) == .stop)
    #expect(w.handle(.didWake) == .reopen)
}

@Test func manualStopAndFailedManualStartDoNotWait() {
    var w = running()
    #expect(w.handle(.stopped) == .none)
    #expect(w.phase == .stopped && !w.wanted)
    #expect(w.handle(.alive(false)) == .none)
    #expect(w.handle(.present(true)) == .none)
    #expect(w.handle(.didWake) == .none)
    #expect(w.handle(.startFailed) == .none)
    #expect(w.phase == .stopped)
}

@Test func otherDeviceStartIsNoReconnect() {
    var w = running("usb-1")
    _ = w.handle(.alive(false))
    _ = w.handle(.started(uid: "builtin", rate: 48000, buffer: 512))
    #expect(w.phase == .running && w.uid == "builtin" && w.reconnects == 0)
}
