import Foundation
import Testing
@testable import PaperCore

@Suite("Highlights put on and taken off in a note")
struct NoteHighlightEditTests {
    private func applied(_ text: String, _ edit: NoteHighlightEdit.Edit) -> (text: String, selected: NSRange) {
        let result = (text as NSString).replacingCharacters(in: edit.range, with: edit.insert)
        return (result, edit.selection)
    }

    @Test("A selection takes the marks and gives them back")
    func wrapAndUnwrap() {
        let on = applied("say word here", NoteHighlightEdit.toggle(in: "say word here", selection: NSRange(location: 4, length: 4), color: nil))
        #expect(on.text == "say ==word== here")
        #expect(on.selected == NSRange(location: 6, length: 4))
        let pink = applied("say word here", NoteHighlightEdit.toggle(in: "say word here", selection: NSRange(location: 4, length: 4), color: "pink"))
        #expect(pink.text == "say =={pink}word== here")
        #expect(pink.selected == NSRange(location: 12, length: 4))
        // Selected whole, or inside its marks: the same colour takes it off.
        let whole = applied("say ==word== here", NoteHighlightEdit.toggle(in: "say ==word== here", selection: NSRange(location: 4, length: 8), color: nil))
        #expect(whole.text == "say word here")
        #expect(whole.selected == NSRange(location: 4, length: 4))
        let inside = applied("say =={pink}word== here", NoteHighlightEdit.toggle(in: "say =={pink}word== here", selection: NSRange(location: 12, length: 4), color: "pink"))
        #expect(inside.text == "say word here")
        #expect(inside.selected == NSRange(location: 4, length: 4))
    }

    @Test("Another colour recolours rather than nesting")
    func recolour() {
        let blue = applied("a ==w== b", NoteHighlightEdit.toggle(in: "a ==w== b", selection: NSRange(location: 4, length: 1), color: "blue"))
        #expect(blue.text == "a =={blue}w== b")
        #expect(blue.selected == NSRange(location: 10, length: 1))
        let plain = applied("a =={blue}w== b", NoteHighlightEdit.toggle(in: "a =={blue}w== b", selection: NSRange(location: 2, length: 11), color: nil))
        #expect(plain.text == "a ==w== b")
        #expect(plain.selected == NSRange(location: 4, length: 1))
    }

    @Test("With nothing selected an empty pair goes in and comes off")
    func caret() {
        let on = applied("ab", NoteHighlightEdit.toggle(in: "ab", selection: NSRange(location: 1, length: 0), color: "green"))
        #expect(on.text == "a=={green}==b")
        #expect(on.selected == NSRange(location: 10, length: 0))
        let off = applied(on.text, NoteHighlightEdit.toggle(in: on.text, selection: on.selected, color: "green"))
        #expect(off.text == "ab")
        #expect(off.selected == NSRange(location: 1, length: 0))
        // Any empty pair under the caret comes off, whatever colour is pressed.
        let other = applied("a====b", NoteHighlightEdit.toggle(in: "a====b", selection: NSRange(location: 3, length: 0), color: "pink"))
        #expect(other.text == "ab")
    }
}
