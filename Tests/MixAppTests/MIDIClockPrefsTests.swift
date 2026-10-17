import Foundation
import Testing
@testable import MixApp

// MIDI-Clock zum Pult: aus als Standard, gespeicherte Einstellungen ohne neue Felder laden weiter.

@Test func midiClockIsOffByDefault() {
    let p = MIDIClockPrefs()
    #expect(!p.enabled)
    #expect(p.destination == "")
    #expect(p.songPosition)
    #expect(p.offsetMs == 0)
}

@Test func midiClockPrefsDecodeMissingFieldsWithDefaults() throws {
    let empty = try JSONDecoder().decode(MIDIClockPrefs.self, from: Data("{}".utf8))
    #expect(empty == MIDIClockPrefs())
    let some = try JSONDecoder().decode(MIDIClockPrefs.self, from: Data(#"{"enabled":true,"offsetMs":-5}"#.utf8))
    #expect(some.enabled && some.offsetMs == -5)
    #expect(some.songPosition && some.destination == "")
    let round = try JSONDecoder().decode(MIDIClockPrefs.self, from: JSONEncoder().encode(some))
    #expect(round == some)
}
