import CoreGraphics
import Foundation
import InkEngine
import LibraryStore
import PDFKit
import PaperCore
import Testing
@testable import PDFReader

/// The sketch layer's life in a session: sidecar first, PDF copy after, and
/// back from the PDF when the sidecar is missing.
@Suite("Saving sketches")
@MainActor
struct SketchSavingTests {
    static func box(_ x: CGFloat) -> SketchElement {
        SketchElement(
            kind: .rectangle,
            points: [CGPoint(x: x, y: 500), CGPoint(x: x + 100, y: 560)],
            style: SketchStyle(fill: .paleYellow),
            text: "Who?"
        )
    }

    @Test("A sketch is a sidecar at once and annotations in the file after a flush")
    func sidecarThenFile() async throws {
        let (store, paper) = try SyncTests.makeLibrary()
        let session = try await DocumentSession.open(paper: paper, store: store)
        let element = Self.box(40)
        session.setSketch([element], forPage: 0)
        #expect(session.sketch(forPage: 0) == [element])
        #expect(session.saveState == .pending)

        // The sidecar lands without waiting for the PDF.
        try await Task.sleep(for: .milliseconds(300))
        let sidecar = paper.folder.sketchURL(pageIndex: 0)
        #expect(FileManager.default.fileExists(atPath: sidecar.path(percentEncoded: false)))

        await session.flush()
        #expect(session.saveState == .idle)
        let saved = try #require(PDFDocument(url: paper.documentURL))
        let page = try #require(saved.page(at: 0))
        #expect(page.annotations.contains { $0.type == "Square" && SketchWriter.isOwned($0) })
        #expect(SketchWriter.elements(fromOwnedOn: page) == [element])
    }

    @Test("Opening again reads the sidecar; without one, the file's copy is adopted")
    func reopening() async throws {
        let (store, paper) = try SyncTests.makeLibrary()
        let element = Self.box(40)
        do {
            let session = try await DocumentSession.open(paper: paper, store: store)
            session.setSketch([element], forPage: 0)
            await session.flush()
        }
        let again = try await DocumentSession.open(paper: paper, store: store)
        #expect(again.sketch(forPage: 0) == [element])

        // A device that got the PDF but not the sidecar.
        try FileManager.default.removeItem(at: paper.folder.sketchURL(pageIndex: 0))
        let third = try await DocumentSession.open(paper: paper, store: store)
        #expect(third.sketch(forPage: 0) == [element])
        #expect(FileManager.default.fileExists(atPath: paper.folder.sketchURL(pageIndex: 0).path(percentEncoded: false)))
    }

    @Test("A sidecar written by another device comes in on reload; an unsaved one here stays")
    func merging() async throws {
        let (store, paper) = try SyncTests.makeLibrary()
        let session = try await DocumentSession.open(paper: paper, store: store)
        let mine = Self.box(40)
        session.setSketch([mine], forPage: 1)
        try await Task.sleep(for: .milliseconds(300))

        // The other device writes page 0's sidecar directly.
        let theirs = Self.box(300)
        let data = try #require(DocumentSession.encodeSketch([theirs]))
        try await store.saveSketch(data, pageIndex: 0, in: paper.folder)

        await session.reloadFromDisk()
        #expect(session.sketch(forPage: 0) == [theirs])
        #expect(session.sketch(forPage: 1) == [mine])
    }

    @Test("Clearing a page's sketch removes the sidecar and the file's copy")
    func clearing() async throws {
        let (store, paper) = try SyncTests.makeLibrary()
        let session = try await DocumentSession.open(paper: paper, store: store)
        session.setSketch([Self.box(40)], forPage: 0)
        await session.flush()
        session.setSketch([], forPage: 0)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!FileManager.default.fileExists(atPath: paper.folder.sketchURL(pageIndex: 0).path(percentEncoded: false)))
        await session.flush()
        let saved = try #require(PDFDocument(url: paper.documentURL))
        let page = try #require(saved.page(at: 0))
        #expect(!page.annotations.contains { SketchWriter.isOwned($0) })
    }
}
