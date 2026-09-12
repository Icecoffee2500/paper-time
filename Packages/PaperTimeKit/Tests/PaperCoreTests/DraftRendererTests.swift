import CoreGraphics
import Foundation
import Testing
@testable import PaperCore

@Suite("Draft rendering")
struct DraftRendererTests {
    let ewc = UUID(), openvla = UUID()
    var passage: NoteAnchor { NoteAnchor(pageIndex: 2, rect: CGRect(x: 1, y: 2, width: 3, height: 4), quotedText: "slows learning on important weights", paperID: ewc) }

    var idea: Zettel {
        var note = Zettel(id: "idea", title: "Consolidation is not rehearsal", body: "The weights are protected, not replayed [again](\(NoteAnchor(pageIndex: 1, rect: .zero, quotedText: "x", paperID: openvla).url.absoluteString)).")
        note.paperID = openvla
        return note
    }

    var draft: Zettel {
        Zettel(id: "d", kind: .draft, title: "Related work", body: """
        ## Continual learning

        - EWC penalises change [\(passage.label)](\(passage.url.absoluteString)) & works at 100%.
        - [[idea|An idea]]
        - *Rehearsal* methods **replay** data.
        """)
    }

    func key(_ id: UUID) -> String? { id == ewc ? "kirkpatrick2017" : id == openvla ? "kim2024" : nil }
    func note(_ id: String) -> Zettel? { id == "idea" ? idea : nil }

    @Test("LaTeX: passages become \\cite, notes unfold, the rest is escaped")
    func latex() {
        let made = DraftRenderer.render(draft, as: .latex, key: key, note: note)
        #expect(made.text.contains("\\subsection*{Continual learning}"))
        #expect(made.text.contains("EWC penalises change \\cite{kirkpatrick2017} \\& works at 100\\%."))
        #expect(made.text.contains("The weights are protected, not replayed \\cite{kim2024}."))
        #expect(made.text.contains("\\emph{Rehearsal} methods \\textbf{replay} data."))
        #expect(made.cited == [ewc, openvla])
    }

    @Test("Markdown: pandoc citations, Markdown kept")
    func markdown() {
        let made = DraftRenderer.render(draft, as: .markdown, key: key, note: note)
        #expect(made.text.contains("## Continual learning"))
        #expect(made.text.contains("- EWC penalises change [@kirkpatrick2017] & works at 100%."))
        #expect(made.text.contains("[@kim2024]"))
    }

    @Test("A passage of a paper with no key still cites something stable")
    func noKey() {
        let made = DraftRenderer.render(draft, as: .latex, key: { _ in nil }, note: note)
        #expect(made.text.contains("\\cite{paper-"))
    }
}
