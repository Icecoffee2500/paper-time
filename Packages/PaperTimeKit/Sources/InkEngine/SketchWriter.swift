import CoreGraphics
import Foundation
import PDFKit

/// Writes sketch elements into a page as the standard annotations every
/// reader draws — squares, circles, lines, ink, free text — and reads them
/// back.
///
/// The sidecar beside the PDF is where the elements live; what goes into the
/// file is a copy, the way the pen's ink is. But the copy carries the element
/// itself, as JSON in a private key on the annotation, so a device that has
/// the PDF and not the sidecar can rebuild the sidecar exactly — the curve of
/// an arrow, the roundness of a corner, none of which a PDF annotation can
/// say on its own.
public enum SketchWriter {
    /// The title every annotation of ours carries. Not the pen's "Paper
    /// Time": the pen's converter treats any ink under that name as a stroke
    /// of its own, and a bent arrow is written as ink.
    public static let ownerName = "Paper Time Sketch"
    static let idKey = PDFAnnotationKey(rawValue: "/PTSketchID")
    /// The element, as base64 of its JSON. Base64 so the PDF's string
    /// escaping has nothing to trip over.
    static let payloadKey = PDFAnnotationKey(rawValue: "/PTSketch")
    /// On the free-text annotation that carries a box's label, so it is not
    /// mistaken for the element itself.
    static let partKey = PDFAnnotationKey(rawValue: "/PTSketchPart")

    public static func isOwned(_ annotation: PDFAnnotation) -> Bool {
        annotation.value(forAnnotationKey: idKey) != nil || annotation.userName == ownerName
    }

    public static func identifier(of annotation: PDFAnnotation) -> UUID? {
        (annotation.value(forAnnotationKey: idKey) as? String).flatMap(UUID.init(uuidString:))
    }

    public static func removeOwned(from page: PDFPage) {
        for annotation in page.annotations where isOwned(annotation) {
            page.removeAnnotation(annotation)
        }
    }

    /// Replaces the page's copy of the sketch with these elements. Wholesale,
    /// like the ink: the file and the sidecar agree by construction.
    @discardableResult
    public static func apply(_ elements: [SketchElement], to page: PDFPage) -> Int {
        removeOwned(from: page)
        var count = 0
        for element in elements {
            for annotation in annotations(for: element) {
                page.addAnnotation(annotation)
                count += 1
            }
        }
        return count
    }

    /// True when the page's copy already says exactly this — so a save
    /// that changes nothing does not rewrite it, and does not send a storm
    /// of change notifications from the writer's thread.
    public static func isAlreadyWritten(_ elements: [SketchElement], on page: PDFPage) -> Bool {
        let written = Set(page.annotations.compactMap { $0.value(forAnnotationKey: payloadKey) as? String })
        let wanted = Set(elements.compactMap(payload(for:)))
        return written == wanted && written.count == elements.count
    }

    /// The elements a page's own annotations describe, in the order they lie
    /// on the page — for a device that has no sidecar for it yet.
    public static func elements(fromOwnedOn page: PDFPage) -> [SketchElement] {
        var seen: Set<UUID> = []
        var result: [SketchElement] = []
        for annotation in page.annotations {
            guard let raw = annotation.value(forAnnotationKey: payloadKey) as? String,
                  let data = Data(base64Encoded: raw),
                  let element = try? JSONDecoder().decode(SketchElement.self, from: data),
                  !seen.contains(element.id)
            else { continue }
            seen.insert(element.id)
            result.append(element)
        }
        return result
    }

