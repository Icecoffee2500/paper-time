import Foundation

/// Tables in a note: found, read, and made from what is pasted.
///
/// A note's table is a Markdown table, the kind every Markdown editor writes:
///
///     | Year | Factor |
///     | ---- | -----: |
///     | 2023 | 5%     |
///
/// The note is read a line at a time, and a table is the second thing
/// (after a `$$` block) that only makes sense as several lines at once, so
/// this finds each table's lines for the renderer to draw as one grid. And
/// a table copied out of ChatGPT or Obsidian arrives as HTML, or as rows of
/// tab-separated cells, and pasted as it was each cell became a line of its
/// own; this turns either into the Markdown table it stands for. Offsets are
/// UTF-16. The Portable build is `shared/noteTable.ts`, held to the same
/// answers (`Tests/PaperCoreTests/Fixtures/note-tables.json`).
public enum NoteTable {
    public enum Alignment: String, Sendable, Codable {
        case none, left, center, right
    }

    public struct Table: Equatable, Sendable {
        public var header: [String]
        public var alignments: [Alignment]
        public var rows: [[String]]

        public init(header: [String], alignments: [Alignment], rows: [[String]]) {
            self.header = header
            self.alignments = alignments
            self.rows = rows
        }
    }

    // MARK: - Finding

    /// Each table, from the start of its header line to the end of its last
    /// row. A table is a line with a `|` in it, then a line of dashes and
    /// pipes (colons for alignment), then every following line that has a
    /// `|` in it — as GitHub reads one.
    public static func blocks(in text: String) -> [NSRange] {
        let whole = text as NSString
        let lines = NoteMath.lineRanges(of: whole)
        var result: [NSRange] = []
        var index = 0
        while index + 1 < lines.count {
            let head = whole.substring(with: lines[index])
            let rule = whole.substring(with: lines[index + 1])
            guard head.contains("|"), isRule(rule),
                  cells(of: head).count == cells(of: rule).count
            else {
                index += 1
                continue
            }
            var last = index + 1
            while last + 1 < lines.count, isRow(whole.substring(with: lines[last + 1])) { last += 1 }
            let start = lines[index].location
            let end = lines[last].location + lines[last].length
            result.append(NSRange(location: start, length: end - start))
            index = last + 1
        }
        return result
    }

    /// The table a block of lines holds.
    public static func parse(_ block: String) -> Table? {
        let lines = block.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        guard lines.count >= 2, lines[0].contains("|"), isRule(lines[1]) else { return nil }
        let header = cells(of: lines[0])
        let alignments = cells(of: lines[1]).map(alignment(of:))
        guard header.count == alignments.count else { return nil }
        let rows = lines.dropFirst(2).filter(isRow).map { line -> [String] in
            var row = cells(of: line)
            if row.count < header.count { row += Array(repeating: "", count: header.count - row.count) }
            return Array(row.prefix(header.count))
        }
        return Table(header: header, alignments: alignments, rows: rows)
    }

