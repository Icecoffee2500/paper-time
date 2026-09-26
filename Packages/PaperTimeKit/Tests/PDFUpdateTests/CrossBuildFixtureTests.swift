import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import PDFUpdate

/// The marks of a file written by the Portable build, as compaction reads
/// them — and the same marks spelled the way PDFKit spells them.
///
/// `Fixtures/portable-appended.pdf` is `portable-base.pdf` (two pages of
/// Helvetica, a colleague's highlight with its popup, a link) plus one save
/// of the Portable appender (`Portable/tools/cross-fixture.mjs`): a
/// highlight of two lines with a comment, an underline, a box and a card of
/// the sketch layer, a pen stroke of 41 points. `portable-history.pdf` has a
/// hundred more saves on it.
@Suite("Cross-build fixture")
struct CrossBuildFixtureTests {
    static func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "pdf", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    static func key(_ name: String) -> PDFAnnotationKey { PDFAnnotationKey(rawValue: "/\(name)") }

    @Test("A Portable file reads as marks: one highlight of two lines, not two annotations")
    func readsAsMarks() throws {
        let file = try PDFFile(data: try Self.fixture("portable-appended"))
        let pages = try AnnotationMeaning.pages(of: file)
        #expect(pages.count == 2)
        var foreign = 0, sketches = 0, inks: [AnnotationMeaning.Ink] = [], markups: [AnnotationMeaning.Markup] = []
        for mark in pages[0] {
            switch mark {
            case .foreign: foreign += 1
            case .sketch: sketches += 1
            case let .ink(i): inks.append(i)
            case let .markup(m): markups.append(m)
            }
        }
        #expect(foreign == 1)
        #expect(sketches == 2)
        #expect(inks.count == 1)
        #expect(inks.first?.paths.first?.count == 41)
        #expect(inks.first?.width == 2)
        #expect(inks.first?.colour == [26, 51, 179])
        let highlight = try #require(markups.first { $0.subtype == "Highlight" })
        #expect(highlight.id == "C3A6D2E0-5B1F-4E7A-9C2D-1F0E8B7A6D5C")
        #expect(highlight.boxes == ["72.0 286.0 192.0 297.0", "72.0 300.0 322.0 311.0"])
        #expect(highlight.colour == [255, 214, 64])
        #expect(highlight.comment == "why here? — 여기가 왜")
        let underline = try #require(markups.first { $0.subtype == "Underline" })
        #expect(underline.comment == nil)
        #expect(underline.contents == "The office of the reader is to read")
        // The link on page 1, as it is.
        #expect(pages[1].count == 1)
        if case .foreign = pages[1][0] {} else { Issue.record("the link should be foreign") }

        // A file is the same as itself; the history shows the same marks as
        // the one save, a hundred saves later.
        let appended = try Self.fixture("portable-appended")
        #expect(try AnnotationComparison.markDifference(current: appended, candidate: appended) == nil)
        let history = try Self.fixture("portable-history")
        #expect(try PDFFile(data: history).sections.count == 102)
        #expect(try AnnotationComparison.markDifference(current: appended, candidate: history) == nil)
    }

