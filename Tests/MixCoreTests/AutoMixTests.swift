import Testing
@testable import MixCore

private func cand(_ key: String, artist: String = "a", bpm: Double = 128, code: Int? = nil, side: Int = 0,
                  tags: TagProfile = TagProfile(), grid: Bool = true, analyzed: Bool = true) -> AutoMixCandidate {
    AutoMixCandidate(key: key, artist: artist, bpm: bpm, harmony: code, tags: tags, side: side, hasGrid: grid, analyzed: analyzed)
}

private let refKey8A = Harmony.code(text: "8A")!   // Am
private let refKey8B = Harmony.code(text: "8B")!   // C

private func ref(key: Int? = nil, bpm: Double = 128, tags: TagProfile = TagProfile(), artist: String = "x", side: Int? = 0) -> AutoMixRef {
    AutoMixRef(key: key, bpm: bpm, tags: tags, artist: artist, side: side)
}

@Test func autoMixSkipsTracksWithoutGrid() {
    let rule = MatchRule(), prefs = AutoMixPrefs()
    #expect(AutoMix.score(cand("a", grid: false), ref: ref(), rule: rule, prefs: prefs) == nil)
    #expect(AutoMix.score(cand("a"), ref: ref(), rule: rule, prefs: prefs) != nil)
}

@Test func autoMixKeyPrefersSameThenAdjacentThenEnergy() {
    let rule = MatchRule(), prefs = AutoMixPrefs()
    let r = ref(key: refKey8A, side: nil)
    let same = AutoMix.score(cand("same", code: refKey8A), ref: r, rule: rule, prefs: prefs)!
    let adj = AutoMix.score(cand("adj", code: Harmony.code(text: "9A")!), ref: r, rule: rule, prefs: prefs)!
    let energy = AutoMix.score(cand("energy", code: Harmony.code(text: "10A")!), ref: r, rule: rule, prefs: prefs)!
    #expect(same < adj)
    #expect(adj < energy)
}

@Test func autoMixKeyClashExcludedUnlessAllowed() {
    let rule = MatchRule()
    let r = ref(key: refKey8A, side: nil)
    let clash = cand("clash", code: Harmony.code(text: "3A")!)
    #expect(AutoMix.score(clash, ref: r, rule: rule, prefs: AutoMixPrefs()) == nil)
    var allow = AutoMixPrefs()
    allow.allowKeyClash = true
    #expect(AutoMix.score(clash, ref: r, rule: rule, prefs: allow) != nil)
}

@Test func autoMixTempoWindowFromMatchRule() {
    var rule = MatchRule()
    rule.bpmWindow = 4
    let prefs = AutoMixPrefs()
    #expect(AutoMix.score(cand("ok", bpm: 124), ref: ref(bpm: 128), rule: rule, prefs: prefs) != nil)   // 3,2 %
    #expect(AutoMix.score(cand("slow", bpm: 120), ref: ref(bpm: 128), rule: rule, prefs: prefs) == nil)  // 6,7 %
    // halbes Tempo nur mit der Regel
    #expect(AutoMix.score(cand("half", bpm: 64), ref: ref(bpm: 128), rule: rule, prefs: prefs) == nil)
    rule.halfDouble = true
    #expect(AutoMix.score(cand("half", bpm: 64), ref: ref(bpm: 128), rule: rule, prefs: prefs) != nil)
}

@Test func autoMixTagsPreferSimilarKickAndBass() {
    let rule = MatchRule()
    let prefs = AutoMixPrefs()
    let refTags = TagProfile("K tief B sub H off", separators: " ")
    let same = TagProfile("K tief B sub", separators: " ")
    let other = TagProfile("K hart B sub", separators: " ")
    let s1 = AutoMix.score(cand("same", tags: same), ref: ref(tags: refTags), rule: rule, prefs: prefs)!
    let s2 = AutoMix.score(cand("other", tags: other), ref: ref(tags: refTags), rule: rule, prefs: prefs)!
    #expect(s1 < s2)
    // Rolle wechseln (anderer Rollen-Satz) ist kein Malus
    let role = TagProfile("K tief B sub BREAK", separators: " ")
    let s3 = AutoMix.score(cand("role", tags: role), ref: ref(tags: refTags), rule: rule, prefs: prefs)!
    #expect(s3 == s1)
}

