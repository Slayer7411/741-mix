import Foundation
import CoreMIDI
import MixCore

/// Groove als MIDI: virtuelle Quelle (andere Programme wählen sie als MIDI-Eingang), Noten im Takt der Master-Clock.
/// Eigene Queue mit 10-ms-Takt, Zeitstempel (Host-Zeit) je Ereignis, geplant nur `lookahead` voraus; nichts im Audio-Thread.
/// Zugriffe von außen gehen über die eigene Queue.
public final class GrooveOut: @unchecked Sendable {
    /// Clock: Beat zu einer Host-Zeit (wann hörbar) und Tempo
    public struct Clock: Sendable {
        public var beat: Double
        public var hostTime: UInt64
        public var bpm: Double
        public init(beat: Double, hostTime: UInt64, bpm: Double) { self.beat = beat; self.hostTime = hostTime; self.bpm = bpm }
    }

    /// gesendetes Ereignis (Host-Zeit, 3 Bytes) – Test und Selbsttest
    public struct Sent: Sendable { public var hostTime: UInt64; public var beat: Double; public var bytes: (UInt8, UInt8, UInt8) }

    public static let tick = 0.010
    /// Vorlauf: zwei Takte der Queue plus Reserve
    public static let lookahead = 0.025

    private let queue = DispatchQueue(label: "minos741.groove", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var schedule: GrooveSchedule?
    private var clock: (@Sendable () -> Clock?)?
    private var client = MIDIClientRef()
    private var source = MIDIEndpointRef()
    private var name: String
    private let hidden: Bool
    /// Versatz der Zeitstempel (positiv = später)
    private var offsetSeconds = 0.0
    private var channels: Set<UInt8> = []
    private var buffer = [UInt8](repeating: 0, count: 8192)

    /// je gesendetem Ereignis (auf der Groove-Queue)
    public var onSend: (@Sendable (Sent) -> Void)?
    /// Fehler beim Anlegen der Quelle
    public private(set) var lastError: String?

    /// `hidden`: Quelle für andere Programme unsichtbar (Selbsttest; eigener Eingang kann sie trotzdem verbinden)
    public init(name: String, hidden: Bool = false) {
        self.name = name
        self.hidden = hidden
    }

    deinit {
        timer?.cancel()
        if source != 0 { MIDIEndpointDispose(source) }
        if client != 0 { MIDIClientDispose(client) }
    }

    public var running: Bool { queue.sync { timer != nil } }
    /// Quelle (0 = noch nicht angelegt)
    public var endpoint: MIDIEndpointRef { queue.sync { source } }

    /// Quelle anlegen (bleibt bis zum Ende des Programms, damit das Ziel sie wiederfindet)
    @discardableResult
    public func open() -> Bool { queue.sync { openLocked() } }

    private func openLocked() -> Bool {
        if source != 0 { return true }
        var st = MIDIClientCreateWithBlock("MINOS-741" as CFString, &client) { _ in }
        guard st == noErr else { lastError = "MIDIClientCreate \(st)"; return false }
        st = MIDISourceCreateWithProtocol(client, name as CFString, ._1_0, &source)
        guard st == noErr else { lastError = "MIDISourceCreate \(st)"; return false }
        // feste ID: das Ziel erkennt die Quelle nach einem Neustart wieder (vergeben = andere ID vom System)
        MIDIObjectSetIntegerProperty(source, kMIDIPropertyUniqueID, hidden ? 0x7410_0002 : 0x7410_0001)
        MIDIObjectSetStringProperty(source, kMIDIPropertyManufacturer, "MINOS-741" as CFString)
        if hidden { MIDIObjectSetIntegerProperty(source, kMIDIPropertyPrivate, 1) }
        lastError = nil
        return true
    }

    private var listenPort = MIDIPortRef()

    /// eigener Eingang an der Quelle (Selbsttest): je ankommendem Ereignis Zeitstempel und 3 Bytes
    @discardableResult
    public func listen(_ f: @escaping @Sendable (UInt64, UInt8, UInt8, UInt8) -> Void) -> Bool {
        queue.sync {
            guard openLocked(), listenPort == 0 else { return false }
            let st = MIDIInputPortCreateWithProtocol(client, "listen" as CFString, ._1_0, &listenPort) { list, _ in
                for p in list.unsafeSequence() {
                    let n = Int(p.pointee.wordCount), stamp = p.pointee.timeStamp
                    withUnsafeBytes(of: p.pointee.words) { raw in
                        for w in raw.bindMemory(to: UInt32.self).prefix(n) {
                            f(stamp, UInt8(w >> 16 & 0xFF), UInt8(w >> 8 & 0x7F), UInt8(w & 0x7F))
                        }
                    }
                }
            }
            guard st == noErr else { return false }
            return MIDIPortConnectSource(listenPort, source, nil) == noErr
        }
    }

    public func unlisten() {
        queue.sync {
            if listenPort != 0 { MIDIPortDispose(listenPort); listenPort = 0 }
        }
    }

    public func rename(_ n: String) {
        queue.async { [self] in
            guard n != name, !n.isEmpty else { return }
            name = n
            if source != 0 { MIDIObjectSetStringProperty(source, kMIDIPropertyName, n as CFString) }
        }
    }

    /// Clip ab `origin` (Clock-Beat von Schritt 0) spielen; läuft er schon, wird nur der Clip getauscht (ohne Lücke)
    public func start(clip: GrooveClip, origin: Double, offsetMs: Double = 0, clock: @escaping @Sendable () -> Clock?) {
        queue.async { [self] in
            guard openLocked() else { return }
            self.clock = clock
            offsetSeconds = offsetMs / 1000
            channels.formUnion(clip.notes.map(\.channel))
            if schedule != nil {
                schedule?.clip = clip
                schedule?.origin = origin
            } else {
                schedule = GrooveSchedule(clip: clip, origin: origin)
            }
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: Self.tick, leeway: .milliseconds(1))
            t.setEventHandler { [weak self] in self?.step() }
            timer = t
            t.resume()
        }
    }

