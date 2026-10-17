import SwiftUI
import MixCore
import MixEngine

/// MIDI-Clock an einen MIDI-Ausgang (⌘, -> AUDIO): aus (Standard), Ausgang (leer = automatisch über das erkannte Profil),
/// Song Position, Versatz
struct MIDIClockPrefs: Codable, Equatable {
    var enabled = false
    /// Name des MIDI-Ausgangs; leer = Port des erkannten Pults (wenn es einen gibt)
    var destination = ""
    var songPosition = true
    /// Versatz der Zeitstempel in ms (positiv = später)
    var offsetMs = 0.0

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        destination = try c.decodeIfPresent(String.self, forKey: .destination) ?? ""
        songPosition = try c.decodeIfPresent(Bool.self, forKey: .songPosition) ?? true
        offsetMs = try c.decodeIfPresent(Double.self, forKey: .offsetMs) ?? 0
    }
}

/// Externe Mischpulte (DJM-V10, DJM-A9): Profil-Angebot beim Erkennen, MIDI-Clock an einen MIDI-Ausgang.
/// Der Takt kommt von der Master-Clock (wie Link und Groove), der Transport von „ein Deck läuft“.
@MainActor @Observable
final class ExternalMixerController {
    @ObservationIgnored private unowned let mix: MixModel
    @ObservationIgnored let midi = MIDIClockOut()
    /// Geräte, für die das Profil in dieser Sitzung schon angeboten wurde (kein Wiederholen bei jeder Geräteliste)
    @ObservationIgnored private var offered = Set<String>()
    @ObservationIgnored private var lastPlaying = false
    /// MIDI-Ausgänge für die Auswahl (aktualisiert beim Öffnen der Einstellungen und beim Anwenden)
    private(set) var destinations: [MIDIClockOut.Destination] = []
    /// gewählter oder automatisch erkannter Ausgang
    private(set) var target: MIDIClockOut.Destination?

    init(mix: MixModel) { self.mix = mix }

    /// Ausgänge neu einlesen und den Ausgang nach Einstellung bestimmen: gewählter Name, sonst der Port des erkannten Pults
    func refreshDestinations() {
        destinations = MIDIClockOut.destinations()
        let want = mix.prefs.midiClock.destination
        if !want.isEmpty {
            target = destinations.first { $0.name == want }
        } else if let p = mix.mixerProfile {
            target = destinations.first { p.matchesMIDIPort($0.name) }
        } else {
            target = nil
        }
    }

    /// Einstellungen übernehmen: Ausgang, Versatz, Song Position, ein/aus
    func apply() {
        refreshDestinations()
        let prefs = mix.prefs.midiClock
        midi.setSongPosition(prefs.songPosition)
        midi.setOffset(ms: prefs.offsetMs)
        guard prefs.enabled, let dest = target else {
            midi.setTarget(nil)
            midi.stop()
            return
        }
        midi.setTarget(dest.endpoint)
        let core = mix.core
        midi.start {
            guard let st = core.engine.clockStamp else { return nil }
            return MIDIClockOut.Clock(beat: st.beat, hostTime: st.hostTime, bpm: core.clockTempo)
        }
    }

    /// Gerät hat gewechselt oder die Liste ist neu: Profil anbieten, MIDI-Ausgang nachziehen
    func deviceChanged() {
        offerProfile()
        if mix.prefs.midiClock.enabled || midi.running { apply() }
    }

    /// Statuszeile in den Einstellungen
    var statusText: String {
        guard mix.prefs.midiClock.enabled else { return String(localized: "aus") }
        guard let d = target else { return String(localized: "kein MIDI-Ausgang gefunden") }
        return midi.running ? String(localized: "sendet an \(d.name)") : String(localized: "wartet")
    }

    /// Transport aus der Oberfläche (30 Hz): nur bei Änderung weitergeben
    func transport(playing: Bool) {
        guard playing != lastPlaying else { return }
        lastPlaying = playing
        midi.setPlaying(playing)
    }

    /// Erkanntes Pult anbieten, wenn das Routing noch nicht darauf steht (nie still umschalten). Einmal je Gerät und Sitzung.
    /// Das Angebot nennt die genauen Kanalpaare, die übernommen werden.
    private func offerProfile() {
        guard !Session.isSelfTest, let dev = mix.currentDevice, let p = mix.mixerProfile else { return }
        if MixerProfileStore.applied(uid: dev.uid) { return }
        // Extern mit eigener oder schon passender Zuordnung: nichts anbieten, nie wieder fragen
        if mix.mixerMode == .external {
            MixerProfileStore.markApplied(uid: dev.uid)
            return
        }
        guard offered.insert(dev.uid).inserted else { return }
        StatusCenter.post(.info,
                          String(format: String(localized: "%@ erkannt – ungetestet – Kanalbelegung bitte prüfen. Übernehmen setzt: %@"),
                                 p.name, p.mappingText),
                          key: "mixer.profile", sticky: true,
                          action: (title: String(localized: "Übernehmen"), run: { [weak self] in self?.mix.applyMixerProfile(p) }))
    }
}

