import CoreGraphics
import Foundation
import PDFKit
import PencilKit
import Testing
@testable import InkEngine

/// A pen point's size is not the width PencilKit draws (`PenWidth`): the
/// Mac's thinnest pen wrote its width straight into the size and drew
/// nothing at all.
@Suite("Pen width")
struct PenWidthTests {
    init() { PencilKitHost.prepare() }

    @Test("The size that draws a width, and the width a size draws")
    func law() {
        #expect(PenWidth.size(drawing: 1.5) == 2.75)
        #expect(PenWidth.drawn(bySize: 2.75) == 1.5)
        #expect(PenWidth.drawn(bySize: 1.5) == 0)
        for width: CGFloat in [0.5, 1, 1.5, 3, 5, 12] {
            #expect(abs(PenWidth.drawn(bySize: PenWidth.size(drawing: width)) - width) < 1e-9)
        }
        #expect(PenWidth.applies(to: .pen))
        #expect(PenWidth.applies(to: .monoline))
        #expect(!PenWidth.applies(to: .marker))
    }

    static func line(size: CGFloat, ink: PKInk.InkType = .pen) -> PKStroke {
        let points = (0..<40).map { i in
            PKStrokePoint(location: CGPoint(x: 10 + Double(i) * 2.5, y: 50), timeOffset: Double(i) * 0.01,
                          size: CGSize(width: size, height: size), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(ink, color: .black), path: PKStrokePath(controlPoints: points, creationDate: .now))
    }

    #if os(macOS)
    /// The law itself, asked of PencilKit: the line's coverage down the
    /// middle of its picture, in points.
    static func thickness(of size: CGFloat) throws -> CGFloat {
        let scale: CGFloat = 3
        let image = PKDrawing(strokes: [line(size: size)]).image(from: CGRect(x: 0, y: 0, width: 130, height: 100), scale: scale)
        let picture = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let width = picture.width, height = picture.height
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(picture, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = try #require(context.data).bindMemory(to: UInt8.self, capacity: width * height * 4)
        var coverage: CGFloat = 0
        for y in 0..<height { coverage += CGFloat(pixels[(y * width + width / 2) * 4 + 3]) / 255 }
        return coverage / scale
    }

    @Test("PencilKit draws a pen line as wide as the width its size was made for")
    func pencilKitDrawsTheWidth() throws {
        for width: CGFloat in [1.5, 3, 5] {
            let drawn = try Self.thickness(of: PenWidth.size(drawing: width))
            #expect(abs(drawn - width) < 0.35, "a \(width) pt pen drew \(drawn) pt")
        }
        // The width written straight in, as the Mac's pen did.
        #expect(try Self.thickness(of: 1.5) < 0.1)
        #expect(abs(try Self.thickness(of: 3) - 2) < 0.35)
    }
    #endif

    @Test("The file gets the width the page shows, and gives it back")
    func throughTheFile() throws {
        let document = try #require(PDFDocument(data: InkRoundTripTests.blankPDF(pages: 1)))
        let page = try #require(document.page(at: 0))
        let geometry = PageGeometry(page: page)
        let size = PenWidth.size(drawing: 3)
        InkConverter.apply(PKDrawing(strokes: [Self.line(size: size)]), to: page, geometry: geometry)
        let annotation = try #require(page.annotations.first { $0.type == "Ink" })
        #expect(abs((annotation.border?.lineWidth ?? 0) - 3) < 0.01)
        let back = InkConverter.drawing(fromOwnedInkOn: page, geometry: geometry)
        let point = try #require(back.strokes.first?.path.first)
        #expect(abs(point.size.width - size) < 0.01)
        // The marker is left as it was: its size is its width in the file.
        let marker = try #require(PDFDocument(data: InkRoundTripTests.blankPDF(pages: 1))?.page(at: 0))
        InkConverter.apply(PKDrawing(strokes: [Self.line(size: 12, ink: .marker)]), to: marker, geometry: geometry)
        #expect(abs((marker.annotations.first { $0.type == "Ink" }?.border?.lineWidth ?? 0) - 12) < 0.01)
    }
}
