import Foundation

/// One note a reader wrote about a paper.
///
/// A paper collects notes the way a notebook does — several of them, each
/// about whatever the reader was thinking at the time — and each one is its
/// own Markdown file beside the record, readable without this app.
public struct PaperNote: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var text: String
    public var modified: Date

    public init(id: UUID = UUID(), text: String = "", modified: Date = .now) {
        self.id = id
        self.text = text
        self.modified = modified
    }

    public var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The first line, as a person would read it: without the Markdown that
    /// makes it a heading and without the address inside a link.
    public var title: String {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let plain = Self.plain(String(line))
            if !plain.isEmpty { return plain }
        }
        return "New Note"
    }

    /// What follows the title, for the second line of a row in the list.
    public var preview: String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { Self.plain(String($0)) }
            .drop { $0.isEmpty }
        if !lines.isEmpty { lines = lines.dropFirst() }
        return lines.filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func plain(_ line: String) -> String {
        var text = line
        while text.hasPrefix("#") { text.removeFirst() }
        text = text.replacingOccurrences(
            of: #"\[([^\]\n]*)\]\([^)\s]*\)"#, with: "$1",
            options: .regularExpression
        )
        text = text.replacingOccurrences(of: "**", with: "")
        return text.trimmingCharacters(in: .whitespaces)
    }
}
