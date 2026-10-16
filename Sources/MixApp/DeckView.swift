import SwiftUI
import AppKit
import MixCore
import MixEngine

/// Deck: jede Zeile ist eine eigene Ansicht, die nur ihren Ausschnitt des Deck-Zustands liest (äußere Hülle) und ihn
/// als Wert an eine Equatable-Ansicht gibt. Ändert sich etwas anderes, überspringt SwiftUI Body und Layout der Zeile –
/// eine Zustandsänderung kostet so nur die Zeile, die sie zeigt, statt das ganze Deck neu zu messen.
struct DeckView: View {
    @Environment(MixModel.self) private var mix
    @Environment(LibraryStore.self) private var store
    @Environment(BrowserState.self) private var browser
    let d: Int
    /// Platz für Cover-Spalte und Zeilen (ohne Pitch-Fader): begrenzt die Cover-Breite
    @State private var area = CGSize.zero

    var body: some View {
        let ui = mix.prefs.ui
        let rows = ui.deckRows
        let gridRow = ui.showGridTools
        // großes Cover: eigene Spalte links, über Kopf und Wellenform; der Kopf behält seine Höhe
        let coverSide = ui.deckCoverColumn
            ? DeckCoverFit.side(wanted: ui.deckCoverSize.z, deckWidth: area.width - 4.z, deckHeight: area.height, zoom: 1.z, spacing: 6.z) : 0
        HStack(alignment: .top, spacing: 6.z) {
          HStack(alignment: .top, spacing: 6.z) {
            if coverSide > 0 { CoverTile(d: d, side: coverSide).background(UITestMark(name: deckLetters[d] + " cover")).padding(.leading, 4.z) }
            VStack(alignment: .leading, spacing: 4.z) {
                // Kopfhöhe hängt an den FX-Tasten (ohne Mixer: 1 oder 2 Reihen), am Cover und an den Zusatzinfos
                row("header", DeckHeader(d: d).modifier(DeckDropTarget(d: d)),
                    key: [ui.showMixer ? 0 : ui.fxUnitCount, !ui.showMixer && mix.eqVisible ? 1 : 0, ui.deckCoverInHeader ? Int(ui.deckCoverSize) : 0, rows.info ? 1 : 0, rows.comment || rows.tags ? 1 : 0])
                WaveformView(d: d)
                    .overlay { DeckIdleView(d: d) }   // leer: Lobster, nach Ladefehler 5 s Totenkopf
                    .frame(minHeight: mix.prefs.ui.waveformHeight.z, maxHeight: .infinity)
                if rows.phaseBar { PhaseBar(d: d).frame(height: 8.z) }
                if rows.overview {
                    // Rahmen wie der Phasenbalken: ohne Track sähe die leere Zeile wie ein Spalt aus
                    OverviewView(d: d)
                        .frame(height: ui.overviewHeight.z)
                        .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
                }
                // DAW-Brücke meldet einen Clip derselben Datei: Grid-Streifen mit Position der DAW
                if DAWBridgeModel.shared.deckClip[d] != nil {
                    row("daw", DAWClipStrip(d: d).frame(height: 12.z).overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1)))
                }
                if rows.transport { row("transport", TransportRow(d: d)) }
                if rows.hotcues { row("cues", CueRow(d: d)) }
                // EDIT: Schnitt an der Stelle der Loop-Größen, Grid an der von Beatjump, falls die Grid-Zeile aus ist.
                // Beide Zeilen liegen im selben Platz übereinander, Umschalten ändert nur die Deckkraft: keine neuen
                // Hosting-Views, kein neues Deck-Layout. Der Schalter wird nur gelesen, wo er eine Zeile hinzufügt
                // Vorbereiten: eigene Werkzeugzeile mit Schnitt und Grid, EDIT bringt dann keine Zeilen dazu
                let editRows = !rows.prepare && mix.editing(d)
                if rows.loop || editRows { row("loop", Slot(d: d, normal: LoopRow(d: d), edit: CutRow(d: d))) }
                if rows.jump || (!gridRow && editRows) {
                    if gridRow { row("jump", JumpRow(d: d)) } else { row("jump", Slot(d: d, normal: JumpRow(d: d), edit: GridToolsRow(d: d))) }
                }
                if gridRow { row("grid", GridToolsRow(d: d)) }
                if rows.groove { row("groove", GrooveRow(d: d)) }
                if rows.prepare { row("prepare", PrepareRow(d: d)) }
            }
          }
          .onGeometryChange(for: CGSize.self, of: { $0.size }) { area = $0 }
            if rows.tempo { TempoColumn(d: d).padding(.trailing, 3.z) }
        }
        .padding(.vertical, 3.z)   // seitlich nichts: die Wellenform endet am Deck-Rand (Zeilen rücken selbst ein)
        .frame(maxHeight: .infinity)
        .background(Frame(d: d, border: false))
        .overlay(Frame(d: d, border: true))
        .contentShape(Rectangle())
        .onTapGesture { mix.focusedDeck = d }
    }

    /// Fläche und Rahmen (Fokus, Master gold) lesen Fokus und Master selbst: ein Master-Wechsel färbt nur sie neu,
    /// DeckView und seine Zeilen bleiben unberührt
    struct Frame: View {
        @Environment(MixModel.self) private var mix
        let d: Int
        let border: Bool

        var body: some View {
            let focused = mix.focusedDeck == d
            if border {
                Rectangle().stroke(mix.effectiveMaster == d ? Theme.gold : (focused ? Theme.bone.opacity(0.5) : Theme.hairline), lineWidth: 1)
            } else {
                Rectangle().fill(focused ? Theme.deckFocused : Theme.deck)
            }
        }
    }

    /// Zeile in eigener Hosting-View: eine Änderung (Taste an/aus) rechnet nur das Layout dieser Zeile, nicht das des
    /// ganzen Decks. Breite vom Deck, Höhe einmal gemessen (je `key`, z. B. FX-Tasten im Kopf ohne Mixer).
    private func row<V: View>(_ name: String, _ v: V, key: AnyHashable = 0) -> some View {
        // eigene Hosting-View erbt keine Umgebung: Library und Browser mitgeben (Menü „Track bearbeiten“, Drop-Ziel im Kopf)
        Isolated(deckLetters[d] + " " + name, sizeKey: key, fillWidth: true) {
            v.environment(mix).environment(store).environment(browser).foregroundStyle(Theme.bone).tint(Theme.state)
                .padding(.horizontal, 4.z)
        }
    }

    static func same(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

    /// Zeile mit zweitem Inhalt für den EDIT-Modus: beide bleiben aufgebaut, sichtbar ist einer
    struct Slot<Normal: View, Edit: View>: View {
        @Environment(MixModel.self) private var mix
        let d: Int
        let normal: Normal
        let edit: Edit

        var body: some View {
            let on = mix.editing(d)
            ZStack {
                normal.opacity(on ? 0 : 1).allowsHitTesting(!on)
                edit.opacity(on ? 1 : 0).allowsHitTesting(on)
            }
        }
    }
}

