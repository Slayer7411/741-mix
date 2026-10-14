import AppKit
import Observation
import SwiftUI
import MixCore
import MixEngine

/// Rip-Prüfung: Ergebnisse (`ripcheck.json`), offene Befunde (nicht verworfen, ohne Schnitt auf ihrer Seite),
/// Aktionen (Schnitt setzen, Bereich als neue Datei entfernen, verwerfen). Geprüft wird in der Analyse-Warteschlange.
@MainActor @Observable
final class RipChecks {
    static let shared = RipChecks()

    @ObservationIgnored let store = RipCheckStore(url: Session.isSelfTest ? nil : HistoryStore.baseDir.appendingPathComponent("ripcheck.json"))
    /// Änderungszähler (Spalte, Chip, Quelle ZU BEARBEITEN)
    private(set) var revision = 0
    /// Tracks mit offenem Befund
    @ObservationIgnored private(set) var openKeys: Set<String> = []
    @ObservationIgnored weak var mix: MixModel? { didSet { for k in store.all.keys { changed(k) } } }
    @ObservationIgnored weak var library: LibraryStore?
    @ObservationIgnored private var pending: Set<String> = []

    var openCount: Int { openKeys.count }

    private init() {
        store.onChange = { key in
            DispatchQueue.main.async { MainActor.assumeIsolated { RipChecks.shared.changed(key) } }
        }
        for k in store.all.keys where !open(k).isEmpty { openKeys.insert(k) }
    }

    /// offene Befunde eines Tracks
    func open(_ key: String) -> [RipCheck.Finding] {
        guard let e = store.entry(for: key) else { return [] }
        let ed = mix?.edits.edit(for: key)
        return e.open(trim: ed?.trim, gridEdited: ed?.hasGrid ?? false)
    }

    func columnText(_ key: String) -> String {
        openKeys.contains(key) ? RipCheck.columnText(open(key)) : ""
    }

