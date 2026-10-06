// The answers the Portable build's `shared/noteCode.ts` is held to: the
// Mac's own `NoteCode` on a set of notes and fence lines.
//
//     swiftc -O -parse-as-library \
//       Packages/PaperTimeKit/Sources/PaperCore/Model/NoteMath.swift \
//       Packages/PaperTimeKit/Sources/PaperCore/Model/NoteCode.swift \
//       Scripts/note-code-fixture.swift -o /tmp/note-code-fixture
//     /tmp/note-code-fixture > Packages/PaperTimeKit/Tests/PaperCoreTests/Fixtures/note-code.json
//
// Change NoteCode and run this again; both builds' tests read the file.
import Foundation

@main
enum NoteCodeFixture {
    static let notes = [
        "```python\ni = 1\nprint(i)\n```",
        "Before\n```\nplain\n```\nAfter",
        "```js\nconst a = 1\n\n// blank above\n```\ntext\n~~~bash\necho hi\n~~~",
        "````md\n```\nnested fence, not a close\n```\n````",
        "```python\nnever closed\n# not a heading\n- not a bullet",
        "  ```swift\n  let x = 1\n  ```",
        "    ```indented four is not a fence\n```",
        "inline ```code``` is not a fence\n```{.python}\nx\n```",
        "```c++ extra words\nint main() {}\n```   \nafter",
        "```\r\nwindows\r\n```\r\nend",
        "~~~\n```\nstill code\n~~~",
        "```\n```",
        "no fences at all\n$$x$$",
        "```python\n\n```",
        "한글 앞\n```py\n# 한글 주석\nprint(\"안녕\")\n```\n뒤",
    ]

    static let fences = [
        "```", "```python", "  ```py", "   ```", "    ```", "``", "~~~ ruby", "```a`b", "`````", "```{r}", "``` swift  ",
    ]

    static let languages = [
        "python", "py", "JS", "ts", "swift", "c", "cpp", "c++", "cs", "objc", "bash", "sh", "zsh", "json", "yml",
        "html", "tex", "md", "rb", "go", "rust", "text", "unknownlang", "",
    ]

    static func main() throws {
        func range(_ r: NSRange) -> [Int] { [r.location, r.location + r.length] }
        var notes: [[String: Any]] = []
        for text in Self.notes {
            let blocks = NoteCode.blocks(in: text).map { block -> [String: Any] in
                var item: [String: Any] = [
                    "range": range(block.range), "open": range(block.open),
                    "lines": block.lines.map(range), "language": block.language,
                    "code": NoteCode.code(of: block, in: text as NSString),
                ]
                item["close"] = block.close.map(range) ?? NSNull()
                return item
            }
            notes.append(["text": text, "blocks": blocks])
        }
        let fences = Self.fences.map { line -> [String: Any] in
            guard let fence = NoteCode.opening(line) else { return ["line": line, "fence": NSNull()] }
            return ["line": line, "fence": ["character": String(fence.character), "length": fence.length, "language": fence.language]]
        }
        let names = Self.languages.map { ["language": $0, "name": NoteCode.displayName(of: $0)] }
        let data = try JSONSerialization.data(withJSONObject: ["notes": notes, "fences": fences, "names": names],
                                              options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
