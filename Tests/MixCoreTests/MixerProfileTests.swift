import Foundation
import Testing
@testable import MixCore

// Mischpult-Profile: Erkennung am Gerätenamen, Standard-Zuordnung Deck → Kanalpaar, Vorhören, MIDI-Ziel.

@Test func djmProfilesMatchDeviceNamesAndChannelCounts() {
    #expect(MixerProfile.match(deviceName: "Pioneer DJ DJM-V10", outputChannels: 12)?.id == "djm-v10")
    #expect(MixerProfile.match(deviceName: "DJM-A9", outputChannels: 8)?.id == "djm-a9")
    // Schreibweise egal: Leer-, Binde- und Unterstriche, Groß/Klein
    #expect(MixerProfile.match(deviceName: "djm_v10", outputChannels: 12)?.id == "djm-v10")
    #expect(MixerProfile.match(deviceName: "djm a9", outputChannels: 8)?.id == "djm-a9")
    // zu wenige Kanäle: keine Zusage (das Gerät ist dann kein Pult dieses Typs)
    #expect(MixerProfile.match(deviceName: "DJM-V10", outputChannels: 4) == nil)
    #expect(MixerProfile.match(deviceName: "DJM-A9", outputChannels: 2) == nil)
    // fremde Geräte
    #expect(MixerProfile.match(deviceName: "MacBook Pro-Lautsprecher", outputChannels: 2) == nil)
    #expect(MixerProfile.match(deviceName: "Xone:96", outputChannels: 12) == nil)
}

@Test func profileChannelsAndUSBPairs() {
    #expect(MixerProfile.djmV10.channels == 6 && MixerProfile.djmV10.usbChannels == 12)
    #expect(MixerProfile.djmA9.channels == 4 && MixerProfile.djmA9.usbChannels == 8)
    // CH1 → erster Kanal 0 (USB 1/2), CH2 → 2, CH3 → 4, CH4 → 6, CH5 → 8, CH6 → 10
    #expect((1...6).map(MixerProfile.firstChannel(ofMixerChannel:)) == [0, 2, 4, 6, 8, 10])
}

@Test func defaultDeckMappingIsACh1BCh2CCh3DCh4() {
    for p in MixerProfile.all {
        #expect(p.deckPairs == [0, 2, 4, 6], "\(p.name)")
        // vier Decks auf verschiedenen Paaren, alle innerhalb der Kanäle des Pults
        #expect(Set(p.deckPairs).count == 4)
        #expect(p.deckPairs.allSatisfy { $0 + 1 < p.usbChannels })
    }
}

@Test func previewSuggestionUsesSpareChannelsOnlyWhereThereAreSome() {
    // V10: CH5/6 frei für Vorhören, Kopfhörer, Sampler
    #expect(MixerProfile.djmV10.previewPair == 8)
    #expect(MixerProfile.djmV10.previewPair! + 1 < MixerProfile.djmV10.usbChannels)
    // A9: alle vier Kanäle sind Decks, kein Vorschlag
    #expect(MixerProfile.djmA9.previewPair == nil)
}

@Test func midiPortPreselectionByName() {
    #expect(MixerProfile.djmV10.matchesMIDIPort("DJM-V10"))
    #expect(MixerProfile.djmV10.matchesMIDIPort("Pioneer DJ DJM-V10 MIDI"))
    #expect(!MixerProfile.djmV10.matchesMIDIPort("IAC-Treiber Bus 1"))
    #expect(!MixerProfile.djmA9.matchesMIDIPort("DJM-V10"))
}

@Test func customisedMappingIsDetected() {
    #expect(!MixerProfile.djmV10.isCustomised(deckPairs: [0, 2, 4, 6]))
    // die Standard-Zuordnung der Xone-Einrichtung (A 1/2 · B 5/6 · C 3/4 · D 7/8) ist eine eigene Einstellung
    #expect(MixerProfile.djmV10.isCustomised(deckPairs: [0, 4, 2, 6]))
}

@Test func normalizedIgnoresPunctuationAndCase() {
    #expect(MixerProfile.normalized("DJM-V10") == "DJMV10")
    #expect(MixerProfile.normalized("djm_v 10") == "DJMV10")
}

@Test func mappingTextShowsEveryPairThatWillBeSet() {
    #expect(MixerProfile.djmV10.mappingText == "A→CH1 (1/2) · B→CH2 (3/4) · C→CH3 (5/6) · D→CH4 (7/8) · Vorhören→CH5 (9/10)")
    #expect(MixerProfile.djmA9.mappingText == "A→CH1 (1/2) · B→CH2 (3/4) · C→CH3 (5/6) · D→CH4 (7/8)")
}