/// Deck in eigener NSHostingView = Layout-Grenze. SwiftUI reicht jede Größen-Invalidierung bis zur Wurzel durch und
/// misst von dort alles neu (vier Decks, Mixer, Leiste, Browser); in eigener Hosting-View rechnet eine Zustandsänderung
/// nur das Layout dieses Decks. Größe kommt von außen (sizingOptions leer: keine Rückmeldung nach oben).
struct DeckHost: NSViewRepresentable {
    @Environment(MixModel.self) private var mix
    @Environment(WaveformCache.self) private var cache
    @Environment(LibraryStore.self) private var store
    @Environment(BrowserState.self) private var browser
    let d: Int

    /// eigene Hosting-View erbt keine Umgebung: alles, was das Deck liest (Menü „Track bearbeiten“, Drop-Ziel), kommt hier mit
    struct Root: View {
        let d: Int
        let mix: MixModel
        let cache: WaveformCache
        let store: LibraryStore
        let browser: BrowserState
        var body: some View {
            DeckView(d: d)
                .environment(mix)
                .environment(cache)
                .environment(store)
                .environment(browser)
                .foregroundStyle(Theme.bone)
                .tint(Theme.state)
        }
    }

    func makeNSView(context: Context) -> BoundaryHostingView<Root> {
        let v = BoundaryHostingView(rootView: Root(d: d, mix: mix, cache: cache, store: store, browser: browser))
        v.name = "deck " + deckLetters[d]
        v.sizingOptions = []
        // Rechtsklick auf die Deckfläche (Zeilen, Cover, Übersicht, Wellenform ohne eigenes Menü): Track-Menü
        v.areaMenu = { [weak v] _ in
            guard let r = v?.rootView else { return nil }
            return TrackMenu.deckMenu(r.d, mix: r.mix, store: r.store, browser: r.browser)
        }
        return v
    }

    func updateNSView(_ v: BoundaryHostingView<Root>, context: Context) {
        if v.rootView.d != d || v.rootView.mix !== mix || v.rootView.cache !== cache || v.rootView.store !== store || v.rootView.browser !== browser {
            v.rootView = Root(d: d, mix: mix, cache: cache, store: store, browser: browser)
        }
    }

    /// nimmt den angebotenen Platz; sonst fragt SwiftUI bei jedem äußeren Layout fittingSize ab (Auto Layout + inneres Layout)
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: BoundaryHostingView<Root>, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}

/// Track per Maus vom Deck ziehen: auf ein anderes Deck (laden, Lade-Schutz gilt, ⌥ erzwingt) oder auf PREPARATION
enum TrackDrag {
    static let prefix = "minos741-track:"

    static func provider(_ key: String?) -> NSItemProvider {
        NSItemProvider(object: (key.map { prefix + $0 } ?? "") as NSString)
    }

    /// Schlüssel aus den Providern (nur eigene Tracks), auf dem Hauptthread
    @discardableResult
    static func keys(_ providers: [NSItemProvider], _ done: @escaping @MainActor ([String]) -> Void) -> Bool {
        let own = providers.filter { $0.canLoadObject(ofClass: NSString.self) }
        guard !own.isEmpty else { return false }
        var keys: [String] = []
        let group = DispatchGroup()
        for p in own {
            group.enter()
            p.loadObject(ofClass: NSString.self) { obj, _ in
                if let s = obj as? String, s.hasPrefix(prefix) { keys.append(String(s.dropFirst(prefix.count))) }
                group.leave()
            }
        }
        group.notify(queue: .main) { MainActor.assumeIsolated { if !keys.isEmpty { done(keys) } } }
        return true
    }
}

/// Deck als Ziel: Track aus einem anderen Deck (oder dem Browser) fallen lassen -> laden
struct DeckDropTarget: ViewModifier {
    @Environment(MixModel.self) private var mix
    @Environment(LibraryStore.self) private var store
    let d: Int
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .onDrop(of: [.text], isTargeted: $targeted) { providers in
                TrackDrag.keys(providers) { keys in
                    guard let k = keys.first, let t = store.track(k) ?? mix.decks.compactMap({ $0.state.track }).first(where: { $0.key == k }) else { return }
                    if !mix.load(t, deck: d) { StatusCenter.post(.warning, String(localized: "Deck \(deckLetters[d]) spielt · Laden gesperrt (⌥ erzwingt)"), key: "load.\(d)") }
                }
            }
            .overlay { if targeted { Rectangle().stroke(Theme.state, lineWidth: 2) } }
    }
}

/// Kopf: Buchstabe, Titel/Artist, FX-Zuweisung, Zeit, BPM, Code, Key, Phase. Rechtsklick: Track-Menü der Deckfläche
struct DeckHeader: View {
    @Environment(MixModel.self) private var mix
    let d: Int

    struct Model: Equatable {
        var playing = false, title = "", subtitle = "", isError = false
        var showFX = false, fxUnits = 2, fxAssign: [Bool] = [], info = true, meta = true
        var showEQ = false, eq: [Double] = [0, 0, 0]   // HI, MID, LO: ohne Mixer-Ansicht am Deck
        var bpm = 0.0, tempoPct = 0.0, gridEdited = false
        var time = TimeReadout.Model(), code = CodeReadout.Model(), key = KeyReadout.Model(), phaseActive = false
    }

    var body: some View {
        let s = mix.deck(d), ui = mix.prefs.ui
        var m = Model()
        m.playing = s.playing
        m.title = s.loading ? "Lade …" : (s.track?.title ?? "—")
        m.subtitle = s.error ?? s.track?.artist ?? String(localized: "Kein Track geladen")
        m.isError = s.error != nil
        m.showFX = !ui.showMixer
        m.showEQ = !ui.showMixer && mix.eqVisible
        m.eq = [s.eqHigh, s.eqMid, s.eqLow]
        m.fxUnits = ui.fxUnitCount
        m.fxAssign = s.fxAssign
        m.info = ui.deckRows.info
        m.meta = ui.deckRows.comment || ui.deckRows.tags
        m.bpm = s.bpm
        m.tempoPct = s.tempoPct
        m.gridEdited = s.gridEdited
        m.time = .init(hasTrack: s.track != nil, end: s.duration > 0 ? s.playRange.upperBound : 0, playing: s.playing, grid: s.grid,
                       warnAt: mix.prefs.engine.trackEndWarning)
        m.code = .init(hasTrack: s.track != nil, playing: s.playing, bars: max(4, ui.phraseBeats) / 4)
        m.key = KeyReadout.Model(track: s.track, deviation: mix.keyDeviation(d))
        m.phaseActive = s.playing && (mix.clockMaster || mix.effectiveMaster != nil)
        return Content(d: d, m: m).equatable()
    }

    struct Content: View, Equatable {
        @Environment(MixModel.self) private var mix
        let d: Int
        let m: Model
        static func == (a: Self, b: Self) -> Bool { a.d == b.d && a.m == b.m }

