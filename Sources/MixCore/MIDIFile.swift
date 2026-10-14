import Foundation

/// Standard MIDI File: schreiben (Typ 1) und lesen (für Tests und Prüfung)
public enum MIDIFile {
    public struct Event: Equatable, Sendable {
        /// absolute Ticks
        public var tick: Int
        /// Statusbyte (0x80…0xEF) oder 0xFF (Meta)
        public var status: UInt8
        public var data: [UInt8]
        /// Meta-Typ (nur bei status 0xFF)
        public var meta: UInt8 = 0
        public init(tick: Int, status: UInt8, data: [UInt8], meta: UInt8 = 0) {
            self.tick = tick; self.status = status; self.data = data; self.meta = meta
        }
    }

    public struct Track: Equatable, Sendable {
        public var name: String
        public var events: [Event]
        /// Tick des Spur-Endes (Loop-Länge in der DAW); nil = nach dem letzten Ereignis
        public var end: Int?
        public init(name: String, events: [Event], end: Int? = nil) { self.name = name; self.events = events; self.end = end }
        public var notes: [(tick: Int, length: Int, channel: UInt8, note: UInt8, velocity: UInt8)] {
            var open = [Int: (Int, UInt8)](), out = [(tick: Int, length: Int, channel: UInt8, note: UInt8, velocity: UInt8)]()
            for e in events where e.status < 0xF0 && e.data.count == 2 {
                let ch = e.status & 0x0F, key = Int(ch) << 8 | Int(e.data[0])
                let on = e.status & 0xF0 == 0x90 && e.data[1] > 0
                if on { open[key] = (e.tick, e.data[1]) }
                else if e.status & 0xF0 == 0x80 || e.status & 0xF0 == 0x90, let o = open.removeValue(forKey: key) {
                    out.append((o.0, e.tick - o.0, ch, e.data[0], o.1))
                }
            }
            return out.sorted { $0.tick != $1.tick ? $0.tick < $1.tick : $0.note < $1.note }
        }
    }

    public struct File: Equatable, Sendable {
        public var format: Int
        public var ppq: Int
        public var tracks: [Track]
        /// erstes Tempo (µs je Viertel) -> BPM
        public var bpm: Double? {
            for t in tracks { for e in t.events where e.status == 0xFF && e.meta == 0x51 && e.data.count == 3 {
                let us = Int(e.data[0]) << 16 | Int(e.data[1]) << 8 | Int(e.data[2])
                return us > 0 ? 60_000_000 / Double(us) : nil
            } }
            return nil
        }
    }

    public enum ParseError: Error { case header, chunk, truncated }

    // MARK: Schreiben

    /// Typ 1; Tempo und Taktart stehen in der ersten Spur
    public static func write(tracks: [Track], bpm: Double, ppq: Int = 480) -> Data {
        var out = Data("MThd".utf8)
        out += be32(6) + be16(1) + be16(UInt16(tracks.count)) + be16(UInt16(ppq))
        for (i, t) in tracks.enumerated() {
            var head = [Event(tick: 0, status: 0xFF, data: Array(t.name.utf8.prefix(127)), meta: 0x03)]
            if i == 0 {
                let us = UInt32(max(1, min(16_777_215, (60_000_000 / max(1, bpm)).rounded())))
                head.append(Event(tick: 0, status: 0xFF, data: [UInt8(us >> 16 & 0xFF), UInt8(us >> 8 & 0xFF), UInt8(us & 0xFF)], meta: 0x51))
                head.append(Event(tick: 0, status: 0xFF, data: [4, 2, 24, 8], meta: 0x58))
            }
            // stabil sortiert: Offs vor Ons im selben Tick (eine wiederholte Note bleibt getrennt)
            let body = t.events.enumerated().sorted { a, b in
                if a.element.tick != b.element.tick { return a.element.tick < b.element.tick }
                let ao = isOff(a.element), bo = isOff(b.element)
                return ao != bo ? ao : a.offset < b.offset
            }.map(\.element)
            var chunk = Data(), last = 0
            for e in head + body {
                chunk += vlq(max(0, e.tick - last))
                last = max(last, e.tick)
                if e.status == 0xFF {
                    chunk.append(0xFF); chunk.append(e.meta); chunk += vlq(e.data.count); chunk += e.data
                } else {
                    chunk.append(e.status); chunk += e.data
                }
            }
            chunk += vlq(max(0, (t.end ?? last) - last)) + Data([0xFF, 0x2F, 0x00])
            out += Data("MTrk".utf8) + be32(UInt32(chunk.count)) + chunk
        }
        return out
    }

    private static func isOff(_ e: Event) -> Bool {
        e.status & 0xF0 == 0x80 || (e.status & 0xF0 == 0x90 && e.data.count == 2 && e.data[1] == 0)
    }

