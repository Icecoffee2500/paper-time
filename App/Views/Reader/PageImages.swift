#if os(macOS)
import AppKit
import CoreImage
import InkEngine
import PDFKit
import PencilKit

/// Where the pictures are on a page.
///
/// Found by walking the page's content stream the way the renderer does —
/// tracking the transform through `q`, `Q` and `cm` and noting every `Do`
/// that draws an image, into forms one level down — because PDFKit has no
/// notion of a figure and the alternative, guessing from where the text is
/// not, guesses wrong on every page with a wide margin.
enum PageImages {
    /// Image rectangles in the page's user space, cached per page.
    nonisolated(unsafe) private static var cache: [ObjectIdentifier: [CGRect]] = [:]

    static func rects(on page: PDFPage) -> [CGRect] {
        let key = ObjectIdentifier(page)
        if let known = cache[key] { return known }
        let found = scan(page)
        cache[key] = found
        return found
    }

    private final class Walk {
        var transforms: [CGAffineTransform] = [.identity]
        var rects: [CGRect] = []
        var depth = 0
        var current: CGAffineTransform { transforms.last ?? .identity }
    }

    private static func scan(_ page: PDFPage) -> [CGRect] {
        guard let ref = page.pageRef else { return [] }
        let walk = Walk()
        let stream = CGPDFContentStreamCreateWithPage(ref)
        run(stream, walk: walk)
        // Not a hairline rule drawn as an image. Anything bigger is kept:
        // a figure made of small photographs (a grid of video frames, a
        // row of robot views) is the common case, and each of them turned
        // into a negative is what "the pictures are inverted too" meant.
        let box = page.bounds(for: .mediaBox)
        return walk.rects.filter { $0.width > 12 && $0.height > 12 && $0.intersects(box) }
    }

    private static func run(_ stream: CGPDFContentStreamRef, walk: Walk) {
        guard let table = CGPDFOperatorTableCreate() else { return }
        let info = Unmanaged.passUnretained(walk).toOpaque()

        CGPDFOperatorTableSetCallback(table, "q") { _, info in
            let walk = Unmanaged<Walk>.fromOpaque(info!).takeUnretainedValue()
            walk.transforms.append(walk.current)
        }
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in
            let walk = Unmanaged<Walk>.fromOpaque(info!).takeUnretainedValue()
            if walk.transforms.count > 1 { walk.transforms.removeLast() }
        }
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
            let walk = Unmanaged<Walk>.fromOpaque(info!).takeUnretainedValue()
            var values = [CGPDFReal](repeating: 0, count: 6)
            // Popped in reverse: f, e, d, c, b, a.
            for index in stride(from: 5, through: 0, by: -1) {
                var value: CGPDFReal = 0
                guard CGPDFScannerPopNumber(scanner, &value) else { return }
                values[index] = value
            }
            let matrix = CGAffineTransform(a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5])
            walk.transforms[walk.transforms.count - 1] = matrix.concatenating(walk.current)
        }
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            let walk = Unmanaged<Walk>.fromOpaque(info!).takeUnretainedValue()
            var namePointer: UnsafePointer<Int8>?
            guard CGPDFScannerPopName(scanner, &namePointer), let namePointer else { return }
            let stream = CGPDFScannerGetContentStream(scanner)
            guard let object = CGPDFContentStreamGetResource(stream, "XObject", namePointer) else { return }
            var xobject: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &xobject), let xobject,
                  let dictionary = CGPDFStreamGetDictionary(xobject)
            else { return }
            var subtypePointer: UnsafePointer<Int8>?
            guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtypePointer), let subtypePointer else { return }
            let subtype = String(cString: subtypePointer)
            if subtype == "Image" {
                // An image is drawn into the unit square of the current
                // transform; its corners are where that square lands.
                let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
                walk.rects.append(unit.applying(walk.current))
            } else if subtype == "Form", walk.depth < 2 {
                var matrix = CGAffineTransform.identity
                var matrixArray: CGPDFArrayRef?
                if CGPDFDictionaryGetArray(dictionary, "Matrix", &matrixArray), let matrixArray,
                   CGPDFArrayGetCount(matrixArray) == 6 {
                    var values = [CGPDFReal](repeating: 0, count: 6)
                    for index in 0..<6 { CGPDFArrayGetNumber(matrixArray, index, &values[index]) }
                    matrix = CGAffineTransform(a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5])
                }
                // Draw the form as the renderer would: its matrix, then ours,
                // and its own resources. The second argument is the form's
                // `/Resources`, not its stream dictionary — given the latter,
                // every name inside the form was looked up in the wrong place
                // and no picture inside a form was ever found. A figure put
                // into a TeX paper as a PDF is exactly such a form, so its
                // photographs were inverted with the page (the corpus has
                // 1,493 pictures of that size, of which 998 were being found).
                walk.transforms.append(matrix.concatenating(walk.current))
                walk.depth += 1
                var resources: CGPDFDictionaryRef?
                let own = CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources) ? resources ?? dictionary : dictionary
                PageImages.run(CGPDFContentStreamCreateWithStream(xobject, own, stream), walk: walk)
                walk.depth -= 1
                walk.transforms.removeLast()
            }
        }

        let scanner = CGPDFScannerCreate(stream, table, info)
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFOperatorTableRelease(table)
    }
}

