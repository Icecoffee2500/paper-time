import Foundation
import Testing
@testable import PaperCore

/// `Fixtures/note-code.json` is what this code answers
/// (`Scripts/note-code-fixture.swift`); the Portable build's tests read the
/// same file. A change to `NoteCode` that is not written back here fails.
@Suite struct NoteCodeFixtureTests {
    struct Block: Decodable { var range: [Int]; var open: [Int]; var close: [Int]?; var lines: [[Int]]; var language: String; var code: String }
    struct Note: Decodable { var text: String; var blocks: [Block] }
    struct FenceAnswer: Decodable { var character: String; var length: Int; var language: String }
    struct Fence: Decodable { var line: String; var fence: FenceAnswer? }
    struct Name: Decodable { var language: String; var name: String }
    struct File: Decodable { var notes: [Note]; var fences: [Fence]; var names: [Name] }

    func fixture() throws -> File {
        let url = try #require(Bundle.module.url(forResource: "note-code", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
    }

    func span(_ range: NSRange) -> [Int] { [range.location, range.location + range.length] }

    @Test func notesReadAsTheFileSays() throws {
        for note in try fixture().notes {
            let blocks = NoteCode.blocks(in: note.text)
            #expect(blocks.count == note.blocks.count, "\(note.text.debugDescription)")
            for (block, expected) in zip(blocks, note.blocks) {
                #expect(span(block.range) == expected.range)
                #expect(span(block.open) == expected.open)
                #expect(block.close.map(span) == expected.close)
                #expect(block.lines.map(span) == expected.lines)
                #expect(block.language == expected.language)
                #expect(NoteCode.code(of: block, in: note.text as NSString) == expected.code)
            }
        }
    }

    @Test func fencesAndNamesAreWhatTheFileSays() throws {
        let file = try fixture()
        for fence in file.fences {
            let made = NoteCode.opening(fence.line)
            #expect(made.map { String($0.character) } == fence.fence?.character, "\(fence.line.debugDescription)")
            #expect(made?.length == fence.fence?.length)
            #expect(made?.language == fence.fence?.language)
        }
        for name in file.names { #expect(NoteCode.displayName(of: name.language) == name.name) }
    }
}
