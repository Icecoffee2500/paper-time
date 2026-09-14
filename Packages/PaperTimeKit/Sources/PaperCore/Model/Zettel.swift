import Foundation

/// One note in the slip-box.
///
/// A Zettelkasten is a box of small notes that point at each other: each holds
/// one thought, carries an identifier that never changes, and earns its keep by
/// what it links to. That is what this is — a plain Markdown file with a short
/// header, kept in one folder for the whole library rather than filed under the
/// paper it came from, because a thought written while reading one paper is
/// usually about more than that paper.
///
/// ```markdown
/// ---
/// id: 202609081530
/// title: OpenVLA turns a VLM into a policy
/// paper: 4F3A1C08-…
/// tags: vla, robotics
/// created: 2026-09-08T15:30:00Z
/// ---
///
/// The action head is just detokenised text, which means …
/// See [[202609061204|Discretising continuous actions]].
/// ```
public struct Zettel: Identifiable, Hashable, Sendable {
    /// What a note is for. Most are notes. A *map* is a note whose body
    /// arranges other notes — links under headings — and is the home a
    /// note has instead of a folder. A *draft* is a piece of writing being
    /// assembled from notes and passages, on its way out of the box.
    public enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
        case note, map, draft
    }

    /// The identifier written on the note, and the name of its file: the
    /// minute it was made. It never changes, so links to it never break.
    public var id: String
    public var kind: Kind
    public var title: String
    public var body: String
    /// The paper being read when it was written, if there was one. A note with
    /// a source is a literature note; one without is a note of your own.
    public var paperID: UUID?
    public var created: Date
    public var modified: Date

    public init(
        id: String,
        kind: Kind = .note,
        title: String = "",
        body: String = "",
        paperID: UUID? = nil,
        created: Date = .now,
        modified: Date = .now
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.paperID = paperID
        self.created = created
        self.modified = modified
    }

    public var isEmpty: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A literature note is one written against a source.
    public var isLiterature: Bool { paperID != nil }

    /// A map's body read as an outline: its headings, and under each the
    /// notes it links to, in the order written. Links before the first
    /// heading fall under an unnamed section.
    public var outline: [MapSection] {
        var sections: [MapSection] = [MapSection(title: "", entries: [])]
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            if text.hasPrefix("#") {
                let title = text.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                sections.append(MapSection(title: title, entries: []))
                continue
            }
            let range = NSRange(text.startIndex..., in: text)
            for match in Self.linkPattern.matches(in: text, range: range) {
                guard let idRange = Range(match.range(at: 1), in: text) else { continue }
                let label = Range(match.range(at: 2), in: text).map { String(text[$0]) } ?? ""
                sections[sections.count - 1].entries.append(MapSection.Entry(id: String(text[idRange]), label: label))
            }
        }
        return sections.filter { !$0.entries.isEmpty || !$0.title.isEmpty }
    }

    // MARK: - What the text says

    /// The keywords written in the note as `#tag`.
    public var tags: [String] {
        Self.tagPattern
            .matches(in: body, range: NSRange(body.startIndex..., in: body))
            .compactMap { match in
                Range(match.range(at: 1), in: body).map { String(body[$0]) }
            }
            .reduced()
    }

    /// The notes this one points at, by identifier.
    public var links: [String] {
        Self.linkPattern
            .matches(in: body, range: NSRange(body.startIndex..., in: body))
            .compactMap { match in
                Range(match.range(at: 1), in: body).map { String(body[$0]) }
            }
            .reduced()
    }

    /// The first words of the body, in prose, for a row in a list.
    ///
    /// Everything that is notation rather than words comes out. A formula is
    /// the reason this exists: `$$\mathcal{L}_{\text{rollout}}$$` was being
    /// shown as the note's own title, because a row shows the body when there
    /// is no title and nothing here knew that a formula is not a sentence.
    /// Mathematics is an object in a note, like a picture, so it is left out
    /// of the summary of one rather than spelled.
    public var preview: String {
        var text = body

        for pattern in [
            // Formulas, display first: `$$…$$` before `$…$`, or the opening
            // pair of a display formula reads as one empty inline formula.
            #"\$\$[\s\S]*?\$\$"#,
            #"\$[^$\n]*?\$"#,
            // Fenced and inline code.
            #"```[\s\S]*?```"#,
            // Images, before links: an image is a link with a bang on it.
            #"!\[[^\]]*\]\([^)\s]*\)"#,
        ] {
            text = text.replacingOccurrences(of: pattern, with: " ",
                                             options: .regularExpression)
        }

        text = text
            .replacingOccurrences(of: #"\[\[([^\]|]+)\|([^\]]*)\]\]"#, with: "$2",
                                  options: .regularExpression)
            .replacingOccurrences(of: #"\[\[([^\]|]+)\]\]"#, with: "$1",
                                  options: .regularExpression)
            .replacingOccurrences(of: #"\[([^\]\n]*)\]\([^)\s]*\)"#, with: "$1",
                                  options: .regularExpression)

        return text
            .split(separator: "\n")
            .map { line in
                var text = String(line)
                while text.hasPrefix("#") { text.removeFirst() }
                while text.hasPrefix(">") { text.removeFirst() }
                // List markers, which are punctuation standing in for layout.
                text = text.replacingOccurrences(
                    of: #"^\s*([-*+]|\d+\.)\s+"#, with: "", options: .regularExpression
                )
                return text
                    .replacingOccurrences(of: "**", with: "")
                    .replacingOccurrences(of: "`", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            // Taking things out leaves gaps, and punctuation that was holding
            // hands with what was taken: "a formula, $x$, should" came out as
            // "a formula, , should".
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"([,;:])(\s*[,;:])+"#, with: "$1",
                                  options: .regularExpression)
            .replacingOccurrences(of: #"\s+([,.;:!?])"#, with: "$1",
                                  options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// What a row shows under the title.
    ///
    /// Not the preview: for a note with no title of its own the title *is* the
    /// first of the preview, and a row that repeats it says one thing twice.
    /// This is what is left after it — the way Notes shows a first line and
    /// then the rest.
    public var previewBody: String {
        let full = preview
        let shown = displayTitle
        guard title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              full.hasPrefix(shown)
        else { return full }
        return String(full.dropFirst(shown.count))
            .trimmingCharacters(in: .whitespaces)
    }

    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let firstLine = preview.prefix(60).trimmingCharacters(in: .whitespaces)
        if !firstLine.isEmpty { return firstLine }
        // A note can be a formula and nothing else, and now that formulas are
        // left out of the preview there is nothing left to name it with. Say
        // so rather than showing the notation.
        return body.contains("$") ? "Formula" : "Untitled Note"
    }

    /// How this note is written into another one.
    public var linkMarkdown: String { "[[\(id)|\(displayTitle)]]" }

    // MARK: - Identifiers

    /// Identifiers are the minute the note was made, which is short enough to
    /// type and long enough to stay unique in a box one person writes.
    public static func makeID(at date: Date = .now, avoiding taken: Set<String>) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmm"
        formatter.timeZone = .current
        let base = formatter.string(from: date)
        if !taken.contains(base) { return base }
        for suffix in 1...99 {
            let candidate = "\(base)-\(suffix)"
            if !taken.contains(candidate) { return candidate }
        }
        return "\(base)-\(UUID().uuidString.prefix(4))"
    }

    static let linkPattern = try! NSRegularExpression(
        pattern: #"\[\[([^\]|\n]+)(?:\|([^\]\n]*))?\]\]"#
    )
    static let tagPattern = try! NSRegularExpression(
        pattern: #"(?:^|\s)#([\p{L}\p{N}][\p{L}\p{N}_/-]*)"#
    )
}

/// One heading of a map and the notes under it.
public struct MapSection: Hashable, Sendable {
    public struct Entry: Hashable, Sendable {
        public let id: String
        public let label: String
    }

    public var title: String
    public var entries: [Entry]

    public init(title: String, entries: [Entry]) {
        self.title = title
        self.entries = entries
    }
}

private extension [String] {
    /// Keeps the first of each, in the order they were written.
    func reduced() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}
