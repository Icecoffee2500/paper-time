#if os(macOS)
import AppKit
import PDFKit

/// The formula lasso: a rectangle dragged over the page catches the formula
/// under it, and ⇧⌘C (Ultracopy) and ⌘L (quote to the note) read the
/// rectangle instead of a text selection.
///
/// A drag through a formula is at PDFKit's mercy — on a page whose table it
/// has analysed, or in a Word PDF whose text runs a line off, the selection
/// is not what the hand drew. A rectangle is. And the reader never wanted
/// more than the boxes a selection covers (`MathReader.Region`), so the
/// rectangle goes in where the line boxes went. When the mouse lets go the
/// rectangle **snaps** to what the reader will actually read for it
/// (`MathReader.extentRead`): the whole formula touched, limits and bar and
/// number included, or the words inside — so the box on the page is exactly
/// what ⇧⌘C copies.
///
/// Laid over the whole PDF view while `ReaderConfiguration.mode` is `.lasso`,
/// the way `SketchInputView` is for drawing: it takes the mouse, hands
/// scrolling and pinching down to the scroll view, and redraws when the page
/// moves under it.
@MainActor
final class LassoInputView: NSView {
    private weak var pdfView: PDFView?
    private let configuration: ReaderConfiguration
    private let document: PDFDocument

    /// What the lasso holds: the page and the rectangle on it, in the page's
    /// coordinates as PDFKit gives them. `needsOCR` when the rectangle holds
    /// nothing the reader can use — a scan, a picture of a formula — and the
    /// formula has to be read off the picture (`FormulaOCR`).
    struct Catch {
        var page: PDFPage
        var rect: CGRect
        var needsOCR: Bool
    }
    private(set) var caught: Catch?
    private var drag: (page: PDFPage, origin: CGPoint, current: CGPoint)?

    /// Told whenever the catch changes — the coordinator keeps it on the
    /// `ReaderLink` for ⌘L.
    var onCaught: (Catch?) -> Void = { _ in }
    var onToast: (String) -> Void = { _ in }
    /// Said once per run, the first time something is caught.
    private static var explained = false

    // Removed in `deinit`, which is why they are unsafe rather than isolated.
    nonisolated(unsafe) private var observers: [any NSObjectProtocol] = []

