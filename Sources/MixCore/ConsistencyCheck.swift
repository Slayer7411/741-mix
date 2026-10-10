import Foundation
import AudioToolbox

/// Collection prüfen – nur lesen, nichts wird geändert. Je Track: Datei da / lesbar / nicht leer, Audio-Kopf,
/// Dauer gegen die Collection, Schreibweise des Pfads, Titel/Artist gegen den Dateinamen, Doppelte, Analyse, Grid.
/// Danach Playlist-Einträge ohne Track und Audiodateien in den Musik-Ordnern ohne Collection-Eintrag.
public enum ConsistencyCheck {
    public enum Category: String, CaseIterable, Sendable, Codable {
        case missing, unreadable, empty, badAudio, duration, pathCase, unicodeForm, name, dupPath, dupTrack, noAnalysis, grid, dangling, notInCollection

        /// 4 Zeichen für das Protokoll
        public var tag: String {
            switch self {
            case .missing: "MISS"
            case .unreadable: "PERM"
            case .empty: "ZERO"
            case .badAudio: "BAD "
            case .duration: "TIME"
            case .pathCase: "CASE"
            case .unicodeForm: "NFD "
            case .name: "NAME"
            case .dupPath: "DUP "
            case .dupTrack: "TWIN"
            case .noAnalysis: "ANLZ"
            case .grid: "GRID"
            case .dangling: "LIST"
            case .notInCollection: "NEW "
            }
        }

        /// Problem (rot): Track spielt nicht oder Daten sind falsch; sonst Hinweis (lila)
        public var isProblem: Bool {
            switch self {
            case .missing, .unreadable, .empty, .badAudio, .duration, .dupPath, .dangling: true
            default: false
            }
        }
    }

    public struct Finding: Sendable, Hashable, Identifiable {
        public var id: Int
        public var category: Category
        /// Track-Schlüssel in der Collection (nil: Datei nur im Musik-Ordner)
        public var key: String?
        public var path: String
        public var detail: String

        public init(id: Int = 0, category: Category, key: String?, path: String, detail: String) {
            self.id = id; self.category = category; self.key = key; self.path = path; self.detail = detail
        }
    }

    /// Track-Schlüssel einer Playlist (oder Preparation)
    public struct KeyList: Sendable {
        public var name: String
        public var keys: [String]
        public init(name: String, keys: [String]) { self.name = name; self.keys = keys }
    }

    public struct Input: Sendable {
        public var tracks: [Track]
        public var lists: [KeyList]
        /// Musik-Ordner: Audiodateien darunter ohne Collection-Eintrag (leer = nicht prüfen)
        public var musicRoots: [String]
        public var durationTolerance = 2.0
        public var bpmRange = 60.0...200.0
        /// gleichzeitige Datei-Prüfungen (Google Drive, Netzlaufwerke: nicht zu viele)
        public var concurrency = 6

        public init(tracks: [Track], lists: [KeyList] = [], musicRoots: [String] = []) {
            self.tracks = tracks; self.lists = lists; self.musicRoots = musicRoots
        }
    }

    /// alle Playlists eines Baums (Name mit Pfad)
    public static func lists(in root: PlaylistNode) -> [KeyList] {
        var out: [KeyList] = []
        func walk(_ n: PlaylistNode, _ prefix: String) {
            for c in n.children {
                let name = prefix.isEmpty ? c.name : prefix + " / " + c.name
                if c.kind == .playlist { out.append(KeyList(name: name, keys: c.trackKeys)) }
                walk(c, c.kind == .folder ? name : prefix)
            }
        }
        walk(root, "")
        return out
    }

    // MARK: - Vergleichsformen

    /// klein, ohne Akzente, nur Buchstaben/Ziffern, Wörter durch ein Leerzeichen getrennt
    public static func normalize(_ s: String) -> String {
        let f = s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var out = "", space = true
        for ch in f.unicodeScalars {
            if CharacterSet.alphanumerics.contains(ch) { out.unicodeScalars.append(ch); space = false }
            else if !space { out.append(" "); space = true }
        }
        if out.hasSuffix(" ") { out.removeLast() }
        return out
    }

