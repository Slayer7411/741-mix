import AVFoundation
import Foundation
import MixCore
import MixEngine

/// Signal-Test am echten Gerät (nicht im Selbsttest): Testsignal auf Deck X, Pult-Rückweg auf einem Eingangspaar
/// aufnehmen, auswerten. Start: MIX741_SIGNALTEST=A (oder ABCD), MIX741_SIGNALTEST_IN=11 (erster Eingangskanal,
/// 1-basiert, Standard 11), MIX741_SIGNALTEST_QUIT=1 beendet danach. Headroom 0, Auto-Gain aus während des Tests,
/// danach wie vorher. Bericht: Konsole und ~/Music/MINOS-741/Signaltest-<Zeit>.md
@MainActor
enum SignalTestRun {
    static func runIfRequested(mix: MixModel) {
        let env = ProcessInfo.processInfo.environment
        guard let spec = env["MIX741_SIGNALTEST"], !spec.isEmpty, !Session.isSelfTest else { return }
        let decks = spec.uppercased().compactMap { "ABCD".firstIndex(of: $0).map { "ABCD".distance(from: "ABCD".startIndex, to: $0) } }
        let first = max(1, Int(env["MIX741_SIGNALTEST_IN"] ?? "11") ?? 11) - 1
        let quit = env["MIX741_SIGNALTEST_QUIT"] == "1"
        Task { @MainActor in
            await run(mix: mix, decks: decks.isEmpty ? [0] : decks, firstInput: first)
            if quit { exit(0) }
        }
    }

    static func log(_ s: String) { print("[signaltest] \(s)"); fflush(stdout) }

    static func run(mix: MixModel, decks: [Int], firstInput: Int) async {
        for _ in 0..<100 where !mix.engine.running { try? await Task.sleep(for: .milliseconds(100)) }
        guard mix.engine.running else { log("FEHLER: Ausgabe läuft nicht"); return }
        let rate = mix.engine.outputRate
        log("Gerät: Ausgabe \(Int(rate)) Hz · Modus \(mix.mixerMode == .internalMixer ? "intern" : "extern") · Paare \(mix.deckPairs.map { "\($0 + 1)/\($0 + 2)" }) · Eingang \(firstInput + 1)/\(firstInput + 2)")
        // Testsignal als Datei in der Rate des Geräts (kein Umrechnen im Deck)
        let sig = SignalTest.signal(rate: rate)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("minos741-signaltest-\(Int(rate)).wav")
        do { try write(sig, rate: rate, to: url) } catch { log("FEHLER: Testsignal nicht geschrieben: \(error)"); return }
        // neutral: Headroom 0, Auto-Gain aus
        let before = mix.prefs.engine
        mix.prefs.engine.headroomExternal = 0; mix.prefs.engine.headroomInternal = 0
        mix.prefs.engine.autoGain = false; mix.prefs.engine.autoGainExternal = false
        defer { mix.prefs.engine = before }
        var lines: [String] = []
        for d in decks {
            let name = "Deck \(deckLetters[d])"
            var t = Track(key: url.path + "#\(d)", path: url.path)
            t.title = "MINOS-741 Signal-Test"; t.artist = "MINOS-741"
            guard mix.load(t, deck: d, force: true) else { log("\(name): lädt nicht (Deck spielt?)"); continue }
            for _ in 0..<200 where mix.core.trackAudio(d) == nil { try? await Task.sleep(for: .milliseconds(50)) }
            guard mix.core.trackAudio(d) != nil else { log("\(name): Track nicht geladen"); continue }
            guard let ring = RecordRing(capacityFrames: Int(rate * 4)) else { log("RAM"); return }
            let input = CoreAudioInput()
            let info: CoreAudioInput.Info
            do { info = try input.start(device: mix.engine.routing.device, firstChannel: firstInput, ring: ring) } catch {
                log("\(name): Eingang startet nicht: \(error.localizedDescription)"); continue
            }
            guard abs(info.rate - rate) < 0.5 else { input.stop(); log("\(name): Eingang \(Int(info.rate)) Hz ≠ Ausgang \(Int(rate)) Hz"); continue }
            mix.core.seek(d, seconds: 0)
            try? await Task.sleep(for: .milliseconds(400))
            _ = ring.read(left: nil, right: nil, max: Int(rate * 4))   // Vorlauf verwerfen
            var recL: [Float] = [], recR: [Float] = []
            let chunk = 4096
            let bufL = UnsafeMutablePointer<Float>.allocate(capacity: chunk), bufR = UnsafeMutablePointer<Float>.allocate(capacity: chunk)
            defer { bufL.deallocate(); bufR.deallocate() }
            func drain() { while true { let n = ring.read(left: bufL, right: bufR, max: chunk); if n <= 0 { break }
                recL += UnsafeBufferPointer(start: bufL, count: n); recR += UnsafeBufferPointer(start: bufR, count: n) } }
            if !mix.deck(d).playing { mix.togglePlay(d) }
            let total = Double(sig.count) / rate + 1.0
            let t0 = Date()
            while Date().timeIntervalSince(t0) < total { try? await Task.sleep(for: .milliseconds(100)); drain() }
            if mix.deck(d).playing { mix.togglePlay(d) }
            drain()
            input.stop()
            let rl = SignalTest.analyze(rec: recL, rate: rate), rr = SignalTest.analyze(rec: recR, rate: rate)
            let head = "\(name) (Ausgang \(mix.deckPairs[d] + 1)/\(mix.deckPairs[d] + 2) → Eingang \(firstInput + 1)/\(firstInput + 2))"
            log(head)
            log("  L: \(rl)")
            log("  R: Pegel \(String(format: "%+.2f", rr.gainDb)) dB · Latenz \(rr.latencyFrames) · Aussetzer \(rr.dropouts.count)\(rr.problem.map { " · \($0)" } ?? "")")
            lines += ["## \(head)", "", "```", "L: \(rl)", "R: Pegel \(String(format: "%+.2f", rr.gainDb)) dB · Latenz \(rr.latencyFrames) Frames · Aussetzer \(rr.dropouts.count)", "```", ""]
        }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmm"
        let dir = RecordPrefs.defaultFolder.deletingLastPathComponent()
        let out = dir.appendingPathComponent("Signaltest-\(f.string(from: Date())).md")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? (["# Signal-Test", "", "Ausgabe \(Int(rate)) Hz, Headroom 0, Auto-Gain aus.", ""] + lines).joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
        log("Bericht: \(out.path)")
        log("FERTIG")
    }

    static func write(_ s: [Float], rate: Double, to url: URL) throws {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false)!
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: fmt.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(s.count))!
        buf.frameLength = AVAudioFrameCount(s.count)
        s.withUnsafeBufferPointer { p in
            buf.floatChannelData![0].update(from: p.baseAddress!, count: s.count)
            buf.floatChannelData![1].update(from: p.baseAddress!, count: s.count)
        }
        try file.write(from: buf)
    }
}
