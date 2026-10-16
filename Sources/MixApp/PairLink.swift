import Foundation
import Network
import SystemConfiguration
import MixCore
import MixEngine

/// Zwei-Mac-Modus: Rolle dieses Macs (wirkt nach Neustart)
enum PairRole: String, CaseIterable, Codable, Identifiable {
    case off = "Aus", leader = "Mac 1 · Decks A/C · schreibt", follower = "Mac 2 · Decks B/D"
    var id: String { rawValue }
    var letters: [String] {
        switch self {
        case .off: ["A", "B", "C", "D"]
        case .leader: DeckLabels.leader
        case .follower: DeckLabels.follower
        }
    }
}

/// Zwei Macs als eine Session: Mac 1 bietet sich per Bonjour an (`_minos741._tcp`, jede Verbindung: Ethernet,
/// Thunderbolt-/USB-Bridge, WLAN), Mac 2 verbindet sich. Jeder Mac spielt seine Decks über sein eigenes Interface,
/// den Takt hält Link. Über die Verbindung laufen die Gespielt-Markierungen; in die Collection schreibt nur Mac 1.
@MainActor
final class PairLink {
    static let shared = PairLink()
    static let service = "_minos741._tcp"

    private let queue = DispatchQueue(label: "minos741.pair", qos: .utility)
    private(set) var role = PairRole.off
    private weak var history: HistoryStore?
    private weak var mix: MixModel?
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var reader = PairLineReader()

    /// vor dem ersten Zeichnen: Deck-Buchstaben der Rolle
    static func applyLabels(_ role: PairRole) { DeckLabels.letters = role.letters }

    func start(role: PairRole, history: HistoryStore, mix: MixModel) {
        guard role != .off, !Session.isSelfTest, self.role == .off else { return }
        self.role = role
        self.history = history
        self.mix = mix
        history.onPlayedChange = { add, remove in
            PairLink.shared.send(.played(add: add.sorted(), remove: remove.sorted()))
        }
        if role == .leader { listen() } else { browse() }
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
                if case .failed = s { Self.main { PairLink.shared.restartListener() } }
            }
            l.start(queue: queue)
            listener = l
            StatusCenter.post(.info, String(localized: "Zwei-Mac: Mac 1 wartet auf Mac 2"), key: "pair")
        } catch {
            StatusCenter.post(.error, String(localized: "Zwei-Mac: kein Netz-Dienst (\(error.localizedDescription))"), key: "pair")
        }
    }

    private func restartListener() {
        listener?.cancel()
        listener = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { MainActor.assumeIsolated { PairLink.shared.listen() } }
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
        StatusCenter.post(.info, String(localized: "Zwei-Mac: Mac 2 sucht Mac 1"), key: "pair")
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
            send(.hello(leader: role == .leader, version: PairMessage.version, name: Self.computerName,
                        played: (history?.played ?? []).sorted()))
            if let mix, !mix.clock.linkEnabled { mix.toggleLink() }
        case .failed, .waiting:
            c.cancel()
        case .cancelled:
            connection = nil
            StatusCenter.post(.warning, String(localized: "Zwei-Mac: Verbindung getrennt"), key: "pair")
            // Mac 2: neu suchen (die Trefferliste meldet nur Änderungen)
            if role == .follower {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { MainActor.assumeIsolated { PairLink.shared.browse() } }
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
        case let .hello(leader, version, name, played):
            guard leader != (role == .leader) else {
                StatusCenter.post(.error, String(localized: "Zwei-Mac: beide Macs haben dieselbe Rolle (⌘, -> DECKS)"), key: "pair")
                connection?.cancel()
                return
            }
            let note = version == PairMessage.version ? "" : " · " + String(localized: "andere Version")
            StatusCenter.post(.ok, String(localized: "Zwei-Mac: verbunden mit \(name)") + note, key: "pair")
            if role == .leader {
                let s = PairPlayed.merged(leader: history.played, follower: Set(played))
                history.applyPlayed(s)
                send(.playedSet(s.sorted()))
            }
        case let .playedSet(s):
            if role == .follower { history.applyPlayed(Set(s)) }
        case let .played(add, remove):
            history.applyPlayed(history.played.subtracting(remove).union(add))
        }
    }
}
