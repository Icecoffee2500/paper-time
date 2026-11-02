import CoreGraphics
import Foundation
import Testing
import Bibliography
import LibraryStore
import PaperCore
@testable import Importers

/// Bringing a Bookends or Zotero export across: the plan says what will be
/// attached to what, and the import writes records that the resolver still
/// gets to check (`needsReview`, never `verified`).
@Suite("Library migration")
struct LibraryMigratorTests {
    static func makeRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "papertime-migrate-\(UUID().uuidString)", directoryHint: .isDirectory)
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

    /// Three records the way Zotero and Bookends write them: one with a
    /// `file` field in Zotero's three-part form, one Bookends-style with a
    /// bare path, one with no file at all whose title names the PDF.
    static let bib = """
    @article{qi2024,
      title = {Model aggregation techniques in federated learning: A comprehensive survey},
      author = {Qi, Pian and Chiaro, Diletta},
      journal = {Future Generation Computer Systems},
      year = {2024},
      doi = {https://doi.org/10.1016/j.future.2023.09.008},
      file = {Full Text PDF:files/1234/Qi et al. - 2024 - Model aggregation.pdf:application/pdf}
    }
    @inproceedings{mobahi2020,
      title = {Self-Distillation Amplifies Regularization in Hilbert Space},
      author = {Mobahi, Hossein and Farajtabar, Mehrdad and Bartlett, Peter},
      booktitle = {Advances in Neural Information Processing Systems},
      year = {2020},
      file = {/Users/someone/Bookends/Attachments/self-distillation.pdf}
    }
    @article{kirkpatrick2017,
      title = {Overcoming catastrophic forgetting in neural networks},
      author = {Kirkpatrick, James},
      journal = {PNAS},
      year = {2017}
    }
    @misc{nowhere2019,
      title = {A record whose PDF is not in the folder},
      author = {Nobody},
      year = {2019}
    }
    """

    @Test("The plan matches by file hint first, then by title, and leaves the rest unattached")
    func plan() throws {
        let root = try Self.makeRoot()
        let pdfs = root.appending(path: "pdfs")
        try FileManager.default.createDirectory(at: pdfs, withIntermediateDirectories: true)
        try Self.writePDF(named: "Qi et al. - 2024 - Model aggregation.pdf", in: pdfs)
        try Self.writePDF(named: "self-distillation.pdf", in: pdfs)
        try Self.writePDF(named: "Overcoming catastrophic forgetting in neural networks.pdf", in: pdfs)
        try Self.writePDF(named: "unrelated-scan.pdf", in: pdfs)
        let bibURL = root.appending(path: "library.bib")
        try Self.bib.write(to: bibURL, atomically: true, encoding: .utf8)

        let plan = try LibraryMigrator.plan(bibliographyAt: bibURL, attachmentsFolder: pdfs)
        #expect(plan.totalRecords == 4)
        #expect(plan.matched.count == 3)
        let byKey = Dictionary(uniqueKeysWithValues: plan.matched.map { ($0.record.bibKey, $0) })
        #expect(byKey["qi2024"]?.documentURL?.lastPathComponent == "Qi et al. - 2024 - Model aggregation.pdf")
        #expect(byKey["qi2024"]?.matchReason.contains("file path") == true)
        #expect(byKey["mobahi2020"]?.documentURL?.lastPathComponent == "self-distillation.pdf")
        #expect(byKey["kirkpatrick2017"]?.documentURL?.lastPathComponent == "Overcoming catastrophic forgetting in neural networks.pdf")
        #expect(byKey["kirkpatrick2017"]?.matchReason.contains("title") == true)
        #expect(plan.withoutDocuments.map(\.bibKey) == ["nowhere2019"])
        #expect(plan.orphanedDocuments.map(\.lastPathComponent) == ["unrelated-scan.pdf"])
        // A DOI written as a URL, the way Elsevier's export writes it, is still a DOI.
        #expect(byKey["qi2024"]?.record.identifiers.doi == "10.1016/j.future.2023.09.008")
    }

    @Test("Applying the plan copies the PDFs in and writes records the resolver still checks")
    func apply() async throws {
        let root = try Self.makeRoot()
        let pdfs = root.appending(path: "pdfs")
        try FileManager.default.createDirectory(at: pdfs, withIntermediateDirectories: true)
        try Self.writePDF(named: "self-distillation.pdf", in: pdfs)
        let bibURL = root.appending(path: "library.bib")
        try Self.bib.write(to: bibURL, atomically: true, encoding: .utf8)
        let plan = try LibraryMigrator.plan(bibliographyAt: bibURL, attachmentsFolder: pdfs)

        let libraryRoot = root.appending(path: "library")
        try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        let store = LibraryStore(root: libraryRoot)
        _ = try await store.bootstrap()
        let outcome = await LibraryMigrator.apply(plan, to: store)
        #expect(outcome.failures.isEmpty)
        #expect(outcome.imported.count == 1)
        let paper = try #require(outcome.imported.first)
        #expect(paper.meta.bibKey == "mobahi2020")
        #expect(paper.meta.csl.title == "Self-Distillation Amplifies Regularization in Hilbert Space")
        #expect(paper.meta.csl.type == .paperConference)
        #expect(paper.meta.confidence == .needsReview)
        #expect(paper.meta.provenance.source == .importedBibTeX)
        #expect(FileManager.default.fileExists(atPath: paper.documentURL.path))
        // The original stays where it was: an import copies, it does not move.
        #expect(FileManager.default.fileExists(atPath: pdfs.appending(path: "self-distillation.pdf").path))
    }

    @Test("A Zotero RIS export reads the same way")
    func ris() throws {
        let root = try Self.makeRoot()
        let pdfs = root.appending(path: "pdfs")
        try FileManager.default.createDirectory(at: pdfs, withIntermediateDirectories: true)
        try Self.writePDF(named: "Mobahi et al. - 2020 - Self-Distillation.pdf", in: pdfs)
        let ris = """
        TY  - CONF
        TI  - Self-Distillation Amplifies Regularization in Hilbert Space
        AU  - Mobahi, Hossein
        AU  - Farajtabar, Mehrdad
        T2  - Advances in Neural Information Processing Systems
        PY  - 2020
        L1  - files/99/Mobahi et al. - 2020 - Self-Distillation.pdf
        ER  -

        """
        let risURL = root.appending(path: "export.ris")
        try ris.write(to: risURL, atomically: true, encoding: .utf8)
        let plan = try LibraryMigrator.plan(bibliographyAt: risURL, attachmentsFolder: pdfs)
        #expect(plan.matched.count == 1)
        #expect(plan.matched.first?.documentURL?.lastPathComponent == "Mobahi et al. - 2020 - Self-Distillation.pdf")
    }
}
