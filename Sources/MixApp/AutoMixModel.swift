import Foundation
import MixCore
import MixEngine

/// Auto-Mix (interner Mixer): wählt nach „bester Match“ den nächsten Track aus dem Pool zweier Seiten und fährt den
/// Übergang über die Decks A und B. Läuft auf dem Hauptthread über einen kurzen Takt-Timer und nutzt nur die Befehle
/// der Oberfläche (Laden, Play, Sync, Pegel); die Glättung der Pegel macht der Kern.
/// Ablauf: Start → Übergang an der Phrasengrenze planen (`waiting`) → eingehend an seinem Phrasenstart starten
/// (`mixing`, Bass-Tausch in der Mitte) → ausgehend stoppen, Stellung zurücksetzen, nächsten Track laden.
@MainActor @Observable
final class AutoMixModel {
    enum Phase: Equatable { case off, starting, waiting, mixing }

    private(set) var phase: Phase = .off
    /// ausgehender Track (Deck, das gerade den Übergang trägt) und geplanter nächster
    private(set) var outgoing: Track?
    private(set) var next: Track?
    /// die nächsten drei Vorschläge (der erste ist `next`)
    private(set) var queue: [Track] = []
    /// Takte bis zum Übergang (nil = gerade kein Übergang geplant)
    private(set) var barsLeft: Int?

    @ObservationIgnored weak var mix: MixModel?
    @ObservationIgnored weak var store: LibraryStore?
    @ObservationIgnored weak var history: HistoryStore?
    @ObservationIgnored weak var browser: BrowserState?
    /// nur Selbsttest: Länge des Übergangs statt der Einstellung
    @ObservationIgnored var transitionBarsOverride: Int?

    /// Auto-Mix nutzt die Decks A (0) und B (1)
    private static let decks = [0, 1]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var pool: [String: Track] = [:]
    @ObservationIgnored private var sideOf: [String: Int] = [:]
    /// in dieser Sitzung gespielt (oder verworfen): nicht noch einmal wählen
    @ObservationIgnored private var played: Set<String> = []
    @ObservationIgnored private var failed: Set<String> = []
    @ObservationIgnored private var outDeck = 0
    @ObservationIgnored private var inDeck = 1
    @ObservationIgnored private var incomingKey: String?
    /// Phrasengrenze (Beat des ausgehenden Tracks), an der der Übergang beginnt
    @ObservationIgnored private var startBeat = 0.0
    @ObservationIgnored private var transitionBeats = 64.0
    /// letzter Stand der Pegel je Deck (von uns geschrieben oder beim Sehen); Abweichung = Hand am Regler
    @ObservationIgnored private var seen: [AutoMixLevels?] = [nil, nil]
    /// Hand am Deck im laufenden Übergang: Automatik an diesem Deck aus
    @ObservationIgnored private var paused = [false, false]
    @ObservationIgnored private var savedXF: [XFAssign]?

    var isOn: Bool { phase != .off }

    // MARK: Start / Stopp

    /// Start mit den Quellen je Seite. Im Baum: die markierten Einträge (nach Name), abwechselnd Seite A / B
    func start(sideA: [BrowserSource], sideB: [BrowserSource]) {
        guard let mix, let store, phase == .off else { return }
        guard mix.mixerMode == .internalMixer else {
            StatusCenter.post(.warning, String(localized: "Auto-Mix braucht den internen Mixer"), key: "automix")
            return
        }
        var pool: [String: Track] = [:], side: [String: Int] = [:]
        for (s, sources) in [(0, sideA), (1, sideB)] {
            for src in sources {
                for t in store.tracks(for: src) where !t.key.isEmpty && t.fileExists && pool[t.key] == nil {
                    pool[t.key] = t
                    side[t.key] = s
                }
            }
        }
        startPool(pool, sides: side)
    }

    /// Start mit festem Pool (Selbsttest): Seite nach Reihenfolge abwechselnd
    func start(tracks: [Track]) {
        var pool: [String: Track] = [:], side: [String: Int] = [:]
        for (i, t) in tracks.enumerated() where pool[t.key] == nil {
            pool[t.key] = t
            side[t.key] = i % 2
        }
        startPool(pool, sides: side)
    }