    static func payload(for element: SketchElement) -> String? {
        let encoder = JSONEncoder()
        // The same element must always make the same bytes, or "already
        // written" can never be true.
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(element))?.base64EncodedString()
    }

    // MARK: - One element, as annotations

    public static func annotations(for element: SketchElement) -> [PDFAnnotation] {
        var made: [PDFAnnotation] = []
        let primary: PDFAnnotation
        switch element.kind {
        case .rectangle, .ellipse, .frame:
            primary = box(element)
            if !element.text.isEmpty {
                made.append(label(element))
            }
        case .line, .arrow:
            primary = connector(element)
        case .text:
            primary = freeText(element)
        case .group:
            // A group draws nothing, but it has to be in the file for a
            // device without the sidecar to rebuild it: a square with no
            // edge and no colour, hidden, carrying the payload.
            let ghost = PDFAnnotation(bounds: element.rect, forType: .square, withProperties: nil)
            ghost.border = border(for: element.style, width: 0)
            ghost.shouldDisplay = false
            primary = ghost
        }
        primary.setValue(payload(for: element) ?? "", forAnnotationKey: payloadKey)
        made.insert(primary, at: 0)
        for annotation in made {
            annotation.userName = ownerName
            annotation.setValue(element.id.uuidString, forAnnotationKey: idKey)
            annotation.modificationDate = element.createdAt
        }
        return made
    }

    static func border(for style: SketchStyle, width: CGFloat? = nil) -> PDFBorder {
        let border = PDFBorder()
        border.lineWidth = width ?? style.width
        if let pattern = style.dashPattern {
            border.style = .dashed
            border.dashPattern = pattern.map { max($0, 0.5) as NSNumber }
        }
        return border
    }

    /// The chosen family at the chosen size, or the system's face.
    static func font(for style: SketchStyle) -> PlatformFont {
        if let name = style.fontName, let font = PlatformFont(name: name, size: style.points) { return font }
        return PlatformFont.systemFont(ofSize: style.points)
    }

    static func color(_ color: SketchColor) -> PlatformColor {
        PlatformColor(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }

    private static func box(_ element: SketchElement) -> PDFAnnotation {
        let annotation = PDFAnnotation(
            bounds: element.rect,
            forType: element.kind == .ellipse ? .circle : .square,
            withProperties: nil
        )
        annotation.color = color(element.style.stroke)
        if let fill = element.style.fill {
            annotation.interiorColor = color(fill.flattenedOnWhite)
        }
        // An edge left undrawn is a border of no width.
        annotation.border = border(for: element.style, width: element.style.drawsOutline(for: element.kind) ? nil : 0)
        return annotation
    }

    /// A straight connector is a line annotation with its ends; one that
    /// bends, or ends in a bar, is ink tracing the curve and the heads.
    private static func connector(_ element: SketchElement) -> PDFAnnotation {
        let style = element.style
        let asLine = element.control == nil && style.startHead != .bar && style.endHead != .bar
        let bounds = element.bounds
        if asLine {
            let annotation = PDFAnnotation(bounds: bounds, forType: .line, withProperties: nil)
            // Relative to the annotation's own corner, like an ink path: PDFKit
            // adds the corner back when it writes /L.
            annotation.startPoint = CGPoint(x: element.start.x - bounds.minX, y: element.start.y - bounds.minY)
            annotation.endPoint = CGPoint(x: element.end.x - bounds.minX, y: element.end.y - bounds.minY)
            annotation.startLineStyle = lineStyle(style.startHead)
            annotation.endLineStyle = lineStyle(style.endHead)
            annotation.color = color(style.stroke)
            annotation.interiorColor = color(style.stroke)
            annotation.border = border(for: style)
            return annotation
        }
        let annotation = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
        let offset = CGPoint(x: -bounds.minX, y: -bounds.minY)
        if let curve = PlatformBezierPath.polyline(element.polyline().map { CGPoint(x: $0.x + offset.x, y: $0.y + offset.y) }) {
            annotation.add(curve)
        }
        for (head, tip, direction) in [
            (style.startHead, element.start, element.startDirection),
            (style.endHead, element.end, element.endDirection),
        ] {
            guard let (path, _) = SketchRenderer.headPath(head, at: tip, direction: direction, length: element.headLength, width: style.width) else { continue }
            var points = polylinePoints(of: path).map { CGPoint(x: $0.x + offset.x, y: $0.y + offset.y) }
            if head == .triangle, let first = points.first { points.append(first) }
            if let traced = PlatformBezierPath.polyline(points) { annotation.add(traced) }
        }
        annotation.color = color(style.stroke)
        annotation.border = border(for: style)
        return annotation
    }

    static func lineStyle(_ head: SketchStyle.Head) -> PDFLineStyle {
        switch head {
        case .none, .bar: .none
        case .arrow: .openArrow
        case .triangle: .closedArrow
        case .dot: .circle
        }
    }

    private static func freeText(_ element: SketchElement) -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: element.rect, forType: .freeText, withProperties: nil)
        annotation.contents = element.text
        annotation.font = font(for: element.style)
        annotation.fontColor = color(element.style.stroke)
        // The card behind the words, or nothing. PDFKit fills a free text's
        // box in its colour; clear is written as no colour at all.
        annotation.color = element.style.fill.map { color($0.flattenedOnWhite) } ?? PlatformColor.clear
        switch element.style.textAlign {
        case .left: annotation.alignment = .left
        case .center: annotation.alignment = .center
        case .right: annotation.alignment = .right
        }
        annotation.border = border(for: element.style, width: element.style.border ? element.style.width : 0)
        return annotation
    }

    /// The words inside a box: free text over it, in no colour of its own.
    private static func label(_ element: SketchElement) -> PDFAnnotation {
        let inner = element.rect.insetBy(dx: SketchTypesetter.padding, dy: SketchTypesetter.padding)
        let annotation = PDFAnnotation(bounds: inner, forType: .freeText, withProperties: nil)
        annotation.contents = element.text
        annotation.font = font(for: element.style)
        annotation.fontColor = color(element.style.stroke)
        annotation.color = PlatformColor.clear
        annotation.alignment = .center
        annotation.border = border(for: element.style, width: 0)
        annotation.setValue("label", forAnnotationKey: partKey)
        return annotation
    }

    static func polylinePoints(of path: CGPath) -> [CGPoint] {
        var points: [CGPoint] = []
        path.applyWithBlock { element in
            let e = element.pointee
            switch e.type {
            case .moveToPoint, .addLineToPoint: points.append(e.points[0])
            case .addQuadCurveToPoint: points.append(e.points[1])
            case .addCurveToPoint: points.append(e.points[2])
            case .closeSubpath: break
            @unknown default: break
            }
        }
        return points
    }
}
