import Foundation
import Testing
@testable import Semantic

@Suite("Notes cut into passages")
struct NoteTextTests {
    @Test("The Markdown comes out and the words stay")
    func markdown() {
        let note = """
        ## Why models forget
        > The **first task's** accuracy _drops_ once the *second* is trained.
        - See [[202609061204|the EWC note]] and [the paper](https://arxiv.org/abs/1612.00796).
        1. `Fisher` diagonal
        ![figure](fig.png) shows it. #catastrophic-forgetting
        """
        let plain = NoteText.plain(note)
        #expect(plain == """
        Why models forget
        The first task's accuracy drops once the second is trained.
        See the EWC note and the paper.
        Fisher diagonal
        figure shows it. catastrophic-forgetting
        """)
    }

    @Test("A formula keeps its letters and loses its dollars")
    func formulas() {
        let plain = NoteText.plain("Loss $$\\mathcal{L}_{\\text{rollout}}$$ and $x^2$ inline.")
        #expect(!plain.contains("$"))
        #expect(plain.contains("\\mathcal{L}_{\\text{rollout}}"))
        #expect(plain.contains("x^2"))
        // A note that is one formula still has words to embed.
        #expect(!SemanticChunker.chunks(ofNote: "$$e = mc^2$$").isEmpty)
    }

    @Test("Fences go and the code stays; a rule and a front matter go whole")
    func fencesAndRules() {
        let plain = NoteText.plain("---\nid: 1\n---\n```python\nx = 1\n```\n\n---\n\nafter")
        #expect(!plain.contains("```"))
        #expect(!plain.contains("id: 1"))
        #expect(plain.contains("x = 1"))
        #expect(plain.contains("after"))
        #expect(!plain.contains("---"))
    }

    @Test("A note is one passage when it is short, and overlapping windows when it is long")
    func windows() throws {
        let short = SemanticChunker.chunks(ofNote: "# A thought\nabout **two** things")
        let one = try #require(short.first)
        #expect(short.count == 1)
        #expect(one.text == "A thought about two things")
        // Where it is, in the plain text: the chunker's own offsets.
        let plain = NoteText.plain("# A thought\nabout **two** things")
        #expect((plain as NSString).substring(with: one.range) == "A thought\nabout two things")

        let long = (0..<180).map { "w\($0)" }.joined(separator: " ")
        let many = SemanticChunker.chunks(ofNote: long)
        #expect(many.count == 3)
        #expect(many[0].text.hasPrefix("w0 ") && many[0].text.hasSuffix(" w99"))
        #expect(many[1].text.hasPrefix("w75 ") && many[1].text.hasSuffix(" w174"))
        #expect(many[2].text.hasPrefix("w150 ") && many[2].text.hasSuffix(" w179"))
    }

    @Test("The same words on a page and in a note share one key")
    func sharedKey() {
        let words = "Elastic weight consolidation slows learning."
        let page = SemanticChunker.chunks(ofPage: words, paperID: UUID(), pageIndex: 0)
        let note = SemanticChunker.chunks(ofNote: "> " + words)
        #expect(page.first?.key == note.first?.key)
    }

    @Test("An empty note has no passages")
    func empty() {
        #expect(SemanticChunker.chunks(ofNote: "").isEmpty)
        #expect(SemanticChunker.chunks(ofNote: "## \n\n- \n").isEmpty)
    }
}
