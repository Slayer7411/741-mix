import Foundation
import Testing
@testable import MixCore

@Test func pairTempoPlayingMasterLeads() {
    // nur ein Master-Deck spielt: diese Seite führt, unabhängig von der bisherigen Führung
    #expect(PairTempo.leads(ownPlaying: true, peerPlaying: false, ownLeads: false, peerLeads: true, ownName: "B", peerName: "A"))
    #expect(PairTempo.leads(ownPlaying: true, peerPlaying: false, ownLeads: true, peerLeads: false, ownName: "A", peerName: "B"))
    #expect(!PairTempo.leads(ownPlaying: false, peerPlaying: true, ownLeads: true, peerLeads: false, ownName: "A", peerName: "B"))
    #expect(!PairTempo.leads(ownPlaying: false, peerPlaying: true, ownLeads: false, peerLeads: true, ownName: "B", peerName: "A"))
}

@Test func pairTempoBothOrNeitherKeepsLeader() {
    // beide oder keiner spielt: die bisherige Führung bleibt
    #expect(PairTempo.leads(ownPlaying: true, peerPlaying: true, ownLeads: true, peerLeads: false, ownName: "B", peerName: "A"))
    #expect(!PairTempo.leads(ownPlaying: true, peerPlaying: true, ownLeads: false, peerLeads: true, ownName: "A", peerName: "B"))
    #expect(PairTempo.leads(ownPlaying: false, peerPlaying: false, ownLeads: true, peerLeads: false, ownName: "B", peerName: "A"))
    #expect(!PairTempo.leads(ownPlaying: false, peerPlaying: false, ownLeads: false, peerLeads: true, ownName: "A", peerName: "B"))
}

@Test func pairTempoConflictResolvesByName() {
    // beide führen oder keiner (Wiederverbinden, gleichzeitiger Anspruch): der kleinere Name führt
    #expect(PairTempo.leads(ownPlaying: false, peerPlaying: false, ownLeads: true, peerLeads: true, ownName: "A", peerName: "B"))
    #expect(!PairTempo.leads(ownPlaying: false, peerPlaying: false, ownLeads: true, peerLeads: true, ownName: "B", peerName: "A"))
    #expect(PairTempo.leads(ownPlaying: true, peerPlaying: true, ownLeads: false, peerLeads: false, ownName: "A", peerName: "B"))
    #expect(!PairTempo.leads(ownPlaying: true, peerPlaying: true, ownLeads: false, peerLeads: false, ownName: "B", peerName: "A"))
}

@Test func pairTempoBothMacsAgreeOnOneLeader() {
    // jede Eingabe: beide Macs rechnen aus ihrer Sicht und genau einer führt
    for pa in [false, true] { for pb in [false, true] { for la in [false, true] { for lb in [false, true] {
        let a = PairTempo.leads(ownPlaying: pa, peerPlaying: pb, ownLeads: la, peerLeads: lb, ownName: "A", peerName: "B")
        let b = PairTempo.leads(ownPlaying: pb, peerPlaying: pa, ownLeads: lb, peerLeads: la, ownName: "B", peerName: "A")
        #expect(a != b, "pa \(pa) pb \(pb) la \(la) lb \(lb)")
    } } } }
}