    public func update(clip: GrooveClip) {
        queue.async { [self] in
            channels.formUnion(clip.notes.map(\.channel))
            schedule?.clip = clip
        }
    }

    public func setOffset(ms: Double) { queue.async { [self] in offsetSeconds = ms / 1000 } }

    /// anhalten: offene Noten beenden, All Notes Off auf den benutzten Kanälen
    public func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            guard source != 0 else { schedule = nil; return }
            let now = mach_absolute_time()
            var ev = [(UInt64, Double, (UInt8, UInt8, UInt8))]()
            for e in schedule?.flush(now: 0) ?? [] { ev.append((now, e.beat, (e.status, e.note, 0))) }
            for ch in channels.sorted() { ev.append((now, 0, (0xB0 | ch, 123, 0))) }
            schedule = nil
            send(ev)
        }
    }

    /// ein Takt der Queue: Clock lesen, Fenster planen, senden
    private func step() {
        guard var sch = schedule, let c = clock?(), c.bpm > 0 else { return }
        let now = mach_absolute_time()
        let spb = 60 / c.bpm
        // Clock-Beat jetzt (Zeitstempel = wann hörbar; liegt meist etwas in der Zukunft)
        let beatNow = c.beat + Self.seconds(from: c.hostTime, to: now) / spb
        let events = sch.events(now: beatNow, ahead: Self.lookahead / spb)
        schedule = sch
        guard !events.isEmpty else { return }
        var out = [(UInt64, Double, (UInt8, UInt8, UInt8))]()
        for e in events {
            let secs = (e.beat - c.beat) * spb + offsetSeconds
            let host = secs >= 0 ? c.hostTime &+ LinkSession.hostTicks(seconds: secs) : c.hostTime &- LinkSession.hostTicks(seconds: -secs)
            out.append((max(host, now), e.beat, (e.status, e.note, e.velocity)))
        }
        send(out)
    }

    private func send(_ ev: [(UInt64, Double, (UInt8, UInt8, UInt8))]) {
        guard source != 0, !ev.isEmpty else { return }
        // höchstens ~150 Ereignisse je Liste (Puffer 8 KB, 24 Bytes je Paket mit einem Wort reichen großzügig)
        for chunk in stride(from: 0, to: ev.count, by: 150).map({ Array(ev[$0..<min(ev.count, $0 + 150)]) }) {
            buffer.withUnsafeMutableBytes { raw in
                let list = raw.baseAddress!.assumingMemoryBound(to: MIDIEventList.self)
                var pkt: UnsafeMutablePointer<MIDIEventPacket>? = MIDIEventListInit(list, ._1_0)
                for (host, _, b) in chunk where pkt != nil {
                    // UMP MIDI 1.0 Channel Voice (Typ 2, Gruppe 0)
                    var word = UInt32(0x2) << 28 | UInt32(b.0) << 16 | UInt32(b.1 & 0x7F) << 8 | UInt32(b.2 & 0x7F)
                    pkt = MIDIEventListAdd(list, raw.count, pkt!, host, 1, &word)
                }
                MIDIReceivedEventList(source, list)
            }
        }
        if let cb = onSend { for (h, beat, b) in ev { cb(Sent(hostTime: h, beat: beat, bytes: b)) } }
    }

    static func seconds(from a: UInt64, to b: UInt64) -> Double {
        b >= a ? Double(LinkSession.micros(hostTicks: b - a)) / 1e6 : -Double(LinkSession.micros(hostTicks: a - b)) / 1e6
    }
}
