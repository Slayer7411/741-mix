import Foundation
import Testing
@testable import MixCore

private typealias P = OverviewPolicy

/// Laden (und 4 s danach) hält alles an – auch den Rechtsklick-Stapel und in jedem Modus
@Test func overviewGateWaitsWhileLoading() {
    for mode in [P.Mode.always, .idleOnly, .off] {
        for explicit in [false, true] {
            #expect(P.gate(mode, explicit: explicit, decks: .init(loading: true)) == .wait(.loading))
            #expect(P.gate(mode, explicit: explicit, decks: .init(playing: true, sinceLoad: 1)) == .wait(.loading))
            #expect(P.gate(mode, explicit: explicit, decks: .init(sinceLoad: P.settle - 0.1)) == .wait(.loading))
        }
    }
    #expect(P.gate(.always, explicit: false, decks: .init(sinceLoad: P.settle + 0.1)) == .full)
}

/// immer: spielt ein Deck -> gedrosselt, sonst voll; nur ohne Deck: wartet beim Spielen; aus: nur der Stapel
@Test func overviewGateByMode() {
    let play = P.Decks(playing: true), still = P.Decks()
    #expect(P.gate(.always, explicit: false, decks: play) == .throttled)
    #expect(P.gate(.always, explicit: false, decks: still) == .full)
    #expect(P.gate(.idleOnly, explicit: false, decks: play) == .wait(.playing))
    #expect(P.gate(.idleOnly, explicit: true, decks: play) == .wait(.playing))
    #expect(P.gate(.idleOnly, explicit: false, decks: still) == .full)
    #expect(P.gate(.off, explicit: false, decks: still) == .wait(.off))
    #expect(P.gate(.off, explicit: false, decks: play) == .wait(.off))
    #expect(P.gate(.off, explicit: true, decks: play) == .throttled)
    #expect(P.gate(.off, explicit: true, decks: still) == .full)
}

/// 2 Arbeiter nur für den Stapel ohne laufendes Deck; gedrosselt: halbe Rechenzeit
@Test func overviewWorkersAndPause() {
    #expect(P.workers(gate: .full, explicitQueued: true) == 2)
    #expect(P.workers(gate: .full, explicitQueued: false) == 1)
    #expect(P.workers(gate: .throttled, explicitQueued: true) == 1)
    #expect(P.workers(gate: .wait(.loading), explicitQueued: true) == 1)
    #expect(P.pause(after: 0.01, gate: .full) == 0)
    #expect(abs(P.pause(after: 0.01, gate: .throttled) - 0.01) < 1e-9)
    #expect(P.pause(after: -1, gate: .throttled) == 0)
}

/// reine Cloud-Dateien: Hintergrund überspringt, Rechtsklick liest; fehlende Dateien nie
@Test func overviewAdmitFiles() {
    #expect(P.admit(explicit: false, file: .local) == .read)
    #expect(P.admit(explicit: false, file: .onlineOnly) == .skipOnline)
    #expect(P.admit(explicit: true, file: .onlineOnly) == .read)
    #expect(P.admit(explicit: true, file: .missing) == .skipMissing)
    #expect(P.admit(explicit: false, file: .missing) == .skipMissing)
}

/// echte Datei = lokal, fehlende = missing
@Test func overviewFileState() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("minos-fs-\(UUID().uuidString)")
    try Data([1, 2, 3]).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(P.fileState(path: url.path) == .local)
    #expect(P.fileState(path: url.path + ".none") == .missing)
}
