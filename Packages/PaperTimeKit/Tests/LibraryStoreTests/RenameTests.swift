import CoreGraphics
import Foundation
import PaperCore
import Testing
@testable import LibraryStore

/// The name in the app and the name in Finder are the same name, so renaming
/// here renames the file — and nothing else moves.
@Suite("Renaming the file")
struct RenameTests {
    static func makeRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "papertime-rename-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func writePDF(named name: String, in folder: URL) throws {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data) else { return }
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return }
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(mediaBox)
        context.endPDFPage()
        context.closePDF()
        try (data as Data).write(to: folder.appending(path: name))
    }

    static func imported(named name: String = "2403.18293v1.pdf") async throws -> (LibraryStore, URL, LoadedPaper) {
        let root = try makeRoot()
        try writePDF(named: name, in: root)
        let store = LibraryStore(root: root)
        try await store.bootstrap()
        let outcome = try await store.importDocument(at: root.appending(path: name))
        guard case let .imported(paper) = outcome else {
            throw RenameTrouble.notImported
        }
        return (store, root, paper)
    }

    enum RenameTrouble: Error { case notImported }

    @Test("The file takes the new name and the record stays put")
    func renamesTheFile() async throws {
        let (store, root, paper) = try await Self.imported()
        defer { try? FileManager.default.removeItem(at: root) }

        let renamed = try await store.rename(paper, to: "Diffusion Policy.pdf")

        #expect(renamed.documentURL.lastPathComponent == "Diffusion Policy.pdf")
        #expect(renamed.meta.file.relativePath == "Diffusion Policy.pdf")
        #expect(renamed.meta.file.originalName == "Diffusion Policy.pdf")
        // Same paper, same record folder: marks, ink and notes do not move.
        #expect(renamed.meta.id == paper.meta.id)
        #expect(renamed.folder.url == paper.folder.url)

        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(names.contains("Diffusion Policy.pdf"))
        #expect(!names.contains("2403.18293v1.pdf"))

        // And the record on disk agrees, not just the copy in hand.
        let reloaded = try await store.loadMeta(paper.folder)
        #expect(reloaded.file.relativePath == "Diffusion Policy.pdf")
    }

    @Test("A name typed without .pdf keeps the extension anyway")
    func keepsTheExtension() async throws {
        let (store, root, paper) = try await Self.imported()
        defer { try? FileManager.default.removeItem(at: root) }

        let renamed = try await store.rename(paper, to: "Diffusion Policy")
        #expect(renamed.documentURL.lastPathComponent == "Diffusion Policy.pdf")
    }

    @Test("A name already on another file is refused, and nothing moves")
    func refusesATakenName() async throws {
        let (store, root, paper) = try await Self.imported()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.writePDF(named: "taken.pdf", in: root)

        await #expect(throws: LibraryStore.RenameFailure.taken("taken.pdf")) {
            try await store.rename(paper, to: "taken.pdf")
        }
        #expect(FileManager.default.fileExists(atPath: paper.documentURL.path(percentEncoded: false)))
    }

    @Test("A name that is a path is refused: it would leave the library")
    func refusesAPath() async throws {
        let (store, root, paper) = try await Self.imported()
        defer { try? FileManager.default.removeItem(at: root) }

        await #expect(throws: LibraryStore.RenameFailure.notAName) {
            try await store.rename(paper, to: "../elsewhere.pdf")
        }
        await #expect(throws: LibraryStore.RenameFailure.empty) {
            try await store.rename(paper, to: "   ")
        }
    }

    @Test("Only the case can change, on a disk that does not mind")
    func changesTheCase() async throws {
        let (store, root, paper) = try await Self.imported(named: "openvla.pdf")
        defer { try? FileManager.default.removeItem(at: root) }

        let renamed = try await store.rename(paper, to: "OpenVLA.pdf")
        #expect(renamed.documentURL.lastPathComponent == "OpenVLA.pdf")
        #expect(FileManager.default.fileExists(atPath: renamed.documentURL.path(percentEncoded: false)))
    }
}

/// A note about no paper has no folder to belong to, so the app keeps it.
@Suite("The app's own box")
struct LooseNotesTests {
    static func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "papertime-loose-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("A note written here comes back the same")
    func keepsANote() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let box = LooseNotes(directory: directory)

        var note = Zettel(id: "260922_0001", kind: .map, title: "A map")
        note.body = "- [[260922_0002]]"
        try await box.saveNote(note)

        let read = await box.loadNotes()
        #expect(read.count == 1)
        #expect(read.first?.id == "260922_0001")
        #expect(read.first?.kind == .map)
        #expect(read.first?.title == "A map")
        // Plain Markdown in a plain folder: the same file a library folder
        // holds, so one can be moved into the other and nothing is lost.
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(names == ["260922_0001.md"])
    }

    @Test("Deleting takes the file with it")
    func deletesANote() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let box = LooseNotes(directory: directory)

        try await box.saveNote(Zettel(id: "260922_0003", title: "Gone soon"))
        try await box.deleteNote("260922_0003")
        #expect(await box.loadNotes().isEmpty)
        // And deleting one that is not there is not an error.
        try await box.deleteNote("260922_0003")
    }

    @Test("An empty note is not kept at all")
    func dropsAnEmptyNote() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let box = LooseNotes(directory: directory)

        try await box.saveNote(Zettel(id: "260922_0004"))
        #expect(await box.loadNotes().isEmpty)
    }
}