        var body: some View {
            HStack(alignment: .center, spacing: 6.z) {
                Text(deckLetters[d]).font(Theme.label(22.z, .bold)).foregroundStyle(m.playing ? Theme.state : Theme.bone)
                CoverTile(d: d)
                VStack(alignment: .leading, spacing: 0) {
                    Text(m.title)
                        .font(Theme.mono(13.z, .semibold)).lineLimit(1)
                    Text(m.subtitle)
                        .font(Theme.mono(11.z)).foregroundStyle(m.isError ? Color.red : Color.secondary).lineLimit(1)
                }
                .contentShape(Rectangle())
                .onDrag { TrackDrag.provider(mix.deck(d).track?.key) }
                .layoutPriority(1)   // Titel vor den Tags
                // Kommentar und Tags in der freien Mitte des Kopfs statt in einer eigenen Zeile
                if m.meta { DeckMetaRow(d: d, inline: true) } else { Spacer(minLength: 4.z) }
                if m.showEQ {
                    // ohne Mixer-Ansicht: EQ direkt am Deck
                    HStack(alignment: .bottom, spacing: 3.z) {
                        eqKnob(mix, d, \.eqHigh, "HI", size: 22)
                        eqKnob(mix, d, \.eqMid, "MID", size: 22)
                        eqKnob(mix, d, \.eqLow, "LO", size: 22)
                    }
                }
                if m.showFX {
                    // ohne Mixer-Ansicht: FX-Zuweisung direkt am Deck
                    // FX-Zuweisung am Kanal: 1 2 (3 4)
                    VStack(spacing: 2.z) {
                        ForEach(0..<(m.fxUnits == 4 ? 2 : 1), id: \.self) { row in
                            HStack(spacing: 2.z) {
                                ForEach([0, 1].map { row * 2 + $0 }, id: \.self) { u in
                                    DeckButton(title: "FX\(u + 1)", active: m.fxAssign[u], color: Theme.state) { mix.toggleFXAssign(d, u) }.stable()
                                }
                            }
                        }
                    }
                }
                if m.info {
                    TimeReadout(d: d, m: m.time).equatable()
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(String(format: "%.2f", m.bpm)).font(Theme.mono(15.z, .bold))
                        HStack(spacing: 3.z) {
                            // Grid von Hand gesetzt: kleine rote Raute vor dem Tempo (Zustand, nicht Warnung)
                            if m.gridEdited {
                                Text("◆").font(Theme.mono(8.z)).foregroundStyle(Theme.state)
                                    .help("Grid von Hand gesetzt (eigene Änderung) – RESET in der Grid-Zeile nimmt sie weg")
                            }
                            Text(String(format: "%+.2f%%", m.tempoPct)).font(Theme.mono(10.z)).foregroundStyle(.secondary)
                        }
                    }
                    CodeReadout(d: d, m: m.code).equatable()
                    KeySyncButton { mix.keySync(d) }
                        .help("Key Sync: Key-Shift auf den Key des Master-Decks (gleich oder Nachbar auf dem Open-Key-Rad, kleinster Schritt, höchstens ±6), Keylock an")
                    VStack(alignment: .trailing, spacing: 0) {
                        KeyReadout(m: m.key).equatable()
                        PhaseMeter(d: d, active: m.phaseActive).equatable().frame(width: 44.z, height: 6.z)
                    }
                    .frame(minWidth: 46.z)
                }
            }
        }
    }
}

/// Zeile unter dem Kopf, bündig mit dem Titel: Tags (Kommentar 2) wie im Browser (Textmarker in der Tag-Farbe), dahinter
/// Kommentar gedämpft. Eigene Zeile: Play, Tempo, Key im Kopf messen sie nicht mit. Ein einziger Text, eine Zeile,
/// zu lang -> „…“; feste Höhe, auch ohne Track
struct DeckMetaRow: View {
    @Environment(MixModel.self) private var mix
    let d: Int
    /// in der Mitte des Deck-Kopfs (zwei Zeilen, nimmt die freie Breite) statt als eigene Zeile
    var inline = false

    /// cover = Breite des Covers im Kopf (pt vor dem Zoom, 0 = keins)
    struct Model: Equatable { var cover = 0.0, comment = "", tags: [String] = [], tagHighlight = true, tagGroups = true, tagColors: [String: String] = [:] }

    var body: some View {
        let s = mix.deck(d), ui = mix.prefs.ui
        var m = Model(cover: ui.deckCoverInHeader ? ui.deckCoverSize : 0)
        if let t = s.track, !s.loading {
            if ui.deckRows.comment { m.comment = t.comment }
            if ui.deckRows.tags {
                // Zerlegung aus dem Speicher des Browsers (je Text einmal)
                m.tags = BrowserPaneModel.tagIndex.entry(t.comment2, separators: ui.tagSeparators).shown(groups: ui.tagGroups).tags
                m.tagHighlight = ui.tagHighlight
                m.tagColors = ui.tagColors
                m.tagGroups = ui.tagGroups
            }
        }
        return Content(d: d, m: m, inline: inline).equatable()
    }

    struct Content: View, Equatable {
        let d: Int
        let m: Model
        var inline = false
        static func == (a: Self, b: Self) -> Bool { a.d == b.d && a.m == b.m && a.inline == b.inline }

        var body: some View {
            if inline {
                Text(text).font(Theme.mono(10.z)).lineLimit(2).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 26.z)
                    .padding(.horizontal, 4.z)
            } else {
                row
            }
        }

        private var row: some View {
            HStack(spacing: 6.z) {
                // so breit wie Buchstabe und Cover im Kopf
                Text(deckLetters[d]).font(Theme.label(22.z, .bold)).hidden().frame(height: 0)
                if m.cover > 0 { Color.clear.frame(width: m.cover.z, height: 0) }
                Text(text).font(Theme.mono(10.z)).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 14.z)
        }

        private var text: AttributedString {
            var ui = UIPrefs()
            ui.tagHighlight = m.tagHighlight
            ui.tagColors = m.tagColors
            ui.tagGroups = m.tagGroups
            // ohne Filter liest TagChipsText die Vergleichsformen nicht
            var text = TagChipsText.text(tags: m.tags, keys: [], ui: ui, filter: TagFilter())
            let comment = m.comment.split(whereSeparator: \.isNewline).joined(separator: " ")
            if !comment.isEmpty {
                var c = AttributedString((m.tags.isEmpty ? "" : "  ") + comment)
                c.foregroundColor = Theme.muted
                text += c
            }
            return text
        }
    }
}

/// Transport: CUP CUE ▶ | SYNC MASTER KEY − + REV FLUX
struct TransportRow: View {
    @Environment(MixModel.self) private var mix
    let d: Int

    struct Model: Equatable {
        var playing = false, cueHeld = false, sync = false, master = false, keylock = false, reverse = false, flux = false, edit = false
    }

    var body: some View {
        let s = mix.deck(d)
        Content(d: d, m: Model(playing: s.playing, cueHeld: s.cueHeld, sync: s.sync, master: mix.effectiveMaster == d,
                               keylock: s.keylock, reverse: s.reverse, flux: s.flux, edit: mix.editing(d))).equatable()
    }

    struct Content: View, Equatable {
        @Environment(MixModel.self) private var mix
        let d: Int
        let m: Model
        static func == (a: Self, b: Self) -> Bool { a.d == b.d && a.m == b.m }

