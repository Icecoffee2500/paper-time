import Foundation
import Testing
@testable import PaperCore

@Suite("Slip-box notes")
struct ZettelTests {
    @Test("A note survives the trip to its file and back")
    func roundTrip() {
        let note = Zettel(
            id: "202609081530",
            title: "OpenVLA turns a VLM into a policy",
            body: "The action head is detokenised text. #vla\nSee [[202609061204|Discretising actions]].",
            paperID: UUID(uuidString: "4F3A1C08-0000-0000-0000-000000000001"),
            created: Date(timeIntervalSince1970: 1_757_000_000)
        )
        let restored = ZettelFile.note(
            from: ZettelFile.text(of: note), id: "fallback", modified: .now
        )
        #expect(restored.id == note.id)
        #expect(restored.title == note.title)
        #expect(restored.body == note.body)
        #expect(restored.paperID == note.paperID)
        #expect(Int(restored.created.timeIntervalSince1970) == 1_757_000_000)
    }

    @Test("A note without a header is all body")
    func headerless() {
        let note = ZettelFile.note(from: "just a thought", id: "202609081530", modified: .now)
        #expect(note.id == "202609081530")
        #expect(note.body == "just a thought")
        #expect(note.title.isEmpty)
    }

    @Test("A rule inside the note is not mistaken for the end of the header")
    func ruleInBody() {
        let text = """
        ---
        id: 202609081530
        title: Kept
        ---

        One thought.

        ---

        Another, after a rule.
        """
        let note = ZettelFile.note(from: text, id: "x", modified: .now)
        #expect(note.title == "Kept")
        #expect(note.body.contains("Another, after a rule."))
    }

    @Test("Tags and links are read out of what was written")
    func tagsAndLinks() {
        let note = Zettel(
            id: "1",
            body: """
            #vla and #robot-learning matter here, but not a#b.
            See [[202609061204|Discretising actions]] and [[202609071010]].
            """
        )
        #expect(note.tags == ["vla", "robot-learning"])
        #expect(note.links == ["202609061204", "202609071010"])
    }

    @Test("Identifiers are the minute, and never collide")
    func identifiers() {
        let when = Date(timeIntervalSince1970: 1_757_000_000)
        let first = Zettel.makeID(at: when, avoiding: [])
        let second = Zettel.makeID(at: when, avoiding: [first])
        #expect(first.count == 12)
        #expect(first != second)
        #expect(second.hasPrefix(first))
    }

    @Test("A note with no title is named by what it says")
    func fallbackTitle() {
        let note = Zettel(id: "1", body: "# A heading\nand a body")
        #expect(note.displayTitle == "A heading and a body")
        #expect(Zettel(id: "2").displayTitle == "Untitled Note")
    }
}
