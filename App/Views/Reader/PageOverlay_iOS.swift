#if canImport(UIKit)
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
        // Multiplied onto the page, so the pale band lets the ink through.
        layer.compositingFilter = "multiplyBlendMode"
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

/// One view over a page holding its overlays: the mask over the margin's
/// stamps, the marks with their rounded ends, and on top the pencil canvas.
final class PageOverlay: UIView {
    private let marginMask: MarginMaskView
    let canvas: PKCanvasView

    init(page: PDFPage, canvas: PKCanvasView) {
        marginMask = MarginMaskView(page: page)
        self.canvas = canvas
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        let marks = MarkOverlayView(page: page)
        for child in [marginMask, marks, canvas] as [UIView] {
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

    /// Touches go to the canvas when it is drawing, and otherwise through
    /// to the page — the overlays themselves never take one.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard canvas.isUserInteractionEnabled else { return nil }
        return canvas.hitTest(convert(point, to: canvas), with: event)
    }
}
#endif
