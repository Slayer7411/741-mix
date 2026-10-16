import Testing
@testable import MixCore

private func probe(_ f: Int, worst: Double, avg: Double = 10, overruns: Int = 0, wd: Int = 0, done: Bool = true) -> BufferTest.Probe {
    BufferTest.Probe(frames: f, worstPct: worst, avgPct: avg, overruns: overruns, watchdogTimeouts: wd, completed: done)
}

@Test func bufferTestPicksSmallestSafeSize() {
    let r = BufferTest.recommend([probe(64, worst: 120, overruns: 9), probe(128, worst: 40), probe(256, worst: 30), probe(512, worst: 15)])
    #expect(r == BufferTest.Recommendation(frames: 128, reason: .safe))
}

@Test func bufferTestOverrunDisqualifiesEvenIfWorstIsLow() {
    // 0 % schwerster Block, aber eine Überlast: nicht sicher
    let r = BufferTest.recommend([probe(128, worst: 20, overruns: 1), probe(256, worst: 30)])
    #expect(r == BufferTest.Recommendation(frames: 256, reason: .safe))
}

@Test func bufferTestWatchdogTimeoutDisqualifies() {
    let r = BufferTest.recommend([probe(128, worst: 20, wd: 1), probe(256, worst: 30)])
    #expect(r.frames == 256)
}

@Test func bufferTestWorstLimitIsStrict() {
    // genau 60 % sind nicht unter der Grenze
    #expect(BufferTest.recommend([probe(128, worst: 60), probe(256, worst: 59.9)]).frames == 256)
    #expect(BufferTest.recommend([probe(128, worst: 59.9)]).frames == 128)
}

@Test func bufferTestMarginStepsOneSizeUp() {
    // 128 ist sicher, aber 50 % > 45 % -> 256
    let r = BufferTest.recommend([probe(128, worst: 50), probe(256, worst: 25), probe(512, worst: 12)])
    #expect(r == BufferTest.Recommendation(frames: 256, reason: .margin))
}

@Test func bufferTestMarginAtBoundaryNotApplied() {
    // genau 45 % ist nicht über der Reserve-Grenze
    #expect(BufferTest.recommend([probe(128, worst: 45), probe(256, worst: 20)]) == BufferTest.Recommendation(frames: 128, reason: .safe))
}

@Test func bufferTestMarginWithoutLargerSizeKeepsSafe() {
    // größte getestete Stufe: keine Reserve möglich
    #expect(BufferTest.recommend([probe(1024, worst: 52)]) == BufferTest.Recommendation(frames: 1024, reason: .safe))
}

@Test func bufferTestNoSafeSize() {
    let r = BufferTest.recommend([probe(64, worst: 140, overruns: 30), probe(128, worst: 80), probe(256, worst: 61)])
    #expect(r == BufferTest.Recommendation(frames: nil, reason: .noSafe))
}

@Test func bufferTestNoCompletedRun() {
    #expect(BufferTest.recommend([]) == BufferTest.Recommendation(frames: nil, reason: .none))
    // abgebrochen: zählt nicht, auch wenn die Werte gut sind
    #expect(BufferTest.recommend([probe(128, worst: 10, done: false)]) == BufferTest.Recommendation(frames: nil, reason: .none))
}

@Test func bufferTestIgnoresOrderAndIncompleteRuns() {
    let r = BufferTest.recommend([probe(512, worst: 10), probe(128, worst: 10, done: false), probe(256, worst: 40), probe(64, worst: 5, overruns: 2)])
    #expect(r == BufferTest.Recommendation(frames: 256, reason: .safe))
}

@Test func bufferTestSizesFollowDeviceRange() {
    #expect(BufferTest.sizes(range: 16...4096) == [64, 128, 256, 512, 1024])
    #expect(BufferTest.sizes(range: 128...512) == [128, 256, 512])
    #expect(BufferTest.sizes(range: 512...512) == [512])
    #expect(BufferTest.sizes(range: 1...63).isEmpty)
}

@Test func bufferTestLatencyMs() {
    #expect(abs(BufferTest.bufferMs(frames: 256, rate: 48000) - 256.0 / 48 ) < 1e-9)
    #expect(abs(BufferTest.bufferMs(frames: 64, rate: 44100) - 64.0 / 44.1) < 1e-9)
    #expect(BufferTest.bufferMs(frames: 128, rate: 0) == 0)
}
