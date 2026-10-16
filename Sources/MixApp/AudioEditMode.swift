import SwiftUI
import AppKit
import Observation
import MixCore
import MixEngine

/// Audio-Edit-Modus: ein Deck (A) über die volle Breite, im Browser-Bereich die Arbeitsliste (Import-Analyse) und rechts
/// die Vorschläge zum geladenen Track (Rip-Befunde, Grid, Lautheit, fehlende Werte). Eingang: Schalter AUDIO-EDIT, Taste,
/// Menü oder Baum „Import analysieren …“. Verlassen stellt die Ansicht von vorher wieder her. Geschnitten wird nur über
/// die vorhandenen Aktionen (Schnitt in edits.json, neue Dateien); die Collection wird nicht angefasst.
@MainActor @Observable
final class AudioEditMode {
    static let shared = AudioEditMode()
    /// das Deck der Arbeit
    static let deck = 0

    private(set) var active = false
    /// Quelle (Kopf der Liste)
    private(set) var title = ""
    /// Arbeitsliste in der Reihenfolge der Quelle; `index` = der Eintrag auf Deck A
    private(set) var list: [Track] = []
    private(set) var index = 0
    /// Erledigt-Markierungen und Lauf geändert
    private(set) var revision = 0

    /// Editor (Wellenform von Deck A): Cursor und Auswahl in Ausgabe-Zeit, Raster (SNAP), Ansicht (Sekunden je Punkt,
    /// Anfang), Marken des Tracks (Quellzeiten). `secPerPoint` 0 = noch nicht eingepasst
    var cursor = 0.0
    var selection: TrackRange?
    var snap = false
    var secPerPoint = 0.0
    var viewStart = 0.0
    var marks: [AudioMarker] = []

    @ObservationIgnored let store = AudioEditStore(url: Session.isSelfTest ? nil : HistoryStore.baseDir.appendingPathComponent("audioedit.json"))
    /// Marken je Track, eigene Datei neben edits.json
    @ObservationIgnored let markStore = AudioMarkStore(url: Session.isSelfTest ? nil : HistoryStore.baseDir.appendingPathComponent("audioedit-marks.json"))
    /// Zwischenablage des Editors (nur im selben Track einfügbar) und Breite der Wellenform (Punkte, vom Editor gemeldet)
    @ObservationIgnored var clip: AudioEditClip?
    @ObservationIgnored var viewWidth = 0.0
    @ObservationIgnored weak var mix: MixModel?
    @ObservationIgnored weak var browser: BrowserState?
    /// Ansicht vor dem Eintritt: Profil-Felder und das aktive Profil
    @ObservationIgnored private var saved: (view: LayoutProfile, active: String)?
    /// EDIT-Modus von Deck A vor dem Eintritt (der Editor braucht ihn an)
    @ObservationIgnored var wasEditing = false

    private init() {}

    var current: Track? { list.indices.contains(index) ? list[index] : nil }

    func attach(mix: MixModel, browser: BrowserState) {
        self.mix = mix
        self.browser = browser
    }

    /// AUDIO-EDIT (Schalter, Taste, Menü): Liste aus dem aktiven Browser-Bereich, ohne Import-Lauf. Erneut = verlassen
    func toggle() {
        if active { leave(); return }
        guard let browser else { return }
        let pane = browser.activePane
        enter(title: pane.source.title, tracks: pane.shown, importRun: false)
    }

    /// Baum „Import analysieren …“: neue und noch nicht analysierte Tracks der Quelle; Analyse und Rip-Prüfung in die Warteschlange
    func importRun(_ tracks: [Track], title: String) {
        enter(title: title, tracks: tracks, importRun: true)
    }

    private func enter(title: String, tracks: [Track], importRun: Bool) {
        guard let mix, let browser else { return }
        var list = tracks
        if importRun {
            list = AudioEdit.pick(tracks, lastRun: store.lastImport, ownAnalysis: { Analyses.shared.store.entry(for: $0) != nil },
                                  ripChecked: RipChecks.checked)
            store.setLastImport(Date())
            Analyses.shared.enqueueImport(list)
        }
        if !active {
            saved = (LayoutProfile(name: "", ui: mix.prefs.ui, maximized: browser.maximized), mix.prefs.ui.activeLayoutProfile)
            var ui = mix.prefs.ui
            LayoutProfile.audioEdit(from: ui).apply(to: &ui)
            mix.prefs.ui = ui
            browser.maximized = false
            // Editor: Deck A im EDIT-Modus (Schnittliste), Raster standardmäßig aus (Einstellung „Raster beim Markieren“)
            wasEditing = mix.editing(Self.deck)
            mix.setEditing(Self.deck, true)
            snap = mix.prefs.ui.audioEditGrid
            cursor = 0
            selection = nil
            secPerPoint = 0
            viewStart = 0
        }
        self.title = title
        self.list = list
        index = 0
        active = true
        revision += 1
        reloadMarks()
        if list.isEmpty {
            StatusCenter.post(.info, importRun ? String(localized: "Keine neuen Tracks seit dem letzten Import-Lauf")
                                               : String(localized: "Keine Tracks in dieser Ansicht"), key: "audioedit")
        } else {
            show(0)
        }
    }

