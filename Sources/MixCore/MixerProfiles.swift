import Foundation

/// Bekannte externe Mischpulte: Erkennung am Ausgabegerät, Standard-Zuordnung Deck → Kanalpaar, Vorhör-Vorschlag,
/// MIDI-Ziel. Reine Tabelle ohne Audio-Zugriff (testbar). Nicht am Gerät geprüft: Kanalzuordnung und Gerätename sind Annahmen.
public struct MixerProfile: Identifiable, Equatable, Sendable {
    /// stabile ID (Einstellungen merken sich die Entscheidung je Gerät)
    public let id: String
    /// Anzeigename
    public let name: String
    /// Teilstrings des CoreAudio-Gerätenamens (normalisiert, siehe `normalized`)
    public let deviceMatch: [String]
    /// Kanäle des Pults (je Kanal ein Stereo-Paar am USB-Interface)
    public let channels: Int
    /// erster Kanal (0-basiert) je Deck A–D: A→CH1, B→CH2, C→CH3, D→CH4
    public let deckPairs: [Int]
    /// Vorschlag für das Vorhör-Paar (erster Kanal, 0-basiert), nil = automatisch
    public let previewPair: Int?
    /// Teilstring des MIDI-Ziels, das beim Erkennen vorgewählt wird (normalisiert)
    public let midiPortMatch: String

    /// USB-Kanäle, die das Interface für dieses Pult braucht (zwei je Kanal)
    public var usbChannels: Int { channels * 2 }

    /// Erster Kanal (0-basiert) des Pult-Kanals `ch` (1-basiert): CH1 → 0, CH2 → 2, …
    public static func firstChannel(ofMixerChannel ch: Int) -> Int { (ch - 1) * 2 }

    public static let djmV10 = MixerProfile(
        id: "djm-v10", name: "Pioneer DJM-V10", deviceMatch: ["DJMV10"], channels: 6,
        deckPairs: [0, 2, 4, 6], previewPair: firstChannel(ofMixerChannel: 5), midiPortMatch: "DJMV10")

    public static let djmA9 = MixerProfile(
        id: "djm-a9", name: "Pioneer DJM-A9", deviceMatch: ["DJMA9"], channels: 4,
        deckPairs: [0, 2, 4, 6], previewPair: nil, midiPortMatch: "DJMA9")

    public static let all: [MixerProfile] = [djmV10, djmA9]

    /// Großbuchstaben, ohne Leer-, Binde- und Unterstriche: „DJM-V10“ und „djm v10“ werden gleich
    public static func normalized(_ s: String) -> String {
        String(s.uppercased().filter { $0.isLetter || $0.isNumber })
    }

    /// Profil zu einem Ausgabegerät: Name passt und das Gerät hat genug Kanäle (sonst keine Zusage)
    public static func match(deviceName: String, outputChannels: Int) -> MixerProfile? {
        let n = normalized(deviceName)
        return all.first { p in
            p.deviceMatch.contains { n.contains($0) } && outputChannels >= p.usbChannels
        }
    }

    /// Profil zu einem MIDI-Zielnamen (für die Vorwahl des Ports)
    public func matchesMIDIPort(_ portName: String) -> Bool {
        !midiPortMatch.isEmpty && MixerProfile.normalized(portName).contains(midiPortMatch)
    }

    /// Zuordnung als Text für Angebot und Anzeige, z. B. „A→CH1 (1/2) · B→CH2 (3/4) · … · Vorhören→CH5 (9/10)“
    public var mappingText: String {
        var parts = zip(["A", "B", "C", "D"], deckPairs).map { letter, first in
            "\(letter)→CH\(first / 2 + 1) (\(first + 1)/\(first + 2))"
        }
        if let pv = previewPair { parts.append("Vorhören→CH\(pv / 2 + 1) (\(pv + 1)/\(pv + 2))") }
        return parts.joined(separator: " · ")
    }

    /// Einstellungen gelten als angepasst, wenn die Deck-Zuordnung von der Vorlage abweicht
    public func isCustomised(deckPairs current: [Int]) -> Bool { current != deckPairs }
}
