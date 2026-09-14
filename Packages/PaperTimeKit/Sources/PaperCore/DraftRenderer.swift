import Foundation

/// A draft, rendered for the manuscript it is going into.
///
/// A draft is a note (`kind: draft`) whose bullets are prose, links to
/// notes, and passages with addresses. Rendered, the prose stays prose, a
/// linked note is unfolded into its own words, and every passage becomes
/// the citation of the paper it was cut from — `\cite{key}` for LaTeX,
/// `[@key]` for pandoc — so that what leaves the box arrives in Overleaf
/// with its references intact. The keys are the papers' BibTeX keys, and
/// the papers cited come back as a list so a `.bib` of exactly those can
/// go with it.
public enum DraftRenderer {
    public enum Format: String, CaseIterable, Sendable {
        case latex, markdown
    }

    public struct Rendered: Sendable {
        public var text: String
        /// The papers cited, in the order first cited.
        public var cited: [UUID]
    }

    /// - Parameters:
    ///   - key: the BibTeX key of a paper, or nil when it has none.
    ///   - note: another note by identifier, for unfolding.
    public static func render(
        _ draft: Zettel, as format: Format,
        key: (UUID) -> String?, note: (String) -> Zettel?
    ) -> Rendered {
        var cited: [UUID] = []
        let body = expand(draft.body, depth: 0, note: note)
        var out = ""
        for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            // Passages become citations.
            line = replace(pattern: #"\[([^\]]*)\]\((papertime://anchor[^)\s]*)\)"#, in: line) { groups in
                guard let url = URL(string: groups[2]), let anchor = NoteAnchor(url: url), let paper = anchor.paperID else {
                    return groups[1]
                }
                if !cited.contains(paper) { cited.append(paper) }
                let citeKey = key(paper) ?? "paper-\(paper.uuidString.prefix(8).lowercased())"
                return format == .latex ? "\\cite{\(citeKey)}" : "[@\(citeKey)]"
            }
            // Headings and bullets, for LaTeX; Markdown keeps its own.
            if format == .latex {
                if line.hasPrefix("### ") { line = "\\subsubsection*{\(escapeLaTeX(String(line.dropFirst(4))))}" }
                else if line.hasPrefix("## ") { line = "\\subsection*{\(escapeLaTeX(String(line.dropFirst(3))))}" }
                else if line.hasPrefix("# ") { line = "\\section*{\(escapeLaTeX(String(line.dropFirst(2))))}" }
                else {
                    // A bullet is a paragraph of the prose; the marker goes.
                    line = line.replacingOccurrences(of: #"^\s*[-*+]\s+"#, with: "", options: .regularExpression)
                    line = replace(pattern: #"\*\*([^*]+)\*\*"#, in: line) { "\\textbf{\($0[1])}" }
                    line = replace(pattern: #"(?<![*\\])\*([^*]+)\*"#, in: line) { "\\emph{\($0[1])}" }
                    // Everything outside a citation or maths is text to escape.
                    line = escapeOutsideCommands(line)
                }
                out += line + "\n"
            } else {
                out += line + "\n"
            }
        }
        return Rendered(text: out.trimmingCharacters(in: .newlines) + "\n", cited: cited)
    }

    /// A linked note unfolds into its words, one level down: a draft says
    /// "this idea here", and the idea is the note's body.
    static func expand(_ body: String, depth: Int, note: (String) -> Zettel?) -> String {
        guard depth < 2 else { return body }
        return replace(pattern: #"\[\[([^\]|\n]+)(?:\|([^\]\n]*))?\]\]"#, in: body) { groups in
            guard let linked = note(groups[1]), linked.kind == .note else { return groups[2].isEmpty ? groups[1] : groups[2] }
            let unfolded = expand(linked.body, depth: depth + 1, note: note)
                .split(separator: "\n").map { String($0) }
                .filter { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { $0.replacingOccurrences(of: #"^\s*[-*+]\s+"#, with: "", options: .regularExpression) }
                .joined(separator: " ")
            return unfolded.isEmpty ? linked.displayTitle : unfolded
        }
    }

    static func replace(pattern: String, in text: String, with body: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = ""
        var last = text.startIndex
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let whole = Range(match.range, in: text) else { continue }
            result += text[last..<whole.lowerBound]
            var groups: [String] = [String(text[whole])]
            for index in 1..<match.numberOfRanges {
                groups.append(Range(match.range(at: index), in: text).map { String(text[$0]) } ?? "")
            }
            result += body(groups)
            last = whole.upperBound
        }
        result += text[last...]
        return result
    }

    static func escapeLaTeX(_ text: String) -> String {
        var out = ""
        for character in text {
            switch character {
            case "&", "%", "$", "#", "_", "{", "}": out += "\\" + String(character)
            case "~": out += "\\textasciitilde{}"
            case "^": out += "\\textasciicircum{}"
            default: out.append(character)
            }
        }
        return out
    }

    /// Escapes the text between `\cite{…}`, other commands and `$…$` maths,
    /// which are already LaTeX.
    static func escapeOutsideCommands(_ line: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\\[a-zA-Z]+\*?(\{[^}]*\})*|\$[^$]*\$"#) else { return escapeLaTeX(line) }
        var result = ""
        var last = line.startIndex
        for match in regex.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
            guard let range = Range(match.range, in: line) else { continue }
            result += escapeLaTeX(String(line[last..<range.lowerBound]))
            result += line[range]
            last = range.upperBound
        }
        result += escapeLaTeX(String(line[last...]))
        return result
    }
}