    /// A line of a table's body: anything with a `|` in it that is not blank.
    private static func isRow(_ line: String) -> Bool {
        line.contains("|") && !line.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The line under a header: cells of dashes, a colon at either end.
    private static func isRule(_ line: String) -> Bool {
        guard line.contains("|") else { return false }
        let parts = cells(of: line)
        guard !parts.isEmpty else { return false }
        return parts.allSatisfy { part in
            var body = Substring(part)
            if body.hasPrefix(":") { body = body.dropFirst() }
            if body.hasSuffix(":") { body = body.dropLast() }
            return !body.isEmpty && body.allSatisfy { $0 == "-" }
        }
    }

    private static func alignment(of rule: String) -> Alignment {
        switch (rule.hasPrefix(":"), rule.hasSuffix(":")) {
        case (true, true): return .center
        case (false, true): return .right
        case (true, false): return .left
        default: return .none
        }
    }

    /// A row's cells: split at every `|` that is not escaped, the outer
    /// pipes dropped, each cell trimmed, `\|` read as a bar.
    public static func cells(of line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|"), !text.hasSuffix("\\|") { text.removeLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in text {
            if escaped {
                current.append(character == "|" ? "|" : "\\")
                if character != "|" { current.append(character) }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    // MARK: - Writing

    /// A table as Markdown: a header, its rule, its rows, pipes escaped.
    public static func markdown(_ table: Table) -> String {
        let columns = max(table.header.count, table.rows.map(\.count).max() ?? 0)
        guard columns > 0 else { return "" }
        func row(_ cells: [String]) -> String {
            let padded = cells + Array(repeating: "", count: max(0, columns - cells.count))
            return "| " + padded.prefix(columns).map(escape).joined(separator: " | ") + " |"
        }
        let alignments = (0..<columns).map { $0 < table.alignments.count ? table.alignments[$0] : .none }
        let rule = "| " + alignments.map { alignment -> String in
            switch alignment {
            case .none: return "---"
            case .left: return ":---"
            case .center: return ":---:"
            case .right: return "---:"
            }
        }.joined(separator: " | ") + " |"
        return ([row(table.header), rule] + table.rows.map(row)).joined(separator: "\n")
    }

    private static func escape(_ cell: String) -> String {
        cell.replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    // MARK: - From what is pasted

    /// Rows of tab-separated cells — what a spreadsheet, and many a web
    /// page, puts on the clipboard as plain text — as a Markdown table, the
    /// first row its header. Nil unless there are at least two rows and every
    /// row has the same number of tabs, one or more.
    public static func fromTabSeparated(_ text: String) -> String? {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.count >= 2 else { return nil }
        let rows = lines.map { $0.components(separatedBy: "\t").map { $0.trimmingCharacters(in: .whitespaces) } }
        guard let width = rows.first?.count, width >= 2, rows.allSatisfy({ $0.count == width }) else { return nil }
        return markdown(Table(header: rows[0], alignments: [], rows: Array(rows.dropFirst())))
    }

    /// An HTML fragment with a table in it — what ChatGPT, Obsidian's
    /// reading view and every browser put on the clipboard — as Markdown:
    /// each table as a Markdown table, and the words around it as lines of
    /// text. Nil when there is no table in it.
    public static func fromHTML(_ html: String) -> String? {
        guard html.range(of: "<table", options: .caseInsensitive) != nil else { return nil }
        var out: [String] = []
        var prose = ""
        var tables: [[[String]]] = []
        var row: [String]? = nil
        var cell: String? = nil
        var depth = 0

        func flushProse() {
            let lines = prose.components(separatedBy: "\n")
                .map { $0.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ") }
                .filter { !$0.isEmpty }
            if !lines.isEmpty { out.append(lines.joined(separator: "\n")) }
            prose = ""
        }
        // The page's own line breaks are only layout: a break in the words
        // comes from a tag.
        func text(_ piece: String) {
            let decoded = decodeEntities(piece)
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\t", with: " ")
            if cell != nil { cell! += decoded } else if depth == 0 { prose += decoded }
        }

        var index = html.startIndex
        while index < html.endIndex {
            guard let open = html[index...].firstIndex(of: "<") else {
                text(String(html[index...]))
                break
            }
            text(String(html[index..<open]))
            guard let close = html[open...].firstIndex(of: ">") else { break }
            let tag = html[html.index(after: open)..<close].lowercased()
            index = html.index(after: close)
            let closing = tag.hasPrefix("/")
            let name = String(tag.drop(while: { $0 == "/" }).prefix(while: { $0.isLetter || $0.isNumber }))
            // Comments, styles and scripts are not words.
            if tag.hasPrefix("!--") {
                if let end = html[open...].range(of: "-->") { index = end.upperBound }
                continue
            }
            if !closing, name == "style" || name == "script" {
                if let end = html[index...].range(of: "</\(name)", options: .caseInsensitive),
                   let after = html[end.upperBound...].firstIndex(of: ">") {
                    index = html.index(after: after)
                }
                continue
            }
            switch (name, closing) {
            case ("table", false):
                depth += 1
                if depth == 1 {
                    flushProse()
                    tables.append([])
                }
            case ("table", true):
                guard depth > 0 else { break }
                depth -= 1
                if depth == 0, let rows = tables.popLast() {
                    let width = rows.map(\.count).max() ?? 0
                    if width > 0, !rows.isEmpty {
                        let filled = rows.map { $0 + Array(repeating: "", count: width - $0.count) }
                        out.append(markdown(Table(header: filled[0], alignments: [], rows: Array(filled.dropFirst()))))
                    }
                    row = nil
                    cell = nil
                }
            case ("tr", false) where depth == 1:
                row = []
            case ("tr", true) where depth == 1:
                if let finished = row, !finished.isEmpty { tables[tables.count - 1].append(finished) }
                row = nil
            case ("td", false) where depth == 1, ("th", false) where depth == 1:
                if row == nil { row = [] }
                cell = ""
            case ("td", true) where depth == 1, ("th", true) where depth == 1:
                if let finished = cell {
                    row?.append(finished.split(whereSeparator: \.isWhitespace).joined(separator: " "))
                }
                cell = nil
            case ("h1", false), ("h2", false), ("h3", false), ("h4", false), ("h5", false), ("h6", false):
                // A heading stays a heading; the level is the tag's.
                if depth == 0, let level = Int(name.dropFirst()) {
                    prose += "\n" + String(repeating: "#", count: level) + " "
                }
            case ("br", _), ("p", true), ("div", true), ("li", true), ("h1", true), ("h2", true),
                 ("h3", true), ("h4", true), ("h5", true), ("h6", true), ("pre", true):
                if cell != nil { cell! += " " } else if depth == 0 { prose += "\n" }
            case ("li", false):
                if depth == 0 { prose += "\n- " }
            default:
                break
            }
        }
        flushProse()
        let result = out.joined(separator: "\n\n")
        return result.isEmpty ? nil : result
    }

    private static let entities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "ndash": "–", "mdash": "—", "hellip": "…", "times": "×", "middot": "·",
    ]

    /// `&amp;`, `&#39;`, `&#x2014;` and the handful of names a copied page uses.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text.replacingOccurrences(of: "\u{A0}", with: " ") }
        var out = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "&", let semicolon = text[index...].prefix(12).firstIndex(of: ";") {
                let name = String(text[text.index(after: index)..<semicolon])
                var replacement: String?
                if name.hasPrefix("#x") || name.hasPrefix("#X"), let value = UInt32(name.dropFirst(2), radix: 16) {
                    replacement = Unicode.Scalar(value).map { String(Character($0)) }
                } else if name.hasPrefix("#"), let value = UInt32(name.dropFirst()) {
                    replacement = Unicode.Scalar(value).map { String(Character($0)) }
                } else {
                    replacement = entities[name]
                }
                if let replacement {
                    out += replacement
                    index = text.index(after: semicolon)
                    continue
                }
            }
            out.append(text[index])
            index = text.index(after: index)
        }
        return out.replacingOccurrences(of: "\u{A0}", with: " ")
    }
}
