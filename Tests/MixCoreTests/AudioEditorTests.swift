import Foundation
import Testing
@testable import MixCore

// Audio-Edit-Editor: Samples und Zeit, Ansicht und Zoom, Stille / Rückwärts / Zwischenablage in der Schnittliste,
// Marken-Datei (Rundlauf)

@Test func sampleTimeMath() {
    let rate = 44_100.0
    #expect(AudioEditView.sample(1, rate: rate) == 44_100)
    #expect(AudioEditView.time(22_050, rate: rate) == 0.5)
    #expect(AudioEditView.aligned(0.000_01, rate: rate) == 0)
    let s = AudioEditView.samples(TrackRange(0.5, 1.5), rate: rate)
    #expect(s.start == 22_050 && s.end == 66_150 && s.length == 44_100)
}

@Test func clockFormatAndParse() {
    #expect(AudioEditView.clock(0) == "0:00.000")
    #expect(AudioEditView.clock(83.5) == "1:23.500")
    #expect(AudioEditView.clock(59.9996) == "1:00.000")
    #expect(AudioEditView.parse("1:23.500") == 83.5)
    #expect(AudioEditView.parse("83,5") == 83.5)
    #expect(AudioEditView.parse("2:05") == 125)
    #expect(AudioEditView.parse("-1") == nil)
    #expect(AudioEditView.parse("x:1") == nil)
    #expect(AudioEditView.parse("") == nil)
}

@Test func viewZoomAndLimits() {
    let rate = 44_100.0, dur = 60.0, w = 1_000.0
    let r = AudioEditView.secPerPointRange(duration: dur, width: w, rate: rate)
    #expect(abs(r.lowerBound - 1 / (rate * 16)) < 1e-12)   // feinste Ansicht: 16 Punkte je Sample
    #expect(r.upperBound == 0.06)                          // ganze Datei passt in 1000 Punkte
    let fit = AudioEditView.fit(duration: dur, width: w, rate: rate)
    #expect(fit.start == 0 && fit.secPerPoint == 0.06)
    // Zoom hinein: der Punkt unter dem Zeiger bleibt, wo er war
    let z = AudioEditView.zoom(secPerPoint: fit.secPerPoint, start: fit.start, by: 4, at: 30, x: 500, width: w, duration: dur, rate: rate)
    #expect(abs(AudioEditView.time(x: 500, start: z.start, secPerPoint: z.secPerPoint) - 30) < 1e-9)
    // hinaus über die ganze Datei: begrenzt
    let out = AudioEditView.zoom(secPerPoint: fit.secPerPoint, start: 0, by: 0.1, at: 1, x: 10, width: w, duration: dur, rate: rate)
    #expect(out.secPerPoint == fit.secPerPoint)
    // hinein über die Sample-Ebene: begrenzt
    #expect(AudioEditView.clamp(secPerPoint: 1e-9, start: 0, width: w, duration: dur, rate: rate).secPerPoint == r.lowerBound)
    // Anfang bleibt in der Datei
    #expect(AudioEditView.clamp(secPerPoint: 0.01, start: 50, width: w, duration: dur, rate: rate).start == 50)
    #expect(AudioEditView.clamp(secPerPoint: 0.01, start: 55, width: w, duration: dur, rate: rate).start == 50)
    #expect(AudioEditView.clamp(secPerPoint: 0.06, start: 50, width: w, duration: dur, rate: rate).start == 0)
    // Zeitlinie: 90 Punkte Abstand mindestens
    #expect(AudioEditView.tickStep(secPerPoint: 0.01) == 1)
    #expect(AudioEditView.tickStep(secPerPoint: 1 / (rate * 16)) == 0.000_2)
}

