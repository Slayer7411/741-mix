import Foundation
import Testing
@testable import MixCore

@Test func trackEditKeepsActiveLoops() throws {
    var e = TrackEdit()
    #expect(e.isEmpty)
    e.activeLoops = [3]
    #expect(!e.isEmpty && !e.same(as: TrackEdit()))
    let back = try JSONDecoder().decode(TrackEdit.self, from: JSONEncoder().encode(e))
    #expect(back.activeLoops == [3] && back.same(as: e))
    // ältere Datei ohne das Feld
    let old = try JSONDecoder().decode(TrackEdit.self, from: Data(#"{"bpm":128,"modified":0}"#.utf8))
    #expect(old.activeLoops == nil && old.bpm == 128)
    e.activeLoops = []
    #expect(e.isEmpty)
}
