import Foundation
import Network
import SystemConfiguration
import MixCore
import MixEngine

/// Zwei Macs als eine Session: der schreibende Mac bietet sich per Bonjour an (`_minos741._tcp`, jede Verbindung:
/// Ethernet, Thunderbolt-/USB-Bridge, WLAN), der andere verbindet sich. Jeder Mac spielt seine Decks (⌘, -> DECKS)
/// über sein eigenes Interface, den Takt hält Link. Über die Verbindung laufen die Gespielt-Markierungen; in die
/// Collection schreibt nur der schreibende Mac. Umschalten wirkt sofort
@MainActor
final class PairLink {
    static let shared = PairLink()
    static let service = "_minos741._tcp"

    private let queue = DispatchQueue(label: "minos741.pair", qos: .utility)
    private(set) var setup = PairSetup()
    private weak var history: HistoryStore?
    private weak var mix: MixModel?
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var reader = PairLineReader()

    /// Einstellung übernehmen: Verbindung abbauen und nach der neuen Einstellung wieder aufbauen
    func configure(_ new: PairSetup, history: HistoryStore, mix: MixModel) {
        guard !Session.isSelfTest, new != setup else { return }
        listener?.cancel(); listener = nil
        browser?.cancel(); browser = nil
        let old = connection
        connection = nil
        old?.cancel()
        setup = new
        self.history = history
        self.mix = mix
        guard new.on else {
            history.onPlayedChange = nil
            StatusCenter.post(.info, String(localized: "Zwei-Mac: aus"), key: "pair")
            return
        }
        history.onPlayedChange = { add, remove in
            PairLink.shared.send(.played(add: add.sorted(), remove: remove.sorted()))
        }
        if new.writes { listen() } else { browse() }
    }

    private static var computerName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "MINOS-741"
    }

    private static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        return NWParameters(tls: nil, tcp: tcp)
    }

    nonisolated private static func main(_ f: @escaping @MainActor @Sendable () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated(f) }
    }

    // MARK: Verbinden

    private func listen() {
        do {
            let l = try NWListener(using: Self.parameters())
            l.service = NWListener.Service(name: Self.computerName, type: Self.service)
            l.newConnectionHandler = { c in Self.main { PairLink.shared.adopt(c) } }
            l.stateUpdateHandler = { s in
                if case .failed = s { Self.main { if PairLink.shared.listener === l { PairLink.shared.restartListener() } } }
            }
            l.start(queue: queue)
            listener = l
            StatusCenter.post(.info, String(localized: "Zwei-Mac: schreibender Mac wartet auf den zweiten"), key: "pair")
        } catch {
            StatusCenter.post(.error, String(localized: "Zwei-Mac: kein Netz-Dienst (\(error.localizedDescription))"), key: "pair")
        }
    }

    private func restartListener() {
        listener?.cancel()
        listener = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            MainActor.assumeIsolated { let p = PairLink.shared; if p.setup.on, p.setup.writes, p.listener == nil { p.listen() } }
        }
    }

    private func browse() {
        browser?.cancel()
        let b = NWBrowser(for: .bonjour(type: Self.service, domain: nil), using: Self.parameters())
        b.browseResultsChangedHandler = { results, _ in
            guard let ep = results.first?.endpoint else { return }
            Self.main { PairLink.shared.found(ep) }
        }
        b.start(queue: queue)
        browser = b
        StatusCenter.post(.info, String(localized: "Zwei-Mac: sucht den schreibenden Mac"), key: "pair")
    }

    private func found(_ ep: NWEndpoint) {
        guard connection == nil else { return }
        adopt(NWConnection(to: ep, using: Self.parameters()))
    }

    /// genau ein Gegenüber: eine neue Verbindung ersetzt die alte
    private func adopt(_ c: NWConnection) {
        connection?.cancel()
        connection = c
        reader = PairLineReader()
        c.stateUpdateHandler = { s in Self.main { PairLink.shared.changed(s, of: c) } }
        c.start(queue: queue)
        receive(c)
    }

    private func changed(_ s: NWConnection.State, of c: NWConnection) {
        guard c === connection else { return }
        switch s {
        case .ready:
            send(.hello(writes: setup.writes, decks: setup.decks, version: PairMessage.version, name: Self.computerName,
                        played: (history?.played ?? []).sorted()))
            if let mix, !mix.clock.linkEnabled { mix.toggleLink() }
        case .failed, .waiting:
            c.cancel()
        case .cancelled:
            connection = nil
            StatusCenter.post(.warning, String(localized: "Zwei-Mac: Verbindung getrennt"), key: "pair")
            // nicht schreibender Mac: neu suchen (die Trefferliste meldet nur Änderungen)
            if setup.on, !setup.writes {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    MainActor.assumeIsolated { let p = PairLink.shared; if p.setup.on, !p.setup.writes, p.connection == nil { p.browse() } }
                }
            }
        default:
            break
        }
    }

    private func receive(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, done, error in
            Self.main {
                let link = PairLink.shared
                guard c === link.connection else { return }
                if let data { link.reader.feed(data).forEach(link.handle) }
                if done || error != nil { c.cancel() } else { link.receive(c) }
            }
        }
    }

    // MARK: Nachrichten

    private func send(_ m: PairMessage) {
        guard let c = connection, c.state == .ready else { return }
        c.send(content: m.line(), completion: .contentProcessed { _ in })
    }

    private func handle(_ m: PairMessage) {
        guard let history else { return }
        switch m {
        case let .hello(writes, decks, version, name, played):
            let problems = PairCheck.problems(ownWrites: setup.writes, ownDecks: setup.decks, peerWrites: writes, peerDecks: decks)
            if problems.contains(.bothWrite) || problems.contains(.noneWrites) {
                StatusCenter.post(.error, problems.contains(.bothWrite) ? String(localized: "Zwei-Mac: beide Macs schreiben (⌘, -> DECKS)")
                                  : String(localized: "Zwei-Mac: kein Mac schreibt (⌘, -> DECKS)"), key: "pair")
                connection?.cancel()
                return
            }
            var note = version == PairMessage.version ? "" : " · " + String(localized: "andere Version")
            for case let .sharedDecks(d) in problems {
                note += " · " + String(localized: "Deck \(d.map { deckLetters[$0] }.joined(separator: "/")) auf beiden")
            }
            let theirs = decks.map { deckLetters[$0] }.joined(separator: "/")
            StatusCenter.post(note.isEmpty ? .ok : .warning, String(localized: "Zwei-Mac: verbunden mit \(name) (Decks \(theirs))") + note, key: "pair")
            if setup.writes {
                let s = PairPlayed.merged(history.played, Set(played))
                history.applyPlayed(s)
                send(.playedSet(s.sorted()))
            }
        case let .playedSet(s):
            if !setup.writes { history.applyPlayed(Set(s)) }
        case let .played(add, remove):
            history.applyPlayed(history.played.subtracting(remove).union(add))
        }
    }
}
