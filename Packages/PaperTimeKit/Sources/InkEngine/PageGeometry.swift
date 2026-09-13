import CoreGraphics
import Foundation
import PDFKit

/// Converts between the coordinate space a drawing canvas uses and the one a
/// PDF page uses.
///
/// The two disagree on everything that matters: PDF puts the origin at the
/// bottom left with y increasing upwards, views put it at the top left with y
/// increasing downwards, the visible area is the crop box rather than the
/// media box, and a page can carry a rotation that only affects display. Every
/// one of those is silent when wrong — the ink lands in the wrong place, or
/// mirrored — so the mapping is isolated here and tested directly.
public struct PageGeometry: Hashable, Sendable {
    /// The page's crop box, in PDF coordinates.
    public let cropBox: CGRect
    /// Clockwise display rotation in degrees: 0, 90, 180 or 270.
    public let rotation: Int

    public init(cropBox: CGRect, rotation: Int) {
        self.cropBox = cropBox
        // PDF permits any multiple of 90, including negatives.
        let normalised = ((rotation % 360) + 360) % 360
        self.rotation = (normalised / 90) * 90
    }

    public init(page: PDFPage) {
        self.init(cropBox: page.bounds(for: .cropBox), rotation: page.rotation)
    }

    /// The size the page occupies on screen at 100%, after rotation.
    public var displaySize: CGSize {
        switch rotation {
        case 90, 270: CGSize(width: cropBox.height, height: cropBox.width)
        default: CGSize(width: cropBox.width, height: cropBox.height)
        }
    }

    /// Maps a point from the overlay view onto the PDF page.
    public func pdfPoint(fromCanvas point: CGPoint) -> CGPoint {
        let width = cropBox.width
        let height = cropBox.height
        let local: CGPoint = switch rotation {
        case 90: CGPoint(x: point.y, y: point.x)
        case 180: CGPoint(x: width - point.x, y: point.y)
        case 270: CGPoint(x: width - point.y, y: height - point.x)
        default: CGPoint(x: point.x, y: height - point.y)
        }
        return CGPoint(x: local.x + cropBox.minX, y: local.y + cropBox.minY)
    }

    /// Maps a point from the PDF page into the overlay view.
    public func canvasPoint(fromPDF point: CGPoint) -> CGPoint {
        let local = CGPoint(x: point.x - cropBox.minX, y: point.y - cropBox.minY)
        let width = cropBox.width
        let height = cropBox.height
        return switch rotation {
        case 90: CGPoint(x: local.y, y: local.x)
        case 180: CGPoint(x: width - local.x, y: local.y)
        case 270: CGPoint(x: height - local.y, y: width - local.x)
        default: CGPoint(x: local.x, y: height - local.y)
        }
    }

    /// Maps a rectangle, keeping it normalised after the flip.
    public func pdfRect(fromCanvas rect: CGRect) -> CGRect {
        let first = pdfPoint(fromCanvas: CGPoint(x: rect.minX, y: rect.minY))
        let second = pdfPoint(fromCanvas: CGPoint(x: rect.maxX, y: rect.maxY))
        return CGRect(
            x: min(first.x, second.x),
            y: min(first.y, second.y),
            width: abs(second.x - first.x),
            height: abs(second.y - first.y)
        )
    }

    public func canvasRect(fromPDF rect: CGRect) -> CGRect {
        let first = canvasPoint(fromPDF: CGPoint(x: rect.minX, y: rect.minY))
        let second = canvasPoint(fromPDF: CGPoint(x: rect.maxX, y: rect.maxY))
        return CGRect(
            x: min(first.x, second.x),
            y: min(first.y, second.y),
            width: abs(second.x - first.x),
            height: abs(second.y - first.y)
        )
    }
}