    /// Verlassen: Ansicht, aktives Profil und Browser groß wie vor dem Eintritt. Deck A spielt weiter, wie es ist
    func leave() {
        guard active else { return }
        active = false
        title = ""
        list = []
        index = 0
        revision += 1
        marks = []
        selection = nil
        if let mix { mix.setEditing(Self.deck, wasEditing) }
        guard let mix, let browser, let s = saved else { return }
        saved = nil
        var ui = mix.prefs.ui
        s.view.apply(to: &ui, browser: browser)
        ui.activeLayoutProfile = s.active
        mix.prefs.ui = ui
    }

    /// Eintrag auf Deck A laden. Spielt Deck A, bleibt es, wie es ist, und die Statuszeile fragt nach
    @discardableResult
    func show(_ i: Int) -> Bool {
        guard active, let mix, list.indices.contains(i) else { return false }
        let d = Self.deck, t = list[i]
        if mix.deck(d).playing || mix.deck(d).cueHeld {
            StatusCenter.post(.warning, String(localized: "Deck A spielt noch – stoppen, dann laden?"), key: "audioedit")
            return false
        }
        if mix.deck(d).track?.key != t.key {
            guard mix.load(t, deck: d, force: false) else { return false }
            cursor = 0
            selection = nil
            secPerPoint = 0
            viewStart = 0
        }
        index = i
        reloadMarks()
        markRipOnDeck()
        return true
    }

    func next() {
        if index + 1 < list.count { show(index + 1) } else { StatusCenter.post(.info, String(localized: "Letzter Track der Liste"), key: "audioedit") }
    }

    func previous() {
        if index > 0 { show(index - 1) } else { StatusCenter.post(.info, String(localized: "Erster Track der Liste"), key: "audioedit") }
    }

    /// ✓ ERLEDIGT: markieren und zum nächsten
    func done() {
        guard active, let t = current else { return }
        store.markReviewed(t.key)
        revision += 1
        if index + 1 < list.count { show(index + 1) } else { StatusCenter.post(.ok, String(localized: "Liste erledigt"), key: "audioedit") }
    }

    /// Erledigt zurücknehmen (Zeile im Menü)
    func reopen(_ i: Int) {
        guard list.indices.contains(i) else { return }
        store.unmarkReviewed(list[i].key)
        revision += 1
    }

    func isReviewed(_ t: Track) -> Bool { store.isReviewed(t.key) }

    /// Stand eines Eintrags: erledigt, laufende Analyse, Warteschlange, Rip-Prüfung, offene Vorschläge
    func status(_ t: Track) -> AudioEdit.Status {
        AudioEdit.status(reviewed: store.isReviewed(t.key), analysing: Analyses.shared.running.contains(t.key),
                         queued: Analyses.shared.isQueued(t.key), ripChecked: RipChecks.checked(t.key),
                         open: RipChecks.shared.open(t.key).count)
    }

    /// Rip-Befund des geladenen Tracks als Bereich markieren (wie beim Laden; die Einstellung dafür gilt hier nicht)
    func markRipOnDeck() {
        let d = Self.deck
        guard let mix, let t = current, mix.deck(d).track?.key == t.key, !mix.deck(d).loading,
              mix.range(d) == nil, mix.ripMark(d) == nil,
              RipChecks.shared.open(t.key).contains(where: \.cuts) else { return }
        mix.pendingRip[d] = t.key
        mix.applyPendingRip(d)
    }

    /// Einstellung: Import-Lauf und alle erledigt-Markierungen zurücksetzen
    func resetRun() {
        store.reset()
        revision += 1
        StatusCenter.post(.info, String(localized: "Import-Lauf und erledigt-Markierungen zurückgesetzt"), key: "audioedit")
    }
}

extension RipChecks {
    /// Rip-Prüfung in der aktuellen Fassung vorhanden
    static func checked(_ key: String) -> Bool { (shared.store.entry(for: key)?.version ?? 0) >= RipCheck.version }
}

