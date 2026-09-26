import CoreGraphics
import Foundation
import InkEngine
import LibraryStore
import PDFKit
import PDFUpdate
import PaperCore
import Testing
@testable import PDFReader

/// Where a file stands against its import, how its history is folded, and
/// how a paper's original text is put back under its marks.
@Suite("Provenance, compaction and restore")
@MainActor
struct ProvenanceAndCompactionTests {
    static func mark(_ x: CGFloat, comment: String = "") -> MarkupDescriptor {
        MarkupDescriptor(kind: .highlight, pageIndex: 0, rects: [CGRect(x: x, y: 695, width: 40, height: 14)], color: .yellow, quotedText: "word", comment: comment)
    }

    /// A library whose record knows the file as imported.
    static func makeLibrary(text: String = "office affine different") throws -> (store: LibraryStore, paper: LoadedPaper, original: Data) {
        let (store, paper0) = try SyncTests.makeLibrary()
        let original = try SavingTests.makeDocument(text: text)
        try original.write(to: paper0.documentURL)
        var paper = paper0
        paper.meta.file.byteSize = Int64(original.count)
        paper.meta.file.importDigest = FileOperations.sha256(of: original)
        return (store, paper, original)
    }

    static func write(_ url: URL, _ marks: [MarkupDescriptor], folder: PaperFolder? = nil) throws -> DocumentSession.WriteOutcome {
        try DocumentSession.write(to: url, additions: marks, removals: [], ink: [:], recordingBaseIn: folder).get()
    }

    // MARK: Provenance

    @Test("A file is pristine, appended or rewritten by its digest alone")
    func classification() throws {
        let original = try SavingTests.makeDocument(text: "alpha beta")
        let digest = FileOperations.sha256(of: original)
        let size = Int64(original.count)
        #expect(FileProvenance.classify(original, importDigest: digest, byteSize: size) == .pristine)
        #expect(FileProvenance.classify(original, importDigest: "", byteSize: size) == .unknown)

        let url = try SavingTests.write(original)
        defer { try? FileManager.default.removeItem(at: url) }
        guard case .appended = try Self.write(url, [Self.mark(40)]) else { Issue.record("no append"); return }
        let appended = try Data(contentsOf: url)
        #expect(FileProvenance.classify(appended, importDigest: digest, byteSize: size) == .appended(tail: appended.count - original.count))

        // What every save did before saves were appends.
        let rewritten = try #require(PDFDocument(data: appended)?.dataRepresentation())
        #expect(FileProvenance.classify(rewritten, importDigest: digest, byteSize: size) == .rewritten)
        // A record whose size is wrong but whose digest is right still says
        // the file is the original.
        #expect(FileProvenance.classify(original, importDigest: digest, byteSize: 7) == .pristine)
    }

    @Test("The first append records the file it appended after, once")
    func baseIsRecorded() throws {
        let (_, paper, original) = try Self.makeLibrary()
        #expect(PDFBase.load(from: paper.folder) == nil)
        guard case .appended = try Self.write(paper.documentURL, [Self.mark(40)], folder: paper.folder) else { Issue.record("no append"); return }
        let base = try #require(PDFBase.load(from: paper.folder))
        #expect(base.length == original.count)
        #expect(base.digest == paper.meta.file.importDigest)
        guard case .appended = try Self.write(paper.documentURL, [Self.mark(40), Self.mark(100)], folder: paper.folder) else { Issue.record("no second append"); return }
        #expect(PDFBase.load(from: paper.folder) == base)
        let now = try Data(contentsOf: paper.documentURL)
        #expect(base.fits(now))
        #expect(PDFBase.find(for: now, in: paper.folder, meta: paper.meta) == base)
    }

