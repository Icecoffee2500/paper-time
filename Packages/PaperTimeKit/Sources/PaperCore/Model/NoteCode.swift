import Foundation

/// Fenced code in a note:
///
///     ```python
///     i = 1
///     ```
///
/// The note is read a line at a time, and fenced code is the one thing
/// whose lines mean nothing on their own: inside a fence `# comment` is not a
/// heading, `- x` is not a bullet and `$x$` is not mathematics. So the fences
/// are found first, over the whole note, and every line between two of them
/// is code. The rules are CommonMark's, as Latex Suite reads them
/// (`LSMarkdown.fencedCode`): a fence is three or more backticks or tildes
/// after at most three spaces; a backtick fence's info string has no
/// backtick in it; the fence is closed by a line of the same character, at
/// least as long, and nothing after it but spaces; a fence never closed runs
/// to the end of the note. Offsets are UTF-16. The Portable build is
/// `shared/noteCode.ts`, held to the same answers
/// (`Tests/PaperCoreTests/Fixtures/note-code.json`).
public enum NoteCode {
    public struct Block: Equatable, Sendable {
        /// From the start of the opening fence's line to the end of the
        /// closing fence's line — or of the note, when it is never closed.
        public var range: NSRange
        /// The opening fence's line, without its newline.
        public var open: NSRange
        /// The closing fence's line; nil when the code runs to the end.
        public var close: NSRange?
        /// The lines of code between, each without its newline.
        public var lines: [NSRange]
        /// The info string's first word — `python` — as written; empty when
        /// there is none.
        public var language: String

        public init(range: NSRange, open: NSRange, close: NSRange?, lines: [NSRange], language: String) {
            self.range = range
            self.open = open
            self.close = close
            self.lines = lines
            self.language = language
        }
    }

    /// Every fenced block in the text, in order.
    public static func blocks(in text: String) -> [Block] {
        let whole = text as NSString
        // Lines with no fence character in them cannot open one: most of a
        // note is passed over on that alone.
        guard text.utf16.contains(96) || text.utf16.contains(126) else { return [] }
        let lines = NoteMath.lineRanges(of: whole)
        var result: [Block] = []
        var index = 0
        while index < lines.count {
            guard let fence = opening(whole.substring(with: lines[index])) else {
                index += 1
                continue
            }
            var body: [NSRange] = []
            var close: NSRange?
            var next = index + 1
            while next < lines.count {
                if closes(whole.substring(with: lines[next]), fence: fence) {
                    close = lines[next]
                    next += 1
                    break
                }
                body.append(lines[next])
                next += 1
            }
            let start = lines[index].location
            let last = close ?? body.last ?? lines[index]
            result.append(Block(range: NSRange(location: start, length: NSMaxRange(last) - start),
                                open: lines[index], close: close, lines: body, language: fence.language))
            index = next
        }
        return result
    }

    /// The code a block holds: its lines, as written, one to a line.
    public static func code(of block: Block, in text: NSString) -> String {
        block.lines.map { text.substring(with: $0) }.joined(separator: "\n")
    }

    /// An opening fence: its character, how long it is, and the language
    /// its info string names.
    public struct Fence: Equatable, Sendable {
        public var character: Character
        public var length: Int
        public var language: String
    }

    /// The fence a line opens, if it opens one.
    public static func opening(_ line: String) -> Fence? {
        // A note written on Windows ends its lines in "\r\n"; the line is
        // read up to the "\n", and the "\r" is not part of the info string.
        let characters = Array(line.hasSuffix("\r") ? String(line.dropLast()) : line)
        var index = 0
        while index < characters.count, characters[index] == " ", index < 3 { index += 1 }
        guard index < characters.count, characters[index] == "`" || characters[index] == "~" else { return nil }
        let mark = characters[index]
        var end = index
        while end < characters.count, characters[end] == mark { end += 1 }
        guard end - index >= 3 else { return nil }
        let info = String(characters[end...])
        // A backtick fence's info string has no backtick in it: ```x``` on a
        // line is code in a sentence, not a fence.
        if mark == "`", info.contains("`") { return nil }
        return Fence(character: mark, length: end - index, language: language(of: info))
    }

