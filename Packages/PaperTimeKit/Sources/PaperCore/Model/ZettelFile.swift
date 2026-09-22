import Foundation

/// The text of a note on disk: a small header, then the note.
///
/// The header is the plainest thing that other tools already read — the same
/// `---` block Obsidian, Zettlr and every static site generator understand —
/// so a slip-box written here can be opened, searched and kept anywhere.
public enum ZettelFile {

    public static func text(of note: Zettel) -> String {
        var header = "---\n"
        header += "id: \(note.id)\n"
        if note.kind != .note { header += "kind: \(note.kind.rawValue)\n" }
        if !note.title.isEmpty { header += "title: \(note.title)\n" }
        if let paperID = note.paperID { header += "paper: \(paperID.uuidString)\n" }
        let tags = note.tags
        if !tags.isEmpty { header += "tags: \(tags.joined(separator: ", "))\n" }
        header += "created: \(note.created.formatted(.iso8601))\n"
        header += "---\n\n"
        return header + note.body
    }

    public static func note(from text: String, id fallbackID: String, modified: Date) -> Zettel {
        var fields: [String: String] = [:]
        var body = text

        if text.hasPrefix("---\n"), let end = range(ofClosingFenceIn: text) {
            let header = String(text[text.index(text.startIndex, offsetBy: 4)..<end.lowerBound])
            for line in header.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...]
                    .trimmingCharacters(in: .whitespaces)
                fields[key] = value
            }
            body = String(text[end.upperBound...])
            while body.hasPrefix("\n") { body.removeFirst() }
        }

        return Zettel(
            id: fields["id"] ?? fallbackID,
            kind: fields["kind"].flatMap(Zettel.Kind.init(rawValue:)) ?? .note,
            title: fields["title"] ?? "",
            body: body,
            paperID: fields["paper"].flatMap(UUID.init(uuidString:)),
            created: fields["created"].flatMap {
                try? Date($0, strategy: .iso8601)
            } ?? modified,
            modified: modified
        )
    }

    /// The `---` that closes the header, which is only a fence when it sits on
    /// a line of its own.
    private static func range(ofClosingFenceIn text: String) -> Range<String.Index>? {
        var search = text.index(text.startIndex, offsetBy: 4)..<text.endIndex
        while let found = text.range(of: "\n---", range: search) {
            let after = found.upperBound
            if after == text.endIndex || text[after] == "\n" || text[after] == "\r" {
                return found
            }
            search = after..<text.endIndex
        }
        return nil
    }
}