    /// The Portable file's marks, written again by PDFKit onto the base the
    /// way the Mac's writers spell them: the highlight as one annotation per
    /// line, `/Border`, `/DA`, `/T`, the stroke resampled, the payload as a
    /// plain string.
    static func respelled(_ portable: Data, base: Data, tweak: (PDFPage) -> Void = { _ in }) throws -> Data {
        let source = try #require(PDFDocument(data: portable)?.page(at: 0))
        func value(_ name: String, of type: String) -> String? {
            source.annotations.first { $0.type == type }?.value(forAnnotationKey: key(name)) as? String
        }
        let outcome = try IncrementalWriter.update(base) { document in
            guard let page = document.page(at: 0) else { return }
            for rect in [CGRect(x: 72, y: 300, width: 250, height: 11), CGRect(x: 72, y: 286, width: 120, height: 11)] {
                let a = PDFAnnotation(bounds: rect, forType: .highlight, withProperties: nil)
                a.color = PlatformColor(red: 1, green: 0.84, blue: 0.25, alpha: 1)
                a.contents = "why here? — 여기가 왜"
                a.userName = "Somebody"
                a.setValue("C3A6D2E0-5B1F-4E7A-9C2D-1F0E8B7A6D5C", forAnnotationKey: key("PTMarkupID"))
                a.setValue("why here? — 여기가 왜", forAnnotationKey: key("PTComment"))
                page.addAnnotation(a)
            }
            let u = PDFAnnotation(bounds: CGRect(x: 72, y: 698, width: 200, height: 12), forType: .underline, withProperties: nil)
            u.color = PlatformColor(red: 0.42, green: 0.71, blue: 0.98, alpha: 1)
            // The quotation as PDFKit takes it off the page: not the same words.
            u.contents = "The office of the reader is to read, an"
            u.setValue("7D4B9F21-3C8E-4A6D-B1F5-2E9C0A7D4B31", forAnnotationKey: key("PTMarkupID"))
            page.addAnnotation(u)

            // The stroke, sampled twice as finely along the same line.
            let path = PlatformBezierPath()
            for k in 0...80 {
                let t = Double(k) / 80
                let p = CGPoint(x: 80 + 200 * t, y: 420 + 30 * sin(t * .pi * 2))
                if k == 0 { path.move(to: p) } else { path.line(to: p) }
            }
            let bounds = path.bounds.insetBy(dx: -2, dy: -2)
            let ink = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
            let moved = path.copy() as! PlatformBezierPath
            moved.transform(using: AffineTransform(translationByX: -bounds.minX, byY: -bounds.minY))
            ink.add(moved)
            ink.color = PlatformColor(red: 0.1, green: 0.2, blue: 0.7, alpha: 1)
            let border = PDFBorder()
            border.lineWidth = 2
            ink.border = border
            ink.userName = "Paper Time"
            ink.setValue("Paper Time", forAnnotationKey: key("PTInk"))
            ink.setValue("abc123", forAnnotationKey: key("PTInkStroke"))
            page.addAnnotation(ink)

            let box = PDFAnnotation(bounds: CGRect(x: 100, y: 600, width: 150, height: 80), forType: .square, withProperties: nil)
            box.userName = "Paper Time Sketch"
            box.setValue(value("PTSketchID", of: "Square") ?? "", forAnnotationKey: key("PTSketchID"))
            box.setValue(value("PTSketch", of: "Square") ?? "", forAnnotationKey: key("PTSketch"))
            page.addAnnotation(box)
            let card = PDFAnnotation(bounds: CGRect(x: 320, y: 600, width: 160, height: 60), forType: .freeText, withProperties: nil)
            card.contents = "a card with $x^2$"
            card.userName = "Paper Time Sketch"
            card.setValue(value("PTSketchID", of: "FreeText") ?? "", forAnnotationKey: key("PTSketchID"))
            card.setValue(value("PTSketch", of: "FreeText") ?? "", forAnnotationKey: key("PTSketch"))
            page.addAnnotation(card)
            tweak(page)
        }
        guard case let .appended(data, _) = outcome else { throw PDFError.missing("no append") }
        return data
    }

    @Test("PDFKit's spelling of the same marks is the same marks")
    func spellingDoesNotCount() throws {
        let portable = try Self.fixture("portable-appended")
        let base = try Self.fixture("portable-base")
        let mac = try Self.respelled(portable, base: base)
        #expect(try AnnotationComparison.markDifference(current: portable, candidate: mac) == nil)
        #expect(try AnnotationComparison.markDifference(current: mac, candidate: portable) == nil)
    }

    @Test("A mark that moved, changed colour, lost its comment or its stroke is not the same")
    func changesCount() throws {
        let portable = try Self.fixture("portable-appended")
        let base = try Self.fixture("portable-base")
        func differs(_ tweak: @escaping (PDFPage) -> Void) throws -> String {
            try #require(try AnnotationComparison.markDifference(current: portable, candidate: try Self.respelled(portable, base: base, tweak: tweak)))
        }
        // Moved by a third of a point.
        let moved = try differs { page in
            let a = page.annotations.first { $0.type == "Underline" }!
            a.bounds = a.bounds.offsetBy(dx: 0.3, dy: 0)
        }
        #expect(moved.contains("Underline"))
        // Recoloured by two 255ths.
        let recoloured = try differs { page in
            page.annotations.first { $0.type == "Underline" }!.color = PlatformColor(red: 0.42, green: 0.71, blue: 0.99, alpha: 1)
        }
        #expect(recoloured.contains("Underline"))
        // The comment gone.
        let uncommented = try differs { page in
            for a in page.annotations where a.type == "Highlight" && a.value(forAnnotationKey: Self.key("PTComment")) != nil {
                a.removeValue(forAnnotationKey: Self.key("PTComment"))
                a.contents = "A second line"
            }
        }
        #expect(uncommented.contains("Highlight"))
        // A comment on the underline where there was none.
        let commented = try differs { page in
            page.annotations.first { $0.type == "Underline" }!.setValue("really?", forAnnotationKey: Self.key("PTComment"))
        }
        #expect(commented.contains("Underline"))
        // The stroke a point to the right.
        let shifted = try differs { page in
            let a = page.annotations.first { $0.type == "Ink" }!
            a.bounds = a.bounds.offsetBy(dx: 1, dy: 0)
        }
        #expect(shifted.contains("Ink"))
        // The card gone.
        let lost = try differs { page in
            page.removeAnnotation(page.annotations.first { $0.type == "FreeText" }!)
        }
        #expect(lost.contains("FreeText"))
    }
}
