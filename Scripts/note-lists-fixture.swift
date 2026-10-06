// The answers the Portable build's `shared/noteList.ts` is held to: the Mac's
// own `NoteList` on what numbered items show, and on what Tab and ⇧Tab,
// Return, Backspace, Delete and the «[] » and «-- » shortcuts do to a list.
//
//     swiftc -O -parse-as-library \
//       Packages/PaperTimeKit/Sources/PaperCore/Model/NoteMath.swift \
//       Packages/PaperTimeKit/Sources/PaperCore/Model/NoteCode.swift \
//       Packages/PaperTimeKit/Sources/PaperCore/Model/NoteTable.swift \
//       Packages/PaperTimeKit/Sources/PaperCore/Model/NoteList.swift \
//       Scripts/note-lists-fixture.swift -o /tmp/note-lists-fixture
//     /tmp/note-lists-fixture > Packages/PaperTimeKit/Tests/PaperCoreTests/Fixtures/note-lists.json
//
// Change NoteList and run this again; both builds' tests read the file.
import Foundation

@main
enum NoteListsFixture {
    /// Notes whose numbered items are counted.
    static let notes = [
        // A reader's: items moved in with Tab kept the numbers they had.
        "## Method\n\n1. original model\n  2. the whole gradient\n  3. the retain gradient\n  4. $$\\nabla L = 0$$\n2. \n$$\nL(w)\n$$",
        // The same number on every item, as some people write them.
        "1. a\n1. b\n1. c",
        // A list at the left starts where its first item says.
        "3. a\n4. b\n7. c",
        // Blank lines between items leave the list whole.
        "1. a\n\n2. b\n\n\n5. c",
        // A paragraph ends it; the next list starts at its own number.
        "1. a\nA paragraph.\n2. b\n3. c\nAnother.\n1. d",
        // Lists in lists, each counted on its own, starting at 1.
        "1. a\n  5. x\n  6. y\n    7. deep\n    8. deeper\n  9. z\n2. b",
        // A bullet at the depth breaks a numbered list; one deeper does not.
        "1. a\n- bullet\n2. b\n  - sub\n3. c",
        // Fenced code is never an item, and breaks a list at the left.
        "1. a\n```\n1. not an item\n```\n2. b",
        // Code set in under an item is the item's.
        "1. a\n  ```\n  1. not an item\n  ```\n2. b",
        // A formula over several lines is one line, here the item's.
        "1. a\n  $$\nx = 1\n  $$\n2. b",
        // A line of words at a list's depth ends it.
        "1. a\n  1. x\n  words in between\n  7. y",
        // Brackets for points, a box, a toggle.
        "1) a\n2) b\n- [ ] task\n1. c\n+ toggle\n  1. child\n  2. child",
        // The other mark is another list.
        "1. first\n12) twelfth\n13) thirteenth\n2. second",
        // Three deep and round again.
        "1. a\n  1. b\n    1. c\n      1. d\n        2. e",
        // Windows line breaks.
        "1. a\r\n  4. b\r\n  5. c\r\n2. d",
    ]