        var body: some View {
            HStack(spacing: 3.z) {
                DeckButton(title: "CUP", width: 26) { mix.cup(d) }.stable().helpInfo("deck.cup")
                PressButton(title: "CUE", active: m.cueHeld, width: 30, down: { mix.cueDown(d) }, up: { mix.cueUp(d) })
                DeckButton(title: m.playing ? "❚❚" : "▶", active: m.playing, color: Theme.state, width: 30) { mix.togglePlay(d) }.stable()
                Divider().frame(height: 14.z)
                DeckButton(title: "SYNC", active: m.sync, color: Theme.state) { mix.toggleSync(d) }.stable().helpInfo("deck.sync")
                DeckButton(title: "MASTER", active: m.master,
                           color: Theme.secondary) { mix.toggleMaster(d) }.stable().helpInfo("deck.master")
                DeckButton(title: "KEY", active: m.keylock, color: Theme.state) { mix.toggleKeylock(d) }.stable().helpInfo("deck.keylock")
                DeckButton(title: "−") { mix.shiftKey(d, -1) }.stable()
                DeckButton(title: "+") { mix.shiftKey(d, 1) }.stable()
                DeckButton(title: "REV", active: m.reverse, color: Theme.state) { mix.toggleReverse(d) }.stable().helpInfo("deck.rev")
                DeckButton(title: "FLUX", active: m.flux, color: Theme.state) { mix.toggleFlux(d) }.stable().helpInfo("deck.flux")
                Spacer(minLength: 2.z)
                DeckButton(title: "DBL") { mix.instantDouble(from: d ^ 1, to: d) }.stable().helpInfo("deck.dbl")
                    .help(String(localized: "Instant Double: Track, Position, Tempo, Key, Loop von Deck \(deckLetters[d ^ 1]) übernehmen, läuft synchron mit (⌥-Klick: auch wenn dieses Deck spielt, Rechtsklick: anderes Deck)"))
                    .contextMenu {
                        ForEach((0..<4).filter { $0 != d }, id: \.self) { s in
                            Button(String(localized: "Double von Deck \(deckLetters[s])")) { mix.instantDouble(from: s, to: d) }
                        }
                    }
                DeckButton(title: "EDIT", active: m.edit, color: Theme.state) { mix.toggleEdit(d) }.stable().helpInfo("deck.edit")
                    .help("EDIT-Modus: Schnitt und Grid setzen (⌥⌘E)")
            }
        }
    }
}

/// Grid-Werkzeuge: verschieben, BPM, ×2/÷2, Marker setzen, zurücksetzen
struct GridToolsRow: View {
    @Environment(MixModel.self) private var mix
    let d: Int

    struct Model: Equatable { var bpm: Double?, suggestion: Int?, confidence = 0.0, edited = false }

    var body: some View {
        let s = mix.deck(d)
        Content(d: d, m: Model(bpm: s.grid?.bpm, suggestion: s.phraseSuggestion, confidence: s.phraseConfidence,
                               edited: s.gridEdited)).equatable()
    }

    struct Content: View, Equatable {
        @Environment(MixModel.self) private var mix
        let d: Int
        let m: Model
        static func == (a: Self, b: Self) -> Bool { a.d == b.d && a.m == b.m }

        var body: some View {
            HStack(spacing: 3.z) {
                // rot = Grid von Hand gesetzt (eigene Änderung, gewinnt über Collection und Analyse)
                Text("GRID").font(Theme.label(9.z, .bold)).foregroundStyle(m.edited ? Theme.state : Theme.muted)
                    .frame(width: 30.z, alignment: .leading)
                    .help(LocalizedStringKey(m.edited ? "Grid von Hand gesetzt – bleibt beim Laden und Analysieren, RESET nimmt es weg"
                                                      : "Grid aus der Library"))
                DeckButton(title: "◂◂") { mix.shiftGrid(d, ms: -10) }.stable().help("Grid 10 ms früher")
                DeckButton(title: "◂") { mix.shiftGrid(d, ms: -1) }.stable().help("Grid 1 ms früher")
                DeckButton(title: "▸") { mix.shiftGrid(d, ms: 1) }.stable().help("Grid 1 ms später")
                DeckButton(title: "▸▸") { mix.shiftGrid(d, ms: 10) }.stable().help("Grid 10 ms später")
                Divider().frame(height: 14.z)
                DeckButton(title: "BPM −") { mix.setGridBPM(d, (mix.deck(d).grid?.bpm ?? 0) - 0.01) }.stable()
                Text(m.bpm.map { String(format: "%.3f", $0) } ?? "—").font(Theme.mono(10.z)).frame(width: 52.z)
                DeckButton(title: "+") { mix.setGridBPM(d, (mix.deck(d).grid?.bpm ?? 0) + 0.01) }.stable()
                DeckButton(title: "÷2") { mix.scaleGridBPM(d, 0.5) }.stable()
                DeckButton(title: "×2") { mix.scaleGridBPM(d, 2) }.stable()
                DeckButton(title: "TAP") { mix.tapGrid(d) }.stable().help("Auf die Beats tippen: ab 4 Taps BPM des Grids")
                Divider().frame(height: 14.z)
                DeckButton(title: "SET") { mix.setGridAnchorHere(d) }.stable().help("Beat 1 an die aktuelle Position")
                DeckButton(title: "RESET") { mix.resetGrid(d) }.stable()
                    .help("Grid aus der Library (Collection oder eigene Analyse), eigene Änderung weg")
                // Anker um ganze Beats/Takte: Raster bleibt, nur Takt- und Phrasenzählung wandert; schmale Decks: weniger Knöpfe
                // FirstFit statt ViewThatFits: ViewThatFits baut seine Kandidaten bei jedem Layout neu auf (Knöpfe mit
                // Tooltip, Fokus, Tastatur) – das kostete bei jeder Zustandsänderung ~40 ms über vier Decks
                FirstFit {
                    HStack(spacing: 3.z) { Divider().frame(height: 14.z); anchorButtons([-4, -1, 1, 4]); phraseButton(short: false) }
                    HStack(spacing: 3.z) { Divider().frame(height: 14.z); anchorButtons([-1, 1]); phraseButton(short: true) }
                    phraseButton(short: true)
                }
                Spacer(minLength: 0)
            }
        }

        private func anchorButtons(_ steps: [Int]) -> some View {
            ForEach(steps, id: \.self) { n in
                DeckButton(title: n < 0 ? "◂\(-n)" : "\(n)▸") { mix.shiftGridBeats(d, n) }.stable()
                    .help(LocalizedStringKey(n == -4 ? "Grid-Anker 1 Takt früher (Raster bleibt)" : n == 4 ? "Grid-Anker 1 Takt später (Raster bleibt)"
                                 : n < 0 ? "Grid-Anker 1 Beat früher (Raster bleibt)" : "Grid-Anker 1 Beat später (Raster bleibt)"))
            }
        }