/// Whether the reader is showing the dimmed page.
enum NightMode {
    nonisolated(unsafe) static var isOn = false
}

/// Puts a page's figures back the right way round under the dimmed tint.
///
/// Dimmed is an inversion of the whole PDF view's layer, which turns the
/// paper dark and the ink light and every photograph into a negative. This
/// view lies over the page inside that same layer and draws each figure
/// *already inverted* — the same two filters applied once in advance — so
/// that when the layer inverts everything on its way to the screen, the
/// figure comes out as printed. Nothing is drawn when the page is not dimmed.
final class FigureOverlayView: NSView {
    private weak var page: PDFPage?
    /// The whole page, drawn once and passed through the night filters once.
    private var inverted: CGImage?
    /// Each figure's piece of it, and where that piece lies on the page.
    private var pieces: [Int: (image: CGImage, rect: CGRect)] = [:]
    nonisolated(unsafe) private static let ciContext = CIContext()

    init(page: PDFPage) {
        self.page = page
        super.init(frame: .zero)
        wantsLayer = true
        layer?.isOpaque = false
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard NightMode.isOn, let page, let context = NSGraphicsContext.current?.cgContext else { return }
        let rects = PageImages.rects(on: page)
        guard !rects.isEmpty else { return }
        let box = page.bounds(for: .cropBox)
        guard box.width > 0, box.height > 0 else { return }
        let scale = bounds.width / box.width
        for (index, rect) in rects.enumerated() {
            let rough = CGRect(
                x: (rect.minX - box.minX) * scale, y: (rect.minY - box.minY) * scale,
                width: rect.width * scale, height: rect.height * scale
            )
            guard rough.intersects(dirtyRect.insetBy(dx: -2, dy: -2)) else { continue }
            if pieces[index] == nil, let piece = piece(of: rect, on: page) { pieces[index] = piece }
            guard let piece = pieces[index] else { continue }
            let onScreen = CGRect(
                x: (piece.rect.minX - box.minX) * scale, y: (piece.rect.minY - box.minY) * scale,
                width: piece.rect.width * scale, height: piece.rect.height * scale
            )
            context.draw(piece.image, in: onScreen)
        }
    }

    /// A figure's part of the inverted page, cut on whole pixels, with the
    /// page rectangle those pixels cover — so it lands exactly where it was
    /// cut from.
    ///
    /// The page is drawn **once** for all its figures. It used to be drawn
    /// once per figure, which was harmless at a few figures a page and is
    /// not at a grid of forty-eight video frames: PDFKit's page drawing on
    /// the main thread, forty-eight times, is the pattern that once made
    /// table pages stall (see `InkStrip`).
    private func piece(of rect: CGRect, on page: PDFPage) -> (image: CGImage, rect: CGRect)? {
        if inverted == nil { inverted = Self.preinverted(page) }
        guard let sheet = inverted else { return nil }
        let media = page.bounds(for: .mediaBox)
        let pixelScale = CGFloat(sheet.width) / media.width
        // Image rows run from the top; page space runs from the bottom.
        let pixels = CGRect(
            x: (rect.minX - media.minX) * pixelScale, y: (media.maxY - rect.maxY) * pixelScale,
            width: rect.width * pixelScale, height: rect.height * pixelScale
        ).integral.intersection(CGRect(x: 0, y: 0, width: sheet.width, height: sheet.height))
        guard !pixels.isNull, pixels.width >= 1, pixels.height >= 1, let cut = sheet.cropping(to: pixels) else { return nil }
        let covered = CGRect(
            x: media.minX + pixels.minX / pixelScale, y: media.maxY - pixels.maxY / pixelScale,
            width: pixels.width / pixelScale, height: pixels.height / pixelScale
        )
        return (cut, covered)
    }

    /// The page as printed, passed through the night filters once, so that
    /// when the layer inverts everything on its way to the screen the
    /// figures come out the right way round.
    private static func preinverted(_ page: PDFPage) -> CGImage? {
        let media = page.bounds(for: .mediaBox)
        guard media.width > 1, media.height > 1 else { return nil }
        let pixelScale = min(2, 4000 / max(media.width, media.height))
        let width = Int(media.width * pixelScale), height = Int(media.height * pixelScale)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: pixelScale, y: pixelScale)
        page.draw(with: .mediaBox, to: context)
        guard let plain = context.makeImage() else { return nil }
        let input = CIImage(cgImage: plain)
        let output = input
            .applyingFilter("CIColorInvert")
            .applyingFilter("CIHueAdjust", parameters: [kCIInputAngleKey: Double.pi])
        return ciContext.createCGImage(output, from: input.extent, format: .RGBA8, colorSpace: space)
    }
}