    /// Tab and ⇧Tab: a note with its caret, marked `|`, and the way.
    static let shifts: [(note: String, by: Int)] = [
        // Tab on the second item of a list: it starts a list under the first.
        ("1. original model\n2. the whole gradient|", 1),
        // The caret keeps its place in the words; what is left counts on.
        ("1. a\n2. be|ta\n3. c", 1),
        // Into a list already there: it counts on from it.
        ("1. a\n  1. x\n2. b|\n3. c", 1),
        // Out of the middle of a list: the item joins the list above, and
        // the items after it become its own, starting at 1.
        ("1. a\n  1. x\n  2. y|\n  3. z\n2. b", -1),
        // An item takes what is under it along.
        ("1. a\n2. b|\n  1. b1\n  2. b2\n    - deep\n3. c", 1),
        ("1. a\n  1. b|\n    1. b1\n2. c", -1),
        // At the left already: nothing moves, the key is taken.
        ("1. a|\n2. b", -1),
        // A bullet and a toggle move too, with their children.
        ("- a\n- b|", 1),
        ("+ T|\n  child\n+ U", 1),
        // Not an item, or code: not ours.
        ("plain words|", 1),
        ("```\n- x|\n```", 1),
        // The caret in the indent goes to the start of the words.
        ("1. a\n|  1. b", -1),
        // Out from under a bullet: a list of its own, starting at 1.
        ("- p\n  3. x|", -1),
        // Blank lines inside the item go along untouched.
        ("1. a\n2. b|\n\n  more about b\n3. c", 1),
        // Numbers that change their width.
        ("9. a\n10. b|\n11. c", 1),
        // A reader's note, tidied by the next move.
        ("1. original\n  2. the whole|\n  3. the retain\n  4. formula\n2. next", 1),
        ("1. original\n  2. the whole\n  3. the retain|\n  4. formula\n2. next", -1),
        // An empty item stepping out, as Return and Backspace do.
        ("1. a\n  1. x\n  2. |", -1),
        // Several items selected, «⟦» to «⟧»: all of them move, what is under
        // the last goes along, and the selection stays on the same words.
        ("⟦- a\n- b⟧\n- c", 1),
        ("- a\n⟦- b\n- c⟧", 1),
        ("1. a\n⟦2. b\n3. c⟧\n4. d", 1),
        ("1. a\n  ⟦1. b\n  2. c⟧\n2. d", -1),
        ("1. a\n  1. b\n  2. ⟦c\n  3. d⟧\n2. e", -1),
        // Up to the start of a line does not take that line.
        ("- a\n⟦- b\n⟧- c", 1),
        ("⟦1. a\n2. b⟧", -1),
        ("1. a\n⟦2. b\n  1. x⟧\n  2. y\n3. c", 1),
        ("⟦text\n- a⟧", 1),
        ("- p\n  ⟦3. x\n  4. y⟧", -1),
    ]

    /// Return: a note with its caret, marked `|`, and whether the caret's
    /// toggle has its children folded away.
    static let returns: [(note: String, folded: Bool)] = [
        // What the line was doing goes on, in its own marks.
        ("- a|", false),
        ("* a|", false),
        ("1. a|", false),
        ("1) a|", false),
        ("1. a\n  1) x|", false),
        ("- [x] done|", false),
        ("* [ ] t|", false),
        ("> quoted|", false),
        ("9. a|", false),
        // In the middle of a list the items after it count on, in the file too.
        ("1. a|\n2. b\n3. c", false),
        ("1. a\n1. b|\n1. c", false),
        // In the middle of the words: the rest goes onto the new line.
        ("- one| two", false),
        ("- [ ] |todo", false),
        // A caret before a marker, or in it, is at its words: the item
        // breaks there, and nothing of the marker becomes words.
        ("1. a\n2. b\n|3. c", false),
        ("1|. a", false),
        ("  - |x", false),
        // An empty item: in a level, or at the left the end of the list.
        ("- a\n- |", false),
        ("- a\n  - |", false),
        ("1. a\n  1. x\n  2. |", false),
        ("1. a\n    3. |", false),
        ("1. a\n2. |\n3. b", false),
        ("> a\n> |", false),
        ("a\n  > |", false),
        // A toggle's next line is its first child; Return on an empty one
        // steps back out to the toggle's level.
        ("+ Title|", false),
        ("  + Title|", false),
        // At the start of a toggle's words: an empty toggle above it; in
        // the middle, the rest of them is its first child.
        ("+ |Title", false),
        ("+ Ti|tle", false),
        ("+ |T\n  child", true),
        ("+ Title\n  |", false),
        ("  + Title\n    child\n    |", false),
        ("+ T|\n  child\n+ U", true),
        ("+ T|\n  one\n\n  two\n\n+ U", true),
        ("+ T|", true),
        // A line set in with no marker goes on at its indent, as
        // CodeMirror's Return does: a toggle's second child is a child too.
        ("+ T\n  c|", false),
        ("- a\n  more about a|", false),
        ("  ab| cd", false),
        ("  |  x", false),
        ("\tx|", false),
        ("  ## H|", false),
        ("- item\n  |", false),
        // In a formula Return breaks the formula's line; after it, the item.
        ("1. $$x+|y$$", false),
        ("  3. $\\alpha|$ and more", false),
        ("1. $$x+y$$|", false),
        // Not a list's, at the left: a line break and nothing more.
        ("plain|", false),
        ("## Heading|", false),
        ("|> quoted", false),
        ("```\n- x|\n```", false),
    ]

