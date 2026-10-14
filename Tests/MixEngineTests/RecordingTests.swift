import AVFoundation
import Foundation
import Testing
import MixDSP
@testable import MixEngine

// Aufnahme: Ring (über die Grenze, Überlauf, lückenlos), Abgriff des Masters im Kern offline (ohne Metronom und
// Vorhören), Schreib-Queue bis in die Datei.

private func ramp(_ from: Int, _ n: Int) -> [Float] { (0..<n).map { Float(from + $0) } }

@Test func ringWrapsWithoutGaps() throws {
    let ring = try #require(RecordRing(capacityFrames: 1000))
    #expect(ring.capacity == 1024)
    ring.reset(); ring.armed = true
    var next = 0, expect = 0
    var l = [Float](repeating: 0, count: 700), r = l
    // 20 Runden zu 300 Frames rein, 2 × 150 raus: Index läuft mehrfach über die Grenze
    for _ in 0..<20 {
        let a = ramp(next, 300), b = a.map { -$0 }
        a.withUnsafeBufferPointer { pa in b.withUnsafeBufferPointer { pb in ring.write(left: pa.baseAddress!, right: pb.baseAddress!, count: 300) } }
        next += 300
        for _ in 0..<2 {
            let n = l.withUnsafeMutableBufferPointer { pl in r.withUnsafeMutableBufferPointer { pr in ring.read(left: pl.baseAddress, right: pr.baseAddress, max: 150) } }
            #expect(n == 150)
            for i in 0..<n { #expect(l[i] == Float(expect + i) && r[i] == -Float(expect + i)) }
            expect += n
        }
    }
    #expect(ring.overflows == 0 && ring.droppedFrames == 0 && ring.writtenFrames == 6000)
    #expect(ring.available == 0)
}

@Test func ringCountsOverflowAndKeepsOrder() throws {
    let ring = try #require(RecordRing(capacityFrames: 1024))
    ring.reset(); ring.armed = true
    let block = [Float](repeating: 0.25, count: 400)
    block.withUnsafeBufferPointer { p in for _ in 0..<4 { ring.write(left: p.baseAddress!, right: nil, count: 400) } }
    // 2 Blöcke passen (800), 3. und 4. verworfen, nie überschrieben
    #expect(ring.available == 800)
    #expect(ring.overflows == 2 && ring.droppedFrames == 800 && ring.writtenFrames == 800)
    // Pegel auch für verworfene Blöcke; ohne Scharfschalten nur Pegel
    #expect(ring.takePeak().left == 0.25)
    ring.reset()
    #expect(ring.available == 0 && ring.overflows == 0)
    ring.armed = false
    block.withUnsafeBufferPointer { p in ring.write(left: p.baseAddress!, right: p.baseAddress!, count: 400) }
    #expect(ring.available == 0 && ring.takePeak().right == 0.25)
}

/// Kern offline: Deck auf 1/2, Metronom und Vorhören auf demselben Paar – im Ring steht genau der Master ohne beide
@Test func masterTapIsAfterLimiterWithoutMetronome() throws {
    let fs = 48000.0, n = 512
    let e = mdsp_create(fs)!
    defer { mdsp_destroy(e) }
    mdsp_set_master(e, 1)
    let len = Int(fs) * 2
    let tl = UnsafeMutablePointer<Float>.allocate(capacity: len), tr = UnsafeMutablePointer<Float>.allocate(capacity: len)
    defer { tl.deallocate(); tr.deallocate() }
    for i in 0..<len { let v = Float(sin(2 * .pi * 330 * Double(i) / fs)) * 1.5; tl[i] = v; tr[i] = v }   // über 0 dBFS -> begrenzt
    mdsp_set_track(e, 0, tl, tr, Int64(len), fs, 0)
    mdsp_set_param(e, 0, MD_VOLUME, 1)
    mdsp_set_param(e, 0, MD_PLAYING, 1)
    mdsp_clock_set_bpm(e, 300)
    mdsp_metronome(e, true, 1, 0)
    let ring = try #require(RecordRing(capacityFrames: 1 << 16))
    ring.reset(); ring.armed = true
    let out = (0..<2).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: n) }
    defer { out.forEach { $0.deallocate() } }
    var ptrs: [UnsafeMutablePointer<Float>?] = out
    setTap(e, ring, 0)
    var rendered: [Float] = [], recorded = [Float](repeating: 0, count: n)
    var clickDiff: Float = 0
    for _ in 0..<40 {
        ptrs.withUnsafeMutableBufferPointer { mdsp_render(e, $0.baseAddress, 2, Int32(n)) }
        let got = recorded.withUnsafeMutableBufferPointer { ring.read(left: $0.baseAddress, right: nil, max: n) }
        #expect(got == n)
        for i in 0..<n {
            #expect(abs(recorded[i]) <= 1)
            clickDiff = max(clickDiff, abs(out[0][i] - recorded[i]))
        }
        rendered += recorded
    }
    // Ausgang = Master + Klick; Aufnahme = Master: der Unterschied ist der Klick, die Aufnahme klingt (Track läuft)
    #expect(clickDiff > 0.05)
    #expect(rendered.map(abs).max()! > 0.9)
    setTap(e, nil, 0)
    #expect(tapReleased(e, ring) == false)   // erst nach einem Block ohne Abgriff
    for _ in 0..<2 { ptrs.withUnsafeMutableBufferPointer { mdsp_render(e, $0.baseAddress, 2, Int32(n)) } }
    #expect(tapReleased(e, ring))
    #expect(ring.available == 0)
    var total: UInt64 = 0, worst: UInt64 = 0, blocks: UInt32 = 0
    mdsp_record_tap_cost(e, &total, &worst, &blocks)
    #expect(blocks == 40 && total > 0)
}

