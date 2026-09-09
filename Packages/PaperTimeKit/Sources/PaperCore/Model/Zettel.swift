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
    /// The identifier written on the note, and the name of its file: the
    /// minute it was made. It never changes, so links to it never break.
    public var id: String
    public var title: String
    public var body: String
    /// The paper being read when it was written, if there was one. A note with
    /// a source is a literature note; one without is a note of your own.
    public var paperID: UUID?
    public var created: Date
    public var modified: Date

    public init(
        id: String,
        title: String = "",
        body: String = "",
        paperID: UUID? = nil,
        created: Date = .now,
        modified: Date = .now
    ) {
        self.id = id
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

    /// The first words of the body, for a row in a list.
    public var preview: String {
        body
            .replacingOccurrences(of: #"\[\[([^\]|]+)\|([^\]]*)\]\]"#, with: "$2",
                                  options: .regularExpression)
            .replacingOccurrences(of: #"\[([^\]\n]*)\]\([^)\s]*\)"#, with: "$1",
                                  options: .regularExpression)
            .split(separator: "\n")
            .map { line in
                var text = String(line)
                while text.hasPrefix("#") { text.removeFirst() }
                while text.hasPrefix(">") { text.removeFirst() }
                return text
                    .replacingOccurrences(of: "**", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let firstLine = preview.prefix(60)
        return firstLine.isEmpty ? "Untitled Note" : String(firstLine)
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

private extension [String] {
    /// Keeps the first of each, in the order they were written.
    func reduced() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}
