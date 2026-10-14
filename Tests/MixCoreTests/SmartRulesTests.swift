import Foundation
import Testing
@testable import MixCore

private func track(_ key: String, _ f: (inout Track) -> Void = { _ in }) -> Track {
    var t = Track(key: key, path: "/Music/\(key).mp3")
    f(&t)
    t.buildSearchText()
    return t
}

private let now = SmartRules.day("2026-10-14")!

private let lib: [Track] = [
    track("a") { t in
        t.artist = "Kühl Sounds"; t.title = "Deep Night"; t.album = "Night EP"; t.mix = "Original Mix"; t.remixer = "Ben"
        t.producer = "Pro"; t.label = "Ostgut"; t.genre = "Techno"; t.catalogNo = "OST001"; t.comment = "warm up"
        t.comment2 = "dub · hypno · » BASIS"; t.musicalKey = 21; t.bpm = 128.02; t.rating = 4; t.duration = 361
        t.perceivedDb = -1.5; t.bitrate = 320; t.color = 2; t.playCount = 3
        t.releaseDate = SmartRules.day("2019-05-01"); t.importDate = SmartRules.day("2026-10-01"); t.lastPlayed = SmartRules.day("2026-10-10")
    },
    track("b") { t in
        t.artist = "Basic"; t.title = "Night Shift"; t.genre = "Deep House"; t.comment2 = "warm · dub"; t.keyText = "1m"
        t.bpm = 122; t.rating = 2; t.duration = 420; t.bitrate = 256; t.path = "/Music/b.wav"
        t.releaseDate = SmartRules.day("2024-01-01"); t.importDate = SmartRules.day("2025-01-01")
    },
    track("c") { t in
        t.artist = "Other"; t.title = "Silence"; t.genre = "techno"; t.bpm = 0; t.fileMissing = true
    },
]

private func hits(_ r: SmartRule, ctx: SmartContext = SmartContext(now: now, separators: "·")) -> [String] {
    SmartRules(rules: [r]).compile(ctx).apply(lib).map(\.key)
}

@Test func smartTextOperators() {
    #expect(hits(SmartRule(.genre, .contains, "techno")) == ["a", "c"])
    #expect(hits(SmartRule(.genre, .notContains, "techno")) == ["b"])
    #expect(hits(SmartRule(.genre, .equals, "TECHNO")) == ["a", "c"])
    #expect(hits(SmartRule(.genre, .isNot, "techno")) == ["b"])
    #expect(hits(SmartRule(.title, .startsWith, "night")) == ["b"])
    #expect(hits(SmartRule(.title, .endsWith, "night")) == ["a"])
    #expect(hits(SmartRule(.artist, .contains, "kuhl")) == ["a"])   // Akzente egal
    #expect(hits(SmartRule(.label, .isEmpty)) == ["b", "c"])
    #expect(hits(SmartRule(.label, .notEmpty)) == ["a"])
    #expect(hits(SmartRule(.release, .contains, "EP")) == ["a"])
    #expect(hits(SmartRule(.mix, .equals, "original mix")) == ["a"])
    #expect(hits(SmartRule(.remixer, .equals, "ben")) == ["a"])
    #expect(hits(SmartRule(.producer, .startsWith, "pr")) == ["a"])
    #expect(hits(SmartRule(.catalog, .contains, "ost")) == ["a"])
    #expect(hits(SmartRule(.comment, .contains, "warm")) == ["a"])
    #expect(hits(SmartRule(.comment2, .contains, "basis")) == ["a"])
    #expect(hits(SmartRule(.fileType, .equals, "wav")) == ["b"])
    #expect(hits(SmartRule(.path, .startsWith, "/music/")) == ["a", "b", "c"])
}

@Test func smartSearchTagKey() {
    #expect(hits(SmartRule(.search, .contains, "night deep")) == ["a", "b"])   // b: Genre Deep House
    #expect(hits(SmartRule(.search, .notContains, "night")) == ["c"])
    #expect(hits(SmartRule(.tag, .contains, "dub")) == ["a", "b"])
    #expect(hits(SmartRule(.tag, .contains, "du")) == [])   // ganze Tags
    #expect(hits(SmartRule(.tag, .notContains, "hypno")) == ["b", "c"])
    #expect(hits(SmartRule(.tag, .isEmpty)) == ["c"])
    #expect(hits(SmartRule(.tag, .notEmpty)) == ["a", "b"])
    // 21 = Am = 1m; b hat nur den Key-Text 1m
    #expect(hits(SmartRule(.key, .equals, "21")) == ["a", "b"])
    #expect(hits(SmartRule(.key, .isNot, "21")) == ["c"])
    #expect(hits(SmartRule(.key, .isEmpty)) == ["c"])
    #expect(hits(SmartRule(.key, .notEmpty)) == ["a", "b"])
}