    /// Titel ohne Klammerzusätze („(Original Mix)“, „[Label]“)
    static func titleCore(_ title: String) -> String {
        var out = "", depth = 0
        for ch in title {
            if ch == "(" || ch == "[" { depth += 1 } else if ch == ")" || ch == "]" { depth = max(0, depth - 1) } else if depth == 0 { out.append(ch) }
        }
        return normalize(out)
    }

    /// Artist in Einzelnamen (Komma, &, feat., vs., x, and), Klammerzusätze („Matador (IE)“) weg
    static func artistParts(_ artist: String) -> [String] {
        let n = " " + titleCore(artist) + " "
        var parts = [n]
        for sep in [" feat ", " ft ", " featuring ", " vs ", " x ", " and ", " with "] {
            parts = parts.flatMap { $0.components(separatedBy: sep) }
        }
        let raw = artist.split(whereSeparator: { ",&;/+".contains($0) }).map { titleCore(String($0)) }
        return Array(Set((parts.map { $0.trimmingCharacters(in: .whitespaces) } + raw).filter { !$0.isEmpty }))
    }

    /// Titel-Formen für den Vergleich: ganz, ohne Klammern, erster Abschnitt (vor - ( / [ _ :), jeweils ohne
    /// führende Track-Nummer („2. “, „A1_“)
    static func titleForms(_ title: String) -> [String] {
        var t = title
        if let r = t.range(of: #"^\s*[A-Da-d]?\d{1,3}\s*[.)_:-]+\s*"#, options: .regularExpression) { t.removeSubrange(r) }
        var forms = [normalize(t), titleCore(t)]
        if let seg = t.split(whereSeparator: { "-(/[_:".contains($0) }).map({ normalize(String($0)) }).first(where: { $0.count >= 4 }) {
            forms.append(seg)
        }
        return forms.filter { !$0.isEmpty }
    }

    /// Dateiname enthält weder Titel noch Artist (nil = passt oder nichts zu vergleichen). Ganze Wörter; ab 4 Zeichen
    /// auch ohne Leerzeichen, wenn aufeinanderfolgende Wörter des Dateinamens genau passen („BamBam“ = „Bam Bam“,
    /// „I don't eat“ = „i_dont_eat“). Abweichende Zahlen zählen („Ibiza 2007“ in „01 Ibiza 2008.mp3“ ist ein Befund).
    public static func nameMismatch(_ t: Track) -> String? {
        let name = normalize(((t.path as NSString).lastPathComponent as NSString).deletingPathExtension)
        let file = " " + name + " ", words = name.split(separator: " ").map(String.init)
        func joined(_ target: String) -> Bool {
            for i in words.indices {
                var acc = ""
                for w in words[i...] {
                    acc += w
                    if acc == target { return true }
                    if acc.count >= target.count { break }
                }
            }
            return false
        }
        func hit(_ s: String) -> Bool {
            if file.contains(" " + s + " ") { return true }
            let c = s.replacingOccurrences(of: " ", with: "")
            return c.count >= 4 && joined(c)
        }
        let titles = titleForms(t.title), artists = artistParts(t.artist)
        guard !titles.isEmpty || !artists.isEmpty else { return nil }
        if titles.contains(where: hit) || artists.contains(where: hit) { return nil }
        return "file name has neither title \"\(t.title)\" nor artist \"\(t.artist)\""
    }

    /// fehlende Analyse (bpm, grid, key, lautheit) als Text, nil = vollständig
    public static func missingAnalysis(_ t: Track) -> String? {
        var miss: [String] = []
        if !(t.bpm.isFinite && t.bpm > 0) { miss.append("bpm") }
        if t.gridAnchorMs == nil { miss.append("grid") }
        if t.musicalKey < 0 && t.keyText.isEmpty { miss.append("key") }
        if t.perceivedDb == nil { miss.append("loudness") }
        return miss.isEmpty ? nil : "no " + miss.joined(separator: " · ")
    }

    /// NML-Schlüssel als lesbarer Pfad ("Macintosh HD/:Users/:x/:a.mp3" -> "Macintosh HD/Users/x/a.mp3")
    public static func displayPath(key: String) -> String { key.replacingOccurrences(of: "/:", with: "/") }

    static func time(_ s: Double) -> String {
        let t = Int(s.rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    // MARK: - Collection-weite Prüfungen (ohne Dateizugriff)

    /// je Track-Index: Doppelte, Name, Analyse, BPM-Bereich
    static func collectionFindings(_ input: Input) -> [[(Category, String)]] {
        let tracks = input.tracks
        var out = [[(Category, String)]](repeating: [], count: tracks.count)
        // gleiche Datei zweimal (Pfad ohne Groß/klein und Unicode-Form)
        var firstByPath: [String: Int] = [:]
        for (i, t) in tracks.enumerated() where !t.path.isEmpty {
            let m = MusicFolder.match(t.path)
            if let f = firstByPath[m] { out[i].append((.dupPath, "same file as " + displayPath(key: tracks[f].key))) }
            else { firstByPath[m] = i }
        }
        // gleicher Artist + Titel (+ Mix) mit anderer Datei
        var firstByName: [String: Int] = [:]
        for (i, t) in tracks.enumerated() {
            let a = normalize(t.artist), ti = normalize(t.title)
            guard !a.isEmpty, !ti.isEmpty else { continue }
            let k = a + "|" + ti + "|" + normalize(t.mix)
            if let f = firstByName[k] {
                if MusicFolder.match(tracks[f].path) != MusicFolder.match(t.path) { out[i].append((.dupTrack, "same artist + title: " + tracks[f].path)) }
            } else { firstByName[k] = i }
        }
        for (i, t) in tracks.enumerated() {
            if let n = nameMismatch(t) { out[i].append((.name, n)) }
            if let a = missingAnalysis(t) { out[i].append((.noAnalysis, a)) }
            if t.bpm.isFinite, t.bpm > 0, !input.bpmRange.contains(t.bpm) {
                out[i].append((.grid, String(format: "bpm %.2f outside %.0f–%.0f", t.bpm, input.bpmRange.lowerBound, input.bpmRange.upperBound)))
            }
        }
        return out
    }

    // MARK: - Datei

    /// Verzeichnis-Inhalte (genaue Namen), einmal je Ordner gelesen – für Groß/klein und Unicode-Form
    final class DirCache: @unchecked Sendable {
        private let lock = NSLock()
        /// Ordner -> (genaue Namen als UTF-8, Vergleichsform -> Name auf der Platte); nil = nicht lesbar
        private var dirs: [String: (exact: Set<[UInt8]>, folded: [String: String])?] = [:]

        func listing(_ dir: String) -> (exact: Set<[UInt8]>, folded: [String: String])? {
            lock.lock()
            if let hit = dirs[dir] { lock.unlock(); return hit }
            lock.unlock()
            let names = try? FileManager.default.contentsOfDirectory(atPath: dir)
            let value = names.map { n -> (exact: Set<[UInt8]>, folded: [String: String]) in
                (Set(n.map { Array($0.utf8) }), Dictionary(n.map { (MusicFolder.match($0), $0) }, uniquingKeysWith: { a, _ in a }))
            }
            lock.lock()
            dirs[dir] = value
            lock.unlock()
            return value
        }

        /// abweichende Schreibweise auf der Platte (nil = gleich oder nicht feststellbar): Groß/klein mit dem Namen
        /// auf der Platte, sonst nur Unicode-Form (NFC/NFD – auf APFS ohne Folgen, beim Kopieren auf andere Systeme nicht)
        func diskSpelling(_ path: String) -> (Category, String)? {
            let comps = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            var dir = "", firstCase: (String, String)?, unicodeOnly = false
            for c in comps {
                let parent = dir.isEmpty ? "/" : dir
                if let l = listing(parent) {
                    if !l.exact.contains(Array(c.utf8)) {
                        guard let disk = l.folded[MusicFolder.match(c)] else { return nil }
                        if disk.precomposedStringWithCanonicalMapping.unicodeScalars.elementsEqual(c.precomposedStringWithCanonicalMapping.unicodeScalars) {
                            unicodeOnly = true
                        } else if firstCase == nil { firstCase = (c, disk) }
                    }
                }
                dir += "/" + c
            }
            if let (c, disk) = firstCase { return (.pathCase, "case differs: \"\(c)\" is \"\(disk)\" on disk") }
            return unicodeOnly ? (.unicodeForm, "same name, other unicode form (nfc/nfd) on disk") : nil
        }
    }

    /// Datei-Prüfungen eines Tracks; liefert dazu die Dauer laut Datei (für den Grid-Anker)
    static func checkFile(_ t: Track, dirs: DirCache, tolerance: Double) -> (findings: [(Category, String)], duration: Double?) {
        let path = t.path
        guard !path.isEmpty else { return ([(.missing, "no path")], nil) }
        var st = stat()
        if stat(path, &st) != 0 {
            let err = errno
            if err == EACCES { return ([(.unreadable, "no access to folder")], nil) }
            // Groß/klein-empfindliches Laufwerk: Datei nur unter anderer Schreibweise
            if let (c, d) = dirs.diskSpelling(path) { return ([(c, d + " · not found as written")], nil) }
            return ([(.missing, "file not found")], nil)
        }
        var out: [(Category, String)] = []
        if let d = dirs.diskSpelling(path) { out.append(d) }
        if (st.st_mode & S_IFMT) == S_IFDIR { return (out + [(.badAudio, "is a folder")], nil) }
        if st.st_size == 0 { return (out + [(.empty, "0 bytes")], nil) }
        if access(path, R_OK) != 0 { return (out + [(.unreadable, "no read permission")], nil) }
        // Audio-Kopf öffnen (kein Dekodieren); Dauer erst geschätzt, bei Abweichung genau aus der Paketzahl
        var file: AudioFileID?
        let url = URL(fileURLWithPath: path) as CFURL
        let status = AudioFileOpenURL(url, .readPermission, 0, &file)
        guard status == noErr, let file else { return (out + [(.badAudio, "no audio header (\(fourCC(status)))")], nil) }
        defer { AudioFileClose(file) }
        var duration: Double? = estimatedDuration(file)
        if let d = duration, t.duration > 0, abs(d - t.duration) > tolerance, let exact = exactDuration(file) { duration = exact }
        guard let d = duration, d > 0 else { return (out + [(.badAudio, "no audio data")], nil) }
        if t.duration > 0, abs(d - t.duration) > tolerance {
            out.append((.duration, "file " + time(d) + " · collection " + time(t.duration)))
        }
        return (out, d)
    }

    static func estimatedDuration(_ f: AudioFileID) -> Double? {
        var d: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioFileGetProperty(f, kAudioFilePropertyEstimatedDuration, &size, &d) == noErr, d.isFinite else { return nil }
        return d
    }

    /// Paketzahl × Frames je Paket (MP3 ohne Kopf-Angabe: AudioFile liest dafür die Paketgrenzen, ohne zu dekodieren)
    static func exactDuration(_ f: AudioFileID) -> Double? {
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioFileGetProperty(f, kAudioFilePropertyDataFormat, &size, &asbd) == noErr, asbd.mSampleRate > 0 else { return nil }
        var packets: UInt64 = 0
        size = UInt32(MemoryLayout<UInt64>.size)
        guard AudioFileGetProperty(f, kAudioFilePropertyAudioDataPacketCount, &size, &packets) == noErr else { return nil }
        if asbd.mFramesPerPacket > 0 { return Double(packets) * Double(asbd.mFramesPerPacket) / asbd.mSampleRate }
        var frames = AudioFilePacketTableInfo()
        size = UInt32(MemoryLayout<AudioFilePacketTableInfo>.size)
        guard AudioFileGetProperty(f, kAudioFilePropertyPacketTableInfo, &size, &frames) == noErr else { return nil }
        return Double(frames.mNumberValidFrames) / asbd.mSampleRate
    }

    static func fourCC(_ s: OSStatus) -> String {
        let b = [24, 16, 8, 0].map { UInt8((UInt32(bitPattern: s) >> $0) & 0xff) }
        if b.allSatisfy({ $0 >= 32 && $0 < 127 }) { return "'" + String(decoding: b, as: UTF8.self) + "'" }
        return String(s)
    }

    // MARK: - Bericht

    public struct Summary: Sendable {
        public var source: String
        public var tracks: Int
        public var checked: Int
        public var ok: Int
        public var counts: [Category: Int]
        public var folderFiles: Int
        public var elapsed: TimeInterval
        public var cancelled: Bool
        public init(source: String, tracks: Int, checked: Int, ok: Int, counts: [Category: Int], folderFiles: Int, elapsed: TimeInterval, cancelled: Bool) {
            self.source = source; self.tracks = tracks; self.checked = checked; self.ok = ok; self.counts = counts
            self.folderFiles = folderFiles; self.elapsed = elapsed; self.cancelled = cancelled
        }
    }

    /// Text-Bericht: Kopf mit Zählern, dann je Kategorie die Befunde
    public static func reportText(_ s: Summary, findings: [Finding], date: Date = Date()) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withSpaceBetweenDateAndTime]
        var out = "◆ MINOS-741 · COLLECTION CHECK\n"
        out += "date      \(f.string(from: date))\n"
        out += "source    \(s.source)\n"
        out += "tracks    \(s.checked) / \(s.tracks) checked · \(s.ok) ok\(s.cancelled ? " · CANCELLED" : "")\n"
        if s.folderFiles > 0 { out += "folders   \(s.folderFiles) audio files scanned\n" }
        out += String(format: "time      %.1f s\n", s.elapsed)
        out += "mode      read only, nothing was changed\n\n"
        for c in Category.allCases { out += "\(c.tag)  \(s.counts[c] ?? 0)\n" }
        for c in Category.allCases {
            let list = findings.filter { $0.category == c }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            guard !list.isEmpty else { continue }
            out += "\n◆ \(c.tag.trimmingCharacters(in: .whitespaces)) · \(list.count)\n"
            for x in list { out += "\(c.tag) \(x.path)  · \(x.detail)\n" }
        }
        return out
    }

    /// CSV: category;tag;path;detail;key (Semikolon, Felder in Anführungszeichen)
    public static func reportCSV(findings: [Finding]) -> String {
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var out = "category;tag;path;detail;key\n"
        for x in findings.sorted(by: { ($0.category.rawValue, $0.path) < ($1.category.rawValue, $1.path) }) {
            out += [x.category.rawValue, x.category.tag.trimmingCharacters(in: .whitespaces), x.path, x.detail, x.key ?? ""].map(q).joined(separator: ";") + "\n"
        }
        return out
    }
}

/// Ein Prüflauf im Hintergrund. Arbeiter holen sich Tracks einzeln (Abbruch je Track geprüft), Ergebnisse landen
/// gesammelt hier; die Oberfläche holt sie gebündelt mit `snapshot` (z. B. 20× je Sekunde), nie eine Änderung je Datei.
public final class ConsistencyRun: @unchecked Sendable {
    public typealias Category = ConsistencyCheck.Category
    public typealias Finding = ConsistencyCheck.Finding

