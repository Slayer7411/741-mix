import AppKit
import MixCore
import SwiftUI

/// Hilfe-Modus: Mauszeiger 2 s über einem Bedienelement (`.helpInfo`) zeigt eine kurze Erklärung.
/// Aus: nichts ändert sich, die normalen Tooltips bleiben. Pro Hover höchstens ein Timer, keine Arbeit pro Frame.
@MainActor @Observable
final class HelpMode {
    static let shared = HelpMode()

    /// Hilfe-Modus an/aus; aus löscht Timer und Karte
    var enabled = false {
        didSet { if !enabled { cancel() } }
    }
    /// Id der Karte, die gerade offen ist
    private(set) var shown: String?
    /// Element unter dem Mauszeiger (Hover aktiv)
    private var current: String?
    /// der eine Timer für das aktuelle Element
    private var pending: DispatchWorkItem?

    /// Verzögerung bis zur Karte
    static let delay = 2.0

    /// Mauszeiger rein/raus aus einem Element
    func hover(_ id: String, _ inside: Bool) {
        guard enabled else { return }
        if inside {
            guard current != id else { return }
            cancel()
            current = id
            let w = DispatchWorkItem { MainActor.assumeIsolated { HelpMode.shared.showCard(id) } }
            pending = w
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: w)
        } else if current == id {
            cancel()
        }
    }

    /// Karte schließen (Popover geschlossen durch Klick oder Ausblenden)
    func dismiss(_ id: String) {
        if shown == id { shown = nil }
    }

    private func showCard(_ id: String) {
        guard enabled, current == id else { return }
        pending = nil
        shown = id
    }

    private func cancel() {
        pending?.cancel()
        pending = nil
        current = nil
        shown = nil
    }
}

/// Markiert ein Bedienelement für den Hilfe-Modus; Text aus `HelpTable`
struct HelpInfoModifier: ViewModifier {
    let id: String

    func body(content: Content) -> some View {
        let help = HelpMode.shared
        content
            .onHover { help.hover(id, $0) }
            .popover(isPresented: Binding(get: { help.shown == id }, set: { if !$0 { help.dismiss(id) } }), arrowEdge: .bottom) {
                HelpCard(id: id).allowsHitTesting(false)
            }
    }
}

extension View {
    /// Hilfe-Modus: nach 2 s Verweilen kleine Karte mit Name, Funktion und Taste
    func helpInfo(_ id: String) -> some View { modifier(HelpInfoModifier(id: id)) }
}

/// Karte des Hilfe-Modus: Name in Cinzel, Text in Plex Mono, Taste aus den Einstellungen
struct HelpCard: View {
    let id: String
    @Environment(MixModel.self) private var mix

    var body: some View {
        if let e = HelpTable.entries[id] {
            let en = HelpTable.english
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: en ? e.title.en : e.title.de)
                    .font(Theme.label(11, .bold)).foregroundStyle(Theme.bone)
                Text(verbatim: en ? e.body.en : e.body.de)
                    .font(Theme.mono(10)).foregroundStyle(Theme.bone.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                if let a = e.shortcut, let s = mix.prefs.keys.combo(a)?.symbols {
                    Text(verbatim: (en ? "Key: " : "Taste: ") + s)
                        .font(Theme.mono(10)).foregroundStyle(Theme.muted)
                }
            }
            .padding(10)
            .frame(width: 250, alignment: .leading)
            .background(Theme.chitin)
            .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
        }
    }
}

/// `?` in der Topbar: schaltet den Hilfe-Modus
struct HelpModeButton: View {
    var body: some View {
        let help = HelpMode.shared
        DeckButton(title: "?", active: help.enabled, color: Theme.state) { help.enabled.toggle() }
            .helpInfo("topbar.help")
    }
}

/// Texte des Hilfe-Modus, je Id Deutsch und Englisch. Sprache = Sprache der App (wie String(localized:))
enum HelpTable {
    struct HelpText: Sendable {
        let de: String
        let en: String
    }

    struct Entry: Sendable {
        let title: HelpText
        let body: HelpText
        var shortcut: ShortcutID? = nil
    }

    /// englische Oberfläche (Sprache der App, sonst Deutsch)
    static var english: Bool { Bundle.main.preferredLocalizations.first?.hasPrefix("en") == true }