@Test func smartNumbers() {
    #expect(hits(SmartRule(.bpm, .equals, "128")) == ["a"])   // 128.02 ≈ 128
    #expect(hits(SmartRule(.bpm, .isNot, "128")) == ["b", "c"])
    #expect(hits(SmartRule(.bpm, .greater, "125")) == ["a"])
    #expect(hits(SmartRule(.bpm, .less, "125")) == ["b", "c"])
    #expect(hits(SmartRule(.bpm, .atLeast, "122")) == ["a", "b"])
    #expect(hits(SmartRule(.bpm, .atMost, "122")) == ["b", "c"])
    #expect(hits(SmartRule(.bpm, .between, "130", "120")) == ["a", "b"])
    #expect(hits(SmartRule(.bpm, .between, "120,5", "125")) == ["b"])
    #expect(hits(SmartRule(.rating, .atLeast, "3")) == ["a"])
    #expect(hits(SmartRule(.year, .less, "2020")) == ["a"])
    #expect(hits(SmartRule(.year, .isEmpty)) == ["c"])
    #expect(hits(SmartRule(.duration, .greater, "6:30")) == ["b"])
    #expect(hits(SmartRule(.duration, .between, "6:00", "390")) == ["a"])
    #expect(hits(SmartRule(.loudness, .less, "0")) == ["a"])
    #expect(hits(SmartRule(.loudness, .isEmpty)) == ["b", "c"])
    #expect(hits(SmartRule(.bitrate, .atLeast, "300")) == ["a"])
    #expect(hits(SmartRule(.color, .equals, "2")) == ["a"])
    #expect(hits(SmartRule(.playCount, .greater, "0")) == ["a"])
    #expect(SmartRule(.bpm, .equals, "abc").problem != nil)
    #expect(SmartRule(.rating, .equals, "7").problem != nil)
    #expect(SmartRule(.bpm, .between, "120", "").problem != nil)
    #expect(SmartRule(.duration, .equals, "5:75").problem != nil)
    #expect(SmartRule(.duration, .equals, "5:30").problem == nil)
}

@Test func smartDates() {
    #expect(hits(SmartRule(.importDate, .inLast, "30", "d")) == ["a"])
    #expect(hits(SmartRule(.importDate, .inLast, "2", "y")) == ["a", "b"])
    #expect(hits(SmartRule(.importDate, .notInLast, "30", "d")) == ["b", "c"])   // ohne Datum: nicht in den letzten
    #expect(hits(SmartRule(.importDate, .inLast, "3", "w")) == ["a"])
    #expect(hits(SmartRule(.releaseDate, .before, "2020-01-01")) == ["a"])
    #expect(hits(SmartRule(.releaseDate, .after, "2019-05-01")) == ["b"])   // nach = ab dem Folgetag
    #expect(hits(SmartRule(.releaseDate, .between, "2024-01-01", "2019-05-01")) == ["a", "b"])
    #expect(hits(SmartRule(.lastPlayed, .isEmpty)) == ["b", "c"])
    #expect(hits(SmartRule(.lastPlayed, .notEmpty)) == ["a"])
    #expect(SmartRule(.importDate, .before, "2026-13-01").problem != nil)
    #expect(SmartRule(.importDate, .inLast, "x", "d").problem != nil)
}

@Test func smartFlagsCloudExpression() {
    #expect(hits(SmartRule(.played, .yes)) == ["a"])
    #expect(hits(SmartRule(.played, .no)) == ["b", "c"])
    #expect(hits(SmartRule(.played, .yes), ctx: SmartContext(now: now, played: ["b"])) == ["a", "b"])
    #expect(hits(SmartRule(.analyzed, .yes)) == ["a"])
    #expect(hits(SmartRule(.analyzed, .no)) == ["b", "c"])
    #expect(hits(SmartRule(.cloud, .equals, "missing")) == ["c"])
    #expect(hits(SmartRule(.cloud, .isNot, "local")) == ["c"])
    let ctx = SmartContext(now: now, availability: { $0.key == "b" ? .cloud : $0.fileExists ? .local : .missing })
    #expect(hits(SmartRule(.cloud, .equals, "cloud"), ctx: ctx) == ["b"])
    #expect(hits(SmartRule(.expression, .matches, #"$BPM > 120 & $GENRE % "house""#)) == ["b"])
    #expect(hits(SmartRule(.expression, .matches, #"$TITLE ENDS_WITH "shift""#)) == ["b"])
    #expect(SmartRule(.expression, .matches, #"$BPM >"#).problem != nil)
    #expect(hits(SmartRule(.expression, .matches, #"$BPM >"#)) == [])
}

