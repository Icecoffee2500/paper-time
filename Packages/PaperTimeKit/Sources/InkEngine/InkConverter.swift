import CoreGraphics
import Foundation
import PDFKit
import PencilKit

/// Turns PencilKit drawings into standard PDF ink annotations, and back.
///
/// The app keeps both forms on purpose. A PDF ink annotation is a polyline with
/// one width for the whole stroke, so writing PencilKit's per-point pressure
/// into it loses the taper that makes handwriting look like handwriting. The
/// original `PKDrawing` is therefore kept beside the PDF and used whenever the
/// app itself draws the page, while the annotations exist so that Preview,
/// Acrobat, or any other reader shows the same marks — which is the whole point
/// of writing into the file rather than into a private database.
public enum InkConverter {
    /// Marks the annotations this app owns, so regenerating a page's ink never
    /// touches highlights or notes made elsewhere.
    public static let ownerName = "Paper Time"
    static let ownerKey = PDFAnnotationKey(rawValue: "/PTInk")

    /// Distance in page points between sampled points along a stroke.
    ///
    /// Fine enough that curves stay smooth at reading zoom, coarse enough that
    /// a page of dense handwriting does not produce a megabyte of coordinates.
    static let samplingDistance: CGFloat = 1.5

    public static func annotations(
        from drawing: PKDrawing,
        geometry: PageGeometry
    ) -> [PDFAnnotation] {
        drawing.strokes.compactMap { annotation(from: $0, geometry: geometry) }
    }

    static func annotation(from stroke: PKStroke, geometry: PageGeometry) -> PDFAnnotation? {
        var points: [CGPoint] = []
        var widths: [CGFloat] = []

        for point in stroke.path.interpolatedPoints(by: .distance(samplingDistance)) {
            let located = point.location.applying(stroke.transform)
            points.append(geometry.pdfPoint(fromCanvas: located))
            widths.append(point.size.width)
        }
        guard !points.isEmpty else { return nil }

        let width = widths.isEmpty
            ? 2
            : widths.reduce(0, +) / CGFloat(widths.count)
        guard let path = PlatformBezierPath.polyline(points) else { return nil }

        let padding = max(width, 2)
        let bounds = path.bounds.insetBy(dx: -padding, dy: -padding)
        let annotation = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
        // PDFKit takes the path relative to the annotation's own origin and
        // adds the origin back when it writes /InkList. Handed page
        // coordinates, it wrote every stroke at twice its position — outside
        // its /Rect, where every reader but the canvas clipped it away. The
        // iPad showed its ink from the sidecar and never noticed; the Mac saw
        // nothing.
        annotation.add(Self.translated(path, by: CGPoint(x: -bounds.minX, y: -bounds.minY)))
        annotation.color = colour(for: stroke)
        let border = PDFBorder()
        border.lineWidth = width
        annotation.border = border
        annotation.userName = ownerName
        annotation.setValue(ownerName, forAnnotationKey: ownerKey)
        return annotation
    }

    /// PencilKit's marker tool paints with multiply blending, which PDF ink
    /// annotations cannot express; a translucent stroke is the closest match
    /// that every reader renders the same way.
    static func colour(for stroke: PKStroke) -> PlatformColor {
        let base = stroke.ink.color
        switch stroke.ink.inkType {
        case .marker:
            return base.withAlphaComponent(0.35)
        default:
            return base
        }
    }

    // MARK: - Reconciling a page

    /// Replaces the ink this app previously wrote on a page with the drawing's
    /// current contents.
    ///
    /// Regenerating wholesale, rather than diffing stroke by stroke, keeps the
    /// file and the sidecar in step by construction. The cost is that edits
    /// made to *these* annotations in another app are overwritten on the next
    /// save; highlights and notes are untouched because they are not ours.
    @discardableResult
    public static func apply(
        _ drawing: PKDrawing,
        to page: PDFPage,
        geometry: PageGeometry? = nil
    ) -> Int {
        let resolved = geometry ?? PageGeometry(page: page)
        removeOwnedAnnotations(from: page)
        let created = annotations(from: drawing, geometry: resolved)
        for annotation in created { page.addAnnotation(annotation) }
        return created.count
    }