    /// Backspace, Delete and the shortcuts' space: a note with its caret.
    static let backspaces = [
        "- |a", "|- a", "-| a", "  - |a", "1. a\n  1. |x\n  2. y\n2. b", "1. a\n2. |b\n3. c",
        "> |q", "## |H", "#|# H", "|> q", "+ |T", "1. a\n- |", "- p\n  1. |x", "  > |q",
        "- |", "```\n- |x\n```", "- a\n|text", "- a|",
    ]
    static let deletes = [
        "1. a|\n2. b\n3. c", "1. a|\n2. b\n  1. x\n3. c", "- a|\n  - x", "|\n- a", "  |\n  - a",
        "text|\n## H", "a|\nb", "- a|", "- a|\n\n- b", "x|\n```\n- y\n```", "- a|\r\n- b", "- |\n- b",
    ]
    static let shortcuts = [
        "[]|", "  []|", "--|", "  --|", "- []|", "* []|", "  - []|", "x[]|", "[]|tail", "1. []|",
        "```\n[]|\n```", "---|", "- --|",
    ]

    static func main() throws {
        let counted = notes.map { note -> [String: Any] in
            let shown = NoteList.numbers(in: note).sorted { $0.key < $1.key }.map { [$0.key, $0.value] }
            return ["note": note, "numbers": shown]
        }
        let moved = shifts.map { item -> [String: Any] in
            let (note, selection) = read(item.note)
            var entry: [String: Any] = ["note": note, "caret": selection.location, "by": item.by]
            if selection.length > 0 { entry["length"] = selection.length }
            entry["edit"] = written(NoteList.shift(in: note, selection: selection, by: item.by), in: note)
            return entry
        }
        let returned = returns.map { item -> [String: Any] in
            let (note, selection) = read(item.note)
            var entry: [String: Any] = ["note": note, "caret": selection.location]
            if item.folded { entry["folded"] = true }
            entry["edit"] = written(NoteList.newLine(in: note, caret: selection.location, folded: item.folded), in: note)
            return entry
        }
        func keyed(_ notes: [String], _ edit: (String, Int) -> NoteList.Edit?) -> [[String: Any]] {
            notes.map { marked in
                let (note, selection) = read(marked)
                return ["note": note, "caret": selection.location, "edit": written(edit(note, selection.location), in: note)]
            }
        }
        let data = try JSONSerialization.data(
            withJSONObject: [
                "numbers": counted, "shifts": moved, "returns": returned,
                "backspaces": keyed(backspaces) { NoteList.backspace(in: $0, caret: $1) },
                "deletes": keyed(deletes) { NoteList.deleteForward(in: $0, caret: $1) },
                "shortcuts": keyed(shortcuts) { NoteList.shortcut(in: $0, caret: $1) },
            ],
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    /// A note with its caret marked `|`, or its selection `⟦…⟧`, and the
    /// note without the marks.
    static func read(_ marked: String) -> (String, NSRange) {
        var text = marked as NSString
        let open = text.range(of: "⟦")
        if open.location != NSNotFound {
            text = text.replacingCharacters(in: open, with: "") as NSString
            let close = text.range(of: "⟧")
            text = text.replacingCharacters(in: close, with: "") as NSString
            return (text as String, NSRange(location: open.location, length: close.location - open.location))
        }
        let caret = text.range(of: "|").location
        return (text.replacingCharacters(in: NSRange(location: caret, length: 1), with: ""), NSRange(location: caret, length: 0))
    }

    /// An edit as the file has it: what it replaces, with what, where the
    /// caret goes — and the selection's length, when there is one — and the
    /// note after it.
    static func written(_ edit: NoteList.Edit?, in note: String) -> Any {
        guard let edit else { return NSNull() }
        var entry: [String: Any] = [
            "range": [edit.range.location, edit.range.length], "replacement": edit.replacement, "caret": edit.caret,
            "after": (note as NSString).replacingCharacters(in: edit.range, with: edit.replacement),
        ]
        if edit.length > 0 { entry["length"] = edit.length }
        return entry
    }
}
