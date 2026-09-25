import CoreGraphics
import CoreText
import Foundation
import InkEngine
import LibraryStore
import PDFKit
import PaperCore
import Testing
@testable import PDFReader

/// The paper is never written out again: marks are appended after its own
/// bytes, a save with nothing to add writes nothing, and a file that will not
/// take the marks is left exactly as it was while the marks stay in the app.
@Suite("Saving by appending")
@MainActor
struct IncrementalSavingTests {
    static func mark(_ x: CGFloat) -> MarkupDescriptor {
        MarkupDescriptor(kind: .highlight, pageIndex: 0, rects: [CGRect(x: x, y: 695, width: 40, height: 14)], color: .yellow, quotedText: "word")
    }

    static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// A one-page PDF whose owner password forbids adding annotations — it
    /// opens without asking, and says no to marks.
    static func makeForbidding(text: String) throws -> Data {
        let data = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: data))
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let permissions: CGPDFAccessPermissions = [.allowsHighQualityPrinting, .allowsLowQualityPrinting, .allowsContentCopying, .allowsContentAccessibility]
        let info: [CFString: Any] = [
            kCGPDFContextOwnerPassword: "owner",
            kCGPDFContextAccessPermissions: permissions.rawValue,
        ]
        let context = try #require(CGContext(consumer: consumer, mediaBox: &mediaBox, info as CFDictionary))
        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font as Any]))
        context.textPosition = CGPoint(x: 40, y: 700)
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    @Test("A save appends to the paper, and the same save again writes nothing")
    func appendsThenNothing() throws {
        let original = try SavingTests.makeDocument(text: "office affine different")
        let url = try SavingTests.write(original)
        defer { try? FileManager.default.removeItem(at: url) }

        let mark = Self.mark(40)
        let first = try DocumentSession.write(to: url, additions: [mark], removals: [], ink: [:]).get()
        guard case let .appended(bytes) = first else { Issue.record("got \(first)"); return }
        let once = try Data(contentsOf: url)
        #expect(bytes == once.count - original.count)
        #expect(once.prefix(original.count) == original)
        #expect(PDFDocument(data: once)?.page(at: 0)?.string == PDFDocument(data: original)?.page(at: 0)?.string)

        let date = Self.modified(url)
        let second = try DocumentSession.write(to: url, additions: [mark], removals: [], ink: [:]).get()
        #expect(second == .unchanged)
        #expect(try Data(contentsOf: url) == once)
        #expect(Self.modified(url) == date)
    }

    @Test("A file that forbids marks is left byte for byte as it was, and the marks stay in the app")
    func refusalKeepsFile() async throws {
        let original = try Self.makeForbidding(text: "alpha beta gamma")
        #expect(PDFDocument(data: original)?.allowsCommenting == false)
        let (store, paper) = try SyncTests.makeLibrary()
        try original.write(to: paper.documentURL)
        let date = Self.modified(paper.documentURL)

        let direct = try DocumentSession.write(to: paper.documentURL, additions: [Self.mark(40)], removals: [], ink: [:]).get()
        #expect(direct == .keptInApp(.permissions))

        let session = try await DocumentSession.open(paper: paper, store: store)
        session.restore([Self.mark(100)])
        await session.flush()
        #expect(session.saveState == .keptInApp(.forbidden))
        #expect(try Data(contentsOf: paper.documentURL) == original)
        #expect(Self.modified(paper.documentURL) == date)
        // The mark is still the session's; another mark, and a save asked
        // for outright, still leave the file alone.
        #expect(session.markups.count == 1)
        session.restore([Self.mark(200)])
        await session.flush()
        #expect(session.saveState == .keptInApp(.forbidden))
        await session.saveAgain()
        #expect(session.saveState == .keptInApp(.forbidden))
        #expect(try Data(contentsOf: paper.documentURL) == original)
        #expect(session.markups.count == 2)
    }

    @Test("A session's save of nothing new writes nothing")
    func sessionNoOp() async throws {
        let (store, paper) = try SyncTests.makeLibrary()
        let session = try await DocumentSession.open(paper: paper, store: store)
        session.restore([Self.mark(40)])
        await session.flush()
        guard case .success(.appended)? = session.lastWrite.map({ $0.mapError { $0 as NSError } }) else {
            Issue.record("the first save did not append: \(String(describing: session.lastWrite))"); return
        }
        let once = try Data(contentsOf: paper.documentURL)
        await session.saveAgain()
        guard case .success(.unchanged)? = session.lastWrite.map({ $0.mapError { $0 as NSError } }) else {
            Issue.record("a save of nothing wrote: \(String(describing: session.lastWrite))"); return
        }
        #expect(try Data(contentsOf: paper.documentURL) == once)
        #expect(session.saveState == .idle)
    }

    @Test("An update that would change what is already in a file is not written")
    func onlyAppends() throws {
        let original = try SavingTests.makeDocument(text: "one two three")
        let url = try SavingTests.write(original)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: FileOperations.Failure.self) {
            try FileOperations.update(url) { data in
                var changed = data
                changed[changed.startIndex + 20] ^= 0xFF
                return changed + Data("more".utf8)
            }
        }
        #expect(try Data(contentsOf: url) == original)
        #expect(try FileOperations.update(url) { _ in nil } == false)
        #expect(try Data(contentsOf: url) == original)
    }

    /// The source of the package's reader, and of the app when it is next
    /// to it, never serialises a PDFDocument: every way PDFKit has of doing
    /// that re-subsets the fonts, and on papers set in TeX it takes the text
    /// with it. A drawing's `dataRepresentation()` is a different thing and
    /// is allowed; so is a line that says why it is not a paper.
    @Test("Nothing serialises a paper with PDFKit")
    func noPaperIsSerialised() throws {
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var folders = [package.appending(path: "Sources/PDFReader"), package.appending(path: "Sources/PDFUpdate")]
        let app = package.deletingLastPathComponent().deletingLastPathComponent().appending(path: "App")
        if FileManager.default.fileExists(atPath: app.path) { folders.append(app) }
        var offenders: [String] = []
        var files = 0
        for folder in folders {
            let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
            while let url = walker?.nextObject() as? URL {
                guard url.pathExtension == "swift", let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                files += 1
                for (n, line) in text.components(separatedBy: "\n").enumerated() {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("//") { continue }
                    let serialises = line.contains("dataRepresentation(")
                        || line.range(of: #"[Dd]ocument\??\.write\(to"#, options: .regularExpression) != nil
                        || line.contains(".write(toFile")
                    guard serialises else { continue }
                    if line.lowercased().contains("drawing") || line.contains("// not a paper:") { continue }
                    offenders.append("\(url.lastPathComponent):\(n + 1): \(trimmed)")
                }
            }
        }
        #expect(files > 10)
        #expect(offenders.isEmpty, "\(offenders.joined(separator: "\n"))")
    }
}