    /// Ergebnis, eigene Änderung oder Verwerfen eines Tracks geändert: gesammelt neu zählen
    func changed(_ key: String) {
        pending.insert(key)
        guard pending.count == 1 else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let s = RipChecks.shared
                for k in s.pending { if s.open(k).isEmpty { s.openKeys.remove(k) } else { s.openKeys.insert(k) } }
                s.pending = []
                s.revision += 1
            }
        }
    }

    /// Grid für die Prüfung: von Hand gesetztes, sonst das des Tracks
    func grid(of t: Track) -> (bpm: Double, anchor: Double)? {
        if let e = mix?.edits.edit(for: t.key), let b = e.bpm, b > 0, let a = e.gridAnchorMs { return (b, a / 1000) }
        guard t.bpm.isFinite, t.bpm > 0, let a = t.gridAnchorMs else { return nil }
        return (t.bpm, a / 1000)
    }

    func duration(_ key: String) -> Double { store.entry(for: key)?.result.duration ?? 0 }

    private func loadedDeck(_ key: String) -> Int? {
        guard let mix else { return nil }
        return mix.decks.indices.first { mix.deck($0).track?.key == key && !mix.deck($0).loading }
    }

    // MARK: Aktionen

    /// Schnitt IN / OUT auf den Vorschlag (edits.json, keine neue Datei); im Deck mit Rückgängig
    func applyCut(_ key: String, _ f: RipCheck.Finding) {
        guard let mix, f.cuts else { return }
        var e = mix.edits.edit(for: key) ?? TrackEdit()
        var trim = e.trim
        if f.edge == .start { trim.start = f.time } else { trim.end = f.time }
        guard let n = trim.normalized(duration: duration(key)) else {
            StatusCenter.post(.warning, String(localized: "Schnitt zu kurz (mindestens 1 s)"), key: "ripcheck")
            return
        }
        if let d = loadedDeck(key) { mix.setTrimPoint(d, end: f.edge == .end, f.time) }
        e.trim = n
        mix.edits.set(e, for: key)
        changed(key)
        StatusCenter.post(.ok, f.edge == .start ? String(localized: "Schnitt IN auf \(RipCheck.shortTime(f.time)) gesetzt")
                                                : String(localized: "Schnitt OUT auf \(RipCheck.shortTime(f.time)) gesetzt"), key: "ripcheck")
    }

    /// Bereich vor dem Schnitt IN bzw. hinter dem Schnitt OUT als neue Datei entfernen (Weg von „Bereich entfernen“);
    /// erledigt erst, wenn die Datei geschrieben ist
    func removeRegion(_ t: Track, _ f: RipCheck.Finding) {
        guard let mix, let store = library, f.cuts else { return }
        let dur = duration(t.key)
        guard let r = RipCheck.range(f, duration: dur), dur - r.length >= TrackTrim.minLength else {
            StatusCenter.post(.warning, String(localized: "Ergebnis zu kurz (mindestens 1 s)"), key: "cut")
            return
        }
        let d = loadedDeck(t.key)
        let tt = mix.edits.edit(for: t.key)?.apply(to: t) ?? t
        let grid = d.flatMap { mix.deck($0).grid } ?? BeatGrid(track: tt)
        let cues = d.map { Array(mix.deck($0).hotcues.values) } ?? tt.cues.filter { $0.hotcue >= 0 && $0.kind != .grid }
        let key = t.key
        CutJob.start(.init(deck: d ?? mix.focusedDeck, kind: .cut(.remove, r), track: tt, grid: grid, hotcues: cues,
                           audio: d.flatMap { mix.audio($0) }, load: false,
                           directory: Session.isSelfTest ? CutJob.selfTestDirectory : nil), mix: mix, store: store) {
            RipChecks.shared.markDone(key, [f])
        }
    }

    /// erledigt über den markierten Bereich (REMOVE, KEEP, neue Datei, Schnitt aus Bereich)
    func markDone(_ key: String, _ f: [RipCheck.Finding]) { store.markDone(f.map(\.id), for: key) }

    func dismiss(_ key: String, _ f: [RipCheck.Finding]) {
        markDismissed(key, f.map(\.id))
        StatusCenter.post(.info, String(localized: "Befund verworfen"), key: "ripcheck")
    }

    private func markDismissed(_ key: String, _ ids: [String]) { store.dismiss(ids, for: key) }

    /// Deck geladen: offenen Schnitt-Befund als Bereich markieren (⌘, → BROWSER → Analyse, nach dem Laden), sonst Hinweis
    func deckLoaded(_ key: String, deck d: Int, mix m: MixModel) {
        let o = open(key)
        m.pendingRip[d] = m.prefs.ui.ripMarkOnLoad && o.contains(where: \.cuts) ? key : nil
        guard !o.isEmpty, m.pendingRip[d] == nil else { return }
        let text = o.map(Self.text).joined(separator: " · ")
        StatusCenter.post(.info, String(localized: "Rip-Prüfung: \(text) · RIP in der Edit-Zeile"), key: "ripcheck.\(d)")
    }

    /// Bereiche fürs Überblicksbild (nur offene Schnitt-Befunde)
    func regions(_ key: String, duration: Double) -> [ClosedRange<Double>] {
        guard openKeys.contains(key) else { return [] }
        return open(key).filter(\.cuts).map { $0.edge == .start ? 0...$0.time : $0.time...max($0.time, duration) }
    }

    // MARK: Text

    /// Grund kurz: Stille, fremd, Grid
    static func reason(_ f: RipCheck.Finding) -> String {
        switch f.kind {
        case .silence: String(localized: "Stille")
        case .foreign: String(localized: "fremd")
        case .grid: String(localized: "Grid")
        }
    }

    static func text(_ f: RipCheck.Finding) -> String {
        let t = RipCheck.shortTime(f.time)
        switch (f.kind, f.edge) {
        case (.silence, .start): return String(localized: "Anfang \(t) Stille")
        case (.silence, .end): return String(localized: "Stille ab \(t)")
        case (.foreign, .start): return String(localized: "Anfang \(t) vermutlich fremd")
        case (.foreign, .end): return String(localized: "Ende ab \(t) vermutlich fremd")
        case (.grid, _): return String(localized: "Grid prüfen")
        }
    }

    /// Gründe: Tonart, Spektrum, Tempo, Loop, Anker, Phase
    static func reasons(_ f: RipCheck.Finding) -> String {
        var p: [String] = []
        for c in f.cues {
            switch c {
            case .silence: break
            case .key:
                let a = f.keyForeign.map(Track.openKey(code:)) ?? "–", b = f.keyTrack.map(Track.openKey(code:)) ?? "–"
                p.append(f.edge == .start ? String(localized: "Tonart \(a) → \(b)") : String(localized: "Tonart \(b) → \(a)"))
            case .spectrum: p.append(String(localized: "Klang wechselt"))
            case .tempo: p.append(String(localized: "anderes Tempo \(String(format: "%.1f", f.localBPM ?? 0))"))
            case .loop: p.append(String(localized: "Loop \(f.bars ?? 4) Takte"))
            case .anchor: p.append(String(localized: "Anker im fremden Anfang"))
            case .phase: p.append(String(localized: "Beat am Anfang um \(String(format: "%+.0f", f.offsetMs ?? 0)) ms versetzt"))
            case .drift: p.append(String(localized: "Tempo am Anfang \(String(format: "%.1f", f.localBPM ?? 0))"))
            }
        }
        if f.kind == .foreign, let b = f.bars, !f.cues.contains(.loop) { p.append(String(localized: "\(b) Takte")) }
        p.append(String(localized: "Sicherheit \(Int((f.confidence * 100).rounded())) %"))
        return p.joined(separator: " · ")
    }

    /// Rechtsklick auf Tracks: Rip prüfen, bei einem Track mit offenem Befund die Aktionen
    func addMenuItems(_ menu: NSMenu, tracks: @escaping () -> [Track], single: Track?) {
        menu.addItem(ActionItem(String(localized: "Rip prüfen")) { Analyses.shared.enqueueRip(tracks()) })
        guard let t = single else { return }
        let o = open(t.key)
        guard !o.isEmpty else { return }
        for f in o {
            let head = NSMenuItem(title: Self.text(f) + " – " + Self.reasons(f), action: nil, keyEquivalent: "")
            head.isEnabled = false
            menu.addItem(head)
            if f.cuts {
                menu.addItem(ActionItem(f.edge == .start ? String(localized: "Schnitt IN auf \(RipCheck.shortTime(f.time)) setzen")
                                                         : String(localized: "Schnitt OUT auf \(RipCheck.shortTime(f.time)) setzen")) { [weak self] in
                    self?.applyCut(t.key, f)
                })
                menu.addItem(ActionItem(String(localized: "Bereich entfernen (neue Datei)")) { [weak self] in self?.removeRegion(t, f) })
                if let d = loadedDeck(t.key), let mix {
                    menu.addItem(ActionItem(String(localized: "Befund als Bereich markieren")) { mix.markRip(d, f) })
                }
            }
        }
        menu.addItem(ActionItem(String(localized: "Befund verwerfen")) { [weak self] in self?.dismiss(t.key, o) })
    }
}

