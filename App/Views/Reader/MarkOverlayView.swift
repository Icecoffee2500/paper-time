#if os(macOS)
import AppKit
import PDFKit
import InkEngine
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
        let marks = RoundedMarks.takeOver(page)
        guard !marks.isEmpty else { return }

        // The overlay covers the page's display box; page space maps onto it
        // by one scale factor and an offset. Neither is flipped: PDF and an
        // unflipped NSView both put their origin at the bottom left.
        let box = page.bounds(for: .cropBox)
        guard box.width > 0, box.height > 0 else { return }
        context.saveGState()
        context.translateBy(x: 0, y: 0)
        context.scaleBy(x: bounds.width / box.width, y: bounds.height / box.height)
        context.translateBy(x: -box.minX, y: -box.minY)
        for mark in marks {
            RoundedMarks.draw(mark, in: context)
        }
        context.restoreGState()
    }
}

/// The words under a page's highlights, recoloured in each highlight's ink —
/// the way Apple Notes colours a highlighted word: a deep shade of the
/// highlighter over a pale band of it.
///
/// `MarkOverlayView` multiplies its bands onto the page, and nothing
/// multiplied onto black ink can be anything but black. So the page under
/// the highlights is drawn once more, in grey, its darkness taken as the
/// alpha of each highlight's ink inside that highlight's lines, and the
/// picture laid over the page plainly (the lasso's `paintInk`, the same
/// three bitmaps). One picture for all the highlights on the page, made
/// when they change or when the page is zoomed well past it — never a
/// drawing per mark, and never on the pointer's account: a hover changes
/// the band, not the ink.
///
/// Inside the PDF view's layer, so a tint's filters reach it: at night the
/// deep ink turns over into a light shade of the same colour, which is what
/// a highlighted word looks like in Apple Notes at night.
final class MarkInkView: NSView {
    private weak var page: PDFPage?
    private let ink = CALayer()
    /// The picture, the page area it covers (page space), its size in
    /// device pixels, and the marks it was drawn for.
    private var picture: (image: CGImage, drawn: CGRect, pixels: CGSize, key: String)?
    private var pending = false
    private var settling: DispatchWorkItem?

    nonisolated(unsafe) private static var byPage: [ObjectIdentifier: Weak] = [:]
    private struct Weak { weak var view: MarkInkView? }

    init(page: PDFPage) {
        self.page = page
        super.init(frame: .zero)
        wantsLayer = true
        ink.contentsGravity = .resize
        ink.magnificationFilter = .linear
        ink.minificationFilter = .trilinear
        layer?.addSublayer(ink)
        Self.byPage[ObjectIdentifier(page)] = Weak(view: self)
        NotificationCenter.default.addObserver(
            self, selector: #selector(marksChanged),
            name: .paperTimeMarksChanged, object: nil
        )
        // The zoom does not change this view's bounds: PDFKit zooms with
        // the scroll view's magnification, a transform on the clip view's
        // layer above this one. The picture has to be drawn again at the
        // new magnification, and the view hears of it only through this.
        NotificationCenter.default.addObserver(
            self, selector: #selector(scaleChanged),
            name: .PDFViewScaleChanged, object: nil
        )
    }

    deinit { NotificationCenter.default.removeObserver(self) }
    required init?(coder: NSCoder) { nil }

    @objc private func marksChanged() { schedule() }

    @objc private func scaleChanged(_ note: Notification) {
        guard let pdfView = note.object as? NSView, pdfView.window === window else { return }
        place()
        settleSoon()
    }

