#if os(macOS)
import AppKit
import CoreImage
import PDFKit

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
        // Only pictures big enough to be a figure — a logo in a corner or a
        // hairline rule drawn as an image is not something anyone reads.
        let box = page.bounds(for: .mediaBox)
        return walk.rects.filter { $0.width > 40 && $0.height > 24 && $0.intersects(box) }
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
                // Draw the form as the renderer would: its matrix, then ours.
                walk.transforms.append(matrix.concatenating(walk.current))
                walk.depth += 1
                PageImages.run(CGPDFContentStreamCreateWithStream(xobject, dictionary, stream), walk: walk)
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
    private var rendered: [Int: NSImage] = [:]

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
        let box = page.bounds(for: .cropBox)
        guard box.width > 0, box.height > 0 else { return }
        let scale = bounds.width / box.width
        for (index, rect) in PageImages.rects(on: page).enumerated() {
            let onScreen = CGRect(
                x: (rect.minX - box.minX) * scale, y: (rect.minY - box.minY) * scale,
                width: rect.width * scale, height: rect.height * scale
            )
            guard onScreen.intersects(dirtyRect.insetBy(dx: -2, dy: -2)) else { continue }
            if rendered[index] == nil { rendered[index] = Self.preinverted(rect, on: page) }
            rendered[index]?.draw(in: onScreen)
        }
        _ = context
    }

    /// The figure as printed, passed through the dimming filters once.
    private static func preinverted(_ rect: CGRect, on page: PDFPage) -> NSImage? {
        let pixelScale: CGFloat = 2
        let size = NSSize(width: rect.width * pixelScale, height: rect.height * pixelScale)
        guard size.width > 1, size.height > 1, size.width < 6000, size.height < 6000 else { return nil }
        let plain = NSImage(size: size)
        plain.lockFocus()
        if let context = NSGraphicsContext.current?.cgContext {
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(origin: .zero, size: size))
            context.scaleBy(x: pixelScale, y: pixelScale)
            let media = page.bounds(for: .mediaBox)
            context.translateBy(x: -(rect.minX - media.minX), y: -(rect.minY - media.minY))
            page.draw(with: .mediaBox, to: context)
        }
        plain.unlockFocus()

        guard let tiff = plain.tiffRepresentation, let input = CIImage(data: tiff),
              let invert = CIFilter(name: "CIColorInvert"),
              let hue = CIFilter(name: "CIHueAdjust", parameters: [kCIInputAngleKey: Double.pi])
        else { return plain }
        invert.setValue(input, forKey: kCIInputImageKey)
        hue.setValue(invert.outputImage, forKey: kCIInputImageKey)
        guard let output = hue.outputImage else { return plain }
        let representation = NSCIImageRep(ciImage: output)
        let result = NSImage(size: size)
        result.addRepresentation(representation)
        return result
    }
}

/// One view over a page holding both overlays: the marks, multiplied onto
/// the paper, and the figures for the dimmed tint, composited plainly.
final class PageOverlay: NSView {
    init(page: PDFPage) {
        super.init(frame: .zero)
        let marks = MarkOverlayView(page: page)
        let figures = FigureOverlayView(page: page)
        for child in [figures, marks] as [NSView] {
            child.autoresizingMask = [.width, .height]
            addSubview(child)
        }
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        for child in subviews { child.frame = bounds }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
#endif