@Test func autoMixAlternatesSourceOnClose() {
    let rule = MatchRule(), prefs = AutoMixPrefs()
    let r = ref(key: refKey8A, side: 0)
    // gleiche Werte, nur die Seite unterscheidet sich: die andere Seite gewinnt
    let pick = AutoMix.choose([cand("a-side", code: refKey8A, side: 0), cand("b-side", code: refKey8A, side: 1)],
                              ref: r, rule: rule, prefs: prefs)
    #expect(pick?.key == "b-side")
}

@Test func autoMixAvoidsSameArtistTwiceInARow() {
    let rule = MatchRule(), prefs = AutoMixPrefs()
    let r = ref(key: refKey8A, artist: "Muster", side: nil)
    let pool = [cand("same-artist", artist: "Muster", code: refKey8A), cand("other", artist: "Andere", code: Harmony.code(text: "9A")!)]
    #expect(AutoMix.choose(pool, ref: r, rule: rule, prefs: prefs)?.key == "other")
    // ohne Alternative bleibt der Track trotzdem wählbar
    #expect(AutoMix.choose([pool[0]], ref: r, rule: rule, prefs: prefs)?.key == "same-artist")
}

@Test func autoMixPrefersAnalysedTracks() {
    let rule = MatchRule(), prefs = AutoMixPrefs()
    let r = ref(key: refKey8A, side: nil)
    let pool = [cand("raw", code: refKey8A, analyzed: false), cand("analysed", code: refKey8A, analyzed: true)]
    #expect(AutoMix.choose(pool, ref: r, rule: rule, prefs: prefs)?.key == "analysed")
}

@Test func autoMixChoiceIsDeterministicOnTies() {
    let rule = MatchRule(), prefs = AutoMixPrefs()
    let pool = [cand("b", code: refKey8B), cand("a", code: refKey8B)]
    let r = ref(key: refKey8B, side: nil)
    #expect(AutoMix.ranked(pool, ref: r, rule: rule, prefs: prefs).map(\.key) == ["a", "b"])
    #expect(AutoMix.ranked(pool.reversed(), ref: r, rule: rule, prefs: prefs).map(\.key) == ["a", "b"])
}

@Test func autoMixNoReferenceTakesPoolOrder() {
    // ohne laufenden Track: Schlüssel-Reihenfolge, Gridlose raus
    let rule = MatchRule(), prefs = AutoMixPrefs()
    let pool = [cand("c"), cand("nogrid", grid: false), cand("a")]
    #expect(AutoMix.ranked(pool, ref: ref(bpm: 0, side: nil), rule: rule, prefs: prefs).map(\.key) == ["a", "c"])
}

// MARK: Zeitplan

@Test func autoMixPhraseBoundaryIsStrictlyAfterNow() {
    #expect(AutoMixTimeline.nextBoundary(after: 0, phraseBeats: 64) == 64)
    #expect(AutoMixTimeline.nextBoundary(after: 63.9, phraseBeats: 64) == 64)
    #expect(AutoMixTimeline.nextBoundary(after: 64, phraseBeats: 64) == 128)
}

@Test func autoMixOutBeatIsLastPhraseBeforeOutro() {
    // 16-Takt-Phrasen (64 Beats), Ende bei 1000 Beats: Outro = 128 Beats vor dem Ende → Grenze ≤ 872 → 832
    let b = AutoMixTimeline.outBeat(endBeat: 1000, now: 0, phraseBeats: 64, transitionBeats: 64)
    #expect(b == 832)
    #expect(b! <= 1000 - 128)   // liegt vor dem Outro
}