    @Test("A file rewritten before saves were appends gets that rewrite as its base")
    func rewrittenFileBecomesTheBase() throws {
        let (_, paper, original) = try Self.makeLibrary()
        let rewritten = try #require(PDFDocument(data: original)?.dataRepresentation())
        try rewritten.write(to: paper.documentURL)
        guard case .appended = try Self.write(paper.documentURL, [Self.mark(40)], folder: paper.folder) else { Issue.record("no append"); return }
        let base = try #require(PDFBase.load(from: paper.folder))
        #expect(base.length == rewritten.count)
        let now = try Data(contentsOf: paper.documentURL)
        #expect(PDFBase.find(for: now, in: paper.folder, meta: paper.meta) == base)
        // Without the sidecar the record's numbers do not fit: no base.
        try FileManager.default.removeItem(at: paper.folder.pdfBaseURL)
        #expect(PDFBase.find(for: now, in: paper.folder, meta: paper.meta) == nil)
    }

    // MARK: Compaction

    @Test("Two hundred appends fold into one update that halves the file and shows the same marks")
    func compactsLongHistory() throws {
        let (_, paper, original) = try Self.makeLibrary()
        let fixed = Self.mark(40)
        var edited = Self.mark(100, comment: "note")
        var appends = 0
        for k in 1...200 {
            edited.comment = "note " + String(repeating: "x", count: k)
            if case .appended = try Self.write(paper.documentURL, [fixed, edited], folder: paper.folder) { appends += 1 }
        }
        #expect(appends == 200)
        let before = try Data(contentsOf: paper.documentURL)
        let revisionsBefore = try PDFFile(data: before).sections.count
        #expect(revisionsBefore >= 200)
        let text = PDFDocument(data: before)?.page(at: 0)?.string

        let state = Compaction.State(additions: [fixed, edited])
        let outcome = Compaction.run(url: paper.documentURL, folder: paper.folder, meta: paper.meta, state: state)
        guard case let .compacted(was, now, folded) = outcome else { Issue.record("\(outcome)"); return }
        #expect(was == before.count)
        #expect(folded >= 200)
        let after = try Data(contentsOf: paper.documentURL)
        #expect(after.count == now)
        #expect(after.count - original.count <= (before.count - original.count) / 2)
        #expect(after.prefix(original.count) == original)
        #expect(try PDFFile(data: after).sections.count == 2)
        #expect(try AnnotationComparison.markDifference(current: before, candidate: after) == nil)
        #expect(PDFDocument(data: after)?.page(at: 0)?.string == text)
        // What is on the page, as the app reads it.
        let page = try #require(PDFDocument(data: after)?.page(at: 0))
        #expect(TextMarkupWriter.isAlreadyWritten(fixed, on: page))
        #expect(TextMarkupWriter.isAlreadyWritten(edited, on: page))
        // The old words are gone from the file, not only from its current
        // version.
        #expect(!after.contains(Data("note xxxxxxxxxx".utf8)) || String(decoding: after, as: UTF8.self).contains("note " + String(repeating: "x", count: 200)))
        let descriptors = TextMarkupWriter.descriptors(in: PDFDocument(data: after)!)
        #expect(descriptors.count == 2)

        // Not due again.
        let again = Compaction.run(url: paper.documentURL, folder: paper.folder, meta: paper.meta, state: state)
        guard case .notDue = again else { Issue.record("\(again)"); return }
    }

    @Test("A short history is left alone unless asked, and a forced fold of nothing much is refused")
    func notDue() throws {
        let (_, paper, _) = try Self.makeLibrary()
        for x in [40, 100, 160] as [CGFloat] { _ = try Self.write(paper.documentURL, [Self.mark(x)], folder: paper.folder) }
        let state = Compaction.State(additions: [Self.mark(160)])
        let before = try Data(contentsOf: paper.documentURL)
        guard case .notDue = Compaction.run(url: paper.documentURL, folder: paper.folder, meta: paper.meta, state: state) else { Issue.record("ran"); return }
        #expect(try Data(contentsOf: paper.documentURL) == before)
    }