/// One view over a page holding its overlays: the mask over the margin's
/// stamps, the figures for the dimmed tint, composited plainly, and the
/// marks, multiplied onto the paper.
final class PageOverlay: NSView {
    private let mask: MarginMaskView

    init(
        page: PDFPage,
        drawing: @escaping () -> PKDrawing = { PKDrawing() },
        sketch: @escaping () -> [SketchElement] = { [] },
        hiddenSketch: @escaping () -> Set<UUID> = { [] }
    ) {
        mask = MarginMaskView(page: page)
        super.init(frame: .zero)
        let marks = MarkOverlayView(page: page)
        let figures = FigureOverlayView(page: page)
        let ink = InkOverlayView(page: page, drawing: drawing)
        let shapes = SketchOverlayView(page: page, elements: sketch, hidden: hiddenSketch)
        for child in [mask, figures, marks, ink, shapes] as [NSView] {
            child.autoresizingMask = [.width, .height]
            addSubview(child)
        }
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        for child in subviews { child.frame = bounds }
        // The book's crop comes and goes with the layout, and the page is
        // laid out again each time it does.
        mask.needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The page's ink, drawn from its sidecar the way the iPad draws it —
/// PencilKit renders the strokes — so the two look the same and a stroke
/// made on the iPad is on the Mac as soon as its few kilobytes arrive.
final class InkOverlayView: NSView {
    private weak var page: PDFPage?
    private let drawing: () -> PKDrawing
    private var cached: (drawing: PKDrawing, image: NSImage)?

    nonisolated(unsafe) private static var byPage: [ObjectIdentifier: Weak] = [:]
    private struct Weak { weak var view: InkOverlayView? }

    init(page: PDFPage, drawing: @escaping () -> PKDrawing) {
        self.page = page
        self.drawing = drawing
        super.init(frame: .zero)
        Self.byPage[ObjectIdentifier(page)] = Weak(view: self)
    }

    required init?(coder: NSCoder) { nil }

    static func refresh(_ page: PDFPage) {
        byPage[ObjectIdentifier(page)]?.view?.needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let page else { return }
        let strokes = drawing()
        guard !strokes.strokes.isEmpty, bounds.width > 0 else { return }
        let size = PageGeometry(page: page).displaySize
        let image: NSImage
        if let cached, cached.drawing == strokes {
            image = cached.image
        } else {
            image = strokes.image(from: CGRect(origin: .zero, size: size), scale: 2)
            cached = (strokes, image)
        }
        image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
    }
}

/// The page's shapes, arrows and text cards, drawn from the sketch sidecar
/// with the one renderer every device uses — so an arrow bent on the Mac
/// is the same arrow on the iPad. Leaves out whatever the input view is
/// drawing itself at the moment (the box being dragged, the card being
/// typed into), so nothing is drawn twice.
final class SketchOverlayView: NSView {
    private weak var page: PDFPage?
    private let elements: () -> [SketchElement]
    private let hiddenIDs: () -> Set<UUID>

    nonisolated(unsafe) private static var byPage: [ObjectIdentifier: Weak] = [:]
    private struct Weak { weak var view: SketchOverlayView? }

    init(page: PDFPage, elements: @escaping () -> [SketchElement], hidden: @escaping () -> Set<UUID>) {
        self.page = page
        self.elements = elements
        self.hiddenIDs = hidden
        super.init(frame: .zero)
        wantsLayer = true
        Self.byPage[ObjectIdentifier(page)] = Weak(view: self)
    }

    required init?(coder: NSCoder) { nil }

    static func refresh(_ page: PDFPage) {
        byPage[ObjectIdentifier(page)]?.view?.needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let page, let context = NSGraphicsContext.current?.cgContext else { return }
        let left = hiddenIDs()
        let shown = elements().filter { !left.contains($0.id) }
        guard !shown.isEmpty else { return }
        let box = page.bounds(for: .cropBox)
        guard box.width > 0, box.height > 0 else { return }
        context.saveGState()
        context.scaleBy(x: bounds.width / box.width, y: bounds.height / box.height)
        context.translateBy(x: -box.minX, y: -box.minY)
        // Pixels per page point where this is going: the zoom this context was
        // just given, times the screen's own. A formula is the only thing in a
        // card that is a bitmap, and this is the number it has to be made at.
        SketchRenderer.draw(shown, in: context, options: .init(
            rasterScale: (bounds.width / box.width) * (window?.backingScaleFactor ?? 2)
        ))
        context.restoreGState()
    }
}
#endif
