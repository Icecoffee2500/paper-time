#if os(macOS)
import AppKit
import PDFKit
import PDFReader

/// The layer over a page where its highlights are drawn with rounded ends.
///
/// PDFKit paints a highlight as the hard rectangle the file describes, and
/// paints it from a tile renderer on its own queue — a `draw(_:to:)` override
/// on the view is called there, and a `@MainActor` view called off the main
/// thread stops the app dead. The page overlay is the hook PDFKit gives for
/// drawing over a page on the main thread, so this hides each highlight from
/// PDFKit (the flag lives only in memory; the file is untouched) and draws it
/// back on itself as a rounded band, deepened while the pointer is over it.
///
/// Sees no mouse. Every click passes straight through to the PDF view, which
/// already knows what a click on a mark means.
final class MarkOverlayView: NSView {
    private weak var page: PDFPage?

    /// One per page, so a change to a mark can reach the view drawing it
    /// without a way back from the page.
    nonisolated(unsafe) private static var byPage: [ObjectIdentifier: Weak] = [:]

    private struct Weak { weak var view: MarkOverlayView? }

    init(page: PDFPage) {
        self.page = page
        super.init(frame: .zero)
        // Multiplied onto the page as a layer, the way PDFKit's own highlight
        // is. A blend mode set while drawing only blends against this view's
        // own backing store, which is empty — so the bands came out as solid
        // paint over the words. The compositing filter blends the finished
        // layer with what is under it, which is the page.
        wantsLayer = true
        layer?.compositingFilter = "multiplyBlendMode"
        layer?.isOpaque = false
        Self.byPage[ObjectIdentifier(page)] = Weak(view: self)
        // A mark added, removed or recoloured anywhere: PDFKit would draw the
        // new one square until this view drew again.
        NotificationCenter.default.addObserver(
            self, selector: #selector(marksChanged),
            name: .paperTimeMarksChanged, object: nil
        )
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func marksChanged() { needsDisplay = true }

    required init?(coder: NSCoder) { nil }

    /// Redraws the overlay for a page whose marks changed — one added, one
    /// taken away, one recoloured, or the pointer arriving on one.
    static func refresh(_ page: PDFPage) {
        byPage[ObjectIdentifier(page)]?.view?.needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let page, let context = NSGraphicsContext.current?.cgContext else { return }
        let highlights = RoundedMarks.takeOver(page)
        guard !highlights.isEmpty else { return }

        // The overlay covers the page's display box; page space maps onto it
        // by one scale factor and an offset. Neither is flipped: PDF and an
        // unflipped NSView both put their origin at the bottom left.
        let box = page.bounds(for: .cropBox)
        guard box.width > 0, box.height > 0 else { return }
        context.saveGState()
        context.translateBy(x: 0, y: 0)
        context.scaleBy(x: bounds.width / box.width, y: bounds.height / box.height)
        context.translateBy(x: -box.minX, y: -box.minY)
        for highlight in highlights {
            RoundedMarks.draw(highlight, in: context)
        }
        context.restoreGState()
    }
}
#endif
