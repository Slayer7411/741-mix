import Foundation
import Testing
@testable import MixCore

@Test func jsonMergeDeepMergesObjectsAndReplacesRest() {
    let base: [String: Any] = ["ui": ["zoom": 1.0, "pair": ["on": false, "decks": [0, 2]]], "x": 1]
    let patch: [String: Any] = ["ui": ["zoom": 1.5, "pair": ["on": true]], "x": ["a": 1]]
    let m = JSONMerge.merged(base, patch)
    let ui = m["ui"] as? [String: Any]
    #expect(ui?["zoom"] as? Double == 1.5)
    let pair = ui?["pair"] as? [String: Any]
    #expect(pair?["on"] as? Bool == true)
    #expect((pair?["decks"] as? [Int]) == [0, 2])
    #expect((m["x"] as? [String: Any])?["a"] as? Int == 1)
}

@Test func jsonMergeListsUnknownPaths() {
    let ref: [String: Any] = ["ui": ["zoom": 1.0, "deckRows": ["info": true]], "shortcuts": [String: Any]()]
    let patch: [String: Any] = ["ui": ["zoom": 2, "zomo": 3, "deckRows": ["info": false, "nope": true]],
                                "shortcuts": ["neu": "x"], "gibtsnicht": 1]
    #expect(JSONMerge.unknownPaths(patch, reference: ref) == ["gibtsnicht", "ui.deckRows.nope", "ui.zomo"])
}