/// ◆ RIP: nur Tracks mit offenem Befund der Rip-Prüfung
struct RipChip: View {
    let model: BrowserPaneModel

    var body: some View {
        let n = RipChecks.shared.revision >= 0 ? RipChecks.shared.openCount : 0
        DeckButton(title: String(localized: "◆ RIP") + (n > 0 ? " \(n)" : ""), active: model.ripOnly, verbatim: true) { model.ripOnly.toggle() }
            .help("Nur Tracks mit offenem Befund der Rip-Prüfung: Stille, fremder Anfang oder fremdes Ende, Grid prüfen. Rechtsklick auf Tracks → Rip prüfen")
            .background(UITestMark(name: "rip chip"))
    }
}

/// RIP in der Edit- und Vorbereiten-Zeile: nur bei offenem Befund des geladenen Tracks. Klick = Befund als markierten
/// Bereich (weitere Klicks: nächster Befund), ⌥-Klick oder nur Grid-Befund = Befunde und Aktionen
struct RipDeckButton: View {
    @Environment(MixModel.self) private var mix
    let d: Int
    @State private var show = false

    var body: some View {
        let rips = RipChecks.shared
        let _ = rips.revision
        if let t = mix.deck(d).track, !mix.deck(d).loading, rips.openKeys.contains(t.key) {
            DeckButton(title: "RIP", active: true, color: Theme.state) {
                if NSEvent.modifierFlags.contains(.option) || !mix.markNextRip(d) { show.toggle() }
            }
                .help("Rip-Prüfung: Befund am Anfang oder Ende als Bereich markieren (nichts wird geschnitten), ⌥-Klick: Befunde")
                .popover(isPresented: $show, arrowEdge: .bottom) { RipFindingsView(track: t, mark: { [mix, d] in mix.markRip(d, $0) }) { show = false } }
        }
    }
}

