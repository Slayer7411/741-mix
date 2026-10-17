import Testing
@testable import MixApp

/// Pasteboard-Text eines Tracks: nur eigene Einträge werden erkannt, Schlüssel bleibt unverändert
@MainActor @Test func trackDragPayloadRoundTrip() {
    let key = "Musik/Techno/a b.mp3"
    let payload = TrackDrag.prefix + key
    #expect(TrackDrag.key(payload) == key)
    #expect(TreeDrag.track(payload) == key)
    #expect(TrackDrag.key("https://example.org") == nil)
    #expect(TrackDrag.key(TreeDrag.prefix + "7F1C") == nil)   // Baum-Eintrag ist kein Track
    #expect(TrackDrag.key(TrackDrag.prefix) == "")            // leerer Schlüssel: der Aufrufer prüft ihn
}