    public enum Phase: String, Sendable { case files, playlists, folders, done }

    public struct LogLine: Sendable, Identifiable, Hashable {
        public let id: Int
        /// nil = OK
        public let category: Category?
        public let path: String
        public let detail: String
    }

    public struct Snapshot: Sendable {
        public var phase: Phase = .files
        public var done = 0
        public var total = 0
        public var current = ""
        public var lines: [LogLine] = []
        public var findings: [Finding] = []
        public var counts: [Category: Int] = [:]
        public var ok = 0
        public var folderFiles = 0
        public var finished = false
        public var cancelled = false
        public var elapsed: TimeInterval = 0
        /// höchste Zeilennummer bisher (für den nächsten Abruf)
        public var lastLine = 0
        public init() {}
    }

    /// Zeilen im Speicher (die Oberfläche zeigt davon die letzten 2000; Befunde bleiben alle)
    public static let lineBuffer = 4000

    private let input: ConsistencyCheck.Input
    private let lock = NSLock()
    private var state = Snapshot()
    private var lines: [LogLine] = []
    private var lineSeq = 0
    private var findings: [Finding] = []
    private var cancelFlag = false
    private let start = Date()
    private var endTime: Date?
    private let doneSignal = DispatchSemaphore(value: 0)

    private init(input: ConsistencyCheck.Input) {
        self.input = input
        state.total = input.tracks.count
    }

