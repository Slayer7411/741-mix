import AVFoundation
import Foundation
import MixCore
import Testing
@testable import MixMedia

/// Ausgabe: Dither, Abtastratenwandlung, Schreiben in 16 / 24 / 32 Bit, ID3-Chunk, m4a-Metadaten, Format- und Namensregeln
struct ExportTests {
    private func tempDir() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("minos741-export-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// Sinus, Kanal c gegenüber dem anderen um 0,1 leiser
    private func sine(_ frames: Int, rate: Double, hz: Double = 1000, amp: Float = 0.5) -> AudioCutWriter.Render {
        { c, out, from, n in
            for i in 0..<n {
                out[i] = amp * (c == 0 ? 1 : 0.9) * Float(sin(2 * Double.pi * hz * Double(from + i) / rate))
            }
        }
    }

    /// Frames einer Datei als Float (Kanal 0)
    private func readFloat(_ url: URL) throws -> [Float] {
        let f = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
        try f.read(into: buf)
        return Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
    }

    // MARK: Dither

    @Test func ditherStatisticsAreTPDF() {
        var rng = AudioDither()
        let n = 200_000
        let zeros = [Float](repeating: 0, count: n)
        var out = [Int32](repeating: 0, count: n)
        zeros.withUnsafeBufferPointer { x in
            out.withUnsafeMutableBufferPointer { o in
                AudioDither.quantize(x.baseAddress!, count: n, bits: 16, dither: true, rng: &rng, into: o.baseAddress!)
            }
        }
        // ±1 LSB, Mittelwert ~0, kein Gleichanteil
        #expect(out.allSatisfy { $0 >= -1 && $0 <= 1 })
        let mean = Double(out.reduce(0) { $0 + Int($1) }) / Double(n)
        #expect(abs(mean) < 0.01)
        // Dreiecksverteilung (TPDF) um null: P(0) = 3/4, P(±1) = 1/8 je Seite
        let zero = Double(out.filter { $0 == 0 }.count) / Double(n)
        let plus = Double(out.filter { $0 == 1 }.count) / Double(n)
        #expect(abs(zero - 0.75) < 0.01)
        #expect(abs(plus - 0.125) < 0.01)
    }

    @Test func ditherKeepsTheAverageOfASubLSBLevel() {
        var rng = AudioDither()
        let n = 200_000
        let x = [Float](repeating: 0.5 / 32768, count: n)   // ein halbes LSB
        var out = [Int32](repeating: 0, count: n)
        x.withUnsafeBufferPointer { p in
            out.withUnsafeMutableBufferPointer { o in
                AudioDither.quantize(p.baseAddress!, count: n, bits: 16, dither: true, rng: &rng, into: o.baseAddress!)
            }
        }
        let mean = Double(out.reduce(0) { $0 + Int($1) }) / Double(n)
        #expect(abs(mean - 0.5) < 0.01)
        // ohne Dither: immer derselbe Wert
        var plain = [Int32](repeating: 0, count: 4)
        x.withUnsafeBufferPointer { p in
            plain.withUnsafeMutableBufferPointer { o in
                AudioDither.quantize(p.baseAddress!, count: 4, bits: 16, dither: false, rng: &rng, into: o.baseAddress!)
            }
        }
        #expect(Set(plain).count == 1)
    }

    // MARK: Abtastrate

    @Test func resampleLengthAndRate() throws {
        let frames = 44_100
        var out: [Float] = []
        try StreamResampler.run(frames: frames, channels: 1, from: 44_100, to: 48_000, render: sine(frames, rate: 44_100),
                                progress: { _ in true }) { ch, n in
            out.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: n))
        }
        #expect(out.count == 48_000)
        // 1 kHz bleibt 1 kHz: Nulldurchgänge (steigend) über eine Sekunde ~ 1000
        var up = 0
        for i in 1..<out.count where out[i - 1] < 0 && out[i] >= 0 { up += 1 }
        #expect(abs(up - 1000) <= 2)
        // Pegel erhalten (Mitte der Datei, ohne Ränder)
        let peak = out[10_000..<38_000].map(abs).max() ?? 0
        #expect(abs(peak - 0.5) < 0.01)
    }

    @Test func resampleDownLengthAndRate() throws {
        let frames = 96_000
        var out: [Float] = []
        try StreamResampler.run(frames: frames, channels: 2, from: 96_000, to: 44_100, render: { c, o, f, n in
            for i in 0..<n { o[i] = Float(sin(2 * Double.pi * 440 * Double(f + i) / 96_000)) * (c == 0 ? 1 : 0.5) }
        }, progress: { _ in true }) { ch, n in
            out.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: n))
        }
        #expect(out.count == 44_100)
    }

    // MARK: Schreiben und Zurücklesen

    @Test(arguments: [
        AudioCutWriter.Format(container: .wav, bitDepth: 16, ext: "wav"),
        AudioCutWriter.Format(container: .wav, bitDepth: 24, ext: "wav"),
        AudioCutWriter.Format(container: .wav, bitDepth: 32, float: true, ext: "wav"),
        AudioCutWriter.Format(container: .aiff, bitDepth: 16, ext: "aiff"),
        AudioCutWriter.Format(container: .aiff, bitDepth: 24, ext: "aiff"),
        AudioCutWriter.Format.alac(16),
        AudioCutWriter.Format.alac(24),
    ])
    func writerRoundTrip(_ format: AudioCutWriter.Format) throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("out.\(format.ext)")
        let frames = 4_800
        try AudioCutWriter.write(frames: frames, channels: 1, sampleRate: 48_000, format: format, to: url,
                                 render: sine(frames, rate: 48_000))
        let back = try readFloat(url)
        #expect(back.count == frames)
        let lsb: Float = format.float ? 0 : (format.bitDepth == 16 ? 1.0 / 32768 : 1.0 / 8_388_608)
        let want = (0..<frames).map { Float(0.5 * sin(2 * Double.pi * 1000 * Double($0) / 48_000)) }
        let worst = zip(back, want).map { abs($0 - $1) }.max() ?? 0
        #expect(worst <= max(lsb, 1e-6) * 1.01)
    }

    @Test func writerResamplesToTheRequestedRate() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("out.wav")
        var f = AudioCutWriter.Format(container: .wav, bitDepth: 24, ext: "wav")
        f.rate = 96_000
        try AudioCutWriter.write(frames: 44_100, channels: 2, sampleRate: 44_100, format: f, to: url, render: sine(44_100, rate: 44_100))
        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.sampleRate == 96_000)
        #expect(file.length == 96_000)
    }

    @Test func ditheredSixteenBitFromFloatHasNoDCAndStaysWithinOneLSB() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("dith.wav")
        var f = AudioCutWriter.Format(container: .wav, bitDepth: 16, ext: "wav")
        f.dither = true
        let frames = 100_000
        try AudioCutWriter.write(frames: frames, channels: 1, sampleRate: 48_000, format: f, to: url, render: { _, o, _, n in
            o.update(repeating: 0, count: n)
        })
        let back = try readFloat(url)
        #expect(back.allSatisfy { abs($0) <= 1.01 / 32768 })
        // Mittelwert in LSB ~0 (kein Gleichanteil)
        let meanLSB = back.reduce(0, { $0 + Double($1) }) * 32768 / Double(frames)
        #expect(abs(meanLSB) < 0.02)
    }

    // MARK: ID3

    @Test func id3TagBytesRoundTrip() {
        var t = ExportTags()
        t.title = "Tiefe Mitte [cut]"; t.artist = "Ärger & Söhne"; t.album = "Album"; t.remixer = "Remix Person"
        t.label = "Label"; t.genre = "Techno"; t.key = "8a"; t.year = 2026; t.bpm = 128.5; t.comment = "kommentar ü"
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0] + [UInt8](repeating: 7, count: 64))
        let bytes = ID3Chunk.tagBytes(t, picture: jpeg)
        let r = ID3Chunk.parseID3(bytes)
        #expect(r?.text["TIT2"] == t.title)
        #expect(r?.text["TPE1"] == t.artist)
        #expect(r?.text["TALB"] == t.album)
        #expect(r?.text["TPE4"] == t.remixer)
        #expect(r?.text["TPUB"] == t.label)
        #expect(r?.text["TCON"] == t.genre)
        #expect(r?.text["TKEY"] == t.key)
        #expect(r?.text["TDRC"] == "2026")
        #expect(r?.text["TBPM"] == "128.50")
        #expect(r?.text["COMM"] == t.comment)
        #expect(r?.picture == jpeg)
        #expect(r?.tags.year == 2026)
    }

    @Test(arguments: [false, true]) func id3ChunkRoundTripInWavAndAiff(aiff: Bool) throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(aiff ? "t.aiff" : "t.wav")
        let format = aiff ? AudioCutWriter.Format(container: .aiff, bitDepth: 24, ext: "aiff")
                          : AudioCutWriter.Format(container: .wav, bitDepth: 24, ext: "wav")
        var t = ExportTags()
        t.title = "Titel"; t.artist = "Artist"; t.year = 2025; t.bpm = 124; t.key = "11m"; t.comment = "hallo"
        t.cover = .keep
        try AudioCutWriter.write(frames: 1_001, channels: 2, sampleRate: 44_100, format: format, to: url, tags: t,
                                 render: sine(1_001, rate: 44_100))
        // die Datei bleibt lesbar, Länge stimmt
        #expect(try AVAudioFile(forReading: url).length == 1_001)
        let r = try #require(ID3Chunk.read(url))
        #expect(r.text["TIT2"] == "Titel")
        #expect(r.text["TPE1"] == "Artist")
        #expect(r.text["TDRC"] == "2025")
        #expect(r.text["TBPM"] == "124")
        #expect(r.text["TKEY"] == "11m")
        #expect(r.text["COMM"] == "hallo")
        #expect(r.picture == nil)
    }

    @Test func wavListInfoIsWritten() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("list.wav")
        var t = ExportTags()
        t.title = "Nur Titel"
        try AudioCutWriter.write(frames: 500, channels: 1, sampleRate: 48_000,
                                 format: AudioCutWriter.Format(container: .wav, bitDepth: 16, ext: "wav"), to: url, tags: t,
                                 render: sine(500, rate: 48_000))
        let raw = try Data(contentsOf: url)
        #expect(raw.range(of: Data("LIST".utf8)) != nil)
        #expect(raw.range(of: Data("INAM".utf8)) != nil)
        #expect(raw.range(of: Data("Nur Titel".utf8)) != nil)
    }

    // MARK: m4a

    @Test func m4aMetadataRoundTrip() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("meta.m4a")
        var t = ExportTags()
        t.title = "Metatitel"; t.artist = "Metaartist"; t.album = "Metaalbum"; t.remixer = "Remixer X"; t.label = "Labelname"
        t.genre = "House"; t.comment = "Kommentar"; t.key = "8a"; t.year = 2024; t.bpm = 126
        try AudioCutWriter.write(frames: 4_800, channels: 2, sampleRate: 48_000, format: .alac(16), to: url, tags: t,
                                 render: sine(4_800, rate: 48_000))
        #expect(try AVAudioFile(forReading: url).length == 4_800)
        let back = try MediaTags.read(url)
        let values = Set(back.values)
        #expect(values.contains("Metatitel"))
        #expect(values.contains("Metaartist"))
        #expect(values.contains("Metaalbum"))
        #expect(values.contains("Remixer X"))
        #expect(values.contains("Labelname"))
        #expect(values.contains("House"))
        #expect(values.contains("Kommentar"))
        #expect(values.contains("8a"))
        #expect(values.contains("2024"))
        #expect(values.contains("126"))
    }

    @Test func aacFileWithMetadata() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("aac.m4a")
        var f = AudioCutWriter.Format(container: .aac, bitDepth: 16, ext: "m4a", kbps: 192)
        f.dither = false
        var t = ExportTags()
        t.title = "AAC Titel"
        try AudioCutWriter.write(frames: 48_000, channels: 2, sampleRate: 48_000, format: f, to: url, tags: t,
                                 render: sine(48_000, rate: 48_000))
        #expect(abs(try AVAudioFile(forReading: url).length - 48_000) < 4_096)   // AAC: Priming am Anfang
        #expect(try MediaTags.read(url).values.contains("AAC Titel"))
    }

    // MARK: Format und Namen

    @Test func formatFollowsTheOptions() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("src.wav")
        try AudioCutWriter.write(frames: 100, channels: 2, sampleRate: 44_100,
                                 format: AudioCutWriter.Format(container: .wav, bitDepth: 24, ext: "wav"), to: wav,
                                 render: sine(100, rate: 44_100))
        // wie Quelle: WAV bleibt WAV (Vorbereiten), sonst Apple Lossless (Schnitt)
        #expect(AudioCutWriter.format(matching: wav, options: .standard, wavRule: true).container == .wav)
        let cut = AudioCutWriter.format(matching: wav, options: .standard, wavRule: false)
        #expect(cut.container == .alac && cut.ext == "m4a" && cut.bitDepth == 24)
        var o = ExportOptions()
        o.container = .aiff; o.bits = .b16; o.rate = 48_000
        let f = AudioCutWriter.format(matching: wav, options: o, wavRule: false)
        #expect(f.container == .aiff && f.ext == "aiff" && f.bitDepth == 16 && f.rate == 48_000)
        #expect(f.dither)   // 24 -> 16 Bit: TPDF
        // Float nur WAV
        o.container = .alac; o.bits = .float32
        let g = AudioCutWriter.format(matching: wav, options: o, wavRule: false)
        #expect(!g.float && g.container == .alac && g.bitDepth == 24)
        o.container = .wav
        #expect(AudioCutWriter.format(matching: wav, options: o, wavRule: false).float)
        o.container = .aac; o.bits = .source; o.aacKbps = 320
        let a = AudioCutWriter.format(matching: wav, options: o, wavRule: false)
        #expect(a.container == .aac && a.ext == "m4a" && a.kbps == 320 && !a.dither)
        // 24 -> 16 Bit ohne Dither-Wunsch: aus
        var plain = ExportOptions(); plain.bits = .b16; plain.dither = false
        #expect(!AudioCutWriter.format(matching: wav, options: plain, wavRule: false).dither)
    }

    @Test func fileNamePatternAndDefault() {
        var o = ExportOptions()
        let fallback = { "Song [cut].m4a" }
        #expect(o.fileName(original: "Song.wav", tag: "cut", ext: "m4a", taken: { _ in false }, fallback: fallback) == "Song [cut].m4a")
        o.pattern = "{name} – {tag}"
        #expect(o.fileName(original: "Song.wav", tag: "cut", ext: "aiff", taken: { _ in false }, fallback: fallback) == "Song – cut.aiff")
        o.pattern = "{name}/x:y"
        #expect(o.fileName(original: "Song.wav", tag: "cut", ext: "m4a", taken: { _ in false }, fallback: fallback) == "Song-x-y.m4a")
        o.pattern = "{name} {tag}"
        #expect(o.fileName(original: "A.m4a", tag: "cut", ext: "m4a", taken: { $0 == "A cut.m4a" }, fallback: fallback) == "A cut #2.m4a")
    }

    @Test func openKeyMappingIsTheInverseOfTheTrackNotation() {
        for code in 0..<24 {
            #expect(ExportTags.musicalKey(openKey: Track.openKey(code: code)) == code)
        }
        #expect(ExportTags.musicalKey(openKey: "Am") == nil)
    }

    @Test func optionsDecodeOldPrefsAndKeepDefaults() throws {
        let d = try JSONDecoder().decode(ExportOptions.self, from: Data("{}".utf8))
        #expect(d == ExportOptions.standard)
        let e = try JSONEncoder().encode(ExportOptions())
        #expect(try JSONDecoder().decode(ExportOptions.self, from: e) == ExportOptions.standard)
    }
}
