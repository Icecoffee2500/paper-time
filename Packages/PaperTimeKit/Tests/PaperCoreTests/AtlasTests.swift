import Foundation
import Testing
@testable import PaperCore

@Suite("Atlas")
struct AtlasTests {
    func note(_ id: String, _ body: String, kind: Zettel.Kind = .note) -> Zettel {
        Zettel(id: id, kind: kind, title: "", body: body)
    }

    @Test("A map's kind survives the file")
    func kindRoundTrip() {
        let map = Zettel(id: "m", kind: .map, title: "Forgetting", body: "## A\n\n- [[1|one]]\n")
        let text = ZettelFile.text(of: map)
        #expect(text.contains("kind: map"))
        let back = ZettelFile.note(from: text, id: "m", modified: .now)
        #expect(back.kind == .map)
        #expect(ZettelFile.note(from: ZettelFile.text(of: note("n", "x")), id: "n", modified: .now).kind == .note)
    }

    @Test("A map's body reads as sections of links")
    func outline() {
        let map = note("m", "intro [[0|zero]]\n## Synapses\n- [[1|one]] — first\n- [[2|two]]\n## Weights\n[[3]]\n", kind: .map)
        let outline = map.outline
        #expect(outline.map(\.title) == ["", "Synapses", "Weights"])
        #expect(outline[1].entries.map(\.id) == ["1", "2"])
        #expect(outline[1].entries[0].label == "one")
        #expect(outline[2].entries.map(\.id) == ["3"])
    }

    @Test("Five notes that hang together and have no home are a squeeze; fewer are not")
    func squeeze() {
        let cluster = (1...5).map { i in
            note("c\(i)", "Synaptic consolidation protects memory from catastrophic forgetting; dendritic spines persist. Variant \(i).")
        }
        let strays = [note("s1", "Buy milk and eggs."), note("s2", "The robot policy detokenises actions.")]
        let found = Atlas.squeeze(notes: cluster + strays, maps: [])
        #expect(found.count == 1)
        #expect(found.first?.noteIDs == ["c1", "c2", "c3", "c4", "c5"])
        #expect(found.first?.words.isEmpty == false)
        #expect(Atlas.squeeze(notes: Array(cluster.prefix(4)) + strays, maps: []).isEmpty)
    }

    @Test("Notes a map already holds are not squeezed again")
    func housed() {
        let cluster = (1...5).map { i in note("c\(i)", "Synaptic consolidation protects memory from catastrophic forgetting. \(i)") }
        let map = note("m", "## Home\n" + cluster.map { "- \($0.linkMarkdown)" }.joined(separator: "\n"), kind: .map)
        #expect(Atlas.squeeze(notes: cluster, maps: [map]).isEmpty)
    }

    @Test("The draft names the map by the words and files the notes under their papers")
    func draft() {
        let paper = UUID()
        var a = note("a", "Synaptic consolidation of memory."); a.paperID = paper
        let b = note("b", "Memory consolidation again.")
        let suggestion = Atlas.Suggestion(words: ["consolidation", "memory"], noteIDs: ["a", "b"])
        let made = Atlas.draft(for: suggestion, notes: [a, b]) { _ in "Yang 2009" }
        #expect(made.title == "Consolidation · Memory")
        #expect(made.body.contains("## Yang 2009"))
        #expect(made.body.contains("## Notes of my own"))
        #expect(made.body.contains("[[a|"))
    }
}