        /// Phrasen-Anker-Vorschlag (rot), Klick verschiebt den Anker um die vorgeschlagenen Beats
        @ViewBuilder private func phraseButton(short: Bool) -> some View {
            if let n = m.suggestion {
                let v = n > 0 ? "+\(n)" : "\u{2212}\(-n)"
                DeckButton(title: short ? "PHR \(v)" : "PHRASE \(v)", active: true, color: Theme.state) { mix.applyPhraseAnchor(d) }.stable()
                    .help(String(localized: "Phrasen-Anker: Strukturwechsel liegen \(n) Beats neben den 8-Takt-Grenzen – Klick verschiebt den Anker (Sicherheit \(String(format: "%.2f", m.confidence)))"))
            }
        }
    }
}

/// Edit-Zeile (EDIT-Modus): Raster, Schnittliste (REMOVE / KEEP / DUP / MUTE / ◀ ▶) auf dem markierten Bereich bzw. dem
/// Stück unter dem Spielkopf, RENDER (neue Datei `[cut]`), Tool-Loop 2 / 4 / 8 / 16 Beats, ✕ = Bereich aufheben.
/// Breit genug: dahinter IN HERE / OUT HERE / CLEAR CUT (nicht destruktiver Schnitt, nur solange das Deck das Original
/// spielt). Schmale Decks: weniger Knöpfe, alles im Rechtsklick-Menü der Wellenform
struct CutRow: View {
    @Environment(MixModel.self) private var mix
    let d: Int

    struct Model: Equatable {
        var start: Double?, end: Double?, duration = 0.0, range = false
        var snap = EditSnap.bar, previewing = false, pending = false, segments = 1, rip = false
    }

    var body: some View {
        let s = mix.deck(d), e = mix.decks[d].edit
        Content(d: d, m: Model(start: s.trim.start, end: s.trim.end, duration: s.track != nil ? s.duration : 0,
                               range: mix.range(d) != nil, snap: mix.prefs.ui.editSnap, previewing: e?.previewing ?? false,
                               pending: e?.pending ?? false, segments: e?.segments ?? 1, rip: mix.ripMark(d) != nil)).equatable()
    }

    struct Content: View, Equatable {
        @Environment(MixModel.self) private var mix
        let d: Int
        let m: Model
        static func == (a: Self, b: Self) -> Bool { a.d == b.d && a.m == b.m }

        var body: some View {
            HStack(spacing: 3.z) {
                Text("CUT").font(Theme.label(9.z, .bold))
                    .foregroundStyle(m.previewing || m.start != nil || m.end != nil ? Theme.state : Theme.muted)
                    .frame(width: 30.z, alignment: .leading)
                FirstFit {
                    row(.full)
                    row(.medium)
                    row(.narrow)
                    row(.tiny)
                }
                Spacer(minLength: 0)
            }
        }

        enum Width { case full, medium, narrow, tiny }

        private func row(_ w: Width) -> some View {
            HStack(spacing: 3.z) {
                if w != .tiny { snapButton }
                DeckButton(title: m.rip ? "◆ REMOVE RIP" : "REMOVE", active: true, color: Theme.state, verbatim: true) { mix.editAction(d, .remove) }.stable()
                    .help(LocalizedStringKey(m.rip ? "Markierten RIP-Bereich aus der Schnittliste entfernen (Befund erledigt)" : "Bereich (sonst Segment am Spielkopf) aus der Schnittliste entfernen"))
                DeckButton(title: "KEEP") { mix.editAction(d, .keep) }.stable().help("Nur Bereich behalten")
                if w != .tiny {
                    DeckButton(title: "DUP") { mix.editAction(d, .duplicate) }.stable().help("Bereich duplizieren (hinter sich selbst)")
                    DeckButton(title: "MUTE") { mix.editAction(d, .mute) }.stable().help("Bereich stumm (gleiche Länge), noch einmal = hörbar")
                }
                if w == .full || w == .medium {
                    DeckButton(title: "◀") { mix.editAction(d, .left) }.stable().help("Segment nach links")
                    DeckButton(title: "▶") { mix.editAction(d, .right) }.stable().help("Segment nach rechts")
                }
                if w != .tiny {
                    Divider().frame(height: 14.z)
                    DeckButton(title: "RENDER", active: m.previewing, color: Theme.state) { mix.editRenderFile(d) }.stable()
                        .help("Schnittliste als neue Datei rendern (<Name> [cut].m4a, Original bleibt)")
                }
                if w == .full || w == .medium {
                    Divider().frame(height: 14.z)
                    Text("TOOL").font(Theme.label(9.z, .bold)).foregroundStyle(Theme.muted)
                    ForEach(ToolLoop.sizes, id: \.self) { b in
                        DeckButton(title: "\(b)") { mix.exportToolLoop(d, beats: b) }.stable()
                            .help("Tool-Loop \(b) Beats als eigene Datei (aktiver Loop, sonst ab dem nächsten Takt)")
                    }
                }
                DeckButton(title: "✕") { mix.clearRange(d) }.stable().help("Bereich aufheben (Esc)")
                RipDeckButton(d: d)
                if w == .full, !m.previewing {
                    Divider().frame(height: 14.z)
                    DeckButton(title: "IN HERE", active: m.start != nil, color: Theme.state) {
                        mix.trimHere(d, end: false, free: NSEvent.modifierFlags.contains(.option))
                    }.stable()
                        .help("Schnitt-Anfang an die Position (Quantize: nächster Beat, ⌥-Klick: genau hier)")
                    DeckButton(title: "OUT HERE", active: m.end != nil, color: Theme.state) {
                        mix.trimHere(d, end: true, free: NSEvent.modifierFlags.contains(.option))
                    }.stable()
                        .help("Schnitt-Ende an die Position (Quantize: nächster Beat, ⌥-Klick: genau hier)")
                    DeckButton(title: "CLEAR CUT") { mix.clearTrim(d) }.stable().help("Schnitt entfernen: ganze Datei")
                }
            }
            .opacity(m.pending ? 0.6 : 1)
            .fixedSize()
        }

        /// Raster beim Markieren: Klick = nächstes, ⌥-Klick = voriges
        private var snapButton: some View {
            DeckButton(title: m.snap.label) {
                mix.setEditSnap(NSEvent.modifierFlags.contains(.option) ? m.snap.previous : m.snap.next)
            }
            .help("Raster beim Markieren: Klick = nächstes, ⌥-Klick = voriges, ⌥ beim Ziehen = frei")
        }

        /// m:ss.s
        static func time(_ t: Double) -> String {
            let t = max(0, t), min = Int(t / 60)
            return String(format: "%d:%04.1f", min, t - Double(min) * 60)
        }
    }
}

/// Hotcues über die ganze Breite, rechts manueller Loop (IN / OUT / RE)
struct CueRow: View {
    @Environment(MixModel.self) private var mix
    let d: Int

    /// loops: Hotcue ist ein Loop-Cue, active: Active Loop (Punkt)
    struct Model: Equatable { var colors: [Color?] = [], loops: [Bool] = [], active: [Bool] = [], inArmed = false }

