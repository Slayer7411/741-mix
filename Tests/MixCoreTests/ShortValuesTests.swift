import Foundation
import Testing
@testable import MixCore

@Test func versionFromTitleManySpellings() {
    let cases: [(String, String, String)] = [
        ("Track (Original Mix)", "Track", "OM"), ("Track (original mix)", "Track", "OM"), ("Track [ORIGINAL MIX]", "Track", "OM"),
        ("Track - Original Mix", "Track", "OM"), ("Track – Original", "Track", "OM"), ("Track (Original  Mix) ", "Track", "OM"),
        ("Track (Extended Mix)", "Track", "EXT"), ("Track (extended)", "Track", "EXT"), ("Track (Extended Version)", "Track", "EXT"),
        ("Track (Original Extended Mix)", "Track", "EXT"), ("Track (Radio Edit)", "Track", "RADIO"), ("Track (Dub)", "Track", "DUB"),
        ("Track (Foo Remix)", "Track", "Foo RMX"), ("Track (Foo Bar remix)", "Track", "Foo Bar RMX"), ("Track [Remix]", "Track", "RMX"),
        ("Track (VIP Mix)", "Track", "VIP"), ("Track (Someone Rework)", "Track", "Someone RWK"), ("Track (Club Mix)", "Track", "CLUB"),
        ("A (B) (Original Mix)", "A (B)", "OM"), ("Track (Instrumental)", "Track", "INST"),
    ]
    for (title, base, short) in cases {
        let v = ShortValues.version(title)
        #expect(v?.base == base && v?.short == short, "\(title) -> \(String(describing: v))")
    }
    for none in ["Track", "Track (feat. X)", "(Original Mix)", "Track (Remastered)", "Mix - Track (Live)", "", "Track (Foo Original)"] {
        #expect(ShortValues.version(none) == nil, "\(none)")
    }
}

@Test func middleTruncationKeepsBothEnds() {
    #expect(ShortValues.middle("Short", max: 10) == "Short")
    #expect(ShortValues.middle("Very Long Title Name", max: 10) == "Very…Name")
    #expect(ShortValues.middle("Very Long Title Name", max: 10).count <= 10)
    #expect(ShortValues.middle("abcdef", max: 1) == "…")
    #expect(ShortValues.middle("abcdef", max: 0) == "")
    #expect(ShortValues.middle("abcdefghij", max: 5) == "ab…ij")
}

@Test func shortBPM() {
    #expect(ShortValues.bpm(128) == "128")
    #expect(ShortValues.bpm(127.97) == "128")
    #expect(ShortValues.bpm(128.04) == "128")
    #expect(ShortValues.bpm(127.5) == "127.5")
    #expect(ShortValues.bpm(174.93) == "174.9")
    #expect(ShortValues.bpm(0) == "")
}

@Test func shortDateByAge() {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = .current
    let now = c.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 12))!
    let recent = c.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 9))!
    let spring = c.date(from: DateComponents(year: 2026, month: 3, day: 2))!
    let old = c.date(from: DateComponents(year: 2024, month: 10, day: 3))!
    #expect(ShortValues.date(recent, now: now) == "14.10.")
    #expect(ShortValues.date(spring, now: now) == "02.03.")
    #expect(ShortValues.date(old, now: now, locale: Locale(identifier: "de_DE")) == "Okt 24")
    #expect(ShortValues.date(old, now: now, locale: Locale(identifier: "en_US")) == "Oct 24")
    #expect(ShortValues.date(nil, now: now) == "")
}