    /// A fresh picture once the zoom has settled: a pinch lays out every
    /// frame, and a page of highlights is a page drawn.
    private func settleSoon() {
        settling?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let picture, let frame = alignedFrame(of: picture.drawn) else { return }
            if frame.pixels != picture.pixels { schedule() }
        }
        settling = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(120), execute: work)
    }

    /// The ink for a page whose marks changed.
    static func refresh(_ page: PDFPage) {
        byPage[ObjectIdentifier(page)]?.view?.schedule()
    }

    /// The picture as painted for a page, for the probe: its pixels are
    /// what the screen shows, pixel for pixel.
    static func painting(of page: PDFPage) -> (image: CGImage, drawn: CGRect)? {
        guard let picture = byPage[ObjectIdentifier(page)]?.view?.picture else { return nil }
        return (picture.image, picture.drawn)
    }

    /// How this view and its ink layer stand on the screen, for the probe:
    /// the magnification the layer tree puts on top of the view's own points
    /// (the window's size of the bounds over the bounds), and the scales the
    /// layers believe they are drawn at.
    static func standing(of page: PDFPage) -> String {
        guard let view = byPage[ObjectIdentifier(page)]?.view else { return "no view" }
        let onScreen = view.convert(view.bounds, to: nil)
        let magnification = view.bounds.width > 0 ? onScreen.width / view.bounds.width : 0
        var chain: [String] = []
        var layer = view.layer
        while let current = layer {
            let t = current.affineTransform()
            if t.a != 1 || t.d != 1 { chain.append(String(format: "%@ ×%.3f", current.name ?? String(describing: type(of: current)), t.a)) }
            layer = current.superlayer
        }
        return String(format: "bounds %.1f×%.1f window %.1f×%.1f magnification %.3f backing %.1f view.contentsScale %.2f ink.contentsScale %.2f ink.frame %.1f×%.1f pixels %@ transforms [%@]",
                      view.bounds.width, view.bounds.height, onScreen.width, onScreen.height, magnification,
                      view.window?.backingScaleFactor ?? 0, view.layer?.contentsScale ?? 0, view.ink.contentsScale,
                      view.ink.frame.width, view.ink.frame.height,
                      view.picture.map { "\(Int($0.pixels.width))×\(Int($0.pixels.height))" } ?? "none", chain.joined(separator: ", "))
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        schedule()
    }

    override func layout() {
        super.layout()
        place()
        guard picture != nil else { return schedule() }
        settleSoon()
    }

    /// Device pixels per point of this view: the screen's backing scale
    /// times the magnification the layer tree puts on top of the view —
    /// `PDFView.scaleFactor`, which is the scroll view's magnification and
    /// never touches this view's bounds. Measured: at scale 2.0 the view is
    /// 610 points wide and 1220 in the window, with a ×2 transform on
    /// `PDFClipView`. A picture drawn at the backing scale alone was
    /// stretched by that transform, and every highlighted word was soft.
    private func pixelsPerPoint() -> CGFloat {
        let backing = window?.backingScaleFactor ?? 2
        guard window != nil, bounds.width > 0 else { return backing }
        let onScreen = convert(bounds, to: nil)
        let magnification = onScreen.width / bounds.width
        return backing * (magnification.isFinite && magnification > 0 ? magnification : 1)
    }

    /// One drawing per turn of the run loop, however many marks changed.
    private func schedule() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pending = false
            self.paint()
        }
    }

    /// Where a page-space area (the crop box's corner at the origin) lands
    /// in this view, pulled out to whole device pixels — and how many
    /// pixels that is. A picture drawn at exactly that size and put at
    /// exactly that frame is shown without resampling: a glyph drawn into
    /// the picture is as sharp as the page's own.
    private func alignedFrame(of drawn: CGRect) -> (frame: CGRect, pixels: CGSize, area: CGRect)? {
        guard let page, bounds.width > 0, bounds.height > 0 else { return nil }
        let size = PageGeometry(page: page).displaySize
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = CGSize(width: bounds.width / size.width, height: bounds.height / size.height)
        let raw = CGRect(x: drawn.minX * scale.width, y: drawn.minY * scale.height,
                         width: drawn.width * scale.width, height: drawn.height * scale.height)
        // Aligned to device pixels under the magnification: a pixel is
        // 1/(backing × magnification) of a point here, and a frame off that
        // grid is resampled by the GPU however exact the picture is.
        let pixel = 1 / pixelsPerPoint()
        let frame = CGRect(x: (raw.minX / pixel).rounded() * pixel, y: (raw.minY / pixel).rounded() * pixel,
                           width: (raw.width / pixel).rounded() * pixel, height: (raw.height / pixel).rounded() * pixel)
        let pixels = CGSize(width: (frame.width / pixel).rounded(), height: (frame.height / pixel).rounded())
        let area = CGRect(x: frame.minX / scale.width, y: frame.minY / scale.height,
                          width: frame.width / scale.width, height: frame.height / scale.height)
        guard pixels.width >= 1, pixels.height >= 1 else { return nil }
        return (frame, pixels, area)
    }

    private func paint() {
        guard let page, bounds.width > 0, bounds.height > 0 else { return }
        let highlights = RoundedMarks.takeOver(page).filter { $0.type == "Highlight" }
        guard !highlights.isEmpty else {
            picture = nil
            ink.contents = nil
            return
        }
        // What the picture is of: every line's place and every mark's colour.
        var lines: [(rects: [CGRect], ink: CGColor, band: CGColor)] = []
        var key = ""
        for mark in highlights {
            guard let color = RoundedMarks.ink(of: mark), let band = RoundedMarks.bandColor(of: mark) else { continue }
            let rects = RoundedMarks.lineRects(of: mark)
            lines.append((rects, color, band))
            for rect in rects {
                key += String(format: "%.1f,%.1f,%.1f,%.1f|", rect.minX, rect.minY, rect.width, rect.height)
            }
            key += (color.components ?? []).map { String(format: "%.3f", $0) }.joined(separator: ",") + ";"
        }
        guard let first = lines.first?.rects.first else { return }
        let area = lines.flatMap { $0.rects }.reduce(first) { $0.union($1) }.insetBy(dx: -4, dy: -3)
        // `draw(with:to:)` puts the crop box's corner at the origin (and turns
        // a turned page): the area goes where the page's own transform takes it.
        let transform = page.transform(for: .cropBox)
        guard let aligned = alignedFrame(of: area.applying(transform)) else { return }
        // Pixel for pixel on the screen, up to a size the GPU takes.
        let ceiling = 4096 / max(aligned.pixels.width, aligned.pixels.height, 1)
        let fit = min(1, ceiling)
        let pixels = CGSize(width: (aligned.pixels.width * fit).rounded(.down), height: (aligned.pixels.height * fit).rounded(.down))
        if let picture, picture.key == key, picture.pixels == pixels {
            place()
            return
        }
        let width = Int(pixels.width), height = Int(pixels.height)
        guard width > 0, height > 0 else { return }
        let drawn = aligned.area
        let density = CGSize(width: pixels.width / drawn.width, height: pixels.height / drawn.height)
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
        grey.scaleBy(x: density.width, y: density.height)
        grey.translateBy(x: -drawn.minX, y: -drawn.minY)
        // The page as printed, once: PDFKit's own copy of each highlight is
        // hidden (`takeOver`), so the words come up on white.
        page.draw(with: .cropBox, to: grey)
        guard let printed = grey.makeImage() else { return }
        // White where the page is dark: white, less the page.
        mask.setFillColor(gray: 1, alpha: 1)
        mask.fill(full)
        mask.setBlendMode(.difference)
        mask.draw(printed, in: full)
        guard let darkness = mask.makeImage() else { return }
        colour.scaleBy(x: density.width, y: density.height)
        colour.translateBy(x: -drawn.minX, y: -drawn.minY)
        for line in lines {
            // The band first, opaque, inside its rounded shape: the words'
            // own black has to be gone before the ink goes on, or the ink's
            // soft edges mix with black and the words look painted over
            // rather than printed in the colour. Then the ink through the
            // darkness, so each letter's edge is ink fading into band.
            //
            // Both stay inside the band. The ink once reached 2pt past it,
            // for an italic's first stroke — and reached the first letter
            // of the next word, which came up half-coloured and smeared.
            // A stroke that overhangs its line box stays as printed.
            let path = CGMutablePath()
            for rect in line.rects {
                let band = RoundedMarks.band(rect)
                let radius = min(rect.height * RoundedMarks.rounding, RoundedMarks.maximumRadius)
                path.addRoundedRect(in: band, cornerWidth: radius, cornerHeight: radius, transform: transform)
            }
            colour.saveGState()
            colour.addPath(path)
            colour.clip()
            colour.setFillColor(line.band)
            colour.fill(drawn)
            colour.clip(to: drawn, mask: darkness)
            colour.setFillColor(line.ink)
            colour.fill(drawn)
            colour.restoreGState()
        }
        guard let image = colour.makeImage() else { return }
        picture = (image, drawn, pixels, key)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ink.contents = image
        // Pixels per point of the layer: with the transform above, one
        // image pixel lands on one device pixel.
        ink.contentsScale = pixelsPerPoint()
        CATransaction.commit()
        place()
    }

    /// The picture over its place on the page as the page now stands.
    private func place() {
        guard let picture, let aligned = alignedFrame(of: picture.drawn) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ink.frame = aligned.frame
        CATransaction.commit()
    }
}
#endif
