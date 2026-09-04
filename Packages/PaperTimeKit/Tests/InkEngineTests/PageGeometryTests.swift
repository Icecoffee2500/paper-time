import CoreGraphics
import Testing
@testable import InkEngine

@Suite("PageGeometry")
struct PageGeometryTests {
    let letter = CGRect(x: 0, y: 0, width: 612, height: 792)

    @Test("An unrotated page flips y and nothing else")
    func unrotated() {
        let geometry = PageGeometry(cropBox: letter, rotation: 0)
        #expect(geometry.displaySize == CGSize(width: 612, height: 792))
        // The canvas origin is the page's top-left corner.
        #expect(geometry.pdfPoint(fromCanvas: .zero) == CGPoint(x: 0, y: 792))
        #expect(geometry.pdfPoint(fromCanvas: CGPoint(x: 612, y: 792)) == CGPoint(x: 612, y: 0))
    }

    @Test("Round-tripping a point returns it unchanged at every rotation")
    func roundTrip() {
        for rotation in [0, 90, 180, 270] {
            let geometry = PageGeometry(cropBox: letter, rotation: rotation)
            for point in [CGPoint(x: 10, y: 20), CGPoint(x: 300, y: 500), CGPoint(x: 0, y: 0)] {
                let pdf = geometry.pdfPoint(fromCanvas: point)
                let back = geometry.canvasPoint(fromPDF: pdf)
                #expect(abs(back.x - point.x) < 0.001)
                #expect(abs(back.y - point.y) < 0.001)
            }
        }
    }

    @Test("A rotated page swaps its display dimensions")
    func rotatedDisplaySize() {
        #expect(
            PageGeometry(cropBox: letter, rotation: 90).displaySize
                == CGSize(width: 792, height: 612)
        )
        #expect(
            PageGeometry(cropBox: letter, rotation: 270).displaySize
                == CGSize(width: 792, height: 612)
        )
        #expect(
            PageGeometry(cropBox: letter, rotation: 180).displaySize
                == CGSize(width: 612, height: 792)
        )
    }

    @Test("A crop box that does not start at the origin is offset, not scaled")
    func croppedPage() {
        let cropped = CGRect(x: 20, y: 30, width: 572, height: 732)
        let geometry = PageGeometry(cropBox: cropped, rotation: 0)
        let topLeft = geometry.pdfPoint(fromCanvas: .zero)
        #expect(topLeft == CGPoint(x: 20, y: 762))
    }

    @Test("Rotation values outside 0-359 are normalised")
    func normalisation() {
        #expect(PageGeometry(cropBox: letter, rotation: -90).rotation == 270)
        #expect(PageGeometry(cropBox: letter, rotation: 450).rotation == 90)
    }

    @Test("Rectangles stay normalised after the vertical flip")
    func rectangles() {
        let geometry = PageGeometry(cropBox: letter, rotation: 0)
        let canvasRect = CGRect(x: 100, y: 100, width: 200, height: 50)
        let pdfRect = geometry.pdfRect(fromCanvas: canvasRect)
        #expect(abs(pdfRect.width - 200) < 0.001)
        #expect(abs(pdfRect.height - 50) < 0.001)
        #expect(abs(pdfRect.minY - 642) < 0.001)
        let back = geometry.canvasRect(fromPDF: pdfRect)
        #expect(abs(back.minY - canvasRect.minY) < 0.001)
    }
}