    var body: some View {
        let s = mix.deck(d), prefs = mix.prefs
        let colors = (0..<8).map { n in s.hotcues[n].map { Theme.cueColor($0, deck: s, prefs: prefs) } }
        let loops = (0..<8).map { s.hotcues[$0].map { $0.kind == .loop && $0.lengthMs > 0 } ?? false }
        Content(d: d, m: Model(colors: colors, loops: loops, active: (0..<8).map { s.activeLoops.contains($0) },
                               inArmed: s.loopIn != nil && !s.loopActive)).equatable()
    }

    struct Content: View, Equatable {
        @Environment(MixModel.self) private var mix
        let d: Int
        let m: Model
        static func == (a: Self, b: Self) -> Bool { a.d == b.d && a.m == b.m }

        var body: some View {
            HStack(spacing: 3.z) {
                ForEach(0..<8, id: \.self) { n in
                    let c = m.colors[n]
                    DeckButton(title: m.active[n] ? "\(n + 1) •" : "\(n + 1)", active: c != nil, color: c ?? .gray, fill: true) {
                        mix.hotcue(d, n, delete: NSEvent.modifierFlags.contains(.option))
                    }.stable().helpInfo("deck.hotcue")
                    .help(m.loops[n] ? "Klick: springen/setzen · ⌥-Klick: löschen · Rechtsklick: Active Loop" : "Klick: springen/setzen · ⌥-Klick: löschen")
                    .contextMenu {
                        if m.loops[n] {
                            Toggle("Active Loop (rastet beim Erreichen ein)", isOn: Binding(get: { m.active[n] }, set: { _ in mix.toggleActiveLoop(d, n) }))
                        }
                        if c != nil { Button("Hotcue löschen") { mix.hotcue(d, n, delete: true) } }
                    }
                }
                Divider().frame(height: 14.z)
                DeckButton(title: "IN", active: m.inArmed, color: Theme.state) { mix.setLoopIn(d) }.stable().helpInfo("deck.loopIn")
                DeckButton(title: "OUT") { mix.setLoopOut(d) }.stable().helpInfo("deck.loopOut")
                DeckButton(title: "RE") { mix.reloop(d) }.stable().helpInfo("deck.reloop")
            }
        }
    }
}

/// Loopgrößen über die ganze Breite: gewählte Größe lila (auch vom Encoder; rot bleibt LOOP = an/aus).
/// Klick auf eine Größe wählt sie; läuft ein Loop, wird er auf die neue Größe gestellt.
struct LoopRow: View {
    @Environment(MixModel.self) private var mix
    let d: Int

    struct Model: Equatable { var active = false, size = 4.0 }

    var body: some View {
        let s = mix.deck(d)
        Content(d: d, m: Model(active: s.loopActive, size: s.loopSize)).equatable()
    }

    struct Content: View, Equatable {
        @Environment(MixModel.self) private var mix
        let d: Int
        let m: Model
        static func == (a: Self, b: Self) -> Bool { a.d == b.d && a.m == b.m }

        var body: some View {
            HStack(spacing: 3.z) {
                DeckButton(title: "LOOP", active: m.active, color: Theme.state, width: 30) { mix.autoLoop(d) }.stable().helpInfo("deck.loop")
                ForEach(BeatSizes.loop, id: \.self) { s in
                    let selected = DeckView.same(m.size, s)
                    DeckButton(title: BeatSizes.label(s), active: selected, color: Theme.secondary, fill: true) {
                        let deck = mix.deck(d)
                        if deck.loopActive { if !DeckView.same(deck.loopSize, s) { mix.autoLoop(d, size: s) } }
                        else { mix.core.setLoopSize(d, s); mix.pull() }
                    }.stable()
                }
            }
        }
    }
}

/// Beatjump-Größen über die ganze Breite: gewählte Größe rot (auch über Flux + Pads / Encoder), ◀◀ ▶▶ springen
struct JumpRow: View {
    @Environment(MixModel.self) private var mix
    let d: Int

    var body: some View { Content(d: d, size: mix.deck(d).jumpSize).equatable() }

    struct Content: View, Equatable {
        @Environment(MixModel.self) private var mix
        let d: Int
        let size: Double
        static func == (a: Self, b: Self) -> Bool { a.d == b.d && a.size == b.size }

        var body: some View {
            HStack(spacing: 3.z) {
                DeckButton(title: "◀◀", width: 30) { mix.beatjump(d, beats: -mix.deck(d).jumpSize) }.stable().helpInfo("deck.beatjump")
                ForEach(BeatSizes.jump, id: \.self) { s in
                    DeckButton(title: BeatSizes.label(s), active: DeckView.same(size, s), color: Theme.state, fill: true) {
                        mix.setJumpSize(d, s)
                    }.stable()
                }
                DeckButton(title: "▶▶", width: 30) { mix.beatjump(d, beats: mix.deck(d).jumpSize) }.stable().helpInfo("deck.beatjump")
            }
        }
    }
}

/// Laufzeit / Restzeit mit Track-End-Warnung
struct TimeReadout: View, Equatable {
    @Environment(MixModel.self) private var mix
    let d: Int
    let m: Model

    /// end = Ende des gespielten Bereichs (Schnitt-Ende, sonst Track-Ende)
    struct Model: Equatable { var hasTrack = false, end = 0.0, playing = false, grid: BeatGrid?, warnAt = 0.0 }
    static func == (a: Self, b: Self) -> Bool { a.d == b.d && a.m == b.m }

    var body: some View {
        let m = m
        LiveCanvas(fps: 10, running: m.hasTrack) { [mix, d] _, size in
            let pos = mix.position(d)
            let remain = max(0, m.end - pos)
            let warn = m.playing && m.warnAt > 0 && remain < m.warnAt && m.end > 0
            let blink = Int(Date().timeIntervalSince1970 * 2) % 2 == 0
            CG.text("-" + Theme.time(remain), size: 13, color: warn && blink ? CG.stateNS : CG.boneNS, rightAt: size.width, y: 0)
            if let g = m.grid {
                let bb = g.barBeat(at: pos)
                CG.text("\(bb.bar).\(bb.beat)", size: 10, weight: "Regular", color: CG.mutedNS, rightAt: size.width, y: 17)
            }
        }
        .frame(width: 66.z, height: 31.z)
    }
}

/// „Code“ über dem Deck: Takt in der eigenen Phrase und Abstand zum Bar-Zähler.
/// Lila = im Code, rot = verschoben (Takte bzw. Beats), grau = Deck steht oder kein Zähler.
struct CodeReadout: View, Equatable {
    @Environment(MixModel.self) private var mix
    let d: Int
    let m: Model

    struct Model: Equatable { var hasTrack = false, playing = false, bars = 16 }
    static func == (a: Self, b: Self) -> Bool { a.d == b.d && a.m == b.m }

    var body: some View {
        let m = m
        LiveCanvas(fps: 10, running: m.hasTrack) { [mix, d] _, size in
            let muted = CG.mutedNS, lila = CG.secondaryNS
            guard m.hasTrack, let c = mix.phraseCode(d) else {
                CG.text("—", size: 13, color: muted, rightAt: size.width, y: 0)
                return
            }
            let live = m.playing && c.offsetBeats != nil
            let top: NSColor = !live ? muted : c.aligned ? lila : CG.boneNS
            CG.text("\(c.bar)/\(c.phraseBars)", size: 13, color: top, rightAt: size.width, y: 0)
            let (s, col): (String, NSColor) = !live ? ("CODE", muted)
                : c.aligned ? ("◆ CODE", lila) : (c.offsetLabel ?? "", CG.stateNS)
            CG.text(s, size: 10, weight: "Regular", color: col, rightAt: size.width, y: 17)
        }
        .frame(width: 62.z, height: 31.z)
        .help(String(localized: "Code: Takt in der \(m.bars)-Takt-Phrase des Tracks, Abstand zum Bar-Zähler"))
    }
}