    /// Lauf starten (eigener Thread), kehrt sofort zurück
    public static func start(_ input: ConsistencyCheck.Input) -> ConsistencyRun {
        let r = ConsistencyRun(input: input)
        let t = Thread { r.execute() }
        t.qualityOfService = .utility
        t.name = "minos741.consistency"
        t.start()
        return r
    }

    /// Abbrechen: sofort als beendet melden (Befunde bis hierher bleiben); Arbeiter hören vor dem nächsten Track auf,
    /// was danach noch eintrifft (z. B. eine hängende Datei auf Google Drive), wird verworfen
    public func cancel() {
        lock.lock()
        if !state.finished {
            cancelFlag = true
            state.cancelled = true
            state.finished = true
            endTime = Date()
        }
        lock.unlock()
    }

    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelFlag }

    /// Stand seit Zeile `sinceLine` und Befund `sinceFinding` (nur Neues)
    public func snapshot(sinceLine: Int, sinceFinding: Int) -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        var s = state
        s.elapsed = (endTime ?? Date()).timeIntervalSince(start)
        if let first = lines.first, sinceLine < lineSeq {
            let from = max(0, sinceLine - first.id + 1)
            if from < lines.count { s.lines = Array(lines[from...]) }
        }
        s.lastLine = lineSeq
        if sinceFinding < findings.count { s.findings = Array(findings[sinceFinding...]) }
        return s
    }

    /// blockiert bis zum Ende (CLI, Tests)
    public func wait() { doneSignal.wait(); doneSignal.signal() }

    /// alle Befunde (nach Ende)
    public var allFindings: [Finding] { lock.lock(); defer { lock.unlock() }; return findings }

    // MARK: - Ablauf

    private func execute() {
        defer { finish() }
        let tracks = input.tracks
        let pre = ConsistencyCheck.collectionFindings(input)
        let dirs = ConsistencyCheck.DirCache()
        // Dateien: begrenzt parallel, jeder Arbeiter holt den nächsten Index
        DispatchQueue.concurrentPerform(iterations: max(1, min(input.concurrency, tracks.count))) { _ in
            while true {
                if isCancelled { return }
                let i = takeNext()
                guard i < tracks.count else { return }
                let t = tracks[i]
                setCurrent(t.path)
                var (found, duration) = ConsistencyCheck.checkFile(t, dirs: dirs, tolerance: input.durationTolerance)
                if let anchor = t.gridAnchorMs, let len = duration ?? (t.duration > 0 ? t.duration : nil), anchor / 1000 > len + 0.05 {
                    found.append((.grid, "grid anchor " + ConsistencyCheck.time(anchor / 1000) + " after the end (" + ConsistencyCheck.time(len) + ")"))
                }
                record(track: t, found + pre[i])
            }
        }
        guard !isCancelled else { return }
        // Playlist-Einträge ohne Track in der Collection
        setPhase(.playlists)
        let keys = Set(tracks.map(\.key))
        for l in input.lists {
            if isCancelled { return }
            var seen = Set<String>()
            for k in l.keys where !keys.contains(k) && seen.insert(k).inserted {
                record(category: .dangling, key: nil, path: ConsistencyCheck.displayPath(key: k), detail: "playlist: " + l.name)
            }
        }
        // Musik-Ordner: Audiodateien ohne Collection-Eintrag
        guard !input.musicRoots.isEmpty else { return }
        setPhase(.folders)
        let index = Set(tracks.map { MusicFolder.match($0.path) })
        var visited = Set<String>()
        for root in input.musicRoots {
            let base = root.hasSuffix("/") ? String(root.dropLast()) : root
            // verschachtelte Ordner nicht doppelt durchsuchen
            if visited.contains(where: { base.hasPrefix($0 + "/") || base == $0 }) { continue }
            visited.insert(base)
            let url = URL(fileURLWithPath: base, isDirectory: true)
            guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil,
                                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            while let u = e.nextObject() as? URL {
                if isCancelled { return }
                guard MusicFolder.audioExtensions.contains(u.pathExtension.lowercased()) else { continue }
                // Pfad mit dem Präfix des Ordners (Enumerator liefert z. B. /private/var statt /var)
                var p = u.path
                if !p.hasPrefix(base + "/"), let r = p.range(of: "/" + url.lastPathComponent + "/") { p = base + "/" + p[r.upperBound...] }
                folderFile(p)
                if !index.contains(MusicFolder.match(p)) {
                    record(category: .notInCollection, key: nil, path: p, detail: "not in the collection")
                }
            }
        }
    }

    private func finish() {
        lock.lock()
        if !state.finished { state.finished = true; endTime = Date() }
        state.phase = .done
        state.current = ""
        lock.unlock()
        doneSignal.signal()
    }

    private var nextIndex = 0
    private func takeNext() -> Int { lock.lock(); defer { lock.unlock() }; nextIndex += 1; return nextIndex - 1 }
    private func setCurrent(_ p: String) { lock.lock(); state.current = p; lock.unlock() }
    private func setPhase(_ p: Phase) { lock.lock(); if !cancelFlag { state.phase = p }; lock.unlock() }
    private func folderFile(_ p: String) { lock.lock(); state.current = p; state.folderFiles += 1; lock.unlock() }

    private func appendLine(_ c: Category?, _ path: String, _ detail: String) {
        lineSeq += 1
        lines.append(LogLine(id: lineSeq, category: c, path: path, detail: detail))
        if lines.count > Self.lineBuffer + 500 { lines.removeFirst(lines.count - Self.lineBuffer) }
    }

    private func record(track t: Track, _ found: [(Category, String)]) {
        lock.lock(); defer { lock.unlock() }
        guard !cancelFlag else { return }
        state.done += 1
        if found.isEmpty {
            state.ok += 1
            appendLine(nil, t.path, "")
            return
        }
        for (c, d) in found {
            findings.append(Finding(id: findings.count, category: c, key: t.key, path: t.path.isEmpty ? ConsistencyCheck.displayPath(key: t.key) : t.path, detail: d))
            state.counts[c, default: 0] += 1
            appendLine(c, t.path, d)
        }
    }

    private func record(category c: Category, key: String?, path: String, detail: String) {
        lock.lock(); defer { lock.unlock() }
        guard !cancelFlag else { return }
        findings.append(Finding(id: findings.count, category: c, key: key, path: path, detail: detail))
        state.counts[c, default: 0] += 1
        appendLine(c, path, detail)
    }
}