private func setTap(_ e: OpaquePointer, _ ring: RecordRing?, _ ch: Int32) {
    mdsp_set_record_tap(e, ring?.ptr, ch)
}
private func tapReleased(_ e: OpaquePointer, _ ring: RecordRing) -> Bool { mdsp_record_tap_released(e, ring.ptr) }

/// Ring -> Schreib-Queue -> Datei: jede Frame landet in der Datei, in Reihenfolge
@Test func sinkWritesEveryFrame() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("minos-rec-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let ring = try #require(RecordRing(capacityFrames: 1 << 17))
    let url = dir.appendingPathComponent("take.wav")
    let sink = try RecordSink(ring: ring, url: url, kind: .wav, sampleRate: 44100)
    sink.start()
    // 2,5 s in Blöcken zu 512 aus einem fremden Thread (wie der Audio-Thread), Rampe für die Reihenfolge
    let total = 44100 * 5 / 2
    let t = Thread {
        var at = 0
        while at < total {
            let k = min(512, total - at)
            let a = (0..<k).map { Float((at + $0) % 4096) / 8192 }
            a.withUnsafeBufferPointer { ring.write(left: $0.baseAddress!, right: $0.baseAddress!, count: k) }
            at += k
            usleep(1500)
        }
    }
    t.start()
    while ring.writtenFrames < total { try await Task.sleep(for: .milliseconds(20)) }
    let stats: RecordSink.Stats = await withCheckedContinuation { c in sink.stop { c.resume(returning: $0) } }
    #expect(stats.frames == total && stats.overflows == 0 && stats.error == nil)
    let f = try AVAudioFile(forReading: url)
    #expect(Int(f.length) == total && f.fileFormat.sampleRate == 44100 && f.fileFormat.channelCount == 2)
    let buf = try #require(AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(total)))
    try f.read(into: buf)
    let l = buf.floatChannelData![0]
    var maxErr: Float = 0
    for i in 0..<total { maxErr = max(maxErr, abs(l[i] - Float(i % 4096) / 8192)) }
    #expect(maxErr < 1e-5)   // 24 Bit
}

/// Eingang ohne Gerät: sauberer Fehler, nichts läuft (ohne echtes Gerät, ohne Rückfrage nach dem Zugriff)
@Test func inputWithoutDeviceFailsCleanly() throws {
    let ring = try #require(RecordRing(capacityFrames: 4096))
    let input = CoreAudioInput()
    #expect(throws: CoreAudioInput.InputError.noDevice) { try input.start(device: nil, firstChannel: 0, ring: ring) }
    #expect(throws: CoreAudioInput.InputError.noDevice) { try input.start(device: 0xFFFF_FF00, firstChannel: 0, ring: ring) }
    #expect(!input.running && input.info == nil)
    #expect(MixEngine.inputDevice(uid: "minos741-no-such-device") == nil && MixEngine.inputDevice(uid: "") == nil)
    input.stop()
}