    init(pdfView: PDFView, configuration: ReaderConfiguration, document: PDFDocument) {
        self.pdfView = pdfView
        self.configuration = configuration
        self.document = document
        super.init(frame: pdfView.bounds)
        autoresizingMask = [.width, .height]
        wantsLayer = true
        let centre = NotificationCenter.default
        if let clip = pdfView.documentView?.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            observers.append(centre.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.needsDisplay = true }
            })
        }
        observers.append(centre.addObserver(forName: .PDFViewScaleChanged, object: pdfView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.needsDisplay = true }
        })
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    func activate() {
        window?.makeFirstResponder(self)
        window?.invalidateCursorRects(for: self)
    }

    /// The lasso goes away with its catch: a rectangle nobody can see is
    /// not a selection anybody meant.
    func deactivate() {
        drag = nil
        if caught != nil {
            caught = nil
            onCaught(nil)
        }
        needsDisplay = true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    // MARK: - The drag

    override func mouseDown(with event: NSEvent) {
        guard let spot = spot(for: event) else { return }
        drag = (spot.page, spot.point, spot.point)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        self.drag = (drag.page, drag.origin, point(of: event, on: drag.page))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let drag else { return }
        self.drag = nil
        let current = point(of: event, on: drag.page)
        let rect = CGRect(x: min(drag.origin.x, current.x), y: min(drag.origin.y, current.y),
                          width: abs(current.x - drag.origin.x), height: abs(current.y - drag.origin.y))
        // A click lets go of what was caught; a drag catches.
        guard rect.width >= 2, rect.height >= 2 else {
            if caught != nil { caught = nil; onCaught(nil) }
            needsDisplay = true
            return
        }
        self.catch(rect, on: drag.page)
    }

    /// Catches what the rectangle reaches, snapped to it.
    func `catch`(_ rect: CGRect, on page: PDFPage) {
        if let snapped = MathReader.extentRead(on: page, rect: rect) {
            caught = Catch(page: page, rect: snapped, needsOCR: false)
        } else {
            // Nothing to snap to: the rectangle stays as drawn, and the
            // formula is read off the picture.
            caught = Catch(page: page, rect: rect, needsOCR: true)
        }
        onCaught(caught)
        needsDisplay = true
        if !Self.explained {
            Self.explained = true
            onToast(L("수식을 잡았어요. ⇧⌘C로 LaTeX을 복사하고, ⌘L로 노트에 넣어요.",
                      "Caught. ⇧⌘C copies it as LaTeX; ⌘L quotes it in the note."))
        }
    }

    // MARK: - Keys

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:  // Escape: let go of the catch, then put the lasso away.
            if caught != nil {
                caught = nil
                onCaught(nil)
                needsDisplay = true
            } else {
                configuration.mode = .read
            }
        default:
            super.keyDown(with: event)
        }
    }

    // Scrolling and pinching go to the scroll view under this one — PDFKit
    // zooms with NSScrollView's own magnification (`SketchInputView`).
    override func scrollWheel(with event: NSEvent) {
        pdfView?.documentView?.enclosingScrollView?.scrollWheel(with: event)
    }

    override func magnify(with event: NSEvent) {
        guard let pdfView, let scrollView = pdfView.documentView?.enclosingScrollView else { return }
        if pdfView.autoScales { pdfView.autoScales = false }
        scrollView.magnify(with: event)
    }

    override func smartMagnify(with event: NSEvent) {
        guard let pdfView, let scrollView = pdfView.documentView?.enclosingScrollView else { return }
        if pdfView.autoScales { pdfView.autoScales = false }
        scrollView.smartMagnify(with: event)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let accent = NSColor.controlAccentColor
        if let caught {
            let box = viewRect(caught.rect, on: caught.page).insetBy(dx: -3, dy: -3)
            let path = CGPath(roundedRect: box, cornerWidth: 3, cornerHeight: 3, transform: nil)
            context.setFillColor(accent.withAlphaComponent(0.14).cgColor)
            context.addPath(path)
            context.fillPath()
            context.setStrokeColor(accent.withAlphaComponent(0.9).cgColor)
            context.setLineWidth(1.5)
            // Dashed when it will be read off the picture: the box is the
            // hand's, not the formula's.
            if caught.needsOCR { context.setLineDash(phase: 0, lengths: [5, 3]) }
            context.addPath(path)
            context.strokePath()
            context.setLineDash(phase: 0, lengths: [])
        }
        if let drag {
            let rect = CGRect(x: min(drag.origin.x, drag.current.x), y: min(drag.origin.y, drag.current.y),
                              width: abs(drag.current.x - drag.origin.x), height: abs(drag.current.y - drag.origin.y))
            let box = viewRect(rect, on: drag.page)
            context.setFillColor(accent.withAlphaComponent(0.08).cgColor)
            context.fill(box)
            context.setStrokeColor(accent.withAlphaComponent(0.7).cgColor)
            context.setLineWidth(1)
            context.setLineDash(phase: 0, lengths: [4, 3])
            context.stroke(box.insetBy(dx: 0.5, dy: 0.5))
            context.setLineDash(phase: 0, lengths: [])
        }
    }

    // MARK: - Coordinates

    private struct Spot {
        var page: PDFPage
        var point: CGPoint
    }

    /// The page under the pointer, and where on it, kept on the page.
    private func spot(for event: NSEvent) -> Spot? {
        guard let pdfView else { return nil }
        let inPDF = pdfView.convert(event.locationInWindow, from: nil)
        guard let page = pdfView.page(for: inPDF, nearest: true) else { return nil }
        return Spot(page: page, point: point(of: event, on: page))
    }

    /// The pointer's place on a given page, kept on it — a drag that leaves
    /// the page stays on the page it began on.
    private func point(of event: NSEvent, on page: PDFPage) -> CGPoint {
        guard let pdfView else { return .zero }
        let inPDF = pdfView.convert(event.locationInWindow, from: nil)
        let box = page.bounds(for: pdfView.displayBox)
        var point = pdfView.convert(inPDF, to: page)
        point.x = min(max(point.x, box.minX), box.maxX)
        point.y = min(max(point.y, box.minY), box.maxY)
        return point
    }

    private func viewPoint(_ point: CGPoint, on page: PDFPage) -> CGPoint {
        guard let pdfView else { return point }
        return convert(pdfView.convert(point, from: page), from: pdfView)
    }

    private func viewRect(_ rect: CGRect, on page: PDFPage) -> CGRect {
        let a = viewPoint(CGPoint(x: rect.minX, y: rect.minY), on: page)
        let b = viewPoint(CGPoint(x: rect.maxX, y: rect.maxY), on: page)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }
}
#endif