@Test func selectionFitShowsRange() {
    let rate = 44_100.0
    let f = AudioEditView.fit(TrackRange(10, 12), width: 900, duration: 60, rate: rate)
    // 2 s füllen 90 % von 900 Punkten
    #expect(abs(f.secPerPoint - 2 / 810) < 1e-12)
    #expect(AudioEditView.x(10, start: f.start, secPerPoint: f.secPerPoint) > 0)
    #expect(AudioEditView.x(12, start: f.start, secPerPoint: f.secPerPoint) < 900)
}

@Test func silenceInsertAndReplace() {
    var e = EditList(duration: 10)
    let inserted = e.insertSilence(at: 4, length: 2)
    #expect(inserted)
    #expect(e.duration == 12)
    #expect(e.segments.map(\.isSilent) == [false, true, false])
    #expect(e.segments.map(\.length) == [4, 2, 6])
    // Stille ist kein Audio der Quelle: beide Nähte schneiden
    #expect(e.isCut(joint: 0) && e.isCut(joint: 1))
    // Ausgabe 5 liegt in der Stille, die Quelle steht an der Einfügestelle
    #expect(e.sourceTime(5) == 4)
    #expect(e.outputTime(4) == 6)
    #expect(e.frames(rate: 100, sourceFrames: 1_000).silent == [false, true, false])

    var f = EditList(duration: 10)
    let replaced = f.replaceWithSilence(TrackRange(2, 5))
    #expect(replaced)
    #expect(f.duration == 10)
    #expect(f.segments.map(\.length) == [2, 3, 5])
    #expect(f.segments[1].isSilent)
    // Stille gleicher Länge ist weiter „stumm“ im Sinne der Auswahl: kein Crossfade-Verlust, Länge bleibt exakt
    let fr = f.frames(rate: 100, sourceFrames: 1_000)
    #expect(fr.pieces.map(\.count) == [200, 300, 500])
}

@Test func reverseRangeFlipsOrderAndDirection() {
    var e = EditList(duration: 10)
    let r = e.reverse(TrackRange(2, 5))
    #expect(r == TrackRange(2, 5))
    #expect(e.duration == 10)
    #expect(e.segments == [EditSegment(0, 2), EditSegment(2, 5, reversed: true), EditSegment(5, 10)])
    #expect(e.isCut(joint: 0) && e.isCut(joint: 1))
    // Ausgabe 2.5 spielt Quelle 4.5 (von hinten), Quelle 4.5 liegt bei Ausgabe 2.5
    #expect(e.sourceTime(2.5) == 4.5)
    #expect(e.outputTime(4.5) == 2.5)
    // zweimal rückwärts = unverändert (als gehörter Ablauf)
    let base = EditList(duration: 10)
    var twice = base
    twice.reverse(TrackRange(2, 5))
    twice.reverse(TrackRange(2, 5))
    #expect(twice.audible == base.audible && twice.isPlain)
}

@Test func reverseAcrossCutKeepsLength() {
    var e = EditList(duration: 10)
    e.remove(TrackRange(3, 5))           // Quelle 0–3 und 5–10, Ausgabe 8 s
    #expect(e.duration == 8)
    let r = e.reverse(TrackRange(1, 6))
    #expect(r == TrackRange(1, 6))
    #expect(e.duration == 8)
    // Ausgabe 1–6 bestand aus Quelle 1–3 und 5–8: jetzt 5–8 rückwärts, dann 1–3 rückwärts
    #expect(e.segments == [EditSegment(0, 1), EditSegment(5, 8, reversed: true), EditSegment(1, 3, reversed: true), EditSegment(8, 10)])
    #expect(e.segments.map(\.length) == [1, 3, 2, 2])
}

@Test func splitKeepsDirectionAndSilence() {
    var e = EditList(duration: 10)
    e.reverse(TrackRange(0, 10))
    let split = e.split(at: 4)
    #expect(split)
    #expect(e.segments == [EditSegment(6, 10, reversed: true), EditSegment(0, 6, reversed: true)])
    #expect(e.sourceTime(4) == 6)
    var s = EditList(duration: 10)
    s.insertSilence(at: 0, length: 4)
    let splitS = s.split(at: 2)
    #expect(splitS)
    #expect(s.segments.map(\.length) == [2, 2, 10])
    #expect(s.segments[0].isSilent && s.segments[1].isSilent)
}

