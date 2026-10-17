import Foundation
import Testing
@testable import MixCore

// MIDI-Clock: Takte je Beat, Transport (Start/Continue/Stop), Song Position, Einrasten nach Sprüngen, Tempo.

private func isClock(_ e: MIDIClock.Event) -> Bool { e.message.bytes == [MIDIClock.clockByte] }

@Test func clockIsTwentyFourTicksPerBeat() {
    #expect(MIDIClock.ticksPerBeat == 24)
    #expect(MIDIClock.beat(ofTick: 24) == 1.0)
    #expect(MIDIClock.beat(ofTick: 1) == 1.0 / 24)
    // erster Takt zu einer Zeit: aufgerundet, Toleranz gegen Rundungsfehler (1,0 Beat ist genau Takt 24)
    #expect(MIDIClock.tick(atOrAfter: 1.0) == 24)
    #expect(MIDIClock.tick(atOrAfter: 1.00000001) == 24)
    #expect(MIDIClock.tick(atOrAfter: 1.01) == 25)
    #expect(MIDIClock.tick(atOrAfter: 0) == 0)
}

@Test func startSendsStartThenTicksOnTheGrid() {
    var p = MIDIClockPlanner(songPosition: false)
    let ev = p.plan(beatNow: 0, playing: true, ahead: 1.0)
    #expect(ev.first?.message.bytes == [MIDIClock.startByte])
    let ticks = ev.filter(isClock)
    // Beat 0 bis knapp unter 1: 24 Takte, Abstand genau 1/24 Beat
    #expect(ticks.count == 24)
    for (i, t) in ticks.enumerated() { #expect(abs(t.beat - Double(i) / 24) < 1e-12) }
    #expect(p.running)
}

@Test func tickWindowsDoNotOverlapOrSkip() {
    var p = MIDIClockPlanner(songPosition: false)
    var beats: [Double] = []
    // Takt der Queue: 10 ms bei 120 BPM = 0,02 Beat, Vorlauf 25 ms = 0,05 Beat
    var now = 0.0
    for _ in 0..<200 {
        for e in p.plan(beatNow: now, playing: true, ahead: 0.05) where isClock(e) { beats.append(e.beat) }
        now += 0.02
    }
    #expect(beats.count > 0)
    for (i, b) in beats.enumerated() { #expect(abs(b - Double(i) / 24) < 1e-9, "Takt \(i) bei Beat \(b)") }
}

@Test func stopSendsStopOnceAndNothingAfter() {
    var p = MIDIClockPlanner(songPosition: false)
    _ = p.plan(beatNow: 0, playing: true, ahead: 0.05)
    let stop = p.plan(beatNow: 0.3, playing: false, ahead: 0.05)
    #expect(stop.map(\.message.bytes) == [[MIDIClock.stopByte]])
    #expect(!p.running)
    #expect(p.plan(beatNow: 0.4, playing: false, ahead: 0.05).isEmpty)
    #expect(p.halt(beatNow: 0.5).isEmpty)
}

@Test func haltOnlyStopsARunningTransport() {
    var p = MIDIClockPlanner()
    #expect(p.halt(beatNow: 0).isEmpty)
    _ = p.plan(beatNow: 2, playing: true, ahead: 0)
    #expect(p.halt(beatNow: 2).map(\.message.bytes) == [[MIDIClock.stopByte]])
}

@Test func startAwayFromTheBarUsesSongPositionAndContinue() {
    var p = MIDIClockPlanner(songPosition: true)
    // Beat 2,5 = Takt 60 = Sechzehntel 10 (je 6 Takte)
    let ev = p.plan(beatNow: 2.5, playing: true, ahead: 0)
    #expect(ev.map(\.message.bytes) == [[0xF2, 10, 0], [MIDIClock.continueByte]])
    // danach Takte ab dem Sechzehntel: nächster Aufruf liefert die Takte ab 60
    let next = p.plan(beatNow: 2.5, playing: true, ahead: 0.1)
    let ticks = next.filter(isClock)
    #expect(!ticks.isEmpty)
    #expect(abs(ticks[0].beat - 2.5) < 1e-9)
}

@Test func startAtBeatZeroIsPlainStartEvenWithSongPosition() {
    var p = MIDIClockPlanner(songPosition: true)
    let ev = p.plan(beatNow: 0, playing: true, ahead: 0)
    #expect(ev.first?.message.bytes == [MIDIClock.startByte])
}

@Test func songPositionBytesAreFourteenBitLSBFirst() {
    #expect(MIDIClock.Message.songPosition(sixteenths: 0).bytes == [0xF2, 0, 0])
    #expect(MIDIClock.Message.songPosition(sixteenths: 127).bytes == [0xF2, 127, 0])
    #expect(MIDIClock.Message.songPosition(sixteenths: 128).bytes == [0xF2, 0, 1])
    #expect(MIDIClock.Message.songPosition(sixteenths: 200).bytes == [0xF2, 72, 1])
    #expect(MIDIClock.Message.songPosition(sixteenths: 16383).bytes == [0xF2, 127, 127])
    // außerhalb des Bereichs: begrenzt
    #expect(MIDIClock.Message.songPosition(sixteenths: -5).bytes == [0xF2, 0, 0])
    #expect(MIDIClock.Message.songPosition(sixteenths: 99_999).bytes == [0xF2, 127, 127])
}

@Test func sixteenthIsSixTicks() {
    #expect(MIDIClock.sixteenth(ofTick: 0) == 0)
    #expect(MIDIClock.sixteenth(ofTick: 5) == 0)
    #expect(MIDIClock.sixteenth(ofTick: 6) == 1)
    #expect(MIDIClock.sixteenth(ofTick: 60) == 10)
}

@Test func clockJumpResyncsWithSongPosition() {
    var p = MIDIClockPlanner(songPosition: true)
    _ = p.plan(beatNow: 0, playing: true, ahead: 0.05)
    _ = p.plan(beatNow: 0.1, playing: true, ahead: 0.05)
    // Sprung nach Beat 20 (Vor- oder Zurückspringen der Master-Clock): Position + Continue, Takte ab dem Sechzehntel
    let ev = p.plan(beatNow: 20, playing: true, ahead: 0)
    #expect(ev.map(\.message.bytes).prefix(2).elementsEqual([[0xF2, 80, 0], [MIDIClock.continueByte]]))
}

@Test func smallDelayDoesNotResync() {
    var p = MIDIClockPlanner(songPosition: true)
    _ = p.plan(beatNow: 0, playing: true, ahead: 0.05)
    // ein Takt Verzug ist normal (Queue etwas spät): keine Position, keine Lücke
    let ev = p.plan(beatNow: 1.0 / 24 + 0.01, playing: true, ahead: 0.05)
    #expect(ev.allSatisfy { $0.message.bytes.first != 0xF2 })
}

@Test func tempoIsConvertedBySecondsPerBeat() {
    // Beats sind tempounabhängig, Sekunden rechnen sich mit dem Tempo des Takts
    #expect(abs(MIDIClock.seconds(fromBeat: 0, toBeat: 1, bpm: 120) - 0.5) < 1e-12)
    #expect(abs(MIDIClock.seconds(fromBeat: 0, toBeat: 1, bpm: 60) - 1.0) < 1e-12)
    // Tempowechsel mitten im Takt: ein Takt (1/24 Beat) bei 120 BPM = 20,8 ms, bei 240 BPM = 10,4 ms
    #expect(abs(MIDIClock.seconds(fromBeat: 0, toBeat: 1.0 / 24, bpm: 120) - 0.0208333) < 1e-6)
    #expect(abs(MIDIClock.seconds(fromBeat: 0, toBeat: 1.0 / 24, bpm: 240) - 0.0104166) < 1e-6)
}

@Test func tempoChangeKeepsTheBeatGrid() {
    // bei gleicher Beat-Folge bleibt die Taktfolge gleich, egal wie schnell die Master-Clock läuft
    var fast = MIDIClockPlanner(songPosition: false), slow = MIDIClockPlanner(songPosition: false)
    let a = fast.plan(beatNow: 4, playing: true, ahead: 0.5).filter(isClock).map(\.beat)
    let b = slow.plan(beatNow: 4, playing: true, ahead: 0.5).filter(isClock).map(\.beat)
    #expect(a == b)
    #expect(a.count == 12)
}

@Test func stopComesAfterTheLastScheduledTick() {
    var p = MIDIClockPlanner(songPosition: false)
    let ticks = p.plan(beatNow: 0, playing: true, ahead: 0.05).filter(isClock)
    let lastBeat = ticks.last!.beat
    let stop = p.plan(beatNow: 0, playing: false, ahead: 0.05)
    #expect(stop.count == 1)
    #expect(stop[0].beat > lastBeat)
    #expect(abs(stop[0].beat - (lastBeat + 1.0 / 24)) < 1e-9)
}
