import Foundation
import Testing
@testable import PaperCore

/// Tables in a note — and the answers the Portable build is held to
/// (`note-tables.json`, written by `Scripts/note-tables-fixture.swift`).
@Suite struct NoteTableTests {
    let note = """
    Before

    | Year | Factor (Z) |
    | ---- | ---------: |
    | 2023 | 5% |
    | 2024 | 7\\|8% |
    After
    """

    @Test func findsTheTableLines() {
        let blocks = NoteTable.blocks(in: note)
        #expect(blocks.count == 1)
        let text = (note as NSString).substring(with: blocks[0])
        #expect(text.hasPrefix("| Year"))
        #expect(text.hasSuffix("7\\|8% |"))
    }

    @Test func readsCellsAndAlignment() throws {
        let block = (note as NSString).substring(with: NoteTable.blocks(in: note)[0])
        let table = try #require(NoteTable.parse(block))
        #expect(table.header == ["Year", "Factor (Z)"])
        #expect(table.alignments == [.none, .right])
        #expect(table.rows == [["2023", "5%"], ["2024", "7|8%"]])
    }

    @Test func aLineWithABarIsNotATable() {
        #expect(NoteTable.blocks(in: "a | b\nno rule here").isEmpty)
        #expect(NoteTable.blocks(in: "| a | b |\n| --- |").isEmpty)
    }

    @Test func obsidiansTableBecomesMarkdown() {
        let html = """
        <meta charset="utf-8"><h3>5. 보조 테이블</h3><table><thead><tr><th>column</th><th>type</th><th>의미 추정</th></tr></thead>\
        <tbody><tr><td><code>ENGTYPE</code></td><td>VARCHAR</td><td>원 엔진 타입 문자열</td></tr>\
        <tr><td>types</td><td>VARCHAR</td><td>엔진 분류. 예: SSD</td></tr></tbody></table>
        """
        #expect(NoteTable.fromHTML(html) == """
        ### 5. 보조 테이블

        | column | type | 의미 추정 |
        | --- | --- | --- |
        | ENGTYPE | VARCHAR | 원 엔진 타입 문자열 |
        | types | VARCHAR | 엔진 분류. 예: SSD |
        """)
    }

    @Test func tabsBecomeATable() {
        #expect(NoteTable.fromTabSeparated("a\tb\n1\t2\n") == "| a | b |\n| --- | --- |\n| 1 | 2 |")
        #expect(NoteTable.fromTabSeparated("just one\tline") == nil)
        #expect(NoteTable.fromTabSeparated("a\tb\n1\t2\t3") == nil)
    }

    @Test func htmlWithoutATableIsLeftAlone() {
        #expect(NoteTable.fromHTML("<p>Hello <b>there</b></p>") == nil)
    }
}