extension AudioEdit.Status {
    var label: String {
        switch self {
        case .waiting: String(localized: "wartet")
        case .analysing: String(localized: "analysiert …")
        case let .suggestions(n): String(localized: "Vorschläge \(n)")
        case .ok: String(localized: "ok")
        case .reviewed: String(localized: "erledigt")
        case .unchecked: "–"
        }
    }

    var color: Color {
        switch self {
        case .waiting, .reviewed, .unchecked: Theme.muted
        case .analysing, .ok: Theme.bone
        case .suggestions: Theme.gold
        }
    }
}

/// Rechtsklick auf Quellen (Baum): Import-Analyse im Audio-Edit-Modus
struct ImportMenuButton: View {
    /// Name der Quelle (Kopf der Arbeitsliste)
    let source: String
    let tracks: () -> [Track]
    var body: some View {
        Button("Import analysieren …") { AudioEditMode.shared.importRun(tracks(), title: source) }
    }
}

/// Browser-Bereich im Audio-Edit-Modus: oben der Editor (Werkzeugzeile, Wellenform von Deck A), darunter Arbeitsliste,
/// Marken und Schritte (Rückgängig) und die Vorschläge zum geladenen Track
struct AudioEditArea: View {
    var body: some View {
        VStack(spacing: 0) {
            AudioEditToolbar()
            AudioEditWaveHost()
            Rectangle().fill(Theme.hairline).frame(height: 1)
            HStack(spacing: 0) {
                AudioEditWorkList()
                    .frame(width: 340.z)
                Rectangle().fill(Theme.hairline).frame(width: 1)
                VStack(spacing: 0) {
                    AudioEditMarkers()
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                    AudioEditHistory()
                }
                .frame(width: 320.z)
                Rectangle().fill(Theme.hairline).frame(width: 1)
                AudioEditSuggestions()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
        }
        .background(Theme.chitin)
        .onChange(of: RipChecks.shared.revision) { _, _ in AudioEditMode.shared.markRipOnDeck() }
    }
}

/// Wellenform des Editors mit dem Stand des Modus (neu gezeichnet nur bei Änderung)
struct AudioEditWaveHost: View {
    @Environment(MixModel.self) private var mix

