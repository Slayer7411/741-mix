import Foundation
import Testing
import MixMedia
import MixProtocol

/// Cloud-Datei ohne lokale Kopie -> klare Meldung; der leere Fehler am Dateiende ist kein Cloud-Fall
@Test func cloudReadDetectsNotLocal() {
    let drive = "/Users/x/Library/CloudStorage/GoogleDrive-a@b.c/My Drive/Music/a.mp3"
    let local = "/Users/x/Music/a.mp3"
    #expect(CloudRead.notLocal(path: drive, datalessBefore: true, datalessAfter: false))
    #expect(CloudRead.notLocal(path: drive, datalessBefore: false, datalessAfter: true))
    #expect(!CloudRead.notLocal(path: drive, datalessBefore: false, datalessAfter: false), "lokal im Cloud-Ordner: echter Lesefehler")
    #expect(!CloudRead.notLocal(path: local, datalessBefore: true, datalessAfter: true), "nur in Cloud-Ordnern")
    #expect(CloudRead.isCloudBacked("/Users/x/Library/Mobile Documents/com~apple~CloudDocs/a.wav"))
    #expect(!CloudRead.isDataless(local))
}

@Test func notLocalCodeSurvivesTheWire() throws {
    let f = DecodeFailed(id: 7, code: .notLocal, detail: "/p")
    let back = try JSONDecoder().decode(DecodeFailed.self, from: JSONEncoder().encode(f))
    #expect(back == f)
}

/// mp3 mit zu groß geschätzter Länge: Lesefehler in der letzten Sekunde = Ende (gemessen 16187328 von 16193088 Frames)
@Test func readFailureNearEndIsEOF() {
    #expect(TrackAudio.readFailureIsEnd(position: 16_187_328, length: 16_193_088, fileRate: 44100))
    #expect(!TrackAudio.readFailureIsEnd(position: 1_000_000, length: 16_193_088, fileRate: 44100), "mitten in der Datei: Fehler bleibt")
    #expect(!TrackAudio.readFailureIsEnd(position: 0, length: 1000, fileRate: 44100), "nichts gelesen: Fehler bleibt")
}

/// echte Datei mit diesem Fehler (nicht im Repo): MIX741_TEST_SHORT_MP3=<pfad> -> lädt bis zum Ende
@Test(.enabled(if: ProcessInfo.processInfo.environment["MIX741_TEST_SHORT_MP3"] != nil))
func shortMp3DecodesToTheEnd() throws {
    let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MIX741_TEST_SHORT_MP3"]!)
    let a = try TrackAudio.decode(url: url, sampleRate: 44100)
    #expect(a.frames > 0)
}
