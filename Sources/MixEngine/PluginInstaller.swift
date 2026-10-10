import AudioToolbox
import Foundation

/// Plugins installieren: .component- und .vst3-Bundles (einzeln, aus Ordnern oder .zip) in den Benutzer-Ordner kopieren
public enum PluginInstaller {
    /// ~/Library/Audio/Plug-Ins/Components (wird bei Bedarf angelegt; nie /Library – dafür bräuchte es Admin-Rechte)
    public static let userComponents = PluginCatalog.home.appendingPathComponent("Library/Audio/Plug-Ins/Components")
    /// ~/Library/Audio/Plug-Ins/VST3 (für .vst3-Bundles, ebenso nie /Library)
    public static let userVST3 = PluginCatalog.home.appendingPathComponent("Library/Audio/Plug-Ins/VST3")
    static let quarantine = "com.apple.quarantine"

    /// Bundles aus einer Auswahl: .component/.vst3 direkt, Ordner rekursiv, .zip wird nach `scratch` entpackt (ditto)
    public static func collect(_ urls: [URL], scratch: URL) throws -> (components: [URL], vst3: [URL]) {
        var comps: [URL] = [], vst3: [URL] = []
        for (i, u) in urls.enumerated() {
            switch u.pathExtension.lowercased() {
            case "component": comps.append(u)
            case "vst3": vst3.append(u)
            case "zip":
                let dest = scratch.appendingPathComponent("zip-\(i)")
                try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
                try run("/usr/bin/ditto", ["-x", "-k", u.path, dest.path])
                let found = PluginBundle.scan(dest, depth: 6)
                comps += found.components; vst3 += found.vst3
            default:
                let found = PluginBundle.scan(u, depth: 6)
                comps += found.components; vst3 += found.vst3
            }
        }
        return (comps, vst3)
    }

    /// liegt schon ein Bundle gleichen Namens im Ziel? → seine Version und die neue
    public struct Conflict: Equatable, Sendable {
        public let existing: URL
        public let oldVersion: String, newVersion: String
        public var sameVersion: Bool { oldVersion == newVersion }
    }

    public static func conflict(_ bundle: URL, in dest: URL = userComponents) -> Conflict? {
        let target = dest.appendingPathComponent(bundle.lastPathComponent)
        guard FileManager.default.fileExists(atPath: target.path) else { return nil }
        return Conflict(existing: target, oldVersion: PluginBundle.version(target), newVersion: PluginBundle.version(bundle))
    }

    /// kopieren (ersetzt ein vorhandenes gleichen Namens), liefert das Ziel
    @discardableResult
    public static func install(_ bundle: URL, into dest: URL = userComponents) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let target = dest.appendingPathComponent(bundle.lastPathComponent)
        // erst daneben kopieren, dann tauschen: ein halb kopiertes Bundle liegt nie im Plugin-Ordner
        let tmp = dest.appendingPathComponent(".minos-\(UUID().uuidString)-" + bundle.lastPathComponent)
        try fm.copyItem(at: bundle, to: tmp)
        if fm.fileExists(atPath: target.path) {
            _ = try fm.replaceItemAt(target, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: target)
        }
        return target
    }

    /// trägt das Bundle (oder eine Datei darin) die Quarantäne-Markierung aus dem Download?
    public static func isQuarantined(_ url: URL) -> Bool {
        if getxattr(url.path, quarantine, nil, 0, 0, XATTR_NOFOLLOW) >= 0 { return true }
        guard let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else { return false }
        for case let u as URL in en where getxattr(u.path, quarantine, nil, 0, 0, XATTR_NOFOLLOW) >= 0 { return true }
        return false
    }

    /// Quarantäne-Markierung im ganzen Bundle entfernen (nur nach Rückfrage)
    public static func clearQuarantine(_ url: URL) {
        removexattr(url.path, quarantine, XATTR_NOFOLLOW)
        guard let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else { return }
        for case let u as URL in en { removexattr(u.path, quarantine, XATTR_NOFOLLOW) }
    }

    private static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "minos741.plugin", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "\(URL(fileURLWithPath: tool).lastPathComponent) \(p.terminationStatus)"])
        }
    }
}

/// Selbsttest für VST3 (es gibt kein auval dafür): laden, 1 s Rauschen rechnen, Zustand lesen und zurückschreiben,
/// entladen. Bestanden = alles geladen und gerechnet, Ausgang durchgehend endlich.
public enum PluginSelfCheck {
    public static let argument = "--vst3-check"

