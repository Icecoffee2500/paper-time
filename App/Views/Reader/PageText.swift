#if os(macOS)
import CoreGraphics
import PDFKit

/// The runs of text on a page as its content stream sets them: where each
/// begins and ends along its baseline, how large it is, and in what weight.
///
/// PDFKit hands back the words and their sizes but calls every font
/// "Helvetica", whatever the PDF set it in — so whether a line is bold,
/// which is how a journal marks its headings, cannot be read from it. The
/// content stream knows: each run is shown in a named font, and the font's
/// own dictionary says what that font is. This walks the stream the way the
/// renderer does — the transform through `q`, `Q` and `cm`, the text matrix
/// through `BT`, `Td`, `Tm` and the rest — and notes every run it shows,
/// advanced by the font's own glyph widths so that the run's end is known
/// as well as its start.
enum PageText {
    struct Run {
        /// The baseline's two ends, in page space.
        var start: CGPoint
        var end: CGPoint
        /// The size the run is set at on the page, in points.
        var size: CGFloat
        var bold: Bool
        var italic: Bool
        /// How many character codes the run shows.
        var codes: Int

        /// Text that runs across the page rather than up it.
        var isHorizontal: Bool { abs(end.x - start.x) >= abs(end.y - start.y) }
        var minX: CGFloat { min(start.x, end.x) }
        var maxX: CGFloat { max(start.x, end.x) }
    }

    static func runs(on page: PDFPage) -> [Run] { scan(page) }

    // MARK: - Fonts

    private struct Font {
        var bold = false
        var italic = false
        /// Two bytes to a code, as a composite font is.
        var twoByte = false
        /// Glyph widths by code, in thousandths of the size.
        var widths: [Int: CGFloat] = [:]
        var defaultWidth: CGFloat = 500

        func width(of code: Int) -> CGFloat { widths[code] ?? defaultWidth }
    }

    private static func font(named name: UnsafePointer<CChar>, in stream: CGPDFContentStreamRef, walk: Walk) -> Font? {
        guard let object = CGPDFContentStreamGetResource(stream, "Font", name) else { return nil }
        var dictionary: CGPDFDictionaryRef?
        guard CGPDFObjectGetValue(object, .dictionary, &dictionary), let dictionary else { return nil }
        let key = unsafeBitCast(dictionary, to: UInt.self)
        if let known = walk.fonts[key] { return known }
        let parsed = parse(dictionary)
        walk.fonts[key] = parsed
        return parsed
    }