    static func translated(_ path: PlatformBezierPath, by offset: CGPoint) -> PlatformBezierPath {
        let moved = path.copy() as! PlatformBezierPath
        #if canImport(UIKit)
        moved.apply(CGAffineTransform(translationX: offset.x, y: offset.y))
        #else
        moved.transform(using: AffineTransform(translationByX: offset.x, byY: offset.y))
        #endif
        return moved
    }

    /// The strokes a page's own ink annotations describe.
    ///
    /// For a page that has ink in the file but no sidecar — written by a
    /// version before sidecars, or whose sidecar has not come across yet.
    /// The pressure is gone; the shape, width and colour are not, and once
    /// it is a drawing it can be erased and redrawn like the rest.
    public static func drawing(fromOwnedInkOn page: PDFPage, geometry: PageGeometry? = nil) -> PKDrawing {
        let resolved = geometry ?? PageGeometry(page: page)
        var strokes: [PKStroke] = []
        for annotation in page.annotations where annotation.type == "Ink" && isOwned(annotation) {
            // Paths come back relative to the box — except from the files
            // that were written wrong, whose paths read back in page space.
            let offset = isMisplaced(annotation) ? .zero : annotation.bounds.origin
            let width = max(annotation.border?.lineWidth ?? 2, 0.5)
            let colour = annotation.color
            let translucent = colour.cgColor.alpha < 0.95
            let ink = PKInk(translucent ? .marker : .pen, color: colour.withAlphaComponent(1))
            for path in annotation.paths ?? [] {
                let points = polylinePoints(of: path).map {
                    resolved.canvasPoint(fromPDF: CGPoint(x: $0.x + offset.x, y: $0.y + offset.y))
                }
                guard let first = points.first else { continue }
                let controls = (points.count > 1 ? points : [first, CGPoint(x: first.x + 0.01, y: first.y)])
                    .enumerated().map { index, point in
                        PKStrokePoint(
                            location: point, timeOffset: TimeInterval(index) * 0.005,
                            size: CGSize(width: width, height: width), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2
                        )
                    }
                strokes.append(PKStroke(ink: ink, path: PKStrokePath(controlPoints: controls, creationDate: .now)))
            }
        }
        return PKDrawing(strokes: strokes)
    }

    static func polylinePoints(of path: PlatformBezierPath) -> [CGPoint] {
        var points: [CGPoint] = []
        path.cgPath.applyWithBlock { element in
            let e = element.pointee
            switch e.type {
            case .moveToPoint, .addLineToPoint: points.append(e.points[0])
            case .addQuadCurveToPoint: points.append(e.points[1])
            case .addCurveToPoint: points.append(e.points[2])
            default: break
            }
        }
        return points
    }

    /// True for an ink annotation written with page coordinates in its path,
    /// by the versions before the fix above: the path lies outside the box
    /// the annotation is drawn in. Such pages are rewritten on the next save.
    public static func isMisplaced(_ annotation: PDFAnnotation) -> Bool {
        guard annotation.type == "Ink", isOwned(annotation),
              let path = annotation.paths?.first else { return false }
        let local = CGRect(origin: .zero, size: annotation.bounds.size).insetBy(dx: -2, dy: -2)
        return !local.contains(path.bounds)
    }

    public static func removeOwnedAnnotations(from page: PDFPage) {
        for annotation in page.annotations where isOwned(annotation) {
            page.removeAnnotation(annotation)
        }
    }

    public static func isOwned(_ annotation: PDFAnnotation) -> Bool {
        if annotation.value(forAnnotationKey: ownerKey) as? String == ownerName { return true }
        // Older files, and files round-tripped through readers that drop custom
        // keys, are still recognisable by the annotation's title field.
        return annotation.type == "Ink" && annotation.userName == ownerName
    }

    /// True when a page carries ink drawn somewhere other than this app, which
    /// the user should be told about before it gets replaced.
    public static func hasForeignInk(on page: PDFPage) -> Bool {
        page.annotations.contains { $0.type == "Ink" && !isOwned($0) }
    }
}
