import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import InkEngine

/// The sketch layer: shapes, arrows and text cards that live in a sidecar
/// and are copied into the PDF as standard annotations carrying themselves.
@Suite("Sketch elements")
struct SketchTests {
    static func rectangle(_ rect: CGRect, fill: SketchColor? = nil, text: String = "") -> SketchElement {
        SketchElement(
            kind: .rectangle,
            points: [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY)],
            style: SketchStyle(fill: fill),
            text: text
        )
    }

    @Test("An element survives being written as JSON and read back")
    func codableRoundTrip() throws {
        var element = SketchElement(kind: .arrow, points: [CGPoint(x: 10, y: 20), CGPoint(x: 200, y: 120)])
        element.bend = CGPoint(x: 0, y: 40)
        element.style.dash = .dashed
        element.style.fill = .paleBlue
        element.text = "왜?"
        let data = try JSONEncoder().encode(element)
        let back = try JSONDecoder().decode(SketchElement.self, from: data)
        #expect(back == element)
    }

    @Test("A file from a later version with fields this one lacks still reads")
    func unknownFieldsAreIgnored() throws {
        let json = """
        {"id":"6D2F2A1E-2B2F-4C0E-9A5E-000000000001","kind":"rectangle","points":[[0,0],[100,50]],
         "style":{"stroke":{"red":0,"green":0,"blue":1,"alpha":1},"glow":true},"shadow":"soft"}
        """
        let element = try JSONDecoder().decode(SketchElement.self, from: Data(json.utf8))
        #expect(element.kind == .rectangle)
        #expect(element.rect == CGRect(x: 0, y: 0, width: 100, height: 50))
        #expect(element.style.stroke.matches(SketchColor(0, 0, 1)))
        #expect(element.style.width == SketchStyle().width)
    }

    @Test("A bent arrow passes through the point its middle was dragged to")
    func bendFollowsTheHandle() {
        var arrow = SketchElement(kind: .arrow, points: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)])
        arrow.setMidpoint(CGPoint(x: 50, y: 30))
        #expect(abs(arrow.midpoint.x - 50) < 0.01)
        #expect(abs(arrow.midpoint.y - 30) < 0.01)
        // Straightened again when the handle is put back on the line.
        arrow.setMidpoint(CGPoint(x: 50, y: 0))
        #expect(arrow.bend == nil)
    }

    @Test("Hit-testing: an empty box is hit on its edge and not inside; a filled one anywhere")
    func boxHits() {
        let box = Self.rectangle(CGRect(x: 100, y: 100, width: 200, height: 100))
        #expect(box.hits(CGPoint(x: 100, y: 150), tolerance: 3))
        #expect(box.hits(CGPoint(x: 200, y: 200), tolerance: 3))
        #expect(!box.hits(CGPoint(x: 200, y: 150), tolerance: 3))
        let filled = Self.rectangle(CGRect(x: 100, y: 100, width: 200, height: 100), fill: .paleYellow)
        #expect(filled.hits(CGPoint(x: 200, y: 150), tolerance: 3))
        let labelled = Self.rectangle(CGRect(x: 100, y: 100, width: 200, height: 100), text: "hi")
        #expect(labelled.hits(CGPoint(x: 200, y: 150), tolerance: 3))
    }

    @Test("Hit-testing an arrow follows its curve")
    func arrowHits() {
        var arrow = SketchElement(kind: .arrow, points: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)])
        #expect(arrow.hits(CGPoint(x: 50, y: 2), tolerance: 3))
        #expect(!arrow.hits(CGPoint(x: 50, y: 30), tolerance: 3))
        arrow.setMidpoint(CGPoint(x: 50, y: 30))
        #expect(arrow.hits(CGPoint(x: 50, y: 30), tolerance: 3))
        #expect(!arrow.hits(CGPoint(x: 50, y: 2), tolerance: 3))
    }

    @Test("Fitting an element into a new box scales its points and its bend")
    func fitting() {
        var arrow = SketchElement(kind: .arrow, points: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 100)])
        arrow.bend = CGPoint(x: 10, y: -10)
        let old = arrow.rect
        let moved = arrow.fitted(to: CGRect(x: 50, y: 50, width: 200, height: 50), from: old)
        #expect(moved.start == CGPoint(x: 50, y: 50))
        #expect(moved.end == CGPoint(x: 250, y: 100))
        #expect(moved.bend == CGPoint(x: 20, y: -5))
    }

    @Test("Text is measured: more words make a taller card at a fixed width")
    func measurement() {
        let one = SketchTypesetter.cardSize(for: "one line", size: .medium)
        let many = SketchTypesetter.cardSize(for: "one line and then quite a lot more words to wrap", size: .medium, width: one.width + 20)
        #expect(one.height > 12)
        #expect(many.height > one.height * 1.8)
        let empty = SketchTypesetter.cardSize(for: "", size: .medium)
        #expect(empty.height > 12)
    }

    // MARK: - The PDF copy

    static func blankPage() throws -> (PDFDocument, PDFPage) {
        let document = try #require(PDFDocument(data: InkRoundTripTests.blankPDF(pages: 1)))
        return (document, try #require(document.page(at: 0)))
    }

    @Test("Every kind becomes a standard annotation, and the file gives the elements back")
    func writtenAndReadBack() throws {
        let (document, page) = try Self.blankPage()
        var arrow = SketchElement(kind: .arrow, points: [CGPoint(x: 50, y: 500), CGPoint(x: 250, y: 600)])
        arrow.setMidpoint(CGPoint(x: 150, y: 620))
        let straight = SketchElement(kind: .line, points: [CGPoint(x: 50, y: 400), CGPoint(x: 250, y: 400)], style: SketchStyle(endHead: .triangle))
        let box = Self.rectangle(CGRect(x: 300, y: 300, width: 150, height: 80), fill: .paleGreen, text: "Who?")
        let oval = SketchElement(kind: .ellipse, points: [CGPoint(x: 300, y: 500), CGPoint(x: 400, y: 560)])
        var card = SketchElement(kind: .text, points: [CGPoint(x: 60, y: 100), CGPoint(x: 220, y: 140)], text: "user personas\nuser flow path")
        card.style.fill = .paleYellow
        let elements = [arrow, straight, box, oval, card]

        let count = SketchWriter.apply(elements, to: page)
        // Five elements, plus the label inside the box.
        #expect(count == 6)

        let saved = try #require(document.dataRepresentation())
        let reloaded = try #require(PDFDocument(data: saved))
        let reloadedPage = try #require(reloaded.page(at: 0))
        let types = Set(reloadedPage.annotations.compactMap(\.type))
        #expect(types == ["Ink", "Line", "Square", "Circle", "FreeText"])

        let back = SketchWriter.elements(fromOwnedOn: reloadedPage)
        #expect(back.map(\.id) == elements.map(\.id))
        #expect(back == elements)

        // The straight line's ends land where the element's are.
        let line = try #require(reloadedPage.annotations.first { $0.type == "Line" })
        let start = CGPoint(x: line.bounds.minX + line.startPoint.x, y: line.bounds.minY + line.startPoint.y)
        #expect(abs(start.x - 50) < 0.5 && abs(start.y - 400) < 0.5)
        #expect(line.endLineStyle == .closedArrow)
    }

    @Test("Applying again replaces our copy and leaves other annotations alone")
    func reapplyIsScoped() throws {
        let (_, page) = try Self.blankPage()
        let theirs = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 50, height: 50), forType: .square, withProperties: nil)
        page.addAnnotation(theirs)
        let first = Self.rectangle(CGRect(x: 100, y: 100, width: 50, height: 50))
        SketchWriter.apply([first], to: page)
        #expect(SketchWriter.isAlreadyWritten([first], on: page))
        let second = Self.rectangle(CGRect(x: 200, y: 100, width: 50, height: 50))
        #expect(!SketchWriter.isAlreadyWritten([second], on: page))
        SketchWriter.apply([second], to: page)
        let squares = page.annotations.filter { $0.type == "Square" }
        #expect(squares.count == 2)
        #expect(squares.contains { $0 === theirs })
        #expect(SketchWriter.elements(fromOwnedOn: page).map(\.id) == [second.id])
    }

    @Test("Sketch ink is not foreign ink")
    func sketchInkIsOurs() throws {
        let (_, page) = try Self.blankPage()
        var arrow = SketchElement(kind: .arrow, points: [CGPoint(x: 50, y: 500), CGPoint(x: 250, y: 600)])
        arrow.setMidpoint(CGPoint(x: 150, y: 620))
        SketchWriter.apply([arrow], to: page)
        #expect(page.annotations.contains { $0.type == "Ink" })
        #expect(!InkConverter.hasForeignInk(on: page))
        // And the pen's converter does not adopt it as a stroke.
        #expect(InkConverter.drawing(fromOwnedInkOn: page).strokes.isEmpty)
    }

    @Test("Rendering draws something where the element is, and nothing elsewhere")
    func rendersInPlace() throws {
        let width = 200, height = 200
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let box = Self.rectangle(CGRect(x: 20, y: 20, width: 100, height: 60), fill: .paleBlue, text: "Label")
        var arrow = SketchElement(kind: .arrow, points: [CGPoint(x: 130, y: 100), CGPoint(x: 190, y: 190)])
        arrow.style.stroke = .red
        SketchRenderer.draw([box, arrow], in: context)
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        func isWhite(_ x: Int, _ y: Int) -> Bool {
            // Core Graphics bitmaps run top-down; the page's y runs up.
            let row = height - 1 - y
            let i = (row * width + x) * 4
            return pixels[i] > 250 && pixels[i + 1] > 250 && pixels[i + 2] > 250
        }
        #expect(!isWhite(70, 20))   // the box's bottom edge
        #expect(!isWhite(70, 50))   // its blue wash
        #expect(!isWhite(160, 145)) // the arrow's shaft
        #expect(isWhite(150, 30))   // empty paper
        #expect(isWhite(30, 150))
    }
}