    /// Clip als Datei: Spur „Bass“ (Bass-Kanal) und „Drums“ (übrige Kanäle), nur Spuren mit Noten; `repeats` Durchläufe
    public static func clip(_ c: GrooveClip, bpm: Double, bassChannel: UInt8, name: String = "MINOS-741 Groove",
                            repeats: Int = 1, ppq: Int = 480) -> Data {
        let stepTicks = ppq / GroovePattern.stepsPerBeat
        let end = max(1, repeats) * c.steps * stepTicks
        func events(_ notes: [GrooveNote]) -> [Event] {
            var e = [Event]()
            for r in 0..<max(1, repeats) {
                for n in notes {
                    let on = (n.step + r * c.steps) * stepTicks
                    let len = max(1, Int((n.length * Double(stepTicks)).rounded()))
                    e.append(Event(tick: on, status: 0x90 | n.channel & 0x0F, data: [n.note & 0x7F, max(1, n.velocity & 0x7F)]))
                    // über das Ende ragende Note endet mit dem Loop
                    e.append(Event(tick: min(on + len, end), status: 0x80 | n.channel & 0x0F, data: [n.note & 0x7F, 0]))
                }
            }
            return e
        }
        let bass = c.notes.filter { $0.channel == bassChannel }, drums = c.notes.filter { $0.channel != bassChannel }
        var tracks = [Track]()
        if !bass.isEmpty { tracks.append(Track(name: "\(name) Bass", events: events(bass), end: end)) }
        if !drums.isEmpty { tracks.append(Track(name: "\(name) Drums", events: events(drums), end: end)) }
        if tracks.isEmpty { tracks.append(Track(name: name, events: [], end: end)) }
        return write(tracks: tracks, bpm: bpm, ppq: ppq)
    }

    static func be16(_ v: UInt16) -> Data { Data([UInt8(v >> 8), UInt8(v & 0xFF)]) }
    static func be32(_ v: UInt32) -> Data { Data([UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]) }
    static func vlq(_ v: Int) -> Data {
        var v = max(0, v), bytes = [UInt8(v & 0x7F)]
        v >>= 7
        while v > 0 { bytes.insert(UInt8(v & 0x7F) | 0x80, at: 0); v >>= 7 }
        return Data(bytes)
    }

    // MARK: Lesen

    public static func parse(_ d: Data) throws -> File {
        let b = [UInt8](d)
        var p = 0
        func u32() throws -> Int {
            guard p + 4 <= b.count else { throw ParseError.truncated }
            defer { p += 4 }
            return Int(b[p]) << 24 | Int(b[p + 1]) << 16 | Int(b[p + 2]) << 8 | Int(b[p + 3])
        }
        func u16() throws -> Int {
            guard p + 2 <= b.count else { throw ParseError.truncated }
            defer { p += 2 }
            return Int(b[p]) << 8 | Int(b[p + 1])
        }
        func tag() throws -> String {
            guard p + 4 <= b.count else { throw ParseError.truncated }
            defer { p += 4 }
            return String(decoding: b[p..<p + 4], as: UTF8.self)
        }
        guard try tag() == "MThd", try u32() == 6 else { throw ParseError.header }
        let format = try u16(), count = try u16(), ppq = try u16()
        var tracks = [Track]()
        for _ in 0..<count {
            guard try tag() == "MTrk" else { throw ParseError.chunk }
            let len = try u32(), end = p + len
            guard end <= b.count else { throw ParseError.truncated }
            var tick = 0, running: UInt8 = 0, events = [Event](), name = "", endTick: Int?
            func vl() throws -> Int {
                var v = 0
                for _ in 0..<4 {
                    guard p < end else { throw ParseError.truncated }
                    let c = b[p]; p += 1
                    v = v << 7 | Int(c & 0x7F)
                    if c & 0x80 == 0 { return v }
                }
                throw ParseError.truncated
            }
            while p < end {
                tick += try vl()
                guard p < end else { throw ParseError.truncated }
                var st = b[p]
                if st & 0x80 != 0 { p += 1 } else { st = running }
                if st == 0xFF {
                    guard p < end else { throw ParseError.truncated }
                    let m = b[p]; p += 1
                    let n = try vl()
                    guard p + n <= end else { throw ParseError.truncated }
                    let data = Array(b[p..<p + n]); p += n
                    if m == 0x03 { name = String(decoding: data, as: UTF8.self) }
                    if m == 0x2F { endTick = tick; break }
                    events.append(Event(tick: tick, status: 0xFF, data: data, meta: m))
                } else if st == 0xF0 || st == 0xF7 {
                    let n = try vl(); p += n
                } else {
                    running = st
                    let n = st & 0xF0 == 0xC0 || st & 0xF0 == 0xD0 ? 1 : 2
                    guard p + n <= end else { throw ParseError.truncated }
                    events.append(Event(tick: tick, status: st, data: Array(b[p..<p + n]))); p += n
                }
            }
            p = end
            tracks.append(Track(name: name, events: events, end: endTick))
        }
        return File(format: format, ppq: ppq, tracks: tracks)
    }
}
