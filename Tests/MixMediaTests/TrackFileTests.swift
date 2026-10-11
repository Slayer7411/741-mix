import AVFoundation
import Foundation
import Testing
@testable import MixMedia

/// Testdatei: Sinus 440 Hz + leises Rauschen (Spektrum nicht leer), `seconds` lang
func writeTestWAV(rate: Double, channels: UInt32, seconds: Double, in dir: URL) throws -> URL {
    let url = dir.appendingPathComponent("src-\(UUID().uuidString).wav")
    let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
    let file = try AVAudioFile(forWriting: url, settings: fmt.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let n = AVAudioFrameCount(seconds * rate)
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n)!
    buf.frameLength = n
    var g = SystemRandomNumberGenerator()
    for c in 0..<Int(channels) {
        for i in 0..<Int(n) {
            buf.floatChannelData![c][i] = Float(sin(2 * .pi * 440 * Double(i) / rate)) * 0.5 + Float.random(in: -0.02...0.02, using: &g)
        }
    }
    try file.write(from: buf)
    return url
}

func tempDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("minos-mtrk-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func same(_ a: UnsafePointer<Float>, _ b: UnsafePointer<Float>, _ n: Int) -> Bool { memcmp(a, b, n * 4) == 0 }
private func same(_ a: UnsafeBufferPointer<Float>, _ b: UnsafeBufferPointer<Float>) -> Bool {
    a.count == b.count && (a.isEmpty || memcmp(a.baseAddress!, b.baseAddress!, a.count * 4) == 0)
}

/// geschrieben, eingeblendet = bit-gleich mit dem Dekodieren im Prozess (Samples, Wellenform, Spektrum)
@Test(arguments: [(44100.0, UInt32(2), 44100.0), (48000, 1, 44100), (96000, 2, 48000)])
func roundTripIsBitExact(srcRate: Double, channels: UInt32, rate: Double) throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let src = try writeTestWAV(rate: srcRate, channels: channels, seconds: 2.3, in: dir)
    let a = try TrackAudio.decode(url: src, sampleRate: rate)
    let key = try TrackFile.SourceKey.of(path: src.path, sampleRate: rate)
    let dst = dir.appendingPathComponent(key.fileName)
    let size = try TrackFile.write(a, key: key, to: dst)
    #expect(size == (try FileManager.default.attributesOfItem(atPath: dst.path)[.size] as? Int))
    let m = try TrackFile.map(dst, expect: key)
    let b = TrackFile.audio(m)
    #expect(b.mapping === m)
    #expect(a.mapping == nil)
    #expect(b.frames == a.frames && b.sampleRate == a.sampleRate)
    #expect(same(a.left, b.left, a.frames) && same(a.right, b.right, a.frames))
    #expect(same(a.peak, b.peak) && same(a.low, b.low) && same(a.mid, b.mid) && same(a.high, b.high))
    #expect(a.spectrum == b.spectrum && a.spectrum.count == a.peak.count)
    #expect(a.blend == b.blend && a.blend.count == a.peak.count)
    #expect(m.header.key == key)
    // Abschnitte auf 16 KB ausgerichtet, Audio ab 16 KB
    for s in TrackFile.Section.allCases { #expect(m.header.range(s).offset % TrackFile.alignment == 0) }
    #expect(m.header.range(.left).offset == TrackFile.alignment)
    #expect(m.lock() || true)   // mlock darf am Limit scheitern, Lesen muss trotzdem gehen
    // keine Reste vom Schreiben
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains(".tmp") }.isEmpty)
}

/// sehr kurze Tracks (kürzer als ein Block, ein Block)
@Test func shortTracks() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    for seconds in [0.001, 0.0034] {
        let src = try writeTestWAV(rate: 44100, channels: 2, seconds: seconds, in: dir)
        let a = try TrackAudio.decode(url: src, sampleRate: 44100)
        let key = try TrackFile.SourceKey.of(path: src.path, sampleRate: 44100)
        let dst = dir.appendingPathComponent(key.fileName)
        try TrackFile.write(a, key: key, to: dst)
        let b = TrackFile.audio(try TrackFile.map(dst))
        #expect(b.frames == a.frames && b.peak.count == a.peak.count && b.peak.count >= 1)
        #expect(same(a.peak, b.peak))
    }
}

/// eine Testdatei als .mtrk (Pfad, Schlüssel)
private func sample(_ dir: URL, seconds: Double = 0.5) throws -> (URL, TrackFile.SourceKey, TrackAudio) {
    let src = try writeTestWAV(rate: 44100, channels: 2, seconds: seconds, in: dir)
    let a = try TrackAudio.decode(url: src, sampleRate: 44100)
    let key = try TrackFile.SourceKey.of(path: src.path, sampleRate: 44100)
    let dst = dir.appendingPathComponent(key.fileName)
    try TrackFile.write(a, key: key, to: dst)
    return (dst, key, a)
}

private func patch(_ url: URL, at offset: Int, _ bytes: [UInt8]) throws {
    let h = try FileHandle(forWritingTo: url)
    try h.seek(toOffset: UInt64(offset))
    try h.write(contentsOf: Data(bytes))
    try h.close()
}