    private func startPool(_ pool: [String: Track], sides side: [String: Int]) {
        guard let mix, phase == .off else { return }
        let heard = Set(history?.live.map(\.key) ?? [])
        played = heard
        failed = []
        self.pool = pool.filter { !heard.contains($0.key) }
        sideOf = side
        guard self.pool.count >= 2 else {
            StatusCenter.post(.warning, String(localized: "Auto-Mix: weniger als zwei Tracks im Pool (ohne gespielte)"), key: "automix")
            return
        }
        let playing = Self.decks.filter { mix.deck($0).playing && mix.deck($0).track != nil }
        guard playing.count < 2 else {
            StatusCenter.post(.warning, String(localized: "Auto-Mix: beide Decks spielen – eins stoppen"), key: "automix")
            return
        }
        if let d = playing.first, mix.deck(d).grid == nil {
            StatusCenter.post(.warning, String(localized: "Auto-Mix: der laufende Track hat kein Grid"), key: "automix")
            return
        }
        savedXF = Self.decks.map { mix.deck($0).xf }
        for d in Self.decks { mix.updateDeck(d) { $0.xf = .thru } }   // Auto-Mix: der Crossfader bleibt aus dem Spiel
        seen = Self.decks.map { snapshot($0) }
        paused = [false, false]
        if let d = playing.first {
            outDeck = d
            inDeck = 1 - d
            phase = .waiting
            adoptOutgoing()
            planNext()
        } else {
            // nichts läuft: der erste Track (ohne Bezug, nach Analyse und Schlüssel) startet auf Deck A
            outDeck = 0
            inDeck = 1
            guard let first = AutoMix.choose(candidates(), ref: emptyRef, rule: mix.prefs.ui.match, prefs: mix.prefs.autoMix),
                  let t = self.pool[first.key] else { return stop(String(localized: "Auto-Mix: kein passender Track")) }
            incomingKey = first.key
            next = t
            mix.load(t, deck: outDeck, force: true)
            phase = .starting
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        StatusCenter.post(.info, String(localized: "Auto-Mix gestartet: \(self.pool.count) Tracks im Pool"), key: "automix")
    }

    /// Start mit den Quellen der beiden Browser-Bereiche (Seite A / B)
    func startFromPanes() {
        guard let browser else { return }
        start(sideA: [browser.paneA.source], sideB: [browser.paneB.source])
    }

    /// Markierte Einträge des Baums: nach Name sortiert, abwechselnd Seite A und B
    func startFromMarked(_ marked: Set<BrowserSource>) {
        let list = marked.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        start(sideA: list.enumerated().filter { $0.offset % 2 == 0 }.map(\.element),
              sideB: list.enumerated().filter { $0.offset % 2 == 1 }.map(\.element))
    }

    /// Stopp: Automatik aus, Pegel und Crossfader-Zuweisung zurück; was spielt, spielt weiter
    func stop(_ text: String? = nil) {
        timer?.invalidate()
        timer = nil
        if let mix {
            for d in Self.decks {
                if seen[d] != nil { resetLevels(d) }
                if let x = savedXF?[d] { mix.updateDeck(d) { $0.xf = x } }
            }
        }
        savedXF = nil
        phase = .off
        outgoing = nil
        next = nil
        queue = []
        barsLeft = nil
        incomingKey = nil
        seen = [nil, nil]
        paused = [false, false]
        if let text { StatusCenter.post(.info, text, key: "automix") }
    }

    /// SKIP: waiting → Übergang an der nächsten Phrasengrenze; mixing → sofort beenden
    func skip() {
        switch phase {
        case .waiting:
            startBeat = AutoMixTimeline.nextBoundary(after: beatNow(outDeck) ?? 0, phraseBeats: phraseBeats)
        case .mixing:
            finish()
        case .off, .starting:
            break
        }
    }

    // MARK: Takt

    private func tick() {
        guard let mix, phase != .off else { return }
        // Hand am Deck: Regler von Hand → Automatik an diesem Deck für den laufenden Übergang aus
        for d in Self.decks where phase != .starting {
            let now = snapshot(d)
            if let s = seen[d], now != s, !paused[d] {
                paused[d] = true
                StatusCenter.post(.info, String(localized: "Auto-Mix: Deck \(Self.letter(d)) von Hand – Automatik pausiert"), key: "automix")
            }
            seen[d] = now
        }
        let o = mix.deck(outDeck), i = mix.deck(inDeck)
        switch phase {
        case .off:
            break
        case .starting:
            if o.error != nil { return stop(String(localized: "Auto-Mix: Laden fehlgeschlagen")) }
            guard ready(outDeck) else { return }
            if !o.playing { mix.togglePlay(outDeck) }
            phase = .waiting
            adoptOutgoing()
            planNext()
        case .waiting:
            guard let g = o.grid else { return stop(String(localized: "Auto-Mix: der laufende Track hat kein Grid")) }
            if !o.playing {
                // Ausgehender Track ist am Ende (oder gestoppt): den nächsten sofort starten, sonst beenden
                guard ready(inDeck), !paused[inDeck], !i.playing else { return stop(String(localized: "Auto-Mix beendet: Deck \(Self.letter(outDeck)) gestoppt")) }
                beginMix()
                return
            }
            if i.playing { return stop(String(localized: "Auto-Mix beendet: Deck \(Self.letter(inDeck)) von Hand gestartet")) }
            if i.error != nil { return replan() }
            let now = g.beatPosition(at: mix.position(outDeck))
            barsLeft = max(0, Int(((startBeat - now) / BeatGrid.beatsPerBar).rounded(.up)))
            guard now >= startBeat else { return }
            guard next != nil else { return stop(String(localized: "Auto-Mix: keine passenden Tracks mehr – der Track läuft aus")) }
            // Deck B von Hand verändert: dieser Übergang entfällt, der nächste Track wird geplant
            if paused[inDeck] { return replan() }
            guard ready(inDeck) else {
                // eingehend noch nicht bereit: auf die nächste Phrasengrenze verschieben
                startBeat = AutoMixTimeline.nextBoundary(after: now, phraseBeats: phraseBeats)
                return
            }
            beginMix()
        case .mixing:
            guard let g = o.grid else { return finish() }
            let now = g.beatPosition(at: mix.position(outDeck))
            barsLeft = nil
            let p = AutoMixTimeline.progress(beat: now, start: startBeat, transitionBeats: transitionBeats)
            let bass = mix.prefs.autoMix.bassSwap, sweep = mix.prefs.autoMix.filterSweep
            if !paused[outDeck] { apply(outDeck, AutoMixLevels.outgoing(p, bassSwap: bass, filterSweep: sweep)) }
            if !paused[inDeck] { apply(inDeck, AutoMixLevels.incoming(p, bassSwap: bass, filterSweep: sweep)) }
            if p >= 1 || !o.playing { finish() }
            else if !i.playing { stop(String(localized: "Auto-Mix beendet: Deck \(Self.letter(inDeck)) gestoppt")) }
        }
    }

    // MARK: Übergang

    /// eingehenden Track an seinem Phrasenstart (Beat 0 = Grid-Anker) auf den Master setzen und starten
    private func beginMix() {
        guard let mix, let g = mix.deck(inDeck).grid else { return }
        let bass = mix.prefs.autoMix.bassSwap, sweep = mix.prefs.autoMix.filterSweep
        // Bezug für Sync: der ausgehende Track – spielt er (noch), sonst gibt es keinen Master
        let outPlaying = mix.deck(outDeck).playing
        if outPlaying, mix.effectiveMaster != outDeck { mix.toggleMaster(outDeck) }
        if !outPlaying, mix.effectiveMaster == outDeck { mix.toggleMaster(outDeck) }
        if !mix.deck(inDeck).sync { mix.toggleSync(inDeck) }
        if mix.prefs.autoMix.keySync, mix.deck(inDeck).track?.musicalKey ?? -1 >= 0 { mix.keySync(inDeck) }
        apply(inDeck, AutoMixLevels.incoming(0, bassSwap: bass, filterSweep: sweep))
        mix.core.seek(inDeck, seconds: max(0, g.anchor))
        mix.pull()
        mix.togglePlay(inDeck)   // Sync: zieht die Phase auf den Master
        phase = .mixing
        if let t = next { StatusCenter.post(.info, String(localized: "Auto-Mix: Übergang zu \(Self.name(t))"), key: "automix") }
    }

    /// Übergang zu Ende: ausgehender Track stoppt und wird zurückgesetzt, eingehender ist der neue ausgehende
    private func finish() {
        guard let mix else { return }
        let od = outDeck, idn = inDeck
        if mix.deck(od).playing { mix.togglePlay(od) }
        resetLevels(od)
        resetLevels(idn)
        if let k = incomingKey { played.insert(k) }
        outDeck = idn
        inDeck = od
        paused = [false, false]
        if mix.effectiveMaster != outDeck { mix.toggleMaster(outDeck) }
        phase = .waiting
        adoptOutgoing()
        planNext()
    }

    /// eingehender Track fällt aus (Ladefehler oder Hand am Deck): verwerfen und den nächsten laden
    private func replan() {
        if let k = incomingKey { failed.insert(k) }
        planNext()
        if next == nil, phase == .waiting { stop(String(localized: "Auto-Mix: keine passenden Tracks mehr – der Track läuft aus")) }
    }

    /// Ausgehender Track ist der laufende des Decks: Pool-Stand, Verlauf und Vorschlagsliste neu
    private func adoptOutgoing() {
        guard let mix else { return }
        outgoing = mix.deck(outDeck).track
        if let k = outgoing?.key { played.insert(k) }
    }

    /// nächsten Track wählen und auf das freie Deck laden, dazu Zeitplan des Übergangs
    private func planNext() {
        guard let mix else { return }
        let ranked = AutoMix.ranked(candidates(), ref: ref(outDeck), rule: mix.prefs.ui.match, prefs: mix.prefs.autoMix)
        let picks = ranked.prefix(3).compactMap { pool[$0.key] }
        queue = picks
        guard let pick = ranked.first, let t = pool[pick.key] else {
            return stop(String(localized: "Auto-Mix: keine passenden Tracks mehr – der Track läuft aus"))
        }
        // das freie Deck darf nicht von Hand spielen
        if mix.deck(inDeck).playing { return stop(String(localized: "Auto-Mix beendet: Deck \(Self.letter(inDeck)) spielt von Hand")) }
        paused[inDeck] = false
        seen[inDeck] = nil   // der erste Abgleich nach dem Laden setzt den Stand
        mix.load(t, deck: inDeck, force: true)
        next = t
        incomingKey = t.key
        planTransition()
    }

    /// Ausstieg: letzte Phrasengrenze vor dem Outro (oder die nächste, die noch passt)
    private func planTransition() {
        guard let mix, let g = mix.deck(outDeck).grid else { return }
        let now = g.beatPosition(at: mix.position(outDeck))
        let end = g.beatPosition(at: mix.deck(outDeck).playRange.upperBound)
        transitionBeats = Double((transitionBarsOverride ?? mix.prefs.autoMix.transitionBars) * 4)
        startBeat = AutoMixTimeline.outBeat(endBeat: end, now: now, phraseBeats: phraseBeats,
                                            transitionBeats: transitionBeats)
            ?? AutoMixTimeline.nextBoundary(after: now, phraseBeats: phraseBeats)
    }

    // MARK: Auswahl

    private var phraseBeats: Double { Double(max(4, mix?.prefs.ui.phraseBeats ?? 64)) }

    private var emptyRef: AutoMixRef { AutoMixRef(key: nil, bpm: 0, tags: TagProfile(), artist: "", side: nil) }

    /// Bezug: der ausgehende Track mit hörbarem Key (Key-Shift und Tempo wie am Deck)
    private func ref(_ d: Int) -> AutoMixRef {
        guard let mix else { return emptyRef }
        let s = mix.deck(d)
        guard let t = s.track else { return emptyRef }
        let key = t.harmonyCode.map { Harmony.shifted($0, by: Int(mix.keyDeviation(d).rounded())) }
        return AutoMixRef(key: key, bpm: s.bpm, tags: TagProfile(t.comment2, separators: mix.prefs.ui.tagSeparators),
                          artist: Self.artist(t), side: sideOf[t.key])
    }

    /// Kandidaten: Pool ohne gespielte, verworfene und den ausgehenden Track
    private func candidates() -> [AutoMixCandidate] {
        guard let mix else { return [] }
        let sep = mix.prefs.ui.tagSeparators
        return pool.values.filter { !played.contains($0.key) && !failed.contains($0.key) }.map { t in
            AutoMixCandidate(key: t.key, artist: Self.artist(t), bpm: t.bpm, harmony: t.harmonyCode,
                             tags: TagProfile(t.comment2, separators: sep), side: sideOf[t.key] ?? 0,
                             hasGrid: BeatGrid(track: t) != nil, analyzed: t.analyzed)
        }
    }

    // MARK: Hilfen

    private func ready(_ d: Int) -> Bool {
        guard let mix else { return false }
        let s = mix.deck(d)
        return s.track != nil && !s.loading && s.grid != nil && s.error == nil && mix.audio(d) != nil
    }

    private func beatNow(_ d: Int) -> Double? {
        guard let mix, let g = mix.deck(d).grid else { return nil }
        return g.beatPosition(at: mix.position(d))
    }

    private func snapshot(_ d: Int) -> AutoMixLevels {
        guard let mix else { return .neutral }
        let s = mix.deck(d)
        return AutoMixLevels(low: s.eqLow, mid: s.eqMid, high: s.eqHigh, filter: s.filter, fader: s.fader)
    }

    /// Pegel setzen (glättet der Kern); merkt sich den Stand als den unseren
    private func apply(_ d: Int, _ l: AutoMixLevels) {
        guard let mix else { return }
        mix.updateDeck(d) { $0.eqLow = l.low; $0.eqMid = l.mid; $0.eqHigh = l.high; $0.filter = l.filter; $0.fader = l.fader }
        seen[d] = l
    }

    private func resetLevels(_ d: Int) { apply(d, .neutral) }

    private static func letter(_ d: Int) -> String { d == 0 ? "A" : "B" }
    private static func artist(_ t: Track) -> String { t.artist.trimmingCharacters(in: .whitespaces).lowercased() }
    private static func name(_ t: Track) -> String {
        t.artist.isEmpty ? t.title : "\(t.artist) – \(t.title)"
    }
    /// Anzeige: „Artist – Title“
    static func label(_ t: Track) -> String { name(t) }
}
