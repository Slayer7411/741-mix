import AppKit
import SwiftUI

/// Ein Block des Handbuchs (docs/MANUAL.md): Überschrift, Absatz, Listenpunkt, Codeblock, Tabelle, Trennlinie
enum ManualBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    /// Listenpunkt; `number` bei nummerierten Listen
    case bullet(String, number: String?)
    case code(String)
    case table([String])
    case rule
}

enum Manual {
    /// Handbuch aus dem Programm (beim Bauen ins Paket kopiert, make-app.sh). Selbsttest: `MIX741_MANUAL` für Bilder
    static var source: URL? {
        if let u = AppResources.file("MANUAL.md") { return u }
        guard Session.isSelfTest, let p = ProcessInfo.processInfo.environment["MIX741_MANUAL"] else { return nil }
        return URL(fileURLWithPath: p)
    }

    /// Markdown in Blöcke zerlegen (das, was das Handbuch braucht: Überschriften, Absätze, Listen, Codeblöcke, Tabellen)
    static func blocks(_ md: String) -> [ManualBlock] {
        var out: [ManualBlock] = []
        var para: [String] = []
        var table: [String] = []
        var code: [String]?
        func flushPara() { if !para.isEmpty { out.append(.paragraph(para.joined(separator: " "))); para = [] } }
        func flushTable() { if !table.isEmpty { out.append(.table(table)); table = [] } }
        for raw in md.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if code != nil {
                if line.hasPrefix("```") { out.append(.code(code!.joined(separator: "\n"))); code = nil } else { code!.append(raw) }
                continue
            }
            if line.hasPrefix("```") { flushPara(); flushTable(); code = []; continue }
            if line.isEmpty { flushPara(); flushTable(); continue }
            if line.hasPrefix("|") { flushPara(); table.append(line); continue }
            flushTable()
            if line.hasPrefix("#") {
                flushPara()
                let level = line.prefix { $0 == "#" }.count
                out.append(.heading(level: min(level, 3), text: line.dropFirst(level).trimmingCharacters(in: .whitespaces)))
            } else if line == "---" || line == "***" {
                flushPara()
                out.append(.rule)
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flushPara()
                out.append(.bullet(String(line.dropFirst(2)), number: nil))
            } else if let n = numbered(line) {
                flushPara()
                out.append(.bullet(n.text, number: n.number))
            } else if line.hasPrefix(">") {
                flushPara()
                out.append(.paragraph(line.dropFirst().trimmingCharacters(in: .whitespaces)))
            } else {
                para.append(line)
            }
        }
        flushPara()
        flushTable()
        if let c = code, !c.isEmpty { out.append(.code(c.joined(separator: "\n"))) }
        return out
    }

    /// Nummerierter Listenpunkt „12. Text“
    static func numbered(_ line: String) -> (number: String, text: String)? {
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, line.dropFirst(digits.count).hasPrefix(". ") else { return nil }
        return (String(digits), String(line.dropFirst(digits.count + 2)).trimmingCharacters(in: .whitespaces))
    }

    /// Tabellenzeile zur Anzeige: Randstriche weg, Trennzeile („---|---“) fällt weg
    static func tableLine(_ row: String) -> String? {
        let cells = row.split(separator: "|", omittingEmptySubsequences: false).dropFirst().dropLast()
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) { return nil }
        return cells.joined(separator: "   ")
    }
}

@MainActor
enum ManualWindow {
    static func show() {
        let blocks = Manual.source.flatMap { try? String(contentsOf: $0, encoding: .utf8) }.map(Manual.blocks)
        BasicWindows.show("manual", title: "MINOS-741 Handbuch", size: NSSize(width: 680, height: 760)) {
            AnyView(Group {
                if let blocks { ManualView(blocks: blocks) } else { ManualMissingView() }
            })
        }
    }
}

/// Handbuch im 741-Stil: Cinzel-Überschriften, IBM Plex Mono Fließtext, Codeblöcke flach mit Haarlinie
struct ManualView: View {
    let blocks: [ManualBlock]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in row(b) }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.void)
        .foregroundStyle(Theme.bone)
    }

    @ViewBuilder private func row(_ b: ManualBlock) -> some View {
        switch b {
        case let .heading(level, text):
            switch level {
            case 1: Text(inline(text)).font(Theme.label(20)).padding(.top, 6)
            case 2: Text(inline(text)).font(Theme.label(15)).textCase(.uppercase).padding(.top, 14)
            default: Text(inline(text)).font(Theme.label(12)).textCase(.uppercase).padding(.top, 8)
            }
        case let .paragraph(text):
            Text(inline(text)).font(Theme.mono(12)).fixedSize(horizontal: false, vertical: true)
        case let .bullet(text, number):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: number.map { "\($0)." } ?? "·").font(Theme.mono(12)).foregroundStyle(Theme.muted)
                Text(inline(text)).font(Theme.mono(12)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 6)
        case let .code(text):
            Text(verbatim: text)
                .font(Theme.mono(11))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.chitin)
                .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
        case let .table(rows):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                    if let line = Manual.tableLine(r) { Text(verbatim: line).font(Theme.mono(11)) }
                }
            }
            .padding(.leading, 6)
        case .rule:
            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.vertical, 6)
        }
    }

    /// Markdown im Satz (fett, kursiv, Code, Links); sonst der Text unverändert
    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

/// Ohne eingebautes Handbuch (Entwicklungslauf): Verweis auf die Online-Fassung
struct ManualMissingView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Handbuch").font(Theme.label(20)).textCase(.uppercase)
            Text("Das Handbuch liegt in diesem Lauf nicht im Programm. Die aktuelle Fassung steht online.")
                .font(Theme.mono(12))
            DeckButton(title: "Handbuch im Netz") { AppLinks.open(AppLinks.manualOnline) }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.void)
        .foregroundStyle(Theme.bone)
    }
}
