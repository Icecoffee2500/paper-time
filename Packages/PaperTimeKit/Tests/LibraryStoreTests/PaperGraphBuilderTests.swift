import Foundation
import PaperCore
import Testing
@testable import LibraryStore

@Suite("Paper graph")
struct PaperGraphBuilderTests {
    private func paper(
        _ id: UUID,
        title: String = "A Paper",
        authors: [CSLName] = [],
        collections: [UUID] = [],
        tags: [UUID] = []
    ) -> LoadedPaper {
        var meta = PaperMeta(id: id)
        meta.csl.title = title
        meta.csl.author = authors
        meta.collectionIDs = collections
        meta.tagIDs = tags
        return LoadedPaper(
            folder: PaperFolder(url: URL(fileURLWithPath: "/tmp/\(id)")),
            meta: meta,
            state: PaperState(),
            documentURL: URL(fileURLWithPath: "/tmp/\(id).pdf")
        )
    }

    let a = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    let b = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!
    let c = UUID(uuidString: "00000000-0000-0000-0000-0000000000C3")!

    @Test("A citation joins two papers once, whichever way round it is found")
    func citation() {
        let connections = PaperGraphBuilder.connections(
            papers: [paper(a), paper(b)],
            citations: [a: [b], b: [a]],
            collections: CollectionSet(),
            notes: []
        )
        #expect(connections.count == 1)
        #expect(connections[0].kinds == [.cites])
    }

    @Test("A shared author joins papers, and the same person written two ways is one person")
    func authors() {
        let full = CSLName(family: "LeCun", given: "Yann")
        let initial = CSLName(family: "LeCun", given: "Y.")
        let connections = PaperGraphBuilder.connections(
            papers: [paper(a, authors: [full]), paper(b, authors: [initial])],
            citations: [:],
            collections: CollectionSet(),
            notes: []
        )
        #expect(connections.count == 1)
        #expect(connections[0].kinds == [.author])
        #expect(connections[0].reason.contains("LeCun"))
    }

    @Test("Notes about different papers that link to each other join those papers")
    func notesConnect() {
        let first = Zettel(id: "202609081200", title: "One", body: "see [[202609081300|Two]]", paperID: a)
        let second = Zettel(id: "202609081300", title: "Two", body: "a thought", paperID: b)
        let connections = PaperGraphBuilder.connections(
            papers: [paper(a), paper(b)],
            citations: [:],
            collections: CollectionSet(),
            notes: [first, second]
        )
        #expect(connections.count == 1)
        #expect(connections[0].kinds == [.note])
    }

    @Test("Two reasons for the same pair are one connection carrying both")
    func kindsMerge() {
        let name = CSLName(family: "Finn", given: "Chelsea")
        let connections = PaperGraphBuilder.connections(
            papers: [paper(a, authors: [name]), paper(b, authors: [name])],
            citations: [a: [b]],
            collections: CollectionSet(),
            notes: []
        )
        #expect(connections.count == 1)
        #expect(connections[0].kinds == [.cites, .author])
        #expect(connections[0].weight > PaperLink.cites.weight)
    }

    @Test("A name on most of the shelf connects nothing, because it separates nothing")
    func crowdedAuthorIsIgnored() {
        let everywhere = CSLName(family: "Ubiquitous", given: "Ann")
        let papers = (0..<80).map { index -> LoadedPaper in
            let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!
            return paper(id, authors: index < 40 ? [everywhere] : [])
        }
        let connections = PaperGraphBuilder.connections(
            papers: papers, citations: [:], collections: CollectionSet(), notes: []
        )
        #expect(connections.isEmpty)
    }

    @Test("Papers filed in the same collection are joined by that collection's name")
    func filedTogether() {
        let collectionID = UUID()
        var set = CollectionSet()
        set.collections = [Collection(id: collectionID, name: "Vision")]
        let connections = PaperGraphBuilder.connections(
            papers: [paper(a, collections: [collectionID]), paper(b, collections: [collectionID]), paper(c)],
            citations: [:],
            collections: set,
            notes: []
        )
        #expect(connections.count == 1)
        #expect(connections[0].kinds == [.filed])
        #expect(connections[0].reason == "Vision")
        #expect(PaperGraphBuilder.degrees(of: connections)[c] == nil)
    }
}
