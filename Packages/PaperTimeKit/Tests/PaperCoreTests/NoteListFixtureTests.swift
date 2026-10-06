import Foundation
import Testing
@testable import PaperCore

/// `Fixtures/note-lists.json` is what this code answers
/// (`Scripts/note-lists-fixture.swift`); the Portable build's tests read the
/// same file. A change to `NoteList` that is not written back here fails.
@Suite struct NoteListFixtureTests {
    struct Counted: Decodable { var note: String; var numbers: [[Int]] }
    struct Shift: Decodable {
        struct Edit: Decodable { var range: [Int]; var replacement: String; var caret: Int; var after: String }
        var note: String
        var caret: Int
        var by: Int
        var edit: Edit?
    }
    struct File: Decodable { var numbers: [Counted]; var shifts: [Shift] }

    func fixture() throws -> File {
        let url = try #require(Bundle.module.url(forResource: "note-lists", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
    }

    @Test func itemsShowTheNumbersTheFileSays() throws {
        for item in try fixture().numbers {
            let shown = NoteList.numbers(in: item.note).sorted { $0.key < $1.key }.map { [$0.key, $0.value] }
            #expect(shown == item.numbers, "\(item.note.debugDescription)")
        }
    }

    @Test func tabAndShiftTabDoWhatTheFileSays() throws {
        for item in try fixture().shifts {
            let edit = NoteList.shift(in: item.note, caret: item.caret, by: item.by)
            #expect(edit.map { [$0.range.location, $0.range.length] } == item.edit?.range, "\(item.note.debugDescription)")
            #expect(edit?.replacement == item.edit?.replacement, "\(item.note.debugDescription)")
            #expect(edit?.caret == item.edit?.caret, "\(item.note.debugDescription)")
        }
    }

    /// The case a reader met: Tab on the second item of a list starts a list
    /// under the first — «a.», not «b.» — and the caret stays where it was.
    @Test func anItemMovedInStartsAtOne() throws {
        let note = "1. original model\n2. the whole gradient"
        let edit = try #require(NoteList.shift(in: note, caret: (note as NSString).length, by: 1))
        let after = (note as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        #expect(after == "1. original model\n  1. the whole gradient")
        #expect(edit.caret == (after as NSString).length)
        // What is already written that way is shown as if it were.
        let messy = "1. original\n  2. the whole\n  3. the retain\n2. next"
        let shown = NoteList.numbers(in: messy).sorted { $0.key < $1.key }.map(\.value)
        #expect(shown == [1, 1, 2, 2])
    }
}
