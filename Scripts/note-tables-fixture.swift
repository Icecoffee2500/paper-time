// The answers the Portable build's `shared/noteTable.ts` is held to: the
// Mac's own `NoteTable` on a set of notes, pastes and rows.
//
//     swiftc -O -parse-as-library \
//       Packages/PaperTimeKit/Sources/PaperCore/Model/NoteMath.swift \
//       Packages/PaperTimeKit/Sources/PaperCore/Model/NoteTable.swift \
//       Scripts/note-tables-fixture.swift -o /tmp/note-tables-fixture
//     /tmp/note-tables-fixture > Packages/PaperTimeKit/Tests/PaperCoreTests/Fixtures/note-tables.json
//
// Change NoteTable and run this again; both builds' tests read the file.
import Foundation

@main
enum NoteTablesFixture {
    static let notes = [
        "Before\n\n| Year | Factor (Z) |\n| ---- | ---------: |\n| 2023 | 5% |\n| 2024 | 7\\|8% |\nAfter",
        "| a | b |\n|:-|:-:|\n| 1 | 2 |\n| 3 |\n\n| c |\n| --- |\n| 4 |",
        "a | b\n--- | ---\n1 | 2",
        "| a | b |\n| --- |\n| 1 | 2 |",
        "no table | here\njust words",
        "| 한글 | 표 |\n| --- | --- |\n| 셀 `code` | **굵게** |\n\ntext",
        "|x|\n|-|\n",
        "  | indented | table |\n  | --- | --- |\n  | yes | no |",
        "| a\\\\ | b\\| |\n| --- | --- |\n| \\x | \\\\| |",
    ]

    static let pastes = [
        "<meta charset=\"utf-8\"><h3>5. 보조 테이블</h3><h4><code>engine_info</code></h4><table><thead><tr><th>column</th><th>type</th><th>의미 추정</th></tr></thead><tbody><tr><td><code>ENGTYPE</code></td><td><code>VARCHAR</code></td><td>원 엔진 타입 문자열</td></tr><tr><td>types</td><td>VARCHAR</td><td>엔진 분류. 예: <code>SSD</code></td></tr></tbody></table>",
        "<p>Here is the table:</p>\n<table>\n  <tr><th>Model</th><th>Params</th></tr>\n  <tr><td>GPT&#8209;4</td><td>&gt; 1T &amp; more</td></tr>\n  <tr><td>A | B</td><td>line<br>two</td></tr>\n</table>\n<p>That&#39;s all &mdash; <b>done</b>.</p>",
        "<table><tr><td>only</td></tr></table>",
        "<table><tr><td>a</td><td>b</td><td>c</td></tr><tr><td>1</td></tr></table>",
        "<!-- x --><style>td{}</style><table><tr><td>styled</td><td>&#x1F600;</td></tr><tr><td>&nbsp;x&nbsp;</td><td>&unknown;</td></tr></table>",
        "<ul><li>one</li><li>two</li></ul><table><tr><td>h</td></tr><tr><td>r</td></tr></table>",
        "<p>no table here</p>",
        "<table><tr><td><table><tr><td>inner</td></tr></table></td><td>outer</td></tr><tr><td>x</td><td>y</td></tr></table>",
    ]

    static let rows = [
        "Year\tReduction Factor (Z)\n2023\t5%\n2024\t7%\n",
        "a\tb\r\n1\t2",
        "one line\tonly",
        "a\tb\n1\t2\t3",
        "a\n1",
        "  a \t b \n\n 1\t2 ",
    ]

    static func main() {
        struct Parsed: Encodable { var header: [String]; var alignments: [String]; var rows: [[String]] }
        struct Note: Encodable { var text: String; var blocks: [[Int]]; var tables: [Parsed?]; var markdown: [String?] }
        struct Paste: Encodable { var html: String; var markdown: String? }
        struct Rows: Encodable { var text: String; var markdown: String? }
        struct File: Encodable { var notes: [Note]; var pastes: [Paste]; var rows: [Rows] }

        let noteCases = notes.map { text -> Note in
            let blocks = NoteTable.blocks(in: text)
            let parsed = blocks.map { NoteTable.parse((text as NSString).substring(with: $0)) }
            return Note(
                text: text,
                blocks: blocks.map { [$0.location, $0.location + $0.length] },
                tables: parsed.map { $0.map { Parsed(header: $0.header, alignments: $0.alignments.map(\.rawValue), rows: $0.rows) } },
                markdown: parsed.map { $0.map(NoteTable.markdown) }
            )
        }
        let file = File(
            notes: noteCases,
            pastes: pastes.map { Paste(html: $0, markdown: NoteTable.fromHTML($0)) },
            rows: rows.map { Rows(text: $0, markdown: NoteTable.fromTabSeparated($0)) }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        FileHandle.standardOutput.write(try! encoder.encode(file))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
