import Foundation
import Testing
import MixCore
@testable import MixEngine

/// Key Sync, Instant Doubles, Active Loop im Steuerkern ohne Audiogerät.
/// 120 BPM, Grid ab 0 -> Beat = 0,5 s; Datei 24 s.
private func controller(keys: [Int] = [21, 9], cues: [Cue] = [], _ edit: (inout EnginePrefs) -> Void = { _ in }) async throws -> (MixController, URL) {
    let url = try writeWAV(rate: 44100, channels: 2, seconds: 24)
    let c = MixController()
    var p = EnginePrefs()
    edit(&p)
    c.setPrefs(p)
    for (d, k) in keys.enumerated() {
        var t = Track(key: url.path, path: url.path)
        t.bpm = 120
        t.musicalKey = k
        t.cues = [Cue(name: "Grid", kind: .grid, startMs: 0, lengthMs: 0, hotcue: -1)] + cues
        c.load(t, deck: d)
    }
    for _ in 0..<150 where keys.indices.contains(where: { c.trackAudio($0) == nil }) { try await Task.sleep(for: .milliseconds(20)) }
    #expect(keys.indices.allSatisfy { c.trackAudio($0) != nil })
    return (c, url)
}

@Test func keySyncShiftsToMasterAndTurnsKeylockOn() async throws {
    let (c, url) = try await controller { $0.keylockDefault = false }
    defer { try? FileManager.default.removeItem(at: url) }
    c.toggleMaster(1)
    #expect(!c.snapshot().decks[0].keylock)
    c.keySync(0)   // 1m -> 4d (A): Parallele 4m = −3
    let s = c.snapshot().decks[0]
    #expect(s.keylock && s.keyShift == -3)
    // Master ohne Keylock +6 % Tempo ≈ +1 Halbton: 4d -> 11d, Parallele 11m = 1m − 2
    c.setTempo(1, 6)
    c.keySync(0)
    #expect(c.snapshot().decks[0].keyShift == -2)
}

@Test func keySyncWithoutMasterChangesNothing() async throws {
    let (c, url) = try await controller()
    defer { try? FileManager.default.removeItem(at: url) }
    c.toggleMaster(0)
    c.keySync(0)   // Deck ist selbst Master
    #expect(c.snapshot().decks[0].keyShift == 0)
}