@Test func copyAndPasteSegments() {
    var e = EditList(duration: 10)
    let clip = e.copy(TrackRange(2, 4))
    #expect(clip == [EditSegment(2, 4)])
    let out = e.paste(clip ?? [], at: 6)
    #expect(out == TrackRange(6, 8))
    #expect(e.duration == 12)
    #expect(e.segments.map(\.length) == [6, 2, 4])
    #expect(e.segments[1] == EditSegment(2, 4))
    // Auswahl mit Stille und Rückwärts wird mitkopiert
    var f = EditList(duration: 10)
    f.insertSilence(at: 5, length: 1)
    f.reverse(TrackRange(0, 2))
    // Ausgabe 0–6: rückwärts 0–2, Quelle 2–5, Stille 1 s
    let block = f.copy(TrackRange(0, 6))
    #expect(block?.count == 3)
    #expect(block?.last?.isSilent == true)
    var g = EditList(duration: 10)
    _ = g.paste(block ?? [], at: 10)
    #expect(g.duration == 16)
    #expect(g.segments.last?.isSilent == true)
    #expect(g.segments.count == 1 + (block?.count ?? 0))
}

@Test func deleteAndCropStillWork() {
    var e = EditList(duration: 10)
    let removed = e.remove(TrackRange(4, 6))
    #expect(removed)
    #expect(e.duration == 8)
    var c = EditList(duration: 10)
    let kept = c.keep(TrackRange(2, 6))
    #expect(kept)
    #expect(c.duration == 4)
    // zu kurz (unter einer Sekunde) bleibt unverändert
    var s = EditList(duration: 10)
    let short = s.keep(TrackRange(2, 2.5))
    #expect(!short)
    #expect(s == EditList(duration: 10))
}

@Test func codableKeepsNewFieldsAndReadsOld() throws {
    var e = EditList(duration: 10)
    e.insertSilence(at: 3, length: 1)
    e.reverse(TrackRange(0, 2))
    let back = try JSONDecoder().decode(EditList.self, from: JSONEncoder().encode(e))
    #expect(back == e)
    // Datei ohne die neuen Felder
    let old = Data(#"{"source":10,"segments":[{"start":0,"end":10,"muted":false}]}"#.utf8)
    #expect(try JSONDecoder().decode(EditList.self, from: old) == EditList(duration: 10))
    // Richtung „vorwärts“ wird nicht gespeichert
    let plain = String(decoding: try JSONEncoder().encode(EditSegment(0, 1)), as: UTF8.self)
    #expect(!plain.contains("reversed") && !plain.contains("silence"))
}

@Test func markerStoreRoundTrip() {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("minos-marks-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let s = AudioMarkStore(url: url)
    let m1 = AudioMarker(name: "Marke 1", start: 1.25)
    let m2 = AudioMarker(name: "Bereich 1", start: 4, end: 6.5)
    s.set([m2, m1], for: "a.mp3")
    s.set([m1], for: "b.mp3")
    s.flush()
    let back = AudioMarkStore(url: url)
    #expect(back.markers("a.mp3") == [m2, m1])
    #expect(back.markers("b.mp3") == [m1])
    #expect(back.markers("none").isEmpty)
    s.set([], for: "b.mp3")
    s.flush()
    #expect(AudioMarkStore(url: url).markers("b.mp3").isEmpty)
    #expect(AudioMarkStore(url: url).markers("a.mp3").count == 2)
}

@Test func clipLengthFromSegments() {
    let c = AudioEditClip(key: "k", segments: [EditSegment(0, 2), EditSegment.silent(at: 2, length: 0.5)])
    #expect(c.length == 2.5)
    #expect(c.key == "k")
}
