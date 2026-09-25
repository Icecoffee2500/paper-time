import AppKit
import Foundation
import PDFKit
import Testing
@testable import PDFUpdate

/// The reason the writer exists: saving marks must not change a letter of a
/// paper's text.
///
/// Every way PDFKit has of writing a document out re-subsets its fonts. On a
/// paper set in TeX — Computer Modern, the ligatures "ff", "fi", "ffi" as
/// single glyphs named in the font's encoding and no ToUnicode map — the
/// ligatures lose their letters: LeJEPA's "ff" came back as nothing, and
/// "!" appeared sixty-four times. In the file, for every reader.
@Suite("The text layer")
struct TextLayerTests {
    static func texts(_ d: PDFDocument) -> [String] { (0..<d.pageCount).map { d.page(at: $0)?.string ?? "" } }

    static func ligatureFixture() throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "ligatures", withExtension: "pdf", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    @Test("PDFKit's own rewrite of a TeX page loses its ligatures — why the paper is never rewritten")
    func pdfKitRewriteDamagesTeX() throws {
        let original = try Self.ligatureFixture()
        let document = try #require(PDFDocument(data: original))
        let before = Self.texts(document)
        #expect(before[0].contains("\u{FB00}"), "the fixture should read its ff ligature: \(before[0])")
        let rewritten = try #require(document.dataRepresentation())
        let after = Self.texts(try #require(PDFDocument(data: rewritten)))
        // The control. If this ever fails, PDFKit has stopped damaging TeX
        // fonts — worth knowing, and no reason to start rewriting papers.
        #expect(after != before, "PDFKit's rewrite kept the ligatures this time")
        #expect(!after[0].contains("\u{FB00}"))
    }

    @Test("Marks saved into a TeX page leave every letter of it where it was")
    func writerKeepsTeXText() throws {
        let original = try Self.ligatureFixture()
        let before = Self.texts(try #require(PDFDocument(data: original)))
        // A highlight over the first line, a note, and then both taken away.
        guard case let .appended(once, _) = try IncrementalWriter.update(original, edit: { document in
            guard let page = document.page(at: 0),
                  let line = page.selection(for: NSRange(location: 0, length: 30))
            else { return }
            let mark = PDFAnnotation(bounds: line.bounds(for: page), forType: .highlight, withProperties: nil)
            mark.setValue("L-1", forAnnotationKey: PDFAnnotationKey(rawValue: "/PTMarkupID"))
            page.addAnnotation(mark)
            page.addAnnotation(IncrementalUpdateTests.ourNote())
        }) else { Issue.record("nothing written"); return }
        #expect(once.prefix(original.count) == original)
        #expect(Self.texts(try #require(PDFDocument(data: once))) == before)

        guard case let .appended(twice, _) = try IncrementalWriter.update(once, edit: { document in
            guard let page = document.page(at: 0) else { return }
            for a in page.annotations { page.removeAnnotation(a) }
        }) else { Issue.record("the removal wrote nothing"); return }
        #expect(twice.prefix(once.count) == once)
        #expect(Self.texts(try #require(PDFDocument(data: twice))) == before)
        #expect(PDFDocument(data: twice)?.page(at: 0)?.annotations.isEmpty == true)
    }

    // MARK: The real papers, when they are here

    static let corpus = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Documents/Bookends/Attachments")
    static var corpusIsHere: Bool { FileManager.default.fileExists(atPath: corpus.path(percentEncoded: false)) }

    @Test("On the library's own papers: a save changes no page's text, where PDFKit's rewrite does",
          .enabled(if: corpusIsHere, "the papers are not on this machine"), .timeLimit(.minutes(20)))
    func corpus() throws {
        let files = try FileManager.default.contentsOfDirectory(at: Self.corpus, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "pdf" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var written = 0
        var refused: [String] = []
        for url in files {
            // Read, never written: everything below happens in memory.
            let original = try Data(contentsOf: url)
            guard let document = PDFDocument(data: original), !document.isLocked else { continue }
            let before = Self.texts(document)
            let pageIndex = before.firstIndex { $0.count >= 400 } ?? 0
            let outcome: IncrementalWriter.Outcome
            do {
                outcome = try IncrementalWriter.update(original) { d in
                    guard let page = d.page(at: pageIndex) else { return }
                    let box = page.bounds(for: .cropBox)
                    let mark = PDFAnnotation(bounds: CGRect(x: box.minX + 72, y: box.midY, width: 200, height: 12), forType: .highlight, withProperties: nil)
                    mark.setValue("C-1", forAnnotationKey: PDFAnnotationKey(rawValue: "/PTMarkupID"))
                    page.addAnnotation(mark)
                    page.addAnnotation(IncrementalUpdateTests.ourNote())
                }
            } catch {
                refused.append("\(url.lastPathComponent): \(error)")
                continue
            }
            guard case let .appended(out, _) = outcome else {
                Issue.record("\(url.lastPathComponent): nothing written")
                continue
            }
            #expect(out.prefix(original.count) == original, "\(url.lastPathComponent): the paper's bytes changed")
            let after = Self.texts(try #require(PDFDocument(data: out)))
            let differing = before.indices.filter { before[$0] != after[$0] }
            #expect(differing.isEmpty, "\(url.lastPathComponent): the text of \(differing.count) pages changed")
            written += 1
        }
        #expect(refused.isEmpty, "refused: \(refused)")
        #expect(written > 0)

        // The control: the same paper written out by PDFKit, untouched.
        let lejepa = Self.corpus.appending(path: "LeJEPA.pdf")
        if FileManager.default.fileExists(atPath: lejepa.path(percentEncoded: false)) {
            let document = try #require(PDFDocument(url: lejepa))
            let before = Self.texts(document)
            let data = try #require(document.dataRepresentation())
            let rewritten = try #require(PDFDocument(data: data))
            #expect(Self.texts(rewritten) != before, "PDFKit's rewrite of LeJEPA kept its text this time")
        }
    }
}
