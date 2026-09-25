import Foundation

/// A note's Markdown as words, for cutting into passages.
///
/// A note is embedded by what it says, and Markdown is not what it says: a
/// heading's `##`, a link's `[[202609081530|`, the `$` around a formula are
/// notation for the renderer, and the model would spend tokens on them. So
/// the notation comes out and the words stay — *every* word, the formula's
/// letters included, because a note that is one formula still means
/// something and a passage with nothing in it has no vector to give.
///
/// Light on purpose. The passages are keyed by their text, so the rule
/// here is part of the cache's key: a change to it re-embeds every note in
/// every library. The Portable build has the same rule in
/// `shared/semantic/noteText.ts`, and the two are held to the same
/// fixtures.
public enum NoteText {
    /// The words of a note, with the Markdown taken out and the white space
    /// left as it was (the chunker reads any run of it as one break).
    public static func plain(_ markdown: String) -> String {
        var text = markdown
        for (pattern, replacement) in Self.replacements {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                var line = String(line)
                // What stands at the start of a line to say what kind of
                // line it is: a heading's hashes, a quotation's mark, a
                // list's bullet or number.
                line = line.replacingOccurrences(of: #"^\s*(#{1,6}\s+|>\s*)+"#, with: "", options: .regularExpression)
                line = line.replacingOccurrences(of: #"^\s*([-*+]|\d+[.)])\s+"#, with: "", options: .regularExpression)
                return line
            }
            .joined(separator: "\n")
    }

    /// In this order: the fences before the inline code they contain, the
    /// display formula before the inline one (or `$$` reads as an empty
    /// inline formula), the image before the link it is a link with a bang
    /// on.
    private static let replacements: [(String, String)] = [
        // Front matter, if a file's header was handed over with its body.
        (#"\A---\n[\s\S]*?\n---\n"#, ""),
        // Fenced code: the fences go, the code stays.
        (#"```[^\n]*\n?"#, " "),
        // Formulas: the dollars go, the mathematics stays.
        (#"\$\$"#, " "),
        (#"\$"#, " "),
        // Inline code.
        (#"`"#, ""),
        // Images, then links: the words shown stay, the address goes.
        (#"!\[([^\]]*)\]\([^)\s]*\)"#, "$1"),
        (#"\[\[([^\]|\n]+)\|([^\]\n]*)\]\]"#, "$2"),
        (#"\[\[([^\]|\n]+)\]\]"#, "$1"),
        (#"\[([^\]\n]*)\]\([^)\s]*\)"#, "$1"),
        // Emphasis marks, when they stand in pairs around something.
        (#"\*\*([^*\n]+)\*\*"#, "$1"),
        (#"__([^_\n]+)__"#, "$1"),
        (#"(?<![\p{L}\p{N}])\*([^*\n]+)\*(?![\p{L}\p{N}])"#, "$1"),
        (#"(?<![\p{L}\p{N}])_([^_\n]+)_(?![\p{L}\p{N}])"#, "$1"),
        // A rule, which is not a word.
        (#"(?m)^\s*([-*_])\s*\1\s*\1[\s\-*_]*$"#, ""),
        // Tags keep their word: `#robotics` is about robotics.
        (#"(?<=^|\s)#(?=[\p{L}\p{N}])"#, ""),
    ]
}
