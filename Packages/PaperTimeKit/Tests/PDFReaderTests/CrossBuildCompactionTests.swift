import CoreGraphics
import Foundation
import LibraryStore
import PDFKit
import PaperCore
import Testing
@testable import InkEngine
@testable import PDFReader
@testable import PDFUpdate

/// Compaction of a file whose marks were written by the other build.
///
/// `Fixtures/portable-appended.pdf` (in PDFUpdateTests, made by
/// `Portable/tools/cross-fixture.mjs`) is `portable-base.pdf` plus one save
/// of the Portable appender: a highlight of two lines with a comment, an
/// underline without one, a box and a card of the sketch layer, and a pen
/// stroke — on a base that already carries somebody else's highlight and a
/// link. `portable-history.pdf` is the same with a hundred more saves on top.
/// The Mac reads those marks as its own and, when it compacts, rebuilds them
/// with PDFKit, which spells every one of them differently; the rebuilt file
/// has to count as showing the same marks, and the fold has to go through.
@Suite("Compaction across builds")
@MainActor
struct CrossBuildCompactionTests {
    init() { PencilKitHost.prepare() }

    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "PDFUpdateTests/Fixtures")

    static func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: fixtures.appending(path: name))
    }

    static let highlightID = UUID(uuidString: "C3A6D2E0-5B1F-4E7A-9C2D-1F0E8B7A6D5C")!
    static let underlineID = UUID(uuidString: "7D4B9F21-3C8E-4A6D-B1F5-2E9C0A7D4B31")!

    /// The state the Mac's session holds for this file when it compacts,
    /// read from the file alone — no journal, no sidecar: the marks that
    /// carry our identifier, the ink as a drawing, the shapes as elements.
    static func state(of data: Data) throws -> Compaction.State {
        let document = try #require(PDFDocument(data: data))
        var ink: [Int: Data] = [:]
        var sketches: [Int: Data] = [:]
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let drawing = InkConverter.drawing(fromOwnedInkOn: page)
            if !drawing.strokes.isEmpty { ink[index] = drawing.dataRepresentation() }
            let elements = SketchWriter.elements(fromOwnedOn: page)
            if !elements.isEmpty { sketches[index] = DocumentSession.encodeSketch(elements) }
        }
        let own = TextMarkupWriter.ownIdentifiers(in: document)
        let marks = TextMarkupWriter.descriptors(in: document).filter { own.contains($0.id) }
        return Compaction.State(additions: marks, removals: [], ink: ink, sketches: sketches)
    }

    /// The file rebuilt on `base` from `state`, the way `Compaction.run` does.
    static func rebuild(_ state: Compaction.State, on base: Data) throws -> Data {
        let outcome = try IncrementalWriter.update(base) { document in
            DocumentSession.edit(document, additions: state.additions, removals: state.removals, ink: state.ink, sketches: state.sketches)
        }
        guard case let .appended(candidate, _) = outcome else { throw CocoaError(.fileReadCorruptFile) }
        return candidate
    }

    /// A library whose record knows `original` as the imported file.
    static func makeLibrary(original: Data) throws -> (store: LibraryStore, paper: LoadedPaper) {
        let (store, paper0) = try SyncTests.makeLibrary()
        try original.write(to: paper0.documentURL)
        var paper = paper0
        paper.meta.file.byteSize = Int64(original.count)
        paper.meta.file.importDigest = FileOperations.sha256(of: original)
        return (store, paper)
    }

    @Test("What the Mac reads off a Portable file is the marks, not the spelling")
    func readsPortableMarks() throws {
        let portable = try Self.fixture("portable-appended.pdf")
        let state = try Self.state(of: portable)
        // The colleague's highlight is recognised but not ours to rebuild.
        #expect(Set(state.additions.map(\.id)) == [Self.highlightID, Self.underlineID])
        let highlight = try #require(state.additions.first { $0.id == Self.highlightID })
        #expect(highlight.kind == .highlight)
        #expect(highlight.rects.count == 2)
        #expect(highlight.color == .yellow)
        #expect(highlight.comment == "why here? — 여기가 왜")
        // `/Contents` is the quotation as the other build took it, which is
        // not the quotation PDFKit reads back — and not a comment.
        let underline = try #require(state.additions.first { $0.id == Self.underlineID })
        #expect(underline.kind == .underline)
        #expect(underline.comment == "")
        #expect(state.ink.keys.sorted() == [0])
        #expect(state.sketches.keys.sorted() == [0])
    }

    @Test("The Mac's rebuild of a Portable file shows the same marks")
    func rebuildShowsTheSameMarks() throws {
        let portable = try Self.fixture("portable-appended.pdf")
        let base = try Self.fixture("portable-base.pdf")
        let state = try Self.state(of: portable)
        let candidate = try Self.rebuild(state, on: base)
        #expect(candidate.prefix(base.count) == base)
        #expect(try AnnotationComparison.markDifference(current: portable, candidate: candidate) == nil)

        // A rebuild that lost the stroke, or the marks, is not the same.
        var withoutInk = state
        withoutInk.ink = [:]
        let lostInk = try #require(try AnnotationComparison.markDifference(current: portable, candidate: try Self.rebuild(withoutInk, on: base)))
        #expect(lostInk.contains("Ink"))
        var withoutMarks = state
        withoutMarks.additions = []
        let lostMarks = try #require(try AnnotationComparison.markDifference(current: portable, candidate: try Self.rebuild(withoutMarks, on: base)))
        #expect(lostMarks.contains("Highlight"))
    }

    @Test("A hundred Portable saves fold into one update that shows the same marks")
    func foldsPortableHistory() throws {
        let base = try Self.fixture("portable-base.pdf")
        let history = try Self.fixture("portable-history.pdf")
        let (_, paper) = try Self.makeLibrary(original: base)
        try history.write(to: paper.documentURL)
        let revisions = try PDFFile(data: history).sections.count - 1
        #expect(revisions == 101)
        let text = PDFDocument(data: history)?.page(at: 0)?.string

        let state = try Self.state(of: history)
        let outcome = Compaction.run(url: paper.documentURL, folder: paper.folder, meta: paper.meta, state: state)
        guard case let .compacted(was, now, folded) = outcome else { Issue.record("\(outcome)"); return }
        #expect(was == history.count)
        #expect(folded == 101)
        let after = try Data(contentsOf: paper.documentURL)
        #expect(after.count == now)
        #expect(after.count < history.count / 4)
        #expect(after.prefix(base.count) == base)
        #expect(try PDFFile(data: after).sections.count == 2)
        #expect(try AnnotationComparison.markDifference(current: history, candidate: after) == nil)
        #expect(PDFDocument(data: after)?.page(at: 0)?.string == text)

        // As the app reads the result: the same two marks of ours, the
        // colleague's highlight as it was, one stroke, the box and the card.
        let document = try #require(PDFDocument(data: after))
        let page = try #require(document.page(at: 0))
        let marks = TextMarkupWriter.descriptors(in: document)
        #expect(Set(marks.map(\.id)).isSuperset(of: [Self.highlightID, Self.underlineID]))
        #expect(marks.count == 3)
        #expect(marks.first { $0.id == Self.underlineID }?.comment == "")
        #expect(page.annotations.contains { $0.type == "Highlight" && $0.userName == "Someone Else" })
        #expect(page.annotations.filter { $0.type == "Ink" }.count == 1)
        #expect(SketchWriter.elements(fromOwnedOn: page).count == 2)
        #expect(document.page(at: 1)?.annotations.filter { $0.type == "Link" }.count == 1)

        let again = Compaction.run(url: paper.documentURL, folder: paper.folder, meta: paper.meta, state: state)
        guard case .notDue = again else { Issue.record("\(again)"); return }

        // `PAPERTIME_COMPACTED_OUT=<file>` keeps the result: it is the
        // Portable tests' `fixtures/mac-compacted.pdf`, the file that build
        // has to read its marks back from.
        if let out = ProcessInfo.processInfo.environment["PAPERTIME_COMPACTED_OUT"] {
            try after.write(to: URL(fileURLWithPath: out))
        }
    }

    @Test("A state short of a mark the file shows refuses the fold")
    func refusesWhenAMarkIsMissing() throws {
        let base = try Self.fixture("portable-base.pdf")
        let history = try Self.fixture("portable-history.pdf")
        let (_, paper) = try Self.makeLibrary(original: base)
        try history.write(to: paper.documentURL)
        var state = try Self.state(of: history)
        state.sketches = [:]
        let outcome = Compaction.run(url: paper.documentURL, folder: paper.folder, meta: paper.meta, state: state)
        guard case let .refused(why) = outcome else { Issue.record("\(outcome)"); return }
        #expect(why.contains("sketch"))
        #expect(try Data(contentsOf: paper.documentURL) == history)
    }
}
