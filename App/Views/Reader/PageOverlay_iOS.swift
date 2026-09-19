#if canImport(UIKit)
import InkEngine
import PDFKit
import PDFReader
import PencilKit
import UIKit

/// The layer over a page where its highlights are drawn with rounded ends —
/// the UIKit twin of the Mac's, so a mark looks the same on the iPad as on
/// the Mac. See the Mac version for why an overlay and not `draw(_:to:)`.
final class MarkOverlayView: UIView {
    private weak var page: PDFPage?

    nonisolated(unsafe) private static var byPage: [ObjectIdentifier: Weak] = [:]
    private struct Weak { weak var view: MarkOverlayView? }

    init(page: PDFPage) {
        self.page = page
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        // UIKit does not honour a multiply filter on the layer; the band
        // is translucent instead, and the ink shows through it.
        RoundedMarks.blendsByAlpha = true
        contentMode = .redraw
        Self.byPage[ObjectIdentifier(page)] = Weak(view: self)
        NotificationCenter.default.addObserver(
            self, selector: #selector(marksChanged),
            name: .paperTimeMarksChanged, object: nil
        )
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func marksChanged() { setNeedsDisplay() }

    required init?(coder: NSCoder) { nil }

    static func refresh(_ page: PDFPage) {
        byPage[ObjectIdentifier(page)]?.view?.setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let page, let context = UIGraphicsGetCurrentContext() else { return }
        let marks = RoundedMarks.takeOver(page)
        guard !marks.isEmpty else { return }
        let box = page.bounds(for: .cropBox)
        guard box.width > 0, box.height > 0 else { return }
        context.saveGState()
        // UIKit's y runs down the view; the page's runs up it.
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: bounds.width / box.width, y: -bounds.height / box.height)
        context.translateBy(x: -box.minX, y: -box.minY)
        for mark in marks { RoundedMarks.draw(mark, in: context) }
        context.restoreGState()
    }
}

/// The shapes, arrows and text cards the Mac drew, from the same sidecar
/// and with the same renderer, under the pencil canvas. The iPad shows them
/// and does not edit them; the PDF's own copy is hidden so nothing is
/// drawn twice.
final class SketchOverlayView: UIView {
    private weak var page: PDFPage?
    private let elements: () -> [SketchElement]

    nonisolated(unsafe) private static var byPage: [ObjectIdentifier: Weak] = [:]
    private struct Weak { weak var view: SketchOverlayView? }

    init(page: PDFPage, elements: @escaping () -> [SketchElement]) {
        self.page = page
        self.elements = elements
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
        Self.byPage[ObjectIdentifier(page)] = Weak(view: self)
    }

    required init?(coder: NSCoder) { nil }

    static func refresh(_ page: PDFPage) {
        byPage[ObjectIdentifier(page)]?.view?.setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let page, let context = UIGraphicsGetCurrentContext() else { return }
        let shown = elements()
        guard !shown.isEmpty else { return }
        let box = page.bounds(for: .cropBox)
        guard box.width > 0, box.height > 0 else { return }
        context.saveGState()
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: bounds.width / box.width, y: -bounds.height / box.height)
        context.translateBy(x: -box.minX, y: -box.minY)
        SketchRenderer.draw(shown, in: context, options: .init(flipsText: true))
        context.restoreGState()
    }
}

/// One view over a page holding its overlays: the mask over the margin's
/// stamps, the marks with their rounded ends, and on top the pencil canvas.
final class PageOverlay: UIView {
    private let marginMask: MarginMaskView
    let canvas: PKCanvasView

    init(page: PDFPage, canvas: PKCanvasView, sketch: @escaping () -> [SketchElement] = { [] }) {
        marginMask = MarginMaskView(page: page)
        self.canvas = canvas
        super.init(frame: .zero)
        self.page = page
        backgroundColor = .clear
        isOpaque = false
        let marks = MarkOverlayView(page: page)
        let shapes = SketchOverlayView(page: page, elements: sketch)
        for child in [marginMask, marks, shapes, canvas] as [UIView] {
            child.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(child)
        }
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        for child in subviews { child.frame = bounds }
        marginMask.setNeedsDisplay()
    }

    private var wantsInteraction = false