    static let entries: [String: Entry] = [
        // Topbar
        "topbar.help": Entry(title: HelpText(de: "HILFE-MODUS", en: "HELP MODE"),
                             body: HelpText(de: "Mauszeiger 2 s über einem Bedienelement: kurze Erklärung. Nochmal klicken schaltet aus.",
                                        en: "Hover over a control for 2 s: short explanation. Click again to turn off.")),
        "clock.link": Entry(title: HelpText(de: "LINK", en: "LINK"),
                            body: HelpText(de: "Ableton Link: MINOS gibt das Tempo vor. Rechtsklick: Diagnose.",
                                       en: "Ableton Link: MINOS sets the tempo. Right click: diagnosis.")),
        "clock.auto": Entry(title: HelpText(de: "AUTO", en: "AUTO"),
                            body: HelpText(de: "Ein Deck ist Master, automatisch.", en: "A deck is master, automatically.")),
        "clock.master": Entry(title: HelpText(de: "MASTER", en: "MASTER"),
                              body: HelpText(de: "Die MINOS-Uhr gibt das Tempo vor, nicht ein Deck.",
                                         en: "The MINOS clock sets the tempo, not a deck.")),
        "clock.tap": Entry(title: HelpText(de: "TAP", en: "TAP"),
                           body: HelpText(de: "Auf den Beat tippen: das Tempo der Uhr folgt dem Takt.",
                                      en: "Tap on the beat: the clock tempo follows the tapped beat.")),
        // Deck: Transport und Sync
        "deck.cup": Entry(title: HelpText(de: "CUP", en: "CUP"),
                          body: HelpText(de: "Cue-Play: Cue halten spielt ab dem Cue-Punkt, loslassen springt zurück.",
                                     en: "Cue play: hold cue to play from the cue point, release jumps back."),
                          shortcut: .cup),
        "deck.sync": Entry(title: HelpText(de: "SYNC", en: "SYNC"),
                           body: HelpText(de: "Das Deck läuft synchron zum Master (Tempo und Phase).",
                                      en: "The deck runs in sync with the master (tempo and phase)."),
                           shortcut: .sync),
        "deck.master": Entry(title: HelpText(de: "MASTER", en: "MASTER"),
                             body: HelpText(de: "Dieses Deck gibt das Tempo vor. Die Uhr folgt ihm.",
                                        en: "This deck sets the tempo. The clock follows it."),
                             shortcut: .master),
        "deck.keylock": Entry(title: HelpText(de: "KEY", en: "KEY"),
                              body: HelpText(de: "Keylock: Tempo ändern, ohne die Tonhöhe zu verschieben.",
                                         en: "Keylock: change the tempo without moving the pitch."),
                              shortcut: .keylock),
        "deck.rev": Entry(title: HelpText(de: "REV", en: "REV"),
                          body: HelpText(de: "Rückwärts abspielen.", en: "Play backwards.")),
        "deck.flux": Entry(title: HelpText(de: "FLUX", en: "FLUX"),
                           body: HelpText(de: "Flux: der Track läuft im Hintergrund weiter, der Sprung kehrt zur Stelle zurück.",
                                      en: "Flux: the track keeps running in the background, the jump returns to its position.")),
        "deck.dbl": Entry(title: HelpText(de: "DBL", en: "DBL"),
                          body: HelpText(de: "Instant Double: Track, Position, Tempo, Key und Loop vom anderen Deck übernehmen.",
                                     en: "Instant double: take track, position, tempo, key and loop from the other deck."),
                          shortcut: .instantDouble),
        "deck.edit": Entry(title: HelpText(de: "EDIT", en: "EDIT"),
                           body: HelpText(de: "EDIT-Modus: Schnitt und Grid setzen.", en: "Edit mode: set cut and grid."),
                           shortcut: .editMode),
        "deck.rip": Entry(title: HelpText(de: "RIP", en: "RIP"),
                          body: HelpText(de: "Rip-Prüfung: Befund am Anfang oder Ende als Bereich markieren. Nichts wird geschnitten.",
                                     en: "Rip check: mark the finding at the start or end as a range. Nothing is cut.")),
        // Deck: Loop, Hotcues, Beatjump
        "deck.loop": Entry(title: HelpText(de: "LOOP", en: "LOOP"),
                           body: HelpText(de: "Auto-Loop: Loop im Takt setzen oder lösen.", en: "Auto loop: set or release a loop on the bar."),
                           shortcut: .loop),
        "deck.loopIn": Entry(title: HelpText(de: "IN", en: "IN"),
                             body: HelpText(de: "Loop-Anfang setzen.", en: "Set the loop start.")),
        "deck.loopOut": Entry(title: HelpText(de: "OUT", en: "OUT"),
                              body: HelpText(de: "Loop-Ende setzen.", en: "Set the loop end.")),
        "deck.reloop": Entry(title: HelpText(de: "RE", en: "RE"),
                             body: HelpText(de: "Reloop: den letzten Loop wieder aufnehmen.", en: "Reloop: take up the last loop again."),
                             shortcut: .reloop),
        "deck.hotcue": Entry(title: HelpText(de: "HOTCUE", en: "HOTCUE"),
                             body: HelpText(de: "Klick setzt den Cue oder springt dorthin, ⌥-Klick löscht, Rechtsklick: Active Loop.",
                                        en: "Click sets the cue or jumps to it, option-click deletes, right click: active loop.")),
        "deck.beatjump": Entry(title: HelpText(de: "BEATJUMP", en: "BEATJUMP"),
                               body: HelpText(de: "Sprung um die eingestellte Beat-Größe zurück oder vor.",
                                          en: "Jump back or forward by the set beat size."),
                               shortcut: .beatjumpBack),
        "deck.fxAssign": Entry(title: HelpText(de: "FX-ZUWEISUNG", en: "FX ASSIGN"),
                               body: HelpText(de: "Schaltet die Zuweisung dieses Decks zur FX-Einheit: Regler und Tasten steuern den Effekt.",
                                          en: "Toggles this deck's assignment to the FX unit: knobs and buttons control the effect.")),
        // Mixer
        "mixer.fxassign": Entry(title: HelpText(de: "FX-EINHEIT", en: "FX UNIT"),
                                body: HelpText(de: "Schaltet die Zuweisung dieses Decks zur FX-Einheit.",
                                           en: "Toggles this deck's assignment to the FX unit.")),
        "mixer.fader": Entry(title: HelpText(de: "FADER", en: "FADER"),
                             body: HelpText(de: "Lautstärke dieses Decks vor dem Master.", en: "Volume of this deck before the master.")),
        // Browser-Kopf
        "browser.tags": Entry(title: HelpText(de: "TAGS", en: "TAGS"),
                              body: HelpText(de: "Tag-Filter aus Kommentar 2: nur Tracks mit den gewählten Tags. ⌥-Klick schließt aus.",
                                         en: "Tag filter from comment 2: only tracks with the chosen tags. Option-click excludes.")),
        "browser.played": Entry(title: HelpText(de: "UNGESPIELT", en: "UNPLAYED"),
                                body: HelpText(de: "Gespielte Tracks ausblenden. History und Preparation zeigen sie weiter.",
                                           en: "Hide played tracks. History and preparation still show them."),
                                shortcut: .hidePlayed),
        "browser.matching": Entry(title: HelpText(de: "◆ PASST", en: "◆ MATCH"),
                                  body: HelpText(de: "Nur Tracks, die zum Master passen (Key, Tempo).",
                                             en: "Only tracks that match the master (key, tempo)."),
                                  shortcut: .matching),
        // Baum
        "tree.collection": Entry(title: HelpText(de: "TRACK COLLECTION", en: "TRACK COLLECTION"),
                                 body: HelpText(de: "Die ganze Musikbibliothek. Rechtsklick: Export, Prüfung, Reset Played State.",
                                            en: "The whole music library. Right click: export, check, reset played state.")),
        "tree.preparation": Entry(title: HelpText(de: "PREPARATION", en: "PREPARATION"),
                                  body: HelpText(de: "Tracks für das nächste Set. Aus dem Browser hineinziehen.",
                                             en: "Tracks for the next set. Drag them in from the browser.")),
        "tree.history": Entry(title: HelpText(de: "HISTORY", en: "HISTORY"),
                              body: HelpText(de: "Protokoll der gespielten Tracks mit Deck und Zeit.",
                                         en: "Log of played tracks with deck and time.")),
        "tree.playlists": Entry(title: HelpText(de: "PLAYLISTS", en: "PLAYLISTS"),
                                body: HelpText(de: "Eigene Playlists und Ordner sowie die Playlists der Collection.",
                                           en: "Own playlists and folders, plus the collection's playlists.")),
        // FX
        "fx.slot": Entry(title: HelpText(de: "FX-SLOT", en: "FX SLOT"),
                         body: HelpText(de: "Effekt-Slot: Rechtsklick für Parameter, an/aus und Reihenfolge. Ziehen ordnet um.",
                                    en: "Effect slot: right click for parameters, on/off and order. Drag to reorder.")),
    ]
}