/// Tonart über dem Deck: Key des Tracks, daneben der hörbare Key (rot), sobald er abweicht,
/// darunter die Abweichung in Halbtönen (Keylock aus: aus dem Tempo, Keylock an: aus dem Key-Shift)
struct KeyReadout: View, Equatable {
    let m: Model

    struct Model: Equatable {
        var key: String?, shifted = "", deviation = 0.0
        init() {}
        init(track: Track?, deviation dev: Double) {
            key = track?.openKey
            deviation = dev
            if let track, abs(dev) >= 0.05 { shifted = track.openKey(shiftedBy: Int(dev.rounded())) }
        }
        var off: Bool { key != nil && abs(deviation) >= 0.05 }
    }

    var body: some View {
        let off = m.off
        VStack(alignment: .trailing, spacing: 0) {
            HStack(spacing: 3.z) {
                Text(m.key ?? "").font(Theme.mono(13.z, .semibold))
                    .foregroundStyle(off ? Color.secondary : Theme.bone)
                if off {
                    Text("→").font(Theme.mono(10.z)).foregroundStyle(.secondary)
                    Text(m.shifted).font(Theme.mono(13.z, .semibold))
                        .foregroundStyle(Theme.state)
                }
            }
            Text(m.key == nil ? " " : String(format: "%+.2f", m.deviation)).font(Theme.mono(10.z))
                .foregroundStyle(off ? Theme.state : Color.secondary)
                .help(String(localized: "Abweichung von der Tonart des Tracks in Halbtönen"))
        }
    }
}

/// KEY SYNC im Kopf: zweizeilig, so schmal wie möglich (schmale Decks kürzen sonst Titel und Tempo)
struct KeySyncButton: View, Equatable {
    let action: () -> Void
    static func == (a: Self, b: Self) -> Bool { true }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                Text(verbatim: "KEY")
                Text(verbatim: "SYNC")
            }
            .font(Theme.label(8.z, .bold))
            .foregroundStyle(Theme.bone.opacity(0.75))
            .padding(.horizontal, 3.z)
            .frame(height: 28.z)
            .background(Rectangle().fill(Theme.void))
            .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
            .fixedSize()
        }
        .buttonStyle(.plain)
    }
}

/// Phasenanzeige gegenüber dem Master
struct PhaseMeter: View, Equatable {
    @Environment(MixModel.self) private var mix
    let d: Int
    let active: Bool
    static func == (a: Self, b: Self) -> Bool { a.d == b.d && a.active == b.active }

    var body: some View {
        let active = active
        LiveCanvas(fps: 20, running: active) { [mix, d] ctx, size in
            let w = size.width, h = size.height
            ctx.setFillColor(CG.void); ctx.fill(CGRect(origin: .zero, size: size))
            ctx.setFillColor(CG.muted); ctx.fill(CGRect(x: w / 2 - 0.5, y: 0, width: 1, height: h))
            guard active, let e = mix.phaseError(d) else { return }
            let bw = max(2, abs(e) * w)
            ctx.setFillColor(abs(e) < 0.02 ? CG.bone : CG.state)
            ctx.fill(CGRect(x: w / 2 + e * w / 2 - bw / 2, y: 0, width: bw, height: h))
        }
    }
}

/// Großer Phasen-Anzeiger unter der Wellenform: Abstand zum Master in Beats, Mitte = synchron
struct PhaseBar: View {
    @Environment(MixModel.self) private var mix
    let d: Int

    var body: some View {
        Content(d: d, active: mix.deck(d).playing && (mix.clockMaster || mix.effectiveMaster != nil)).equatable()
    }

    struct Content: View, Equatable {
        @Environment(MixModel.self) private var mix
        let d: Int
        let active: Bool
        static func == (a: Self, b: Self) -> Bool { a.d == b.d && a.active == b.active }

        var body: some View {
            let active = active
            LiveCanvas(fps: 30, running: active) { [mix, d] ctx, size in
                let w = size.width, h = size.height
                ctx.setFillColor(CG.void); ctx.fill(CGRect(origin: .zero, size: size))
                ctx.setFillColor(CG.muted); ctx.fill(CGRect(x: w / 2 - 0.5, y: 0, width: 1, height: h))
                ctx.setFillColor(CG.hairline)
                for q in [0.25, 0.75] { ctx.fill(CGRect(x: w * q, y: h / 2, width: 1, height: h / 2)) }
                guard active, let e = mix.phaseError(d) else { return }
                let x = w / 2 + CGFloat(e) * w
                ctx.setFillColor(abs(e) < 0.02 ? CG.bone : CG.state)
                ctx.fill(CGRect(x: min(w / 2, x), y: 1, width: max(2, abs(x - w / 2)), height: h - 2))
            }
            .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
        }
    }
}

/// Senkrechter Tempo-Fader rechts am Deck, mit Bereich, Reset und Pitch-Bend
struct TempoColumn: View {
    @Environment(MixModel.self) private var mix
    let d: Int

    struct Model: Equatable { var range = 8.0, pct = 0.0, sync = false, master = false }

    var body: some View {
        let s = mix.deck(d)
        Content(d: d, m: Model(range: s.tempoRange, pct: s.tempoPct, sync: s.sync, master: mix.effectiveMaster == d)).equatable()
    }

    struct Content: View, Equatable {
        @Environment(MixModel.self) private var mix
        let d: Int
        let m: Model
        static func == (a: Self, b: Self) -> Bool { a.d == b.d && a.m == b.m }

        var body: some View {
            VStack(spacing: 3.z) {
                RangeMenu(d: d, range: m.range).equatable()
                GeometryReader { geo in
                    let h = geo.size.height
                    let f = (m.pct / m.range + 1) / 2   // unten = schneller
                    ZStack(alignment: .top) {
                        Rectangle().fill(Theme.void).frame(width: 4.z).overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
                        Rectangle().fill(Theme.muted).frame(width: 14.z, height: 1).offset(y: h / 2)
                        Rectangle().fill(m.sync ? Theme.secondary : Theme.bone)
                            .frame(width: geo.size.width, height: 8.z)
                            .offset(y: (h - 8.z) * CGFloat(f))
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                        guard !(m.sync && !m.master) else { return }
                        let v = max(0, min(1, g.location.y / h)) * 2 - 1
                        mix.setTempo(d, v * m.range)
                    })
                    .onDoubleClick(name: "dbl TEMPO") { mix.setTempo(d, 0) }
                }
                .frame(width: 22.z)
                HStack(spacing: 1.z) {
                    PressButton(title: "‹", width: 8, down: { mix.bend(d, -1) }, up: { mix.bend(d, 0) })
                    PressButton(title: "›", width: 8, down: { mix.bend(d, 1) }, up: { mix.bend(d, 0) })
                }
                DeckButton(title: "0", width: 10) { mix.setTempo(d, 0) }.stable().help("Tempo zurücksetzen")
            }
            .frame(width: 34.z)
        }
    }

    /// Bereichs-Menü eigene Ansicht: Tempo ziehen baut das Menü nicht neu
    struct RangeMenu: View, Equatable {
        @Environment(MixModel.self) private var mix
        let d: Int
        let range: Double
        static func == (a: Self, b: Self) -> Bool { a.d == b.d && a.range == b.range }

        var body: some View {
            Menu(String(format: "±%g", range)) {
                ForEach([6.0, 8, 10, 16, 50, 100], id: \.self) { r in Button(String(format: "±%g %%", r)) { mix.setTempoRange(d, r) } }
            }
            .menuStyle(.borderlessButton).controlSize(zoomed: .regular).font(Theme.mono(9.z)).fixedSize()
        }
    }
}