private func error(_ f: () throws -> Any) -> TrackFile.FileError? {
    do { _ = try f(); return nil } catch let e as TrackFile.FileError { return e } catch { return .io(-1) }
}

/// kaputter Kopf: Kennung, Version, Prüfsumme, Größe, Schlüssel
@Test func headerCorruptionIsRejected() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let (f1, _, _) = try sample(dir)
    try patch(f1, at: 0, Array("XTRK".utf8))
    #expect(error { try TrackFile.map(f1) } == .magic)

    let (f2, _, _) = try sample(dir)
    try patch(f2, at: 4, [9, 0, 0, 0])
    #expect(error { try TrackFile.map(f2) } == .version(9))

    // ein Bit in den Frames: Prüfsumme
    let (f3, _, _) = try sample(dir)
    try patch(f3, at: 24, [0xFF])
    #expect(error { try TrackFile.map(f3) } == .checksum)

    // Datei gekürzt (darf nie passieren, nur unlink) -> Größe passt nicht
    let (f4, _, _) = try sample(dir)
    let fd = open(f4.path, O_WRONLY)
    ftruncate(fd, off_t(TrackFile.alignment * 2)); close(fd)
    #expect(error { try TrackFile.map(f4) } == .size)

    // kleiner als der Kopf
    let f5 = dir.appendingPathComponent("tiny.mtrk")
    try Data(repeating: 0, count: 100).write(to: f5)
    #expect(error { try TrackFile.map(f5) } == .tooSmall)

    // anderer Schlüssel erwartet (Datei geändert, andere Rate, neuer Dekoder)
    let (f6, k6, _) = try sample(dir)
    var other = k6; other.mtimeNs += 1
    #expect(error { try TrackFile.map(f6, expect: other) } == .key)
    var newer = k6; newer.decoderVersion += 1
    #expect(error { try TrackFile.map(f6, expect: newer) } == .key)
    #expect(error { try TrackFile.map(f6, expect: k6) } == nil)
}

/// Abschnitte im Kopf verschoben, Prüfsumme neu gerechnet -> Aufbau stimmt nicht
@Test func layoutMismatchIsRejected() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let (f, _, _) = try sample(dir)
    var h = try TrackFile.readHeader(f)
    h.offsets[1] += 4
    try patch(f, at: 0, TrackFile.encode(h))
    #expect(error { try TrackFile.map(f) } == .layout)
}

/// löschen (Cache räumt auf), während eingeblendet: die Daten bleiben lesbar, kein SIGBUS
@Test func unlinkWhileMapped() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let (f, _, a) = try sample(dir, seconds: 3)
    let m = try TrackFile.map(f)
    let b = TrackFile.audio(m)
    #expect(unlink(f.path) == 0)
    #expect(!FileManager.default.fileExists(atPath: f.path))
    // neue Datei unter demselben Namen (neu dekodiert) ändert die alte Abbildung nicht
    try Data(repeating: 0xAB, count: 1 << 16).write(to: f)
    var sum: Float = 0
    for i in 0..<b.frames { sum += b.left[i] + b.right[i] }
    #expect(sum.isFinite)
    #expect(same(a.left, b.left, a.frames) && same(a.right, b.right, a.frames))
    #expect(same(a.peak, b.peak))
}

/// Schreiben scheitert (Ordner fehlt) -> Fehler, nichts bleibt liegen
@Test func failedWriteLeavesNothing() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let (_, key, a) = try sample(dir)
    let missing = dir.appendingPathComponent("gone/x.mtrk")
    #expect(error { try TrackFile.write(a, key: key, to: missing) } == .io(ENOENT))
    // Ziel ist ein Ordner: rename scheitert, die tmp-Datei wird gelöscht
    let blocked = dir.appendingPathComponent("blocked.mtrk")
    try FileManager.default.createDirectory(at: blocked.appendingPathComponent("x"), withIntermediateDirectories: true)
    #expect(error { try TrackFile.write(a, key: key, to: blocked) } != nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains(".tmp") }.isEmpty)
}

/// Schlüssel: gleiche Eingaben = gleicher Name, jede Änderung = anderer Name
@Test func sourceKeyNames() {
    let k = TrackFile.SourceKey(path: "/a/b.mp3", size: 10, mtimeNs: 5, sampleRate: 44100)
    #expect(k.name.count == 32 && k.fileName.hasSuffix(".mtrk"))
    #expect(k.name == TrackFile.SourceKey(path: "/a/b.mp3", size: 10, mtimeNs: 5, sampleRate: 44100).name)
    var names: Set<String> = [k.name]
    var p = k; p.path = "/a/c.mp3"; names.insert(p.name)
    var s = k; s.size = 11; names.insert(s.name)
    var t = k; t.mtimeNs = 6; names.insert(t.name)
    var r = k; r.sampleRate = 48000; names.insert(r.name)
    var v = k; v.decoderVersion += 1; names.insert(v.name)
    #expect(names.count == 6)
}