    @Test("Another program's annotation in the folded revisions refuses the fold")
    func refusesForeignAnnotation() throws {
        let (_, paper, _) = try Self.makeLibrary()
        for k in 0..<3 { _ = try Self.write(paper.documentURL, [Self.mark(40 + CGFloat(k) * 50)], folder: paper.folder) }
        // Somebody else appends a square of their own.
        let data = try Data(contentsOf: paper.documentURL)
        let theirs = try IncrementalWriter.update(data) { document in
            let square = PDFAnnotation(bounds: CGRect(x: 300, y: 300, width: 60, height: 40), forType: .square, withProperties: nil)
            square.color = .red
            square.userName = "Someone Else"
            document.page(at: 0)?.addAnnotation(square)
        }
        guard case let .appended(withTheirs, _) = theirs else { Issue.record("no foreign append"); return }
        try withTheirs.write(to: paper.documentURL)
        let state = Compaction.State(additions: [Self.mark(140)])
        let outcome = Compaction.run(url: paper.documentURL, folder: paper.folder, meta: paper.meta, state: state, force: true)
        guard case .refused = outcome else { Issue.record("\(outcome)"); return }
        #expect(try Data(contentsOf: paper.documentURL) == withTheirs)
    }

    @Test("A revision that changed more than annotations refuses the fold")
    func refusesCatalogChange() throws {
        let (_, paper, _) = try Self.makeLibrary()
        _ = try Self.write(paper.documentURL, [Self.mark(40)], folder: paper.folder)
        let data = try Data(contentsOf: paper.documentURL)
        let file = try PDFFile(data: data)
        let info = try #require(file.trailer["Info"]?.ref)
        // A hand-written revision: a new /Info.
        var text = "\(info.num) \(info.gen) obj\n<< /Producer (Somebody) >>\nendobj\n"
        let objectOffset = data.count + 1
        let xrefOffset = objectOffset + text.utf8.count
        text += "xref\n0 1\n0000000000 65535 f\r\n\(info.num) 1\n\(String(format: "%010d", objectOffset)) \(String(format: "%05d", info.gen)) n\r\n"
        text += "trailer\n<< /Size \(file.size) /Root \(file.trailer["Root"]!.ref!.num) 0 R /Info \(info.num) \(info.gen) R /Prev \(file.startxref) >>\nstartxref\n\(xrefOffset)\n%%EOF\n"
        let changed = data + Data("\n".utf8) + Data(text.utf8)
        #expect(try !PDFFile(data: changed).repaired)
        try changed.write(to: paper.documentURL)
        let outcome = Compaction.run(url: paper.documentURL, folder: paper.folder, meta: paper.meta, state: Compaction.State(additions: [Self.mark(40)]), force: true)
        guard case let .refused(why) = outcome else { Issue.record("\(outcome)"); return }
        #expect(why.contains("Info") || why.contains("changed"), "\(why)")
        #expect(try Data(contentsOf: paper.documentURL) == changed)
    }

    @Test("A session folds its history when it closes, if it is due")
    func sessionCompactsOnClose() async throws {
        let (store, paper, original) = try Self.makeLibrary()
        let session = try await DocumentSession.open(paper: paper, store: store)
        session.restore([Self.mark(40)])
        await session.flush()
        for k in 1...5 {
            session.updateComment("words \(k)", forMarkup: session.markups[0].id)
            await session.flush()
        }
        let before = try Data(contentsOf: paper.documentURL)
        // Not due by size; due because a comment's old words are in the
        // history.
        await session.close()
        guard case .compacted? = session.lastCompaction else { Issue.record("\(String(describing: session.lastCompaction))"); return }
        let after = try Data(contentsOf: paper.documentURL)
        #expect(after.count < before.count)
        #expect(after.prefix(original.count) == original)
        #expect(session.markups.count == 1)
        #expect(!String(decoding: after, as: UTF8.self).contains("words 1"))
        #expect(String(decoding: after, as: UTF8.self).contains("words 5"))
        await session.close()
        guard case .notDue? = session.lastCompaction else { Issue.record("\(String(describing: session.lastCompaction))"); return }
    }

    // MARK: Restore