    private static func name(_ key: String, in dictionary: CGPDFDictionaryRef) -> String? {
        var pointer: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, key, &pointer), let pointer else { return nil }
        return String(cString: pointer)
    }

    private static func number(_ key: String, in dictionary: CGPDFDictionaryRef) -> CGFloat? {
        var value: CGPDFReal = 0
        guard CGPDFDictionaryGetNumber(dictionary, key, &value) else { return nil }
        return value
    }

    private static func parse(_ dictionary: CGPDFDictionaryRef) -> Font {
        var font = Font()
        let subtype = name("Subtype", in: dictionary) ?? ""
        var glyphs = dictionary
        if subtype == "Type0" {
            font.twoByte = true
            var descendants: CGPDFArrayRef?
            var descendant: CGPDFDictionaryRef?
            if CGPDFDictionaryGetArray(dictionary, "DescendantFonts", &descendants), let descendants,
               CGPDFArrayGetDictionary(descendants, 0, &descendant), let descendant {
                glyphs = descendant
            }
            font.defaultWidth = number("DW", in: glyphs) ?? 1000
            var widths: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(glyphs, "W", &widths), let widths {
                // [c [w w …]] runs and [first last w] spans, mixed.
                var index = 0
                let count = CGPDFArrayGetCount(widths)
                while index < count {
                    var first: CGPDFReal = 0
                    guard CGPDFArrayGetNumber(widths, index, &first) else { break }
                    var list: CGPDFArrayRef?
                    if index + 1 < count, CGPDFArrayGetArray(widths, index + 1, &list), let list {
                        for offset in 0..<CGPDFArrayGetCount(list) where font.widths.count < 6000 {
                            var width: CGPDFReal = 0
                            if CGPDFArrayGetNumber(list, offset, &width) { font.widths[Int(first) + offset] = width }
                        }
                        index += 2
                    } else if index + 2 < count {
                        var last: CGPDFReal = 0, width: CGPDFReal = 0
                        guard CGPDFArrayGetNumber(widths, index + 1, &last), CGPDFArrayGetNumber(widths, index + 2, &width) else { break }
                        if last - first < 6000 {
                            for code in Int(first)...max(Int(first), Int(last)) { font.widths[code] = width }
                        }
                        index += 3
                    } else { break }
                }
            }
        } else {
            var widths: CGPDFArrayRef?
            let first = Int(number("FirstChar", in: dictionary) ?? 0)
            if CGPDFDictionaryGetArray(dictionary, "Widths", &widths), let widths {
                for offset in 0..<CGPDFArrayGetCount(widths) {
                    var width: CGPDFReal = 0
                    if CGPDFArrayGetNumber(widths, offset, &width) { font.widths[first + offset] = width }
                }
            }
            if subtype == "Type3" {
                // Type 3 widths are in glyph space; the font matrix maps them.
                var matrix: CGPDFArrayRef?
                var scale: CGPDFReal = 0.001
                if CGPDFDictionaryGetArray(dictionary, "FontMatrix", &matrix), let matrix { CGPDFArrayGetNumber(matrix, 0, &scale) }
                for (code, width) in font.widths { font.widths[code] = width * scale * 1000 }
            }
        }

        // What the font is, from its name and its descriptor.
        var base = (name("BaseFont", in: dictionary) ?? name("BaseFont", in: glyphs) ?? "").lowercased()
        if let plus = base.firstIndex(of: "+"), base.distance(from: base.startIndex, to: plus) == 6 { base = String(base[base.index(after: plus)...]) }
        var descriptor: CGPDFDictionaryRef?
        var flags = 0, stemV: CGFloat = 0, weight: CGFloat = 0
        if CGPDFDictionaryGetDictionary(glyphs, "FontDescriptor", &descriptor), let descriptor {
            var raw: CGPDFInteger = 0
            if CGPDFDictionaryGetInteger(descriptor, "Flags", &raw) { flags = Int(raw) }
            stemV = number("StemV", in: descriptor) ?? 0
            weight = number("FontWeight", in: descriptor) ?? 0
            if let missing = number("MissingWidth", in: descriptor), !font.twoByte, missing > 0 { font.defaultWidth = missing }
        }
        let saysRegular = ["regu", "roman", "light", "book", "-it", "ital", "obli"].contains { base.contains($0) }
        let saysBold = ["bold", "black", "heavy", "semib", "demib", "extrab", "ultrab", "-bd", ",b", "nimbus", "frutiger"].contains { base.contains($0) }
            && !["regu", "roman", "light", "book"].contains { base.contains($0) } && (base.contains("bold") || base.contains("black") || base.contains("heavy") || base.contains("semib") || base.contains("demib") || base.contains("extrab") || base.contains("ultrab") || base.contains("-bd") || base.contains(",b") || base.contains("medi"))
        let computerModernBold = base.hasPrefix("cmb") || base.hasPrefix("cmssbx") || base.hasPrefix("cmbsy") || base.hasPrefix("cmmib")
        font.bold = saysBold || computerModernBold
            || flags & (1 << 18) != 0
            || weight >= 600
            || (stemV >= 120 && !saysRegular)
        font.italic = ["ital", "obli", "slant", "-it"].contains { base.contains($0) }
            || base.hasPrefix("cmti") || base.hasPrefix("cmmi") || base.hasPrefix("cmsl")
            || flags & (1 << 6) != 0
        return font
    }

    // MARK: - The walk

    private struct State {
        var ctm: CGAffineTransform
        var font: Font?
        var size: CGFloat = 0
        var charSpacing: CGFloat = 0
        var wordSpacing: CGFloat = 0
        var hscale: CGFloat = 1
        var leading: CGFloat = 0
        var rise: CGFloat = 0
    }

    private final class Walk {
        var states: [State] = [State(ctm: .identity)]
        var textMatrix = CGAffineTransform.identity
        var lineMatrix = CGAffineTransform.identity
        var runs: [Run] = []
        var fonts: [UInt: Font] = [:]
        var depth = 0
        var state: State {
            get { states[states.count - 1] }
            set { states[states.count - 1] = newValue }
        }

        func nextLine(by leading: CGFloat) {
            lineMatrix = CGAffineTransform(translationX: 0, y: -leading).concatenating(lineMatrix)
            textMatrix = lineMatrix
        }

        /// Notes a shown string and advances the text matrix past it.
        func show(_ string: CGPDFStringRef) {
            let length = CGPDFStringGetLength(string)
            guard let bytes = CGPDFStringGetBytePtr(string), length > 0 else { return }
            let state = self.state
            let font = state.font ?? Font()
            let stride = font.twoByte ? 2 : 1
            var advance: CGFloat = 0
            var codes = 0
            var index = 0
            while index < length {
                var code = Int(bytes[index])
                if stride == 2, index + 1 < length { code = code << 8 | Int(bytes[index + 1]) }
                var width = font.width(of: code) / 1000 * state.size + state.charSpacing
                if code == 32, stride == 1 { width += state.wordSpacing }
                advance += width * state.hscale
                codes += 1
                index += stride
            }
            let onPage = textMatrix.concatenating(state.ctm)
            let start = CGPoint(x: 0, y: state.rise).applying(onPage)
            let end = CGPoint(x: advance, y: state.rise).applying(onPage)
            // The size as it lands on the page: a unit of text height, scaled.
            let size = hypot(onPage.c * state.size, onPage.d * state.size)
            if size > 0.5 {
                runs.append(Run(start: start, end: end, size: size, bold: font.bold, italic: font.italic, codes: codes))
            }
            textMatrix = CGAffineTransform(translationX: advance, y: 0).concatenating(textMatrix)
        }
    }

    private static func scan(_ page: PDFPage) -> [Run] {
        guard let ref = page.pageRef else { return [] }
        let walk = Walk()
        run(CGPDFContentStreamCreateWithPage(ref), walk: walk)
        return walk.runs
    }

    private static func popNumbers(_ count: Int, from scanner: CGPDFScannerRef) -> [CGFloat]? {
        var values = [CGFloat](repeating: 0, count: count)
        for index in stride(from: count - 1, through: 0, by: -1) {
            var value: CGPDFReal = 0
            guard CGPDFScannerPopNumber(scanner, &value) else { return nil }
            values[index] = value
        }
        return values
    }

    private static func run(_ stream: CGPDFContentStreamRef, walk: Walk) {
        guard let table = CGPDFOperatorTableCreate() else { return }
        let info = Unmanaged.passUnretained(walk).toOpaque()

        CGPDFOperatorTableSetCallback(table, "q") { _, info in
            let walk = Unmanaged<Walk>.fromOpaque(info!).takeUnretainedValue()
            walk.states.append(walk.state)
        }
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in
            let walk = Unmanaged<Walk>.fromOpaque(info!).takeUnretainedValue()
            if walk.states.count > 1 { walk.states.removeLast() }
        }
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
            let walk = Unmanaged<Walk>.fromOpaque(info!).takeUnretainedValue()
            guard let v = PageText.popNumbers(6, from: scanner) else { return }
            let matrix = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
            walk.state.ctm = matrix.concatenating(walk.state.ctm)
        }
        CGPDFOperatorTableSetCallback(table, "BT") { _, info in
            let walk = Unmanaged<Walk>.fromOpaque(info!).takeUnretainedValue()
            walk.textMatrix = .identity
            walk.lineMatrix = .identity
        }
        CGPDFOperatorTableSetCallback(table, "Tf") { scanner, info in
            let walk = Unmanaged<Walk>.fromOpaque(info!).takeUnretainedValue()
            var size: CGPDFReal = 0
            var name: UnsafePointer<CChar>?
            guard CGPDFScannerPopNumber(scanner, &size), CGPDFScannerPopName(scanner, &name), let name else { return }
            walk.state.size = size
            walk.state.font = PageText.font(named: name, in: CGPDFScannerGetContentStream(scanner), walk: walk)
        }
        CGPDFOperatorTableSetCallback(table, "Td") { scanner, info in
            let walk = Unmanaged<Walk>.fromOpaque(info!).takeUnretainedValue()
            guard let v = PageText.popNumbers(2, from: scanner) else { return }
            walk.lineMatrix = CGAffineTransform(translationX: v[0], y: v[1]).concatenating(walk.lineMatrix)
            walk.textMatrix = walk.lineMatrix
        }
        CGPDFOperatorTableSetCallback(table, "TD") { scanner, info in
            let walk = Unmanaged<Walk>.fromOpaque(info!).takeUnretainedValue()
            guard let v = PageText.popNumbers(2, from: scanner) else { return }
            walk.state.leading = -v[1]
            walk.lineMatrix = CGAffineTransform(translationX: v[0], y: v[1]).concatenating(walk.lineMatrix)
            walk.textMatrix = walk.lineMatrix
        }
        CGPDFOperatorTableSetCallback(table, "Tm") { scanner, info in
            let walk = Unmanaged<Walk>.fromOpaque(info!).takeUnretainedValue()
            guard let v = PageText.popNumbers(6, from: scanner) else { return }
            walk.lineMatrix = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
            walk.textMatrix = walk.lineMatrix
        }
        CGPDFOperatorTableSetCallback(table, "T*") { _, info in
            let walk = Unmanaged<Walk>.fromOpaque(info!).takeUnretainedValue()
            walk.nextLine(by: walk.state.leading)
        }
        CGPDFOperatorTableSetCallback(table, "TL") { scanner, info in
            let walk = Unmanaged<Walk>.fromOpaque(info!).takeUnretainedValue()
            if let v = PageText.popNumbers(1, from: scanner) { walk.state.leading = v[0] }
        }
        CGPDFOperatorTableSetCallback(table, "Tc") { scanner, info in
            let walk = Unmanaged<Walk>.fromOpaque(info!).takeUnretainedValue()
            if let v = PageText.popNumbers(1, from: scanner) { walk.state.charSpacing = v[0] }
        }
        CGPDFOperatorTableSetCallback(table, "Tw") { scanner, info in
            let walk = Unmanaged<Walk>.fromOpaque(info!).takeUnretainedValue()
            if let v = PageText.popNumbers(1, from: scanner) { walk.state.wordSpacing = v[0] }
        }
        CGPDFOperatorTableSetCallback(table, "Tz") { scanner, info in
            let walk = Unmanaged<Walk>.fromOpaque(info!).takeUnretainedValue()
            if let v = PageText.popNumbers(1, from: scanner) { walk.state.hscale = v[0] / 100 }
        }
        CGPDFOperatorTableSetCallback(table, "Ts") { scanner, info in
            let walk = Unmanaged<Walk>.fromOpaque(info!).takeUnretainedValue()
            if let v = PageText.popNumbers(1, from: scanner) { walk.state.rise = v[0] }
        }
        CGPDFOperatorTableSetCallback(table, "Tj") { scanner, info in
            let walk = Unmanaged<Walk>.fromOpaque(info!).takeUnretainedValue()
            var string: CGPDFStringRef?
            guard CGPDFScannerPopString(scanner, &string), let string else { return }
            walk.show(string)
        }
        CGPDFOperatorTableSetCallback(table, "'") { scanner, info in
            let walk = Unmanaged<Walk>.fromOpaque(info!).takeUnretainedValue()
            var string: CGPDFStringRef?
            guard CGPDFScannerPopString(scanner, &string), let string else { return }
            walk.nextLine(by: walk.state.leading)
            walk.show(string)
        }
        CGPDFOperatorTableSetCallback(table, "\"") { scanner, info in
            let walk = Unmanaged<Walk>.fromOpaque(info!).takeUnretainedValue()
            var string: CGPDFStringRef?
            guard CGPDFScannerPopString(scanner, &string), let string,
                  let spacing = PageText.popNumbers(2, from: scanner)
            else { return }
            walk.state.wordSpacing = spacing[0]
            walk.state.charSpacing = spacing[1]
            walk.nextLine(by: walk.state.leading)
            walk.show(string)
        }
        CGPDFOperatorTableSetCallback(table, "TJ") { scanner, info in
            let walk = Unmanaged<Walk>.fromOpaque(info!).takeUnretainedValue()
            var array: CGPDFArrayRef?
            guard CGPDFScannerPopArray(scanner, &array), let array else { return }
            for index in 0..<CGPDFArrayGetCount(array) {
                var string: CGPDFStringRef?
                var adjustment: CGPDFReal = 0
                if CGPDFArrayGetString(array, index, &string), let string {
                    walk.show(string)
                } else if CGPDFArrayGetNumber(array, index, &adjustment) {
                    let shift = -adjustment / 1000 * walk.state.size * walk.state.hscale
                    walk.textMatrix = CGAffineTransform(translationX: shift, y: 0).concatenating(walk.textMatrix)
                }
            }
        }
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            let walk = Unmanaged<Walk>.fromOpaque(info!).takeUnretainedValue()
            var namePointer: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(scanner, &namePointer), let namePointer else { return }
            let stream = CGPDFScannerGetContentStream(scanner)
            guard let object = CGPDFContentStreamGetResource(stream, "XObject", namePointer) else { return }
            var xobject: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &xobject), let xobject,
                  let dictionary = CGPDFStreamGetDictionary(xobject),
                  PageText.name("Subtype", in: dictionary) == "Form", walk.depth < 2
            else { return }
            var matrix = CGAffineTransform.identity
            var matrixArray: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(dictionary, "Matrix", &matrixArray), let matrixArray, CGPDFArrayGetCount(matrixArray) == 6 {
                var values = [CGPDFReal](repeating: 0, count: 6)
                for index in 0..<6 { CGPDFArrayGetNumber(matrixArray, index, &values[index]) }
                matrix = CGAffineTransform(a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5])
            }
            // The form draws in its own space, its matrix then ours; its text
            // state is its own too, and the outer one comes back after.
            let outerText = (walk.textMatrix, walk.lineMatrix)
            walk.states.append(walk.state)
            walk.state.ctm = matrix.concatenating(walk.state.ctm)
            walk.depth += 1
            PageText.run(CGPDFContentStreamCreateWithStream(xobject, dictionary, stream), walk: walk)
            walk.depth -= 1
            walk.states.removeLast()
            (walk.textMatrix, walk.lineMatrix) = outerText
        }

        let scanner = CGPDFScannerCreate(stream, table, info)
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFOperatorTableRelease(table)
    }
}
#endif