struct RipFindingsView: View {
    let track: Track
    /// Befund als Bereich im Deck markieren
    var mark: ((RipCheck.Finding) -> Void)?
    let close: () -> Void

    var body: some View {
        let rips = RipChecks.shared
        let _ = rips.revision
        let o = rips.open(track.key)
        VStack(alignment: .leading, spacing: 8) {
            Text("RIP-PRÜFUNG").font(Theme.label(13, .bold))
            ForEach(o) { f in
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: RipChecks.text(f)).font(Theme.mono(11)).foregroundStyle(Theme.bone)
                    Text(verbatim: RipChecks.reasons(f)).font(Theme.mono(10)).foregroundStyle(Theme.muted)
                    HStack(spacing: 4) {
                        if f.cuts, let mark {
                            DeckButton(title: "◆ BEREICH") { mark(f); close() }
                        }
                        if f.cuts {
                            DeckButton(title: f.edge == .start ? String(localized: "◆ SCHNITT IN \(RipCheck.shortTime(f.time))")
                                                               : String(localized: "◆ SCHNITT OUT \(RipCheck.shortTime(f.time))"),
                                       active: true, verbatim: true) { rips.applyCut(track.key, f); close() }
                            DeckButton(title: "◆ ENTFERNEN (NEUE DATEI)") { rips.removeRegion(track, f); close() }
                        }
                        DeckButton(title: "◆ VERWERFEN") { rips.dismiss(track.key, [f]) }
                    }
                }
            }
        }
        .padding(12)
        .frame(minWidth: 320, alignment: .leading)
        .background(Theme.chitin)
        .zoomExempt()
    }
}

/// markierter Bereich aus einem Befund der Rip-Prüfung: Beschriftung „RIP · …“, Grund im Menü und in der Statuszeile.
/// Gilt, bis der Bereich aufgehoben, neu markiert oder ein anderer Track geladen wird; Ränder ziehen behält ihn
struct RipMark: Equatable {
    let key: String
    let finding: RipCheck.Finding
}

extension MixModel {
    /// RIP-Kennzeichnung des markierten Bereichs
    func ripMark(_ d: Int) -> RipMark? {
        guard decks.indices.contains(d), decks[d].range != nil, let m = decks[d].rip, m.key == decks[d].trackKey else { return nil }
        return m
    }

    func dropRipMark(_ d: Int) { if decks.indices.contains(d), decks[d].rip != nil { decks[d].rip = nil } }