@Test func autoMixOutBeatFallsBackToNextBoundaryWhenOutroPassed() {
    // Ende 400, jetzt 200: Grenze vor dem Outro (256) liegt nach „jetzt“
    #expect(AutoMixTimeline.outBeat(endBeat: 400, now: 200, phraseBeats: 64, transitionBeats: 64) == 256)
    // Ende 330, jetzt 200: Outro-Grenze 192 liegt vor „jetzt“ → nächste Grenze 256, passt noch (256 + 64 ≤ 330)
    #expect(AutoMixTimeline.outBeat(endBeat: 330, now: 200, phraseBeats: 64, transitionBeats: 64) == 256)
    // Ende 300, jetzt 200: Übergang über 128 Beats passt nicht mehr vor das Ende: nil
    #expect(AutoMixTimeline.outBeat(endBeat: 300, now: 200, phraseBeats: 64, transitionBeats: 128) == nil)
}

@Test func autoMixProgressAndBassSwapOnBar8() {
    let start = 832.0, tb = 64.0   // 16 Takte
    #expect(AutoMixTimeline.progress(beat: start, start: start, transitionBeats: tb) == 0)
    #expect(AutoMixTimeline.progress(beat: start + 32, start: start, transitionBeats: tb) == 0.5)   // Takt 8
    #expect(AutoMixTimeline.progress(beat: start + 1000, start: start, transitionBeats: tb) == 1)
    // Bass-Tausch genau bei Takt 8: eingehend vorher aus, danach 0 dB; ausgehend umgekehrt
    #expect(AutoMixLevels.incoming(0.49, bassSwap: true, filterSweep: true).low == AutoMixLevels.kill)
    #expect(AutoMixLevels.incoming(0.5, bassSwap: true, filterSweep: true).low == 0)
    #expect(AutoMixLevels.outgoing(0.49, bassSwap: true, filterSweep: true).low == 0)
    #expect(AutoMixLevels.outgoing(0.5, bassSwap: true, filterSweep: true).low == AutoMixLevels.kill)
    // ohne Bass-Tausch: eingehend bis zum Ende ohne Bass, ausgehend behält den Bass
    #expect(AutoMixLevels.incoming(0.9, bassSwap: false, filterSweep: false).low == AutoMixLevels.kill)
    #expect(AutoMixLevels.outgoing(0.9, bassSwap: false, filterSweep: false).low == 0)
}

@Test func autoMixLevelsEnvelope() {
    // Start: eingehend Bass aus, Höhen −12 dB, leichter Hochpass; ausgehend unverändert
    let i0 = AutoMixLevels.incoming(0, bassSwap: true, filterSweep: true)
    #expect(i0.low == AutoMixLevels.kill && i0.high == -12 && i0.filter > 0)
    let o0 = AutoMixLevels.outgoing(0, bassSwap: true, filterSweep: true)
    #expect(o0.high == 0 && o0.fader == 1 && o0.filter == 0)
    // Mitte der ersten Hälfte: Höhen bei −12 dB → 0 am Bar 8 (p = 0,5)
    #expect(AutoMixLevels.incoming(0.5, bassSwap: true, filterSweep: true).high == 0)
    #expect(AutoMixLevels.outgoing(0.5, bassSwap: true, filterSweep: true).high == -12)
    // Ende: ausgehend Fader auf 0, Tiefpass am Anschlag; eingehend ohne Filter, Höhen 0
    let o1 = AutoMixLevels.outgoing(1, bassSwap: true, filterSweep: true)
    #expect(o1.fader == 0 && o1.filter == -0.9)
    let i1 = AutoMixLevels.incoming(1, bassSwap: true, filterSweep: true)
    #expect(i1.high == 0 && i1.mid == 0 && i1.filter == 0 && i1.low == 0)
    // ohne Sweep kein Filter
    #expect(AutoMixLevels.outgoing(1, bassSwap: true, filterSweep: false).filter == 0)
}
