import Foundation
import Testing
@testable import PaperCore

/// `Fixtures/note-tables.json` is what this code answers
/// (`Scripts/note-tables-fixture.swift`); the Portable build's tests read the
/// same file. A change to `NoteTable` that is not written back here fails.
@Suite struct NoteTableFixtureTests {
    struct Parsed: Decodable { var header: [String]; var alignments: [String]; var rows: [[String]] }
    struct Note: Decodable { var text: String; var blocks: [[Int]]; var tables: [Parsed?]; var markdown: [String?] }
    struct Paste: Decodable { var html: String; var markdown: String? }
    struct Rows: Decodable { var text: String; var markdown: String? }
    struct File: Decodable { var notes: [Note]; var pastes: [Paste]; var rows: [Rows] }

    func fixture() throws -> File {
        let url = try #require(Bundle.module.url(forResource: "note-tables", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
    }

    @Test func notesReadAsTheFileSays() throws {
        for note in try fixture().notes {
            let blocks = NoteTable.blocks(in: note.text)
            #expect(blocks.map { [$0.location, $0.location + $0.length] } == note.blocks)
            for (block, expected) in zip(blocks, note.markdown) {
                #expect(NoteTable.parse((note.text as NSString).substring(with: block)).map(NoteTable.markdown) == expected)
            }
        }
    }

    @Test func pastesBecomeWhatTheFileSays() throws {
        let file = try fixture()
        for paste in file.pastes { #expect(NoteTable.fromHTML(paste.html) == paste.markdown) }
        for rows in file.rows { #expect(NoteTable.fromTabSeparated(rows.text) == rows.markdown) }
    }
}