    /// Schnittliste, die das Deck gerade spielt (nil = Original)
    func playedEditList(_ d: Int) -> EditList? {
        guard let s = editSessions[d], s.preview != nil, core.trackAudio(d) === s.preview else { return nil }
        return s.shown
    }

    /// Beschriftung des Bereichs (Wellenform, Menü)
    func rangeMarked(_ d: Int, grid: BeatGrid?) -> WaveScene.Marked? {
        range(d).map { WaveScene.Marked($0, grid: grid, rip: ripMark(d) != nil) }
    }

    /// Befund als markierten Bereich (anpassbar wie jeder Bereich); geschnitten wird nichts
    @discardableResult
    func markRip(_ d: Int, _ f: RipCheck.Finding) -> Bool {
        let s = deck(d)
        guard let t = s.track, !s.loading, s.duration > 0, f.cuts else { return false }
        if editSessions[d]?.rendering == true {
            StatusCenter.post(.info, String(localized: "Schnittliste wird noch gerechnet …"), key: "edit.\(d)")
            return false
        }
        let edl = playedEditList(d)
        let dur = edl != nil ? editSessions[d]?.source.duration ?? s.duration : s.duration
        guard let r = RipCheck.range(f, duration: dur, edl: edl) else {
            StatusCenter.post(.info, String(localized: "Rip-Befund liegt nicht mehr in der Schnittliste"), key: "ripcheck.\(d)")
            return false
        }
        setRange(d, r)
        decks[d].rip = RipMark(key: t.key, finding: f)
        StatusCenter.post(.info, String(localized: "RIP-Bereich markiert (\(RipChecks.reason(f))): \(RipChecks.text(f)) – \(RipChecks.reasons(f)) · Rechtsklick → Markierten Bereich entfernen"),
                          key: "ripcheck.\(d)")
        return true
    }

    /// RIP-Knopf: nächster offener Schnitt-Befund als Bereich; false = keiner
    func markNextRip(_ d: Int) -> Bool {
        guard let key = deck(d).track?.key else { return false }
        let o = RipChecks.shared.open(key).filter(\.cuts)
        guard !o.isEmpty else { return false }
        let i = ripMark(d).flatMap { m in o.firstIndex { $0.id == m.finding.id } }.map { ($0 + 1) % o.count } ?? 0
        return markRip(d, o[i])
    }

    /// nach dem Laden (und dem Rechnen einer Schnittliste) den vorgemerkten Befund markieren
    func applyPendingRip(_ d: Int) {
        guard let k = pendingRip[d], let t = deck(d).track, t.key == k, !deck(d).loading, core.trackAudio(d) != nil else { return }
        if editing(d), editSessions[d]?.rendering ?? true { return }
        pendingRip[d] = nil
        if let f = RipChecks.shared.open(k).first(where: \.cuts) { markRip(d, f) }
    }

    /// Aktion auf dem markierten Bereich ausgeführt: RIP-Befund erledigt
    func ripRangeDone(_ m: RipMark?) {
        guard let m else { return }
        RipChecks.shared.markDone(m.key, [m.finding])
        StatusCenter.post(.ok, String(localized: "Rip-Befund erledigt: \(RipChecks.text(m.finding))"), key: "ripcheck")
    }

    /// „Markierten Bereich entfernen“: aus der Schnittliste (REMOVE, keine Datei). Ohne EDIT-Modus schaltet es ihn ein –
    /// die Liste spielt nur dort
    func removeMarkedRange(_ d: Int) {
        guard range(d) != nil else { return }
        if !editing(d) {
            setEditing(d, true)
            if editSessions[d]?.rendering == true {
                if let m = ripMark(d) { pendingRip[d] = m.key }
                setRange(d, nil)
                StatusCenter.post(.info, String(localized: "EDIT an: Schnittliste wird gerechnet, Bereich danach neu markieren"), key: "edit.\(d)")
                return
            }
        }
        editAction(d, .remove)
    }
}
