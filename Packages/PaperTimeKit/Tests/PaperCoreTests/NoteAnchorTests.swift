import CoreGraphics
import Foundation
import Testing
@testable import PaperCore

@Suite("Note anchors")
struct NoteAnchorTests {
    let anchor = NoteAnchor(
        pageIndex: 3,
        rect: CGRect(x: 107.53, y: 402.38, width: 391.38, height: 12),
        quotedText: "We introduce the OpenVLA model, a 7B-parameter vision-language-action model"
    )

    @Test("A link survives the trip through its URL")
    func roundTrip() throws {
        let restored = try #require(NoteAnchor(url: anchor.url))
        #expect(restored.pageIndex == anchor.pageIndex)
        #expect(restored.rect == anchor.rect)
    }

    @Test("The label is the opening words, shortened")
    func label() {
        #expect(anchor.label == "We introduce the OpenVLA model, a 7B-parameter…")
        let unquoted = NoteAnchor(pageIndex: 0, rect: .zero, quotedText: "  ")
        #expect(unquoted.label == "p. 1")
    }

    @Test("Anything that is not one of our links is refused")
    func rejectsOthers() {
        #expect(NoteAnchor(url: URL(string: "https://example.com/anchor?p=1")!) == nil)
        #expect(NoteAnchor(url: URL(string: "papertime://anchor")!) == nil)
        #expect(NoteAnchor(url: URL(string: "papertime://paper?p=1&x=1&y=1&w=1&h=1")!) == nil)
    }
}
