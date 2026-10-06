import Foundation
import Testing
@testable import PaperCore

/// `Fixtures/note-lists.json` is what this code answers
/// (`Scripts/note-lists-fixture.swift`); the Portable build's tests read the
/// same file. A change to `NoteList` that is not written back here fails.
@Suite struct NoteListFixtureTests {
    struct Counted: Decodable { var note: String; var numbers: [[Int]] }
    struct Written: Decodable { var range: [Int]; var replacement: String; var caret: Int; var length: Int?; var after: String }
    struct Keyed: Decodable {
        var note: String
        var caret: Int
        var length: Int?
        var by: Int?
        var folded: Bool?
        var edit: Written?
    }
    struct File: Decodable {
        var numbers: [Counted]
        var shifts: [Keyed]
        var returns: [Keyed]
        var backspaces: [Keyed]
        var deletes: [Keyed]
        var shortcuts: [Keyed]
    }

    func fixture() throws -> File {
        let url = try #require(Bundle.module.url(forResource: "note-lists", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
    }

    /// That an edit is the one the file has, and leaves the note it says.
    func check(_ edit: NoteList.Edit?, _ item: Keyed) {
        let label = (item.note as NSString).replacingCharacters(in: NSRange(location: item.caret, length: 0), with: "|").debugDescription
        #expect(edit.map { [$0.range.location, $0.range.length] } == item.edit?.range, "\(label)")
        #expect(edit?.replacement == item.edit?.replacement, "\(label)")
        #expect(edit?.caret == item.edit?.caret, "\(label)")
        #expect((edit?.length ?? 0) == (item.edit?.length ?? 0), "\(label)")
        if let edit, let after = item.edit?.after {
            #expect((item.note as NSString).replacingCharacters(in: edit.range, with: edit.replacement) == after, "\(label)")
        }
    }

    @Test func itemsShowTheNumbersTheFileSays() throws {
        for item in try fixture().numbers {
            let shown = NoteList.numbers(in: item.note).sorted { $0.key < $1.key }.map { [$0.key, $0.value] }
            #expect(shown == item.numbers, "\(item.note.debugDescription)")
        }
    }

    @Test func tabAndShiftTabDoWhatTheFileSays() throws {
        for item in try fixture().shifts {
            let selection = NSRange(location: item.caret, length: item.length ?? 0)
            check(NoteList.shift(in: item.note, selection: selection, by: item.by ?? 1), item)
        }
    }

    @Test func returnDoesWhatTheFileSays() throws {
        for item in try fixture().returns {
            check(NoteList.newLine(in: item.note, caret: item.caret, folded: item.folded ?? false), item)
        }
    }

    @Test func backspaceDeleteAndTheShortcutsDoWhatTheFileSays() throws {
        let file = try fixture()
        for item in file.backspaces { check(NoteList.backspace(in: item.note, caret: item.caret), item) }
        for item in file.deletes { check(NoteList.deleteForward(in: item.note, caret: item.caret), item) }
        for item in file.shortcuts { check(NoteList.shortcut(in: item.note, caret: item.caret), item) }
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

    /// A reader's list, typed a key at a time: every Return, Tab and empty
    /// Return is one edit, and the file is numbered as the note is shown at
    /// every step — never «2.» where «b.» stands.
    @Test func aListTypedKeyByKeyStaysNumberedAsShown() throws {
        var note = ""
        var caret = 0
        func type(_ words: String) {
            note = (note as NSString).replacingCharacters(in: NSRange(location: caret, length: 0), with: words)
            caret += (words as NSString).length
        }
        func apply(_ edit: NoteList.Edit?) throws {
            let edit = try #require(edit)
            note = (note as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
            caret = edit.caret
        }
        type("1. one")
        try apply(NoteList.newLine(in: note, caret: caret))
        try apply(NoteList.shift(in: note, caret: caret, by: 1))
        type("two")
        try apply(NoteList.newLine(in: note, caret: caret))
        try apply(NoteList.shift(in: note, caret: caret, by: 1))
        for word in ["three", "four", "five"] {
            type(word)
            try apply(NoteList.newLine(in: note, caret: caret))
        }
        // The empty «iv.» steps out to «b.», then to «2.», then ends the list.
        try apply(NoteList.newLine(in: note, caret: caret))
        try apply(NoteList.newLine(in: note, caret: caret))
        #expect(note == "1. one\n  1. two\n    1. three\n    2. four\n    3. five\n2. ")
        try apply(NoteList.newLine(in: note, caret: caret))
        #expect(note == "1. one\n  1. two\n    1. three\n    2. four\n    3. five\n\n")
        for (line, number) in NoteList.numbers(in: note) {
            let written = (note as NSString).substring(from: line).prefix { $0 == " " || $0.isNumber }
            #expect(Int(written.trimmingCharacters(in: .whitespaces)) == number)
        }
    }
}