/// Nur Selbsttest: MIX741_SHOT=deck:<pfad.png> rendert Deck A (Track mit Kommentar und Tags, Loop 8, Beatjump 4) ohne
/// Fenster auf dem Bildschirm als PNG: <pfad>-640x300.png Loop aus, <pfad>-480x260.png Loop an,
/// <pfad>-640x300-compact.png kompakt (ohne Pitch-Fader, Hotcues, Grid-Werkzeuge), dazu im EDIT-Modus mit Schnitt und
/// eigenem Grid und markiertem Bereich (<pfad>-edit-640x300.png, <pfad>-edit-480x260.png), Cover 120 pt und Übersicht
/// 90 pt (<pfad>-sizes-900x420.png), und beendet sich.
@MainActor
enum DeckShot {
    static func runIfRequested() {
        guard Session.isSelfTest, let spec = ProcessInfo.processInfo.environment["MIX741_SHOT"], spec.hasPrefix("deck:") else { return }
        var base = String(spec.dropFirst(5))
        if base.hasSuffix(".png") { base.removeLast(4) }
        NSApplication.shared.setActivationPolicy(.prohibited)   // kein Dock-Symbol, kein Fokuswechsel
        // nie das Interface einer laufenden Live-Session: Routing nur für diesen Prozess auf ein eingebautes 2-Kanal-Gerät
        let devs = MixEngine.outputDevices()
        let dev = devs.first { $0.channels == 2 && $0.name.localizedCaseInsensitiveContains("speaker") } ?? devs.first { $0.channels < 8 }
        UserDefaults.standard.setVolatileDomain(["deviceUID": dev?.uid ?? "-", "mixerMode": MixerMode.internalMixer.rawValue,
                                                 "sampleRate": 0.0, "bufferSize": 0, "masterVolume": 0.0],
                                                forName: UserDefaults.argumentDomain)
        let mix = MixModel()
        mix.engine.stop()   // kein Ton, Gerät sofort wieder frei
        // feste Ansicht, unabhängig von gespeicherten Einstellungen (Selbsttest speichert nichts)
        mix.prefs.ui.showAllDeckRows()
        mix.prefs.ui.tagSeparators = "·"
        mix.prefs.ui.tagHighlight = true
        var t = Track(key: "shot", path: "/dev/null")
        t.title = "Deck Size Shot"; t.artist = "MINOS-741"; t.bpm = 128; t.musicalKey = 9; t.duration = 300
        t.comment = "long build, vocal at 2:10 – mix out before the break, works after slow acid"
        t.comment2 = "peak·dark·hypnotic·vocal·acid"
        let cues = [Cue(name: "", kind: .cue, startMs: 1000, lengthMs: 0, hotcue: 0),
                    Cue(name: "", kind: .cue, startMs: 30000, lengthMs: 0, hotcue: 1),
                    Cue(name: "", kind: .loop, startMs: 60000, lengthMs: 3750, hotcue: 3)]
        // andere Decks mit Grid für die Marken oben am Spielkopf: B drei Beats zurück (gestoppt, gedimmt), C in Phase
        // (spielt), D zwölf Beats voraus (am rechten Rand, „D +3 BARS“)
        for (d, anchorBeats, playing) in [(1, 3.0, false), (2, 0, true), (3, -12, false)] {
            mix.updateDeck(d) {
                $0.track = t; $0.duration = 300; $0.grid = BeatGrid(anchor: 1 + anchorBeats * 60 / 128, bpm: 128)
                $0.playing = playing
            }
        }
        var paths: [String] = []
        for (w, h, loop, compact, edit, sizes) in [(640.0, 300.0, false, false, false, false), (480.0, 260.0, true, false, false, false),
                                                   (640.0, 300.0, false, true, false, false),
                                                   (640.0, 300.0, false, false, true, false), (480.0, 260.0, false, false, true, false),
                                                   (900.0, 420.0, false, false, false, true)] {
            mix.prefs.ui.compactDecks = compact
            mix.prefs.ui.deckCoverSize = sizes ? 120 : UIPrefs().deckCoverSize
            mix.prefs.ui.overviewHeight = sizes ? 90 : UIPrefs().overviewHeight
            mix.setEditing(0, edit)
            mix.updateDeck(0) {
                $0.track = t; $0.duration = 300; $0.grid = BeatGrid(anchor: 1, bpm: 128)
                $0.phraseTarget = 1 - 60.0 / 128   // Phrasen-Vorschlag −1 (roter PHRASE-Knopf in der Grid-Zeile)
                $0.hotcues = Dictionary(uniqueKeysWithValues: cues.map { ($0.hotcue, $0) })
                $0.activeLoops = [3]   // Hotcue 4 als Active Loop (Punkt)
                $0.loopSize = 8; $0.jumpSize = 4; $0.loopActive = loop
                $0.trim = edit ? TrackTrim(start: 1.0, end: 290) : TrackTrim()
                $0.gridEdited = edit
            }
            mix.setRange(0, edit ? TrackRange(1 + 2 * 60 / 128, 1 + 6 * 60 / 128) : nil)   // markierter Bereich: Beats 3–7
            let path = "\(base)-\(edit ? "edit-" : "")\(sizes ? "sizes-" : "")\(Int(w))x\(Int(h))\(compact ? "-compact" : "").png"
            render(mix: mix, size: CGSize(width: w, height: h), to: path)
            paths.append(path)
        }
        print("[shot] " + paths.joined(separator: " "))
        fflush(stdout)
        exit(0)
    }

    private static func render(mix: MixModel, size: CGSize, to path: String) {
        let root = DeckView(d: 0)
            .environment(mix)
            .environment(WaveformCache())
            .environment(LibraryStore())
            .environment(BrowserState())
            .frame(width: size.width, height: size.height)
            .background(Theme.background)
            .foregroundStyle(Theme.bone)
            .tint(Theme.state)
            .preferredColorScheme(.dark)
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(origin: .zero, size: size)
        // Fenster nur als Zeichenfläche, wird nie angezeigt
        let win = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: .darkAqua)
        win.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