    /// Whether a line closes a fence: the same character, at least as long,
    /// after at most three spaces, and nothing but spaces after it.
    public static func closes(_ line: String, fence: Fence) -> Bool {
        let characters = Array(line)
        var index = 0
        while index < characters.count, characters[index] == " ", index < 3 { index += 1 }
        var end = index
        while end < characters.count, characters[end] == fence.character { end += 1 }
        guard end - index >= fence.length else { return false }
        return characters[end...].allSatisfy { $0 == " " || $0 == "\t" || $0 == "\r" }
    }

    /// The first word of an info string, without the braces and the dot some
    /// writers put round it (`{python}`, `{.python}`).
    static func language(of info: String) -> String {
        let word = info.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? ""
        var trimmed = Substring(word)
        if trimmed.hasPrefix("{") { trimmed = trimmed.dropFirst() }
        if trimmed.hasSuffix("}") { trimmed = trimmed.dropLast() }
        if trimmed.hasPrefix(".") { trimmed = trimmed.dropFirst() }
        return String(trimmed)
    }

    /// What a language is called over its code: `py` is Python, `cpp` is
    /// C++. A language not on the list is shown as written.
    public static func displayName(of language: String) -> String {
        names[language.lowercased()] ?? language
    }

    private static let names: [String: String] = {
        let groups: [(String, [String])] = [
            ("Python", ["python", "py", "python3", "py3"]),
            ("JavaScript", ["javascript", "js", "jsx", "mjs", "cjs"]),
            ("TypeScript", ["typescript", "ts", "tsx", "mts", "cts"]),
            ("Swift", ["swift"]),
            ("C", ["c", "h"]),
            ("C++", ["cpp", "c++", "cc", "cxx", "hpp", "hh", "hxx"]),
            ("C#", ["csharp", "cs", "c#"]),
            ("Objective-C", ["objectivec", "objective-c", "objc", "obj-c", "m", "mm"]),
            ("Java", ["java"]),
            ("Kotlin", ["kotlin", "kt", "kts"]),
            ("Scala", ["scala"]),
            ("Rust", ["rust", "rs"]),
            ("Go", ["go", "golang"]),
            ("Shell", ["bash", "sh", "shell", "zsh", "console", "shellsession"]),
            ("PowerShell", ["powershell", "ps1", "pwsh"]),
            ("JSON", ["json", "jsonc", "json5"]),
            ("YAML", ["yaml", "yml"]),
            ("TOML", ["toml"]),
            ("INI", ["ini", "cfg", "conf"]),
            ("XML", ["xml", "plist", "svg"]),
            ("HTML", ["html", "htm", "xhtml"]),
            ("CSS", ["css"]),
            ("SCSS", ["scss", "sass"]),
            ("SQL", ["sql", "psql", "mysql", "sqlite"]),
            ("R", ["r"]),
            ("MATLAB", ["matlab"]),
            ("Julia", ["julia", "jl"]),
            ("LaTeX", ["latex", "tex"]),
            ("Markdown", ["markdown", "md"]),
            ("Ruby", ["ruby", "rb"]),
            ("PHP", ["php"]),
            ("Lua", ["lua"]),
            ("Perl", ["perl", "pl"]),
            ("Haskell", ["haskell", "hs"]),
            ("Dart", ["dart"]),
            ("Diff", ["diff", "patch"]),
            ("Dockerfile", ["dockerfile", "docker"]),
            ("Makefile", ["makefile", "make", "mk"]),
            ("Text", ["text", "txt", "plaintext", "plain"]),
        ]
        var table: [String: String] = [:]
        for (name, aliases) in groups { for alias in aliases { table[alias] = name } }
        return table
    }()
}
