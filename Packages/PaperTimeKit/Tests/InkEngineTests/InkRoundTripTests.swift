import CoreGraphics
import Foundation
import PDFKit
import PencilKit
import Testing
@testable import InkEngine

/// Proves the promise the app is built around: a stroke drawn in the app is
/// present in the PDF file itself, survives being written to disk and read back
/// by an unrelated PDF reader, and lands where it was drawn.
@Suite("Ink round trip")
struct InkRoundTripTests {
    static func blankPDF(size: CGSize = CGSize(width: 612, height: 792), pages: Int = 2) -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data) else { return Data() }
        var mediaBox = CGRect(origin: .zero, size: size)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            return Data()
        }
        for _ in 0..<pages {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(mediaBox)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    static func stroke(from start: CGPoint, to end: CGPoint, width: CGFloat = 4) -> PKStroke {
        var points: [PKStrokePoint] = []
        for step in 0...10 {
            let fraction = CGFloat(step) / 10
            let x: CGFloat = start.x + (end.x - start.x) * fraction
            let y: CGFloat = start.y + (end.y - start.y) * fraction
            let point = PKStrokePoint(
                location: CGPoint(x: x, y: y),
                timeOffset: TimeInterval(fraction),
                size: CGSize(width: width, height: width),
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: .pi / 2
            )
            points.append(point)
        }
        let path = PKStrokePath(controlPoints: points, creationDate: Date())
        return PKStroke(ink: PKInk(.pen, color: PlatformColor.red), path: path)
    }

    @Test("A drawn stroke becomes an ink annotation inside the saved PDF file")
    func strokeSurvivesSaving() throws {
        let document = try #require(PDFDocument(data: Self.blankPDF()))
        let page = try #require(document.page(at: 0))

        let drawing = PKDrawing(strokes: [Self.stroke(
            from: CGPoint(x: 100, y: 100),
            to: CGPoint(x: 300, y: 200)
        )])
        let written = InkConverter.apply(drawing, to: page)
        #expect(written == 1)

        // Serialise and re-open, which is what any other reader would do.
        let saved = try #require(document.dataRepresentation())
        let reloaded = try #require(PDFDocument(data: saved))
        let reloadedPage = try #require(reloaded.page(at: 0))
        let inkAnnotations = reloadedPage.annotations.filter { $0.type == "Ink" }

        #expect(inkAnnotations.count == 1)
        let annotation = try #require(inkAnnotations.first)
        // The stroke was drawn 100 points down from the top of a 792-point
        // page, so in PDF coordinates it sits near y = 692.
        #expect(annotation.bounds.maxY > 680)
        #expect(annotation.bounds.minY < 700)
        #expect(annotation.bounds.minX < 105)
        #expect(annotation.bounds.maxX > 295)
    }

    @Test("Re-applying a drawing replaces this app's ink and leaves other marks alone")
    func regenerationIsScoped() throws {
        let document = try #require(PDFDocument(data: Self.blankPDF()))
        let page = try #require(document.page(at: 0))

        // A highlight made by any other app, which must survive.
        let foreign = PDFAnnotation(
            bounds: CGRect(x: 50, y: 50, width: 100, height: 20),
            forType: .highlight,
            withProperties: nil
        )
        page.addAnnotation(foreign)

        InkConverter.apply(
            PKDrawing(strokes: [
                Self.stroke(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 20, y: 20)),
                Self.stroke(from: CGPoint(x: 30, y: 30), to: CGPoint(x: 40, y: 40)),
            ]),
            to: page
        )
        #expect(page.annotations.filter { $0.type == "Ink" }.count == 2)

        InkConverter.apply(
            PKDrawing(strokes: [Self.stroke(from: CGPoint(x: 60, y: 60), to: CGPoint(x: 70, y: 70))]),
            to: page
        )
        #expect(page.annotations.filter { $0.type == "Ink" }.count == 1)
        #expect(page.annotations.contains { $0.type == "Highlight" })
    }

    @Test("An empty drawing clears the page's ink")
    func emptyDrawingClears() throws {
        let document = try #require(PDFDocument(data: Self.blankPDF()))
        let page = try #require(document.page(at: 0))
        InkConverter.apply(
            PKDrawing(strokes: [Self.stroke(from: .zero, to: CGPoint(x: 50, y: 50))]),
            to: page
        )
        #expect(!page.annotations.isEmpty)
        InkConverter.apply(PKDrawing(), to: page)
        #expect(page.annotations.filter { $0.type == "Ink" }.isEmpty)
    }

    @Test("Ink written on a rotated page lands in the same visual place")
    func rotatedPage() throws {
        let document = try #require(PDFDocument(data: Self.blankPDF()))
        let page = try #require(document.page(at: 0))
        page.rotation = 90

        let geometry = PageGeometry(page: page)
        // On a 90-degree page the canvas is 792 wide and 612 tall.
        #expect(geometry.displaySize == CGSize(width: 792, height: 612))

        let drawing = PKDrawing(strokes: [Self.stroke(
            from: CGPoint(x: 100, y: 100),
            to: CGPoint(x: 200, y: 100)
        )])
        InkConverter.apply(drawing, to: page)
        let annotation = try #require(page.annotations.first)
        // A horizontal stroke on the rotated canvas is vertical on the page.
        #expect(annotation.bounds.height > annotation.bounds.width)
    }

    @Test("An ink annotation's path sits inside its own box")
    func pathIsRelativeToBounds() throws {
        var drawing = PKDrawing()
        let ink = PKInk(.pen, color: .black)
        let points = [CGPoint(x: 300, y: 500), CGPoint(x: 340, y: 520), CGPoint(x: 380, y: 500)].map {
            PKStrokePoint(location: $0, timeOffset: 0, size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        drawing.strokes.append(PKStroke(ink: ink, path: PKStrokePath(controlPoints: points, creationDate: .now)))
        let geometry = PageGeometry(cropBox: CGRect(x: 0, y: 0, width: 612, height: 792), rotation: 0)
        let annotation = try #require(InkConverter.annotations(from: drawing, geometry: geometry).first)
        let path = try #require(annotation.paths?.first)
        // PDFKit adds the annotation's origin back when it writes /InkList, so
        // a path handed in page coordinates would land at twice its position.
        #expect(CGRect(origin: .zero, size: annotation.bounds.size).insetBy(dx: -1, dy: -1).contains(path.bounds))
        #expect(annotation.bounds.minX > 290 && annotation.bounds.minX < 300)
    }
}