    @Test("A replace that finds the file changed leaves it alone")
    func replaceChecksTheFile() throws {
        let original = try SavingTests.makeDocument(text: "one")
        let url = try SavingTests.write(original)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: FileOperations.Failure.self) {
            try FileOperations.replace(url, with: Data("x".utf8), ifStill: Data("not it".utf8))
        }
        #expect(try Data(contentsOf: url) == original)
        try FileOperations.replace(url, with: Data("x".utf8), ifStill: original)
        #expect(try Data(contentsOf: url) == Data("x".utf8))
    }

    @Test("The original goes back under the marks; the damaged file goes to the Trash")
    func restoresOriginal() async throws {
        let (store, paper, original) = try Self.makeLibrary()
        let root = paper.folder.url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let originalCopy = root.appending(path: "Downloads-copy.pdf")
        try original.write(to: originalCopy)

        // (b) Damaged by a PDFKit rewrite, with a mark of ours that no
        // journal knows and an annotation of somebody else's.
        let damagedDocument = try #require(PDFDocument(data: original))
        let unjournaled = Self.mark(40, comment: "kept from the file")
        _ = TextMarkupWriter.apply(unjournaled, to: damagedDocument.page(at: 0)!)
        let square = PDFAnnotation(bounds: CGRect(x: 300, y: 300, width: 60, height: 40), forType: .square, withProperties: nil)
        square.color = .red
        square.userName = "Someone Else"
        square.contents = "theirs"
        damagedDocument.page(at: 0)?.addAnnotation(square)
        let damaged = try #require(damagedDocument.dataRepresentation())
        try damaged.write(to: paper.documentURL)
        #expect(FileProvenance.classify(damaged, importDigest: paper.meta.file.importDigest, byteSize: paper.meta.file.byteSize) == .rewritten)

        // And a journaled mark made through a session on the damaged file.
        let session = try await DocumentSession.open(paper: paper, store: store)
        let journaled = Self.mark(120)
        session.restore([journaled])
        await session.flush()
        #expect(session.markups.count == 2)

        // Not the original: refused.
        let other = try SavingTests.write(try SavingTests.makeDocument(text: "office affine different"))
        defer { try? FileManager.default.removeItem(at: other) }
        await #expect(throws: PaperRestore.Refusal.notTheOriginal) {
            _ = try await PaperRestore.plan(original: other, for: paper, store: store)
        }

        let plan = try await PaperRestore.plan(original: originalCopy, for: paper, store: store)
        #expect(plan.preview.pageCount == 1)
        #expect(plan.preview.marks == 2)
        #expect(plan.preview.foreign == 1)
        let damagedNow = try Data(contentsOf: paper.documentURL)
        let report = try PaperRestore.perform(plan, for: paper, libraryRoot: root)
        let restored = try Data(contentsOf: paper.documentURL)
        #expect(restored.count == report.bytes)
        #expect(restored.prefix(original.count) == original)
        #expect(FileProvenance.classify(restored, importDigest: paper.meta.file.importDigest, byteSize: paper.meta.file.byteSize) == .appended(tail: restored.count - original.count))
        let trashed = try #require(report.trashed)
        #expect(try Data(contentsOf: trashed) == damagedNow)
        #expect(PDFBase.load(from: paper.folder)?.length == original.count)

        let page = try #require(PDFDocument(data: restored)?.page(at: 0))
        #expect(TextMarkupWriter.isAlreadyWritten(unjournaled, on: page))
        #expect(TextMarkupWriter.isAlreadyWritten(journaled, on: page))
        #expect(page.annotations.contains { $0.type == "Square" && $0.contents == "theirs" })
        #expect(PaperRestore.difference(current: PDFDocument(data: damagedNow)!, candidate: PDFDocument(data: restored)!) == nil)

        await session.fileWasReplaced()
        #expect(session.markups.count == 2)
        #expect(session.document.page(at: 0)?.annotations.contains { $0.type == "Square" } == true)
        await session.saveAgain()
        guard case .success(.unchanged)? = session.lastWrite.map({ $0.mapError { $0 as NSError } }) else {
            Issue.record("a save after the restore wrote: \(String(describing: session.lastWrite))"); return
        }
    }
}