    /// Whether the page under this overlay takes touches at all.
    ///
    /// PDFKit's page views do not, and while reading that is right — text
    /// selection lives on the document view above them. While drawing, the
    /// pencil has to get down to the canvas, so the way is opened; closed
    /// again when drawing ends, so selecting a sentence works as before.
    func setInteractive(_ on: Bool) {
        wantsInteraction = on
        applyInteraction()
    }

    private func applyInteraction() {
        var view = superview
        while let current = view, !(current is UIScrollView) {
            if NSStringFromClass(type(of: current)).contains("PageView") {
                current.isUserInteractionEnabled = wantsInteraction
            }
            view = current.superview
        }
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        applyInteraction()
    }

    /// The page this overlay lies on, for whoever handles a touch on it.
    private(set) weak var page: PDFPage?

    /// A point on the overlay, on the page — the inverse of the mapping the
    /// marks are drawn with.
    func pagePoint(_ point: CGPoint) -> CGPoint? {
        guard let page, bounds.width > 0, bounds.height > 0 else { return nil }
        let box = page.bounds(for: .cropBox)
        return CGPoint(
            x: box.minX + point.x * box.width / bounds.width,
            y: box.minY + (bounds.height - point.y) * box.height / bounds.height
        )
    }

    /// A point on the page under the eraser: the coordinator takes the marks
    /// there off.
    var onErase: ((CGPoint) -> Void)?
    /// Where a touch is on the page, by the PDF view's own reckoning — the
    /// one mapping that is right at every zoom.
    var pagePointOfTouch: ((UITouch) -> CGPoint?)?
    /// The same for where the touch was a moment ago, so a fast rub still
    /// covers the ground between two samples.
    var previousPagePointOfTouch: ((UITouch) -> CGPoint?)?
    /// Strokes were rubbed out here; the session should hear about the canvas.
    var onStrokesErased: ((PKCanvasView) -> Void)?

    /// Touches go to the canvas when it is drawing, and otherwise through
    /// to the page — the overlays themselves never take one.
    ///
    /// With the eraser chosen the overlay takes the touch itself: PencilKit's
    /// own erasing would not reach the highlights, and a pan recogniser laid
    /// over its canvas was cancelled the moment its stroke began. So one
    /// eraser rubs out both — strokes as objects, marks by their box.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard canvas.isUserInteractionEnabled else { return nil }
        if canvas.tool is PKEraserTool {
            if canvas.drawingPolicy == .pencilOnly,
               let touch = event?.allTouches?.first, touch.type != .pencil {
                return nil
            }
            return self
        }
        return canvas.hitTest(convert(point, to: canvas), with: event)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { erase(touches) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { erase(touches) }

    private func erase(_ touches: Set<UITouch>) {
        guard let page else { return }
        let geometry = PageGeometry(page: page)
        for touch in touches {
            guard let point = pagePointOfTouch?(touch) ?? pagePoint(touch.location(in: self)) else { continue }
            let previous = previousPagePointOfTouch?(touch) ?? point
            // Touch samples arrive a finger's width apart on a quick rub;
            // walk the gap so nothing between them is skipped.
            let distance = hypot(point.x - previous.x, point.y - previous.y)
            let steps = max(1, Int(distance / 3))
            for step in 0...steps {
                let t = CGFloat(step) / CGFloat(steps)
                let sample = CGPoint(x: previous.x + (point.x - previous.x) * t, y: previous.y + (point.y - previous.y) * t)
                onErase?(sample)
                // The strokes live in the canvas's own space; go there from
                // the page rather than through the touch's view coordinates.
                eraseStrokes(at: geometry.canvasPoint(fromPDF: sample))
            }
        }
    }

    private func eraseStrokes(at point: CGPoint) {
        let radius: CGFloat = 14
        var drawing = canvas.drawing
        let before = drawing.strokes.count
        drawing.strokes.removeAll { stroke in
            guard stroke.renderBounds.insetBy(dx: -radius, dy: -radius).contains(point) else { return false }
            return stroke.path.interpolatedPoints(by: .distance(3)).contains { sample in
                let location = sample.location.applying(stroke.transform)
                return hypot(location.x - point.x, location.y - point.y) <= radius
            }
        }
        guard drawing.strokes.count != before else { return }
        canvas.drawing = drawing
        onStrokesErased?(canvas)
    }
}
#endif