    var body: some View {
        let m = AudioEditMode.shared
        let d = AudioEditMode.deck
        AudioEditWave(state: AudioEditWaveState(selection: m.selection, cursor: m.cursor, secPerPoint: m.secPerPoint,
                                                viewStart: m.viewStart, marks: m.marks, edit: mix.decks[d].edit,
                                                duration: mix.deck(d).duration, revision: m.revision))
            .frame(height: 240.z)
    }
}

/// Arbeitsliste: Kopf (Quelle, Anzahl, ✕), Knöpfe ZURÜCK / WEITER / ERLEDIGT, Zeilen mit Stand
struct AudioEditWorkList: View {
    var body: some View {
        let m = AudioEditMode.shared
        let _ = m.revision
        let _ = RipChecks.shared.revision
        let _ = Analyses.shared.running
        let _ = Analyses.shared.progress
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6.z) {
                Text(verbatim: m.title).font(Theme.label(11.z)).lineLimit(1)
                Text(verbatim: String(localized: "\(m.list.count) Tracks · \(m.list.filter(m.isReviewed).count) erledigt"))
                    .font(Theme.mono(10.z)).foregroundStyle(Theme.muted).lineLimit(1)
                Spacer(minLength: 4.z)
                Button { m.leave() } label: { Text(verbatim: "✕ AUDIO-EDIT").font(Theme.label(10.z)) }
                    .buttonStyle(.plain).help(String(localized: "Audio-Edit-Modus verlassen, Ansicht wie vorher"))
            }
            .padding(.horizontal, 8.z).padding(.vertical, 6.z)
            HStack(spacing: 4.z) {
                DeckButton(title: String(localized: "◀ ZURÜCK")) { m.previous() }
                DeckButton(title: String(localized: "WEITER ▶")) { m.next() }
                DeckButton(title: String(localized: "✓ ERLEDIGT"), active: true) { m.done() }
            }
            .padding(.horizontal, 8.z).padding(.bottom, 6.z)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            if m.list.isEmpty {
                Text("keine Tracks").font(Theme.mono(11.z)).foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(m.list.enumerated()), id: \.element.key) { i, t in
                                row(i, t, m).id(t.key)
                            }
                        }
                    }
                    .onChange(of: m.index) { _, _ in
                        if let k = m.current?.key { proxy.scrollTo(k) }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func row(_ i: Int, _ t: Track, _ m: AudioEditMode) -> some View {
        let st = m.status(t)
        return HStack(spacing: 6.z) {
            Text(verbatim: st.label).font(Theme.mono(10.z)).foregroundStyle(st.color)
                .frame(width: 96.z, alignment: .leading).lineLimit(1)
            Text(verbatim: [t.artist, t.title].filter { !$0.isEmpty }.joined(separator: " – "))
                .font(Theme.mono(11.z)).foregroundStyle(i == m.index ? Theme.bone : Theme.bone.opacity(0.8)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8.z).padding(.vertical, 5.z)
        .background(i == m.index ? Theme.state.opacity(0.2) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { m.show(i) }
        .contextMenu {
            if st == .reviewed { Button("Erledigt zurücknehmen") { m.reopen(i) } }
        }
    }
}

/// Vorschläge zum geladenen Track: Rip-Befunde (Aktionen wie im Menü des Tracks), Grid, Lautheit, fehlende Werte
struct AudioEditSuggestions: View {
    @Environment(MixModel.self) private var mix

    var body: some View {
        let m = AudioEditMode.shared
        let _ = m.revision
        let _ = RipChecks.shared.revision
        if let t = m.current {
            let st = m.status(t)
            let open = RipChecks.shared.open(t.key)
            let d = AudioEditMode.deck
            ScrollView {
                VStack(alignment: .leading, spacing: 12.z) {
                    VStack(alignment: .leading, spacing: 3.z) {
                        Text(verbatim: [t.artist, t.title].filter { !$0.isEmpty }.joined(separator: " – "))
                            .font(Theme.label(12.z)).lineLimit(2)
                        Text(verbatim: facts(t)).font(Theme.mono(10.z)).foregroundStyle(Theme.muted)
                    }
                    switch st {
                    case .waiting, .analysing:
                        note(String(localized: "Noch in der Analyse: Vorschläge folgen, wenn sie fertig ist."))
                    case .unchecked:
                        note(String(localized: "Nicht geprüft. Rechtsklick auf den Track → Rip prüfen, oder Import analysieren …"))
                    default:
                        if open.isEmpty {
                            note(String(localized: "Keine offenen Befunde der Rip-Prüfung."))
                        } else {
                            section(String(localized: "RIP-BEFUND")) {
                                RipFindingsView(track: t, mark: { mix.markRip(d, $0) }, close: {})
                            }
                        }
                        if open.contains(where: { $0.kind == .grid }) {
                            section(String(localized: "GRID")) {
                                note(String(localized: "Grid am Anfang prüfen: Tempo oder Beat-Phase passen nicht zum fremden Anfang."))
                                DeckButton(title: String(localized: "GRID-WERKZEUGE")) { mix.prefs.ui.showGridTools = true }
                            }
                        }
                        if let p = t.peakDb, p > mix.prefs.ui.audioEditHeadroom {
                            section(String(localized: "LAUTHEIT")) {
                                note(String(localized: "Spitze \(String(format: "%.1f", p)) dB unter 0 dBFS: lauter machen?"))
                                HStack(spacing: 4.z) {
                                    DeckButton(title: "NORM") { mix.prepareNorm(d) }
                                    DeckButton(title: "AMP +3") { mix.prepareAmp(d, add: 3) }
                                }
                            }
                        }
                        if t.musicalKey < 0 || !(t.bpm > 0) || t.gridAnchorMs == nil {
                            section(String(localized: "FEHLT")) {
                                note(missing(t))
                            }
                        }
                    }
                }
                .padding(12.z)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text("kein Track geladen").font(Theme.mono(11.z)).foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func facts(_ t: Track) -> String {
        let bpm = t.bpm > 0 ? String(format: "%.1f", t.bpm) : "–"
        let key = t.musicalKey >= 0 ? Track.openKey(code: t.musicalKey) : "–"
        var s = String(localized: "BPM \(bpm) · Tonart \(key)")
        if let p = t.peakDb { s += String(localized: " · Reserve \(String(format: "%.1f", p)) dB") }
        return s
    }

    private func missing(_ t: Track) -> String {
        var parts: [String] = []
        if t.musicalKey < 0 { parts.append(String(localized: "Tonart")) }
        if !(t.bpm > 0) || t.gridAnchorMs == nil { parts.append(String(localized: "Tempo / Grid")) }
        return parts.joined(separator: " · ") + " " + String(localized: "nach der Analyse nicht erkannt")
    }

    private func note(_ s: String) -> some View {
        Text(verbatim: s).font(Theme.mono(10.z)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4.z) {
            Text(verbatim: title).font(Theme.label(10.z)).foregroundStyle(Theme.gold)
            content()
        }
    }
}