    public static func run(_ info: PluginInfo, seconds: Double = 1, sampleRate: Double = 48000) -> (passed: Bool, log: String) {
        var log: [String] = []
        let t0 = DispatchTime.now().uptimeNanoseconds
        let ms = { (a: UInt64) in String(format: "%.1f ms", Double(DispatchTime.now().uptimeNanoseconds - a) / 1e6) }
        var inst: PluginInstance?
        do { inst = try PluginInstance(info, sampleRate: sampleRate) } catch {
            log.append("open: " + error.localizedDescription)
            return (false, log.joined(separator: "\n"))
        }
        guard let p = inst else { return (false, "") }
        log.append("open ok · \(ms(t0)) · \(p.parameters.count) params · latency \(Int((p.latency * sampleRate).rounded())) smp · tail "
                   + (p.tail.map { String(format: "%.2f s", $0) } ?? "∞"))
        let n = 512, blocks = max(1, Int(seconds * sampleRate) / n)
        let l = UnsafeMutablePointer<Float>.allocate(capacity: n), r = UnsafeMutablePointer<Float>.allocate(capacity: n)
        defer { l.deallocate(); r.deallocate() }
        var seed: UInt32 = 741, inSum = 0.0, outSum = 0.0, bad = 0, worst = 0.0
        for _ in 0..<blocks {
            for i in 0..<n {
                seed = seed &* 1664525 &+ 1013904223
                l[i] = (Float(seed >> 8) / Float(1 << 24) - 0.5) * 0.5; r[i] = l[i]
                inSum += Double(l[i] * l[i])
            }
            let tb = DispatchTime.now().uptimeNanoseconds
            p.process(l, r, n)
            worst = max(worst, Double(DispatchTime.now().uptimeNanoseconds - tb) / 1e6)
            for i in 0..<n {
                if !l[i].isFinite || !r[i].isFinite { bad += 1 } else { outSum += Double(l[i] * l[i] + r[i] * r[i]) / 2 }
            }
        }
        let total = Double(blocks * n)
        log.append(String(format: "process %d × %d · rms in %.4f · out %.4f · max block %.3f ms · non-finite %d",
                          blocks, n, (inSum / total).squareRoot(), (outSum / total).squareRoot(), worst, bad))
        if let st = p.state {
            p.state = st
            log.append("state \(st.count) bytes · set ok")
        } else {
            log.append("state: none")
        }
        inst = nil
        log.append("closed · total \(ms(t0))")
        return (bad == 0, log.joined(separator: "\n"))
    }
}

/// Prüfung in einem eigenen Prozess (ein abstürzendes Plugin trifft nur diesen): AU mit Apples auval,
/// VST3 mit dem Selbsttest im eigenen Programm (`<exe> --vst3-check <bundle> <klasse>`; ohne Programm im Prozess)
public final class PluginValidator: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    /// Programm für den VST3-Selbsttest im eigenen Prozess (die App selbst); nil = im Prozess (Tests)
    public let selfCheckExecutable: URL?

    public init(selfCheckExecutable: URL? = nil) { self.selfCheckExecutable = selfCheckExecutable }

    /// AU: `auval -v type subtype manu`, bestanden = Exit 0 und "AU VALIDATION SUCCEEDED".
    /// VST3: Selbsttest, bestanden = Exit 0
    public func run(_ info: PluginInfo, timeout: Double = 180, tailLines: Int = 14) async -> PluginValidation {
        if info.isVST3 {
            guard let exe = selfCheckExecutable, let path = info.path, let cid = info.classID else {
                return await withCheckedContinuation { cont in
                    DispatchQueue.global(qos: .userInitiated).async {
                        let r = PluginSelfCheck.run(info)
                        cont.resume(returning: PluginValidation(passed: r.passed, log: r.log))
                    }
                }
            }
            return await run(exe, [PluginSelfCheck.argument, path, cid], timeout: 60, tailLines: tailLines) { status, _ in status == 0 }
        }
        return await run(URL(fileURLWithPath: "/usr/bin/auval"),
                         ["-v", PluginHost.fourCC(info.type), PluginHost.fourCC(info.subtype), PluginHost.fourCC(info.manu)],
                         timeout: timeout, tailLines: tailLines) { status, text in status == 0 && text.contains("AU VALIDATION SUCCEEDED") }
    }

    private func run(_ exe: URL, _ args: [String], timeout: Double, tailLines: Int,
                     passed: @escaping @Sendable (Int32, String) -> Bool) async -> PluginValidation {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        let stop: Bool = lock.withLock { if !cancelled { process = p }; return cancelled }
        if stop { return PluginValidation(passed: false, log: String(localized: "abgebrochen")) }
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                do { try p.run() } catch {
                    lock.withLock { process = nil }
                    cont.resume(returning: PluginValidation(passed: false, log: error.localizedDescription)); return
                }
                let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                timer.cancel()
                let wasCancelled = lock.withLock { () -> Bool in process = nil; return cancelled }
                let text = String(decoding: data, as: UTF8.self)
                let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
                    .filter { !$0.allSatisfy { $0 == "-" || $0 == " " } }
                var tail = lines.suffix(tailLines).joined(separator: "\n")
                if wasCancelled { tail += "\n" + String(localized: "abgebrochen") }
                let ok = !wasCancelled && passed(p.terminationStatus, text)
                cont.resume(returning: PluginValidation(passed: ok, log: tail))
            }
        }
    }

    /// laufende Prüfung abbrechen, weitere sofort beenden (bis `reset`)
    public func cancel() {
        lock.withLock {
            cancelled = true
            if let p = process, p.isRunning { p.terminate() }
        }
    }

    public func reset() { lock.withLock { cancelled = false } }
}
