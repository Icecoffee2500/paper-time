#if os(macOS)
import AppKit
import CoreImage
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
/// number included, or the words inside — and what it caught is shown as a
/// segmentation, not a box: the ink of exactly those glyphs turns the accent
/// colour (`MathReader.extentInk`), so the letters on the page that light up
/// are the letters ⇧⌘C copies.
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
        /// Where the ink of what the reader will read is — a box a glyph,
        /// and the rules among them (`MathReader.extentInk`). Empty when the
        /// picture is read instead.
        var ink: [CGRect]
        var needsOCR: Bool
    }
    private(set) var caught: Catch?
    private var drag: (page: PDFPage, origin: CGPoint, current: CGPoint)?

    /// The caught glyphs' ink, recoloured: a picture of the page under the
    /// catch whose dark pixels inside the glyphs' boxes are the accent and
    /// everything else clear, laid exactly over the letters, with a soft
    /// glow of the same colour round them.
    private let ink = CALayer()
    /// What the picture was made of: the page area, and how many pixels a
    /// page point. Made again when the page is zoomed past it.
    private(set) var inkPicture: (image: CGImage, area: CGRect, density: CGFloat)?
    /// Says the lasso is out, and what to do with it, while it is.
    private let banner = LassoBanner()
    private var tracking: NSTrackingArea?

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
        ink.contentsGravity = .resize
        ink.magnificationFilter = .linear
        ink.shadowOffset = .zero
        ink.shadowRadius = 2
        ink.shadowOpacity = 0.55
        layer?.addSublayer(ink)
        addSubview(banner)
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

    /// The banner's line while a picture is read (`LassoBanner.showReading`).
    func setReading(_ text: String?) {
        banner.showReading(text)
        placeBanner()
    }

    /// What the banner says now — for the probe.
    var debugReadingLine: String { banner.line }

    func activate() {
        window?.makeFirstResponder(self)
        window?.invalidateCursorRects(for: self)
        placeBanner()
        // The pointer is already over the page: the crosshair now, not at
        // the next move.
        if let window, bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
            NSCursor.crosshair.set()
        }
    }

    override func layout() {
        super.layout()
        placeBanner()
    }

    // Before each drawing, not during it: the tint may have changed since.
    override func viewWillDraw() {
        super.viewWillDraw()
        banner.undoNight(NightMode.isOn)
    }

    private func placeBanner() {
        // As much of the line as the pane has room for: in a narrow pane
        // (two papers side by side) the long line ran off both edges.
        banner.fit(width: bounds.width - 24)
        banner.undoNight(NightMode.isOn)
        let size = banner.fittingSize
        banner.frame = CGRect(x: ((bounds.width - size.width) / 2).rounded(), y: bounds.maxY - 12 - size.height,
                              width: size.width, height: size.height)
    }

    /// The lasso goes away with its catch: a rectangle nobody can see is
    /// not a selection anybody meant.
    func deactivate() {
        drag = nil
        if caught != nil {
            caught = nil
            onCaught(nil)
        }
        paintInk()
        needsDisplay = true
    }

    // The crosshair says the lasso is out. PDFKit's own views set their
    // cursors from tracking areas of their own, so a cursor rect alone lost
    // to them half the time; this view's tracking area answers every move.
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.cursorUpdate, .mouseMoved, .mouseEnteredAndExited,
                                                         .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }
    override func mouseEntered(with event: NSEvent) { NSCursor.crosshair.set() }
    override func mouseMoved(with event: NSEvent) {
        if NSCursor.current != NSCursor.crosshair { NSCursor.crosshair.set() }
    }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

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
            caught = Catch(page: page, rect: snapped, ink: MathReader.extentInk(on: page, rect: rect) ?? [], needsOCR: false)
        } else {
            // Nothing to snap to: the rectangle stays as drawn, and the
            // formula is read off the picture.
            caught = Catch(page: page, rect: rect, ink: [], needsOCR: true)
            #if canImport(MLXVLM)
            // The handwriting model, if there is one, starts loading now.
            if HandwritingReader.canRun, let directory = HandwritingModels.shared.readyDirectory {
                Task { await HandwritingReader.shared.prewarm(directory) }
            }
            #endif
        }
        paintInk()
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
        placeInk()
        if let caught, caught.needsOCR {
            // Read off the picture: the box is the hand's, not the
            // formula's, and is drawn as a box — dashed.
            let box = viewRect(caught.rect, on: caught.page).insetBy(dx: -3, dy: -3)
            let path = CGPath(roundedRect: box, cornerWidth: 3, cornerHeight: 3, transform: nil)
            context.setFillColor(accent.withAlphaComponent(0.1).cgColor)
            context.addPath(path)
            context.fillPath()
            context.setStrokeColor(accent.withAlphaComponent(0.9).cgColor)
            context.setLineWidth(1.5)
            context.setLineDash(phase: 0, lengths: [5, 3])
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

    /// Makes the picture of the caught ink: the page under the catch drawn in
    /// grey once, its darkness taken as a mask, and the accent let through
    /// that mask inside the glyphs' boxes only — the "Targets:" before a
    /// formula stays black, the formula turns blue. The page is drawn once a
    /// catch (and again only when the page is zoomed past the picture), as
    /// `InkStrip` does: a page is never drawn line by line.
    private func paintInk() {
        guard let caught, !caught.needsOCR, let first = caught.ink.first, let pdfView else {
            inkPicture = nil
            ink.contents = nil
            return
        }
        let area = caught.ink.dropFirst().reduce(first) { $0.union($1) }.insetBy(dx: -3, dy: -3)
        let backing = window?.backingScaleFactor ?? 2
        // Sharp at the zoom it is seen at, and never a picture past 4096
        // pixels a side.
        let density = min(max(pdfView.scaleFactor * backing, 2), 4096 / max(area.width, area.height, 1))
        let width = Int((area.width * density).rounded(.up)), height = Int((area.height * density).rounded(.up))
        guard width > 0, height > 0 else { return }
        // `draw(with:to:)` puts the crop box's corner at the origin (and
        // turns a turned page): the area goes where the page's own transform
        // takes it.
        let transform = caught.page.transform(for: .cropBox)
        let drawn = area.applying(transform)
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        guard let grey = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let mask = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let colour = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        grey.setFillColor(gray: 1, alpha: 1)
        grey.fill(full)
        grey.scaleBy(x: density, y: density)
        grey.translateBy(x: -drawn.minX, y: -drawn.minY)
        caught.page.draw(with: .cropBox, to: grey)
        guard let page = grey.makeImage() else { return }
        // White where the page is dark: white, less the page.
        mask.setFillColor(gray: 1, alpha: 1)
        mask.fill(full)
        mask.setBlendMode(.difference)
        mask.draw(page, in: full)
        guard let darkness = mask.makeImage() else { return }
        // The accent, through the darkness, inside the glyphs' boxes.
        colour.scaleBy(x: density, y: density)
        colour.translateBy(x: -drawn.minX, y: -drawn.minY)
        colour.addRects(caught.ink.map { $0.insetBy(dx: -0.6, dy: -0.6).applying(transform) })
        colour.clip()
        colour.clip(to: drawn, mask: darkness)
        colour.setFillColor(NSColor.controlAccentColor.usingColorSpace(.deviceRGB)?.cgColor ?? NSColor.controlAccentColor.cgColor)
        colour.fill(drawn)
        guard let picture = colour.makeImage() else { return }
        inkPicture = (picture, area, density)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ink.contents = picture
        ink.shadowColor = NSColor.controlAccentColor.cgColor
        CATransaction.commit()
        placeInk()
    }

    /// The picture over its place on the page as the page now stands — and
    /// made again, sharper, when the page has been zoomed well past it.
    private func placeInk() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let caught, let made = inkPicture, !caught.needsOCR else {
            ink.isHidden = true
            return
        }
        ink.isHidden = false
        ink.frame = viewRect(made.area, on: caught.page)
        if let pdfView, pdfView.scaleFactor * (window?.backingScaleFactor ?? 2) > made.density * 1.4,
           made.density < 4096 / max(made.area.width, made.area.height, 1) {
            DispatchQueue.main.async { [weak self] in self?.paintInk() }
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

/// The capsule at the top of the page while the lasso is out: the lasso's
/// symbol and one line saying what to do. It takes no mouse. (Drawn by
/// hand rather than as a vibrancy view: this view sits inside the PDF
/// view's layer, which a tint filters, and a material under a filter is
/// not a material.)
@MainActor
final class LassoBanner: NSView {
    private let stack = NSStackView()
    private let label = NSTextField(labelWithString: "")
    /// The line, longest first; the first that fits the pane is shown.
    private let lines = [
        L("수식 올가미 — 끌어서 수식을 잡아요. Esc로 끝내요.", "Formula Lasso — drag around a formula. Press Esc to finish."),
        L("수식 올가미 · Esc로 끝내요", "Formula Lasso · Esc to finish"),
        L("수식 올가미", "Formula Lasso"),
    ]

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.borderWidth = 1
        layer?.masksToBounds = true
        let symbol = NSImageView()
        symbol.image = NSImage(systemSymbolName: "lasso", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        symbol.contentTintColor = .controlAccentColor
        label.stringValue = lines[0]
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 14)
        stack.addArrangedSubview(symbol)
        stack.addArrangedSubview(label)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override var fittingSize: NSSize { stack.fittingSize }

    /// Under the night tint the PDF view's layer is inverted with its hue
    /// turned back (`setNightFilter`), and this capsule is inside it: it
    /// takes the same filters first, so the two cancel and it shows as the
    /// app's own — the way the figures overlay draws its photographs.
    func undoNight(_ night: Bool) {
        layerUsesCoreImageFilters = true
        guard night, let invert = CIFilter(name: "CIColorInvert"),
              let hue = CIFilter(name: "CIHueAdjust", parameters: [kCIInputAngleKey: Double.pi])
        else {
            if layer?.filters != nil { layer?.filters = nil }
            return
        }
        if (layer?.filters?.count ?? 0) != 2 { layer?.filters = [invert, hue] }
    }

    /// The longest of the lines that fits in `width`.
    func fit(width: CGFloat) {
        lastWidth = width
        guard reading == nil else { return showReading(reading) }
        for line in lines {
            label.stringValue = line
            if stack.fittingSize.width <= width { return }
        }
    }

    private var lastWidth: CGFloat = .greatestFiniteMagnitude
    /// What the handwriting model has written so far, while it reads.
    private var reading: String?

    /// While a picture is being read, the capsule says so and shows the
    /// last words of the answer as they come — a wait with something
    /// happening in it, rather than a spinner. Nil puts the line back.
    func showReading(_ text: String?) {
        reading = text
        guard let text else { return fit(width: lastWidth) }
        let lead = L("손글씨 읽는 중", "Reading the handwriting")
        let words = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        label.stringValue = words.isEmpty ? lead + "…" : lead + " · " + words
        // From the end: the newest words are the news.
        var kept = words.count
        while stack.fittingSize.width > lastWidth, kept > 8 {
            kept = Int(Double(kept) * 0.8)
            label.stringValue = lead + " · …" + String(words.suffix(kept))
        }
    }

    var line: String { label.stringValue }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.94).cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
    override var wantsUpdateLayer: Bool { true }
}
#endif
