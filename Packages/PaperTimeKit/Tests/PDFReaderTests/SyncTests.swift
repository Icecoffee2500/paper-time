import CoreGraphics
import Foundation
import InkEngine
import LibraryStore
import PDFKit
import PaperCore
import Testing
@testable import PDFReader

/// Another device writes the file while it is open here. What it wrote comes
/// in; what is not yet written from here stays.
@Suite("Following the file")
@MainActor
struct SyncTests {
    static func makeLibrary() throws -> (store: LibraryStore, paper: LoadedPaper) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "papertime-sync-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pdf = root.appending(path: "paper.pdf")
        try SavingTests.makeDocument(text: "alpha beta gamma delta").write(to: pdf)
        let id = UUID()
        var meta = PaperMeta(id: id)
        meta.file.relativePath = "paper.pdf"
        let folder = PaperFolder(url: LibraryLayout.recordsDirectoryURL(inLibrary: root).appending(path: id.uuidString, directoryHint: .isDirectory))
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        let paper = LoadedPaper(folder: folder, meta: meta, state: PaperState(), documentURL: pdf)
        return (LibraryStore(root: root), paper)
    }

    static func mark(_ x: CGFloat, color: MarkupColor = .green) -> MarkupDescriptor {
        MarkupDescriptor(kind: .highlight, pageIndex: 0, rects: [CGRect(x: x, y: 695, width: 40, height: 14)], color: color, quotedText: "word")
    }

    @Test("A mark written elsewhere appears in the open session")
    func foreignMarkArrives() async throws {
        let (store, paper) = try Self.makeLibrary()
        let session = try await DocumentSession.open(paper: paper, store: store)
        #expect(session.markups.isEmpty)

        // The other device writes; the file's date moves on.
        try await Task.sleep(for: .milliseconds(1100))
        let theirs = Self.mark(40)
        _ = try DocumentSession.write(to: paper.documentURL, additions: [theirs], removals: [], ink: [:]).get()

        let before = session.revision
        await session.reloadFromDisk()
        #expect(session.markups.map(\.id) == [theirs.id])
        #expect(session.revision == before + 1)
        #expect(session.document.page(at: 0)?.annotations.contains { $0.type == "Highlight" } == true)
    }

    @Test("A mark not yet saved here survives a reload")
    func pendingMarkStays() async throws {
        let (store, paper) = try Self.makeLibrary()
        let session = try await DocumentSession.open(paper: paper, store: store)
        let mine = Self.mark(100, color: .pink)
        session.restore([mine])

        try await Task.sleep(for: .milliseconds(1100))
        let theirs = Self.mark(40)
        _ = try DocumentSession.write(to: paper.documentURL, additions: [theirs], removals: [], ink: [:]).get()

        await session.reloadFromDisk()
        #expect(Set(session.markups.map(\.id)) == [mine.id, theirs.id])
    }

    @Test("A mark removed elsewhere goes, unless it is ours and unsaved")
    func foreignRemoval() async throws {
        let (store, paper) = try Self.makeLibrary()
        let shared = Self.mark(40)
        _ = try DocumentSession.write(to: paper.documentURL, additions: [shared], removals: [], ink: [:]).get()
        let session = try await DocumentSession.open(paper: paper, store: store)
        try await Task.sleep(for: .milliseconds(300))
        #expect(session.markups.map(\.id) == [shared.id])

        try await Task.sleep(for: .milliseconds(1100))
        _ = try DocumentSession.write(to: paper.documentURL, additions: [], removals: [shared.id], ink: [:]).get()
        await session.reloadFromDisk()
        #expect(session.markups.isEmpty)
    }

    @Test("Another device's journal brings its mark without the PDF changing")
    func journalArrives() async throws {
        let (store, paper) = try Self.makeLibrary()
        let session = try await DocumentSession.open(paper: paper, store: store)
        try await Task.sleep(for: .milliseconds(300))

        var theirs = MarkJournal(device: "iPad-TEST", name: "iPad")
        let mark = Self.mark(40, color: .blue)
        theirs.record(mark)
        try theirs.save(to: paper.folder)

        await session.reloadFromDisk()
        #expect(session.markups.map(\.id) == [mark.id])
        #expect(session.markups.first?.color == .blue)

        // Later they remove it; the newer word wins.
        theirs.recordRemoval(of: mark.id, at: .now.addingTimeInterval(1))
        try theirs.save(to: paper.folder)
        await session.reloadFromDisk()
        #expect(session.markups.isEmpty)
    }

    @Test("Our removal outlives their addition when it is the newer word")
    func newestWordWins() {
        var a = MarkJournal(device: "A", name: "A")
        var b = MarkJournal(device: "B", name: "B")
        let mark = Self.mark(40)
        a.record(mark, at: Date(timeIntervalSince1970: 100))
        b.recordRemoval(of: mark.id, at: Date(timeIntervalSince1970: 200))
        let merged = MarkJournal.merged(["A": a, "B": b])
        #expect(merged[mark.id]?.descriptor == nil)
        b.record(mark, at: Date(timeIntervalSince1970: 300))
        #expect(MarkJournal.merged(["A": a, "B": b])[mark.id]?.descriptor?.id == mark.id)
    }
}