/// Je Gerät gemerkt, ob das Profil übernommen oder bewusst eigen eingestellt wurde (Einstellungen, nicht Sitzung)
enum MixerProfileStore {
    private static let key = "mixerProfile.applied"

    static func applied(uid: String) -> Bool {
        (E2E.defaults.stringArray(forKey: key) ?? []).contains(uid)
    }

    static func markApplied(uid: String) {
        guard !Session.isSelfTest else { return }
        var all = E2E.defaults.stringArray(forKey: key) ?? []
        guard !all.contains(uid) else { return }
        all.append(uid)
        E2E.defaults.set(all, forKey: key)
    }
}

extension MixModel {
    /// Profil zum gewählten Ausgabegerät (oder Systemstandard), nil wenn keins passt
    var mixerProfile: MixerProfile? {
        guard let d = currentDevice else { return nil }
        return MixerProfile.match(deviceName: d.name, outputChannels: d.channels)
    }

    /// Profil übernehmen: Extern, Deck-Zuordnung und Vorhören aus dem Profil, dann MIDI-Ausgang neu wählen
    func applyMixerProfile(_ p: MixerProfile) {
        mixerMode = .external
        deckPairs = p.deckPairs
        previewPair = p.previewPair ?? MixModel.previewAuto
        if let uid = currentDevice?.uid { MixerProfileStore.markApplied(uid: uid) }
        applyRouting()
        mixerLink.apply()
        StatusCenter.post(.ok,
                          String(format: String(localized: "%@ übernommen (ungetestet – Kanalbelegung bitte prüfen): %@"), p.name, p.mappingText),
                          key: "mixer.profile")
    }
}

/// Einstellungen im AUDIO-Bereich: erkanntes Profil, Anwenden, MIDI-Clock an einen MIDI-Ausgang
struct MixerProfileSettings: View {
    @Environment(MixModel.self) private var mix

    var body: some View {
        let link = mix.mixerLink
        Section("Mischpult") {
            LabeledContent("Erkannt") {
                if let p = mix.mixerProfile {
                    Text(verbatim: p.name + " · " + String(localized: "ungetestet – Kanalbelegung bitte prüfen"))
                } else {
                    Text("kein bekanntes Pult am Gerät")
                }
            }
            .settingsAnchor("audio.mixerprofile")
            if let p = mix.mixerProfile {
                VStack(alignment: .leading, spacing: 6) {
                    Button("Profil anwenden") { mix.applyMixerProfile(p) }
                    Text(verbatim: String(localized: "Setzt Modus Extern: ") + p.mappingText)
                        .settingsHint()
                }
                .settingsControlColumn()
            }
        }
        Section("MIDI-Clock") {
            Toggle("MIDI-Clock an MIDI-Ausgang senden", isOn: Binding(
                get: { mix.prefs.midiClock.enabled },
                set: { mix.prefs.midiClock.enabled = $0; link.apply() }))
                .settingsAnchor("audio.midiclock")
            Picker("Ausgang", selection: Binding(
                get: { mix.prefs.midiClock.destination },
                set: { mix.prefs.midiClock.destination = $0; link.apply() })) {
                Text(verbatim: String(localized: "Automatisch") + (mix.mixerProfile.map { " – \($0.name)" } ?? "")).tag("")
                ForEach(link.destinations, id: \.self) { d in Text(verbatim: d.name).tag(d.name) }
            }
            Toggle("Song Position mitsenden", isOn: Binding(
                get: { mix.prefs.midiClock.songPosition },
                set: { mix.prefs.midiClock.songPosition = $0; link.apply() }))
            Stepper(value: Binding(
                get: { mix.prefs.midiClock.offsetMs },
                set: { mix.prefs.midiClock.offsetMs = $0; link.apply() }), in: -50...50, step: 1) {
                Text(verbatim: String(localized: "Versatz") + String(format: " %+.0f ms", mix.prefs.midiClock.offsetMs))
            }
            Text(verbatim: String(localized: "Status") + ": " + link.statusText)
                .settingsHint()
            Text("24 Takte je Viertel aus der Master-Clock an den gewählten MIDI-Ausgang.")
                .settingsHint()
                .help("24 Takte je Viertel aus der Master-Clock an den gewählten MIDI-Ausgang, Start und Stop folgen dem Transport. Wie das empfangende Gerät darauf reagiert, ist nicht geprüft.")
        }
        .onAppear { link.refreshDestinations() }
    }
}
