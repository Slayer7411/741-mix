import Foundation
import Testing
import MixCore

/// Auswertung gegen eine künstliche Aufnahme: verzögert, leiser, Grundrauschen, ein 20-ms-Aussetzer im Rauschen
@Test func signalTestFindsLatencyGainAndDropout() {
    let rate = 48000.0, ref = SignalTest.signal(rate: rate), L = SignalTest.Layout(rate: rate)
    let lat = 1234
    var rec = [Float](repeating: 0, count: ref.count + 4000)
    var seed: UInt64 = 1
    for i in 0..<rec.count {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        rec[i] = Float(Double(seed >> 11) / Double(1 << 53) - 0.5) * 2e-4   // ~ −80 dBFS
        if i >= lat, i - lat < ref.count { rec[i] += ref[i - lat] * 0.5 }   // −6,02 dB
    }
    let drop = L.noiseStart + Int(rate * 2) + lat
    for i in drop..<(drop + Int(rate * 0.02)) { rec[i] = 0 }
    let r = SignalTest.analyze(rec: rec, rate: rate)
    #expect(r.problem == nil)
    #expect(r.latencyFrames == lat)
    #expect(abs(r.gainDb + 6.02) < 0.05)
    #expect(r.response.allSatisfy { abs($0.db) < 0.05 })
    #expect(r.thdnDb < -60)
    #expect(r.noiseFloorDb < -80 && r.noiseFloorDb > -100)
    #expect(r.dropouts.count >= 1 && r.dropouts.count <= 3 && abs(r.dropouts[0] - 2) < 0.02)
    #expect(abs(r.driftPPM) < 1)
}
