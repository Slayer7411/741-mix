import AppKit
import SwiftUI
import MixCore

/// Eine Zeile des Protokolls: Zeit, Stufe, Text (Text · Detail wie in der Statuszeile)
struct StatusLogLine: Identifiable, Equatable {
    let id: Int
    let time: String
    let level: StatusMessage.Level?
    let text: String

    var plain: String {
        [time, level.map { "\($0)" } ?? "", text].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// Protokoll aus `status-log.txt` im Datenordner (die letzten Zeilen) und den Meldungen dieser Sitzung (`StatusCenter.recent`).
/// Meldungen, die schon in der Datei stehen, kommen nur einmal vor
enum StatusLogReader {
    static let limit = 500
    /// Eine Dateizeile zerlegen (Zeit, Stufe, Text); ohne Zeit und Stufe bleibt die ganze Zeile als Text („=== Start …“)
    static func parse(_ line: String) -> (time: String, level: StatusMessage.Level?, text: String) {
        let time = String(line.prefix(19))
        guard isStamp(time), line.count > 20 else { return ("", nil, line) }
        let rest = line.dropFirst(20)
        let word = rest.prefix { $0 != " " }
        guard let level = StatusMessage.Level.allCases.first(where: { "\($0)" == word }) else { return ("", nil, line) }
        return (time, level, String(rest.dropFirst(word.count + 1)))
    }

    /// „JJJJ-MM-TT HH:MM:SS“
    static func isStamp(_ s: String) -> Bool {
        let shape = Array("dddd-dd-dd dd:dd:dd")
        let c = Array(s)
        return c.count == shape.count && zip(c, shape).allSatisfy { ch, want in
            want == "d" ? (ch.isASCII && ch.isNumber) : ch == want
        }
    }

    /// Meldung wie in der Datei: Zeit, Stufe, Text, Detail
    static func format(_ m: StatusMessage) -> String {
        "\(StatusLogFile.stamp(m.posted)) \(m.level) \(m.text)" + (m.detail.map { " · \($0)" } ?? "")
    }

    /// Zeilen für die Anzeige: die letzten `limit` der Datei, danach die Meldungen dieser Sitzung, die nicht in der Datei stehen
    static func lines(fileText: String?, recent: [StatusMessage], limit: Int = limit) -> [StatusLogLine] {
        var raw = (fileText ?? "").components(separatedBy: "\n").filter { !$0.isEmpty }
        raw = Array(raw.suffix(limit))
        let known = Set(raw)
        for m in recent {
            let f = format(m)
            if !known.contains(f) { raw.append(f) }
        }
        return raw.enumerated().map { i, line in
            let p = parse(line)
            return StatusLogLine(id: i, time: p.time, level: p.level, text: p.text)
        }
    }

    /// Nur eine Stufe (nil: alle)
    static func filter(_ lines: [StatusLogLine], level: StatusMessage.Level?) -> [StatusLogLine] {
        guard let level else { return lines }
        return lines.filter { $0.level == level }
    }
}

@MainActor
enum StatusLogWindow {
    static func show() {
        BasicWindows.show("log", title: "MINOS-741 Protokoll", size: NSSize(width: 760, height: 520)) {
            AnyView(StatusLogView(loadFile: {
                (try? String(contentsOf: StatusLogFile.url, encoding: .utf8)).map { String($0.suffix(200_000)) }
            }))
        }
    }
}

struct StatusLogView: View {
    /// Dateiinhalt (die Anzeige liest ihn beim Öffnen und auf „Aktualisieren“ neu)
    let loadFile: () -> String?
    @State private var fileText: String?
    @State private var level: StatusMessage.Level?
    @State private var loaded = false
    private var status: StatusCenter { StatusCenter.shared }

    var body: some View {
        let _ = status.log   // beobachtet: jede neue Meldung aktualisiert die Ansicht (`recent` selbst ist nicht beobachtet)
        let all = StatusLogReader.lines(fileText: fileText, recent: status.recent)
        let shown = StatusLogReader.filter(all, level: level)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Protokoll").font(Theme.label(16)).textCase(.uppercase)
                Spacer()
                DeckButton(title: "Alle", active: level == nil) { level = nil }
                ForEach(StatusMessage.Level.allCases, id: \.self) { l in
                    DeckButton(title: Self.name(l), active: level == l) { level = l }
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if shown.isEmpty {
                        Text("Keine Meldungen").font(Theme.mono(11)).foregroundStyle(Theme.muted).padding(.top, 6)
                    }
                    ForEach(shown) { l in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(verbatim: l.time).font(Theme.mono(10)).foregroundStyle(Theme.muted)
                                .frame(width: 140, alignment: .leading)
                            Text(verbatim: l.level.map { Self.name($0) } ?? "").font(Theme.mono(10, .medium))
                                .foregroundStyle(l.level == .error ? Theme.state : Theme.bone.opacity(0.8))
                                .frame(width: 64, alignment: .leading)
                            Text(verbatim: l.text).font(Theme.mono(11)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .background(Theme.chitin)
            .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
            HStack(spacing: 8) {
                Text("\(shown.count) von \(all.count) Zeilen").font(Theme.mono(10)).foregroundStyle(Theme.muted)
                Spacer()
                DeckButton(title: "Aktualisieren") { fileText = loadFile() }
                DeckButton(title: "Kopieren") {
                    let text = shown.map(\.plain).joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.void)
        .foregroundStyle(Theme.bone)
        .tint(Theme.state)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            fileText = loadFile()
        }
    }

    static func name(_ l: StatusMessage.Level) -> String {
        switch l {
        case .info: String(localized: "Info")
        case .ok: String(localized: "OK")
        case .warning: String(localized: "Warnung")
        case .error: String(localized: "Fehler")
        }
    }
}