@Test func smartMatchSortLimit() {
    let any = SmartRules(match: .any, rules: [SmartRule(.genre, .equals, "deep house"), SmartRule(.bpm, .greater, "125")])
    #expect(any.compile(SmartContext(now: now)).apply(lib).map(\.key) == ["a", "b"])
    let all = SmartRules(match: .all, rules: any.rules)
    #expect(all.compile(SmartContext(now: now)).apply(lib).isEmpty)
    #expect(SmartRules().compile(SmartContext(now: now)).apply(lib).count == 3)   // ohne Regeln: alles
    let top = SmartRules(rules: [], sort: SmartSort(.bpm, ascending: false), limit: 2)
    #expect(top.compile(SmartContext(now: now)).apply(lib).map(\.key) == ["a", "b"])
    let first = SmartRules(rules: [], sort: SmartSort(.title, ascending: true), limit: 1)
    #expect(first.compile(SmartContext(now: now)).apply(lib).map(\.key) == ["a"])
}

/// alte Smartlists (Regel-Text): Zeilen, wenn genau abbildbar, sonst ein Ausdruck – Treffer gleich
@Test func smartLegacyQueries() {
    let cases: [(String, Int?, SmartRules.Match)] = [
        (#"$COMMENT2 % "BASIS""#, 1, .all),
        (#"$COMMENT2 % "dub" & $COMMENT2 !% "hypno""#, 2, .all),
        (#"$GENRE == "techno" | $BPM >= 125"#, 2, .any),
        (#"$IMPORTDATE >= MONTHS_AGO(6) & $RATING > 3"#, 2, .all),
        (#"$KEY == "8m""#, nil, .all),         // Key-Text, nicht der Key -> Ausdruck
        (#"$PLAYED == TRUE"#, 1, .all),
        (#"$TITLE STARTS_WITH "night""#, 1, .all),
        (#"$BPM == 128"#, nil, .all),          // genau vs. gerundet -> Ausdruck
        (#"$GENRE % "a" & ($BPM > 1 | $BPM < 0)"#, nil, .all),
        (#"!($BPM >= 125)"#, nil, .all),
        (#"$GENRE % "#, nil, .all),             // kaputt -> Ausdruck (keine Treffer wie vorher)
    ]
    for (q, n, m) in cases {
        let r = SmartRules.from(query: q)
        if let n {
            #expect(r.rules.count == n && !r.rules.contains { $0.field == .expression } && r.match == m, "\(q) -> \(r.rules)")
        } else {
            #expect(r.rules.count == 1 && r.rules[0].field == .expression && r.rules[0].value == q, "\(q)")
        }
        let old = (try? SmartQuery.parse(q)).map { q in lib.filter { q.matches($0, now: now) }.map(\.key) } ?? []
        #expect(r.compile(SmartContext(now: now)).apply(lib).map(\.key) == old, "\(q)")
    }
    #expect(SmartRules.from(query: "").rules.isEmpty)
}

@Test func smartRulesCodable() throws {
    let r = SmartRules(match: .any, rules: [SmartRule(.bpm, .between, "120", "130"), SmartRule(.tag, .contains, "dub")],
                       sort: SmartSort(.importDate, ascending: false), limit: 50)
    let back = try JSONDecoder().decode(SmartRules.self, from: JSONEncoder().encode(r))
    #expect(back == r)
    // unbekanntes Feld (neuere Version): bleibt lesbar, Zeile ohne Treffer
    let json = #"{"match":"all","rules":[{"field":"future","op":"is","value":"x"},{"field":"genre","op":"contains","value":"techno"}]}"#
    let odd = try JSONDecoder().decode(SmartRules.self, from: Data(json.utf8))
    #expect(odd.rules.count == 2 && odd.rules[0].field == .expression && odd.rules[1].field == .genre)
}

@Test func smartRuleFieldSwitch() {
    var r = SmartRule(.genre, .contains, "techno")
    r.setField(.artist)
    #expect(r.op == .contains && r.value == "techno")
    r.setField(.bpm)
    #expect(r.op == .equals && r.value.isEmpty)
    r.setField(.importDate)
    #expect(r.op == .inLast)
    r.setOp(.inLast)
    #expect(r.value == "30" && r.value2 == "d" && r.problem == nil)
    r.setField(.cloud)
    #expect(r.value == "local" && r.problem == nil)
}
