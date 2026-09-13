import CoreGraphics
import Foundation

/// Reads what a PDF page actually draws.
///
/// `PDFKit` hands over text that has already been through the file's own idea
/// of what its glyphs mean, and for a paper set in TeX that idea is often
/// missing or wrong: the φ comes back as "ε", the ‖ as "↑". Underneath that,
/// the page says exactly what it drew — this glyph, from this font, this size,
/// at this point — and that is what this reads.
///
/// It also collects the thin filled rectangles a page uses for fraction bars
/// and radicals, because those are drawn as shapes and never appear in any
/// text at all, and without them a fraction is just two numbers on top of one
/// another.
final class PDFContentScanner {
    struct Glyph {
        var code: Int
        /// The font's own name, subset prefix and all: "AAAABQ+CMMI10".
        var fontName: String
        /// What the file says the glyph means, when it says anything.
        var unicode: String?
        /// The font's own name for the glyph.
        var glyphName: String?
        /// Whether the font it came from draws symbols or text.
        var isSymbolic = true
        /// The size the glyph is drawn at, in page points.
        var size: CGFloat
        /// The glyph's origin on its baseline, in page coordinates.
        var origin: CGPoint
        var width: CGFloat

        /// Whether the glyph came from an extension font — cmex and its kin,
        /// where the big operators and the pieces of tall delimiters live.
        ///
        /// Those are drawn *below* their reference point rather than above it:
        /// the point sits at the top of the ink, not on a baseline. A sum set
        /// on the line at 526.79 is placed at 534.26, which is nearer the line
        /// of prose above it. Everything that reasons about where a glyph sits
        /// has to know this, or the formula ends up in the wrong paragraph.
        var isExtension: Bool {
            let family = fontName.split(separator: "+").last.map(String.init) ?? fontName
            return family.uppercased().hasPrefix("CMEX")
        }

        /// Where the ink is.
        var rect: CGRect {
            guard isExtension else {
                return CGRect(x: origin.x, y: origin.y, width: width, height: size)
            }
            let height = size * Self.reach(of: glyphName)
            return CGRect(x: origin.x, y: origin.y - height, width: width, height: height)
        }

        /// How far below its reference point a cmex glyph reaches, in ems.
        /// The font's names say which size was asked for — TeX's \big, \Big,
        /// \bigg, \Bigg and the display variants of the big operators — and
        /// a "\Big(" really is drawn about one and four fifths of an em tall.
        private static func reach(of glyphName: String?) -> CGFloat {
            guard let glyphName else { return 1 }
            if glyphName.hasSuffix("Bigg") { return 3.0 }
            if glyphName.hasSuffix("bigg") { return 2.4 }
            if glyphName.hasSuffix("Big") { return 1.8 }
            if glyphName.hasSuffix("big") { return 1.2 }
            if glyphName.hasSuffix("display") { return 1.5 }
            return 1
        }
    }

    /// A filled rectangle: a fraction bar, the roof of a radical, a table rule.
    struct Rule {
        var rect: CGRect
    }

    private(set) var glyphs: [Glyph] = []
    private(set) var rules: [Rule] = []

    // MARK: - Text state

    private var ctm = CGAffineTransform.identity
    private var ctmStack: [CGAffineTransform] = []
    private var textMatrix = CGAffineTransform.identity
    private var lineMatrix = CGAffineTransform.identity
    private var fontSize: CGFloat = 0
    private var charSpacing: CGFloat = 0
    private var wordSpacing: CGFloat = 0
    private var horizontalScale: CGFloat = 1
    private var leading: CGFloat = 0
    private var rise: CGFloat = 0
    private var currentFont: Font?
    private var fonts: [String: Font] = [:]

    /// One font as the page describes it.
    struct Font {
        var name: String
        var widths: [Int: CGFloat] = [:]
        var defaultWidth: CGFloat = 500
        var toUnicode: [Int: String] = [:]
        /// What the font calls each glyph — "summationdisplay", "phi",
        /// "bardbl". A subset font renumbers its glyphs, so the name is the
        /// only thing that survives.
        var glyphNames: [Int: String] = [:]
        /// "MacRomanEncoding", "WinAnsiEncoding", or nothing.
        var baseEncoding: String?
        /// A symbolic font draws symbols and keeps its own encoding; a
        /// nonsymbolic one draws text and means the encoding it declares. TeX
        /// writes both, and the difference decides how a byte is read.
        var isSymbolic = true
    }

    // MARK: - Scanning

    static func scan(page: CGPDFPage) -> PDFContentScanner {
        let scanner = PDFContentScanner()
        scanner.loadFonts(of: page)

        let table = CGPDFOperatorTableCreate()!
        func on(_ name: String, _ callback: @escaping CGPDFOperatorCallback) {
            CGPDFOperatorTableSetCallback(table, name, callback)
        }
        on("q") { _, info in
            guard let me = PDFContentScanner.me(info) else { return }
            me.ctmStack.append(me.ctm)
        }
        on("Q") { _, info in
            guard let me = PDFContentScanner.me(info), let last = me.ctmStack.popLast() else { return }
            me.ctm = last
        }
        on("cm") { scanner, info in
            guard let me = PDFContentScanner.me(info), let numbers = PDFContentScanner.numbers(scanner, 6) else { return }
            me.ctm = CGAffineTransform(a: numbers[0], b: numbers[1], c: numbers[2],
                                       d: numbers[3], tx: numbers[4], ty: numbers[5])
                .concatenating(me.ctm)
        }
        on("BT") { _, info in
            guard let me = PDFContentScanner.me(info) else { return }
            me.textMatrix = .identity
            me.lineMatrix = .identity
        }
        on("Tf") { scanner, info in
            guard let me = PDFContentScanner.me(info) else { return }
            var size: CGPDFReal = 0
            CGPDFScannerPopNumber(scanner, &size)
            var name: UnsafePointer<Int8>?
            CGPDFScannerPopName(scanner, &name)
            me.fontSize = size
            me.currentFont = name.flatMap { me.fonts[String(cString: $0)] }
        }
        on("Td") { scanner, info in
            guard let me = PDFContentScanner.me(info), let numbers = PDFContentScanner.numbers(scanner, 2) else { return }
            me.lineMatrix = CGAffineTransform(translationX: numbers[0], y: numbers[1])
                .concatenating(me.lineMatrix)
            me.textMatrix = me.lineMatrix
        }
        on("TD") { scanner, info in
            guard let me = PDFContentScanner.me(info), let numbers = PDFContentScanner.numbers(scanner, 2) else { return }
            me.leading = -numbers[1]
            me.lineMatrix = CGAffineTransform(translationX: numbers[0], y: numbers[1])
                .concatenating(me.lineMatrix)
            me.textMatrix = me.lineMatrix
        }
        on("Tm") { scanner, info in
            guard let me = PDFContentScanner.me(info), let numbers = PDFContentScanner.numbers(scanner, 6) else { return }
            me.lineMatrix = CGAffineTransform(a: numbers[0], b: numbers[1], c: numbers[2],
                                              d: numbers[3], tx: numbers[4], ty: numbers[5])
            me.textMatrix = me.lineMatrix
        }
        on("T*") { _, info in PDFContentScanner.me(info)?.nextLine() }
        on("TL") { scanner, info in
            var value: CGPDFReal = 0
            CGPDFScannerPopNumber(scanner, &value)
            PDFContentScanner.me(info)?.leading = value
        }
        on("Tc") { scanner, info in
            var value: CGPDFReal = 0
            CGPDFScannerPopNumber(scanner, &value)
            PDFContentScanner.me(info)?.charSpacing = value
        }
        on("Tw") { scanner, info in
            var value: CGPDFReal = 0
            CGPDFScannerPopNumber(scanner, &value)
            PDFContentScanner.me(info)?.wordSpacing = value
        }
        on("Tz") { scanner, info in
            var value: CGPDFReal = 0
            CGPDFScannerPopNumber(scanner, &value)
            PDFContentScanner.me(info)?.horizontalScale = value / 100
        }
        on("Ts") { scanner, info in
            var value: CGPDFReal = 0
            CGPDFScannerPopNumber(scanner, &value)
            PDFContentScanner.me(info)?.rise = value
        }
        on("Tj") { scanner, info in
            guard let me = PDFContentScanner.me(info) else { return }
            var string: CGPDFStringRef?
            guard CGPDFScannerPopString(scanner, &string), let string else { return }
            me.show(string)
        }
        on("'") { scanner, info in
            guard let me = PDFContentScanner.me(info) else { return }
            var string: CGPDFStringRef?
            guard CGPDFScannerPopString(scanner, &string), let string else { return }
            me.nextLine()
            me.show(string)
        }
        on("TJ") { scanner, info in
            guard let me = PDFContentScanner.me(info) else { return }
            var array: CGPDFArrayRef?
            guard CGPDFScannerPopArray(scanner, &array), let array else { return }
            for index in 0..<CGPDFArrayGetCount(array) {
                var string: CGPDFStringRef?
                if CGPDFArrayGetString(array, index, &string), let string {
                    me.show(string)
                    continue
                }
                var number: CGPDFReal = 0
                if CGPDFArrayGetNumber(array, index, &number) {
                    let shift = -number / 1000 * me.fontSize * me.horizontalScale
                    me.textMatrix = CGAffineTransform(translationX: shift, y: 0)
                        .concatenating(me.textMatrix)
                }
            }
        }
        on("m") { scanner, info in
            guard let me = PDFContentScanner.me(info),
                  let numbers = PDFContentScanner.numbers(scanner, 2) else { return }
            me.pathStart = CGPoint(x: numbers[0], y: numbers[1])
            me.pathEnd = nil
        }
        on("l") { scanner, info in
            guard let me = PDFContentScanner.me(info),
                  let numbers = PDFContentScanner.numbers(scanner, 2) else { return }
            me.pathEnd = CGPoint(x: numbers[0], y: numbers[1])
        }
        on("w") { scanner, info in
            var value: CGPDFReal = 0
            CGPDFScannerPopNumber(scanner, &value)
            PDFContentScanner.me(info)?.lineWidth = value
        }
        on("re") { scanner, info in
            guard let me = PDFContentScanner.me(info), let numbers = PDFContentScanner.numbers(scanner, 4) else { return }
            me.pendingRect = CGRect(x: numbers[0], y: numbers[1],
                                    width: numbers[2], height: numbers[3])
        }
        let fill: CGPDFOperatorCallback = { _, info in
            PDFContentScanner.me(info)?.fillPendingRect()
        }
        for filler in ["f", "F", "f*", "B", "B*"] {
            CGPDFOperatorTableSetCallback(table, filler, fill)
        }
        let stroke: CGPDFOperatorCallback = { _, info in
            PDFContentScanner.me(info)?.strokePendingLine()
        }
        for stroker in ["S", "s", "B", "B*"] {
            CGPDFOperatorTableSetCallback(table, stroker, stroke)
        }

        let contentScanner = CGPDFScannerCreate(
            CGPDFContentStreamCreateWithPage(page), table,
            Unmanaged.passUnretained(scanner).toOpaque()
        )
        CGPDFScannerScan(contentScanner)
        return scanner
    }

    private var pendingRect: CGRect?
    private var pathStart: CGPoint?
    private var pathEnd: CGPoint?
    private var lineWidth: CGFloat = 1
    /// Every rectangle the page filled, whatever its size — kept only while
    /// working out why a fraction bar has gone missing.
    private(set) var filledRectangles = 0

    /// A stroked line, thin and level: also a rule.
    private func strokePendingLine() {
        defer { pathStart = nil; pathEnd = nil }
        guard let start = pathStart, let end = pathEnd else { return }
        let a = start.applying(ctm), b = end.applying(ctm)
        guard abs(a.y - b.y) < 1.5, abs(a.x - b.x) > 1 else { return }
        let thickness = max(lineWidth * sqrt(abs(ctm.a * ctm.d - ctm.b * ctm.c)), 0.4)
        rules.append(Rule(rect: CGRect(x: min(a.x, b.x), y: min(a.y, b.y) - thickness / 2,
                                       width: abs(b.x - a.x), height: thickness)))
    }

    private func fillPendingRect() {
        guard let rect = pendingRect else { return }
        filledRectangles += 1
        pendingRect = nil
        let transformed = rect.applying(ctm)
        // Only the thin ones matter: a fraction bar, a radical's roof, a rule.
        guard transformed.height < 3, transformed.width > 1 else { return }
        rules.append(Rule(rect: transformed))
    }

    private func nextLine() {
        lineMatrix = CGAffineTransform(translationX: 0, y: -leading).concatenating(lineMatrix)
        textMatrix = lineMatrix
    }

    /// Lays out one string, glyph by glyph, moving the text matrix as it goes.
    private func show(_ string: CGPDFStringRef) {
        guard let bytes = CGPDFStringGetBytePtr(string) else { return }
        let length = CGPDFStringGetLength(string)
        for index in 0..<length {
            let code = Int(bytes[index])
            let width = (currentFont?.widths[code] ?? currentFont?.defaultWidth ?? 500) / 1000

            let placement = CGAffineTransform(a: fontSize * horizontalScale, b: 0, c: 0,
                                              d: fontSize, tx: 0, ty: rise)
                .concatenating(textMatrix)
                .concatenating(ctm)
            let origin = CGPoint(x: placement.tx, y: placement.ty)
            let scale = sqrt(abs(placement.a * placement.d - placement.b * placement.c))

            glyphs.append(Glyph(
                code: code,
                fontName: currentFont?.name ?? "",
                unicode: currentFont?.toUnicode[code]
                    ?? currentFont.flatMap { Self.decode(code, with: $0.baseEncoding) },
                glyphName: currentFont?.glyphNames[code],
                isSymbolic: currentFont?.isSymbolic ?? true,
                size: scale,
                origin: origin,
                width: width * scale
            ))

            var advance = width * fontSize + charSpacing
            if code == 32 { advance += wordSpacing }
            textMatrix = CGAffineTransform(translationX: advance * horizontalScale, y: 0)
                .concatenating(textMatrix)
        }
    }

    // MARK: - Fonts

    private func loadFonts(of page: CGPDFPage) {
        guard let dictionary = page.dictionary else { return }
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources),
              let resources
        else { return }
        var fontDictionary: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "Font", &fontDictionary),
              let fontDictionary
        else { return }

        var loaded: [String: Font] = [:]
        CGPDFDictionaryApplyBlock(fontDictionary, { key, value, _ in
            var dictionary: CGPDFDictionaryRef?
            guard CGPDFObjectGetValue(value, .dictionary, &dictionary), let dictionary else {
                return true
            }
            var font = Font(name: "")
            var baseFont: UnsafePointer<Int8>?
            if CGPDFDictionaryGetName(dictionary, "BaseFont", &baseFont), let baseFont {
                font.name = String(cString: baseFont)
            }
            var firstChar: CGPDFInteger = 0
            CGPDFDictionaryGetInteger(dictionary, "FirstChar", &firstChar)
            var widths: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(dictionary, "Widths", &widths), let widths {
                for index in 0..<CGPDFArrayGetCount(widths) {
                    var width: CGPDFReal = 0
                    guard CGPDFArrayGetNumber(widths, index, &width) else { continue }
                    font.widths[Int(firstChar) + index] = width
                }
            }
            var descriptorDictionary: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(dictionary, "FontDescriptor", &descriptorDictionary),
               let descriptorDictionary {
                var flags: CGPDFInteger = 0
                CGPDFDictionaryGetInteger(descriptorDictionary, "Flags", &flags)
                font.isSymbolic = (flags & 4) != 0
            }
            var stream: CGPDFStreamRef?
            if CGPDFDictionaryGetStream(dictionary, "ToUnicode", &stream), let stream {
                font.toUnicode = Self.parseToUnicode(stream)
            }
            // An /Encoding is either a dictionary that renames some codes, or
            // the name of a standard encoding — and a font that says
            // "MacRomanEncoding" means it, ligatures and curly quotes and all.
            var encoding: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(dictionary, "Encoding", &encoding), let encoding {
                font.glyphNames = Self.parseDifferences(encoding)
                var base: UnsafePointer<Int8>?
                if CGPDFDictionaryGetName(encoding, "BaseEncoding", &base), let base {
                    font.baseEncoding = String(cString: base)
                }
            }
            var encodingName: UnsafePointer<Int8>?
            if CGPDFDictionaryGetName(dictionary, "Encoding", &encodingName), let encodingName {
                font.baseEncoding = String(cString: encodingName)
            }
            // A font that names nothing in the PDF still names everything in
            // itself: a Type 1 program carries its own encoding in the clear,
            // before the encrypted part, as "dup 245 /fi put". For a symbolic
            // font — every maths font is one — the PDF spec says that built-in
            // encoding is the one that counts, whatever the /Encoding entry
            // claims, and pdfTeX writes "MacRomanEncoding" on fonts that are
            // nothing of the sort.
            let builtIn = Self.builtInEncoding(of: dictionary)
            if !builtIn.isEmpty {
                font.glyphNames = builtIn.merging(font.glyphNames) { own, named in named }
            }
            loaded[String(cString: key)] = font
            return true
        }, nil)
        fonts = loaded
    }

    /// The `Differences` array: a starting code, then the names of the glyphs
    /// that follow it.
    private static func parseDifferences(_ encoding: CGPDFDictionaryRef) -> [Int: String] {
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(encoding, "Differences", &array), let array else {
            return [:]
        }
        var names: [Int: String] = [:]
        var code = 0
        for index in 0..<CGPDFArrayGetCount(array) {
            var number: CGPDFInteger = 0
            if CGPDFArrayGetInteger(array, index, &number) {
                code = Int(number)
                continue
            }
            var name: UnsafePointer<Int8>?
            if CGPDFArrayGetName(array, index, &name), let name {
                names[code] = String(cString: name)
                code += 1
            }
        }
        return names
    }

    /// A byte read through the encoding the font says it uses.
    static func decode(_ code: Int, with encoding: String?) -> String? {
        // The whole range, not just the high half: a font that declares an
        // encoding means it for the printable ASCII too, and that is where a
        // vertical bar lives.
        guard code >= 0x20, let encoding else { return nil }
        let table: CFStringEncoding
        switch encoding {
        case "MacRomanEncoding": table = CFStringEncoding(CFStringBuiltInEncodings.macRoman.rawValue)
        case "WinAnsiEncoding": table = CFStringEncoding(CFStringBuiltInEncodings.windowsLatin1.rawValue)
        default: return nil
        }
        var byte = UInt8(code)
        guard let string = CFStringCreateWithBytes(nil, &byte, 1, table, false) as String? else {
            return nil
        }
        // Ligatures are written out: LaTeX has no use for a single ﬁ.
        return string
            .replacingOccurrences(of: "\u{FB00}", with: "ff")
            .replacingOccurrences(of: "\u{FB01}", with: "fi")
            .replacingOccurrences(of: "\u{FB02}", with: "fl")
            .replacingOccurrences(of: "\u{FB03}", with: "ffi")
            .replacingOccurrences(of: "\u{FB04}", with: "ffl")
    }

    /// The encoding written inside an embedded Type 1 font program.
    private static func builtInEncoding(of font: CGPDFDictionaryRef) -> [Int: String] {
        var descriptor: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(font, "FontDescriptor", &descriptor),
              let descriptor
        else { return [:] }
        var stream: CGPDFStreamRef?
        guard CGPDFDictionaryGetStream(descriptor, "FontFile", &stream), let stream else {
            return [:]
        }
        var format = CGPDFDataFormat.raw
        guard let data = CGPDFStreamCopyData(stream, &format) as Data? else { return [:] }
        // Only the cleartext head is readable; the rest is encrypted and holds
        // the outlines, which are none of our business. The encoding lives
        // somewhere in that head, and "eexec" is where it ends.
        let head: Data
        if let marker = "eexec".data(using: .isoLatin1),
           let range = data.range(of: marker, in: data.startIndex..<min(data.endIndex, data.startIndex + 60_000)) {
            head = data[data.startIndex..<range.lowerBound]
        } else {
            head = data.prefix(20_000)
        }
        guard let text = String(data: head, encoding: .isoLatin1) else { return [:] }

        var names: [Int: String] = [:]
        for match in encodingPattern.matches(
            in: text, range: NSRange(text.startIndex..., in: text)
        ) {
            guard let codeRange = Range(match.range(at: 1), in: text),
                  let nameRange = Range(match.range(at: 2), in: text),
                  let code = Int(text[codeRange])
            else { continue }
            names[code] = String(text[nameRange])
        }
        return names
    }

    private static let encodingPattern = try! NSRegularExpression(
        pattern: #"dup\s+(\d+)\s*/([A-Za-z0-9._]+)\s+put"#
    )

    /// Enough of a CMap reader for the `bfchar` and `bfrange` entries TeX
    /// writes, which is all a paper's fonts use.
    private static func parseToUnicode(_ stream: CGPDFStreamRef) -> [Int: String] {
        var format = CGPDFDataFormat.raw
        guard let data = CGPDFStreamCopyData(stream, &format) as Data? ,
              let text = String(data: data, encoding: .isoLatin1)
        else { return [:] }

        var table: [Int: String] = [:]
        func character(_ hex: String) -> String? {
            var scalars = ""
            var index = hex.startIndex
            while let end = hex.index(index, offsetBy: 4, limitedBy: hex.endIndex) {
                guard let value = UInt32(hex[index..<end], radix: 16),
                      let scalar = Unicode.Scalar(value) else { return nil }
                scalars.append(Character(scalar))
                index = end
            }
            return scalars.isEmpty ? nil : scalars
        }

        let charPattern = try! NSRegularExpression(pattern: "<([0-9A-Fa-f]+)>\\s*<([0-9A-Fa-f]+)>")
        for section in text.components(separatedBy: "beginbfchar").dropFirst() {
            let body = section.components(separatedBy: "endbfchar").first ?? ""
            for match in charPattern.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
                guard let codeRange = Range(match.range(at: 1), in: body),
                      let valueRange = Range(match.range(at: 2), in: body),
                      let code = Int(body[codeRange], radix: 16),
                      let value = character(String(body[valueRange]))
                else { continue }
                table[code] = value
            }
        }
        let rangePattern = try! NSRegularExpression(
            pattern: "<([0-9A-Fa-f]+)>\\s*<([0-9A-Fa-f]+)>\\s*<([0-9A-Fa-f]+)>"
        )
        for section in text.components(separatedBy: "beginbfrange").dropFirst() {
            let body = section.components(separatedBy: "endbfrange").first ?? ""
            for match in rangePattern.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
                guard let lowRange = Range(match.range(at: 1), in: body),
                      let highRange = Range(match.range(at: 2), in: body),
                      let startRange = Range(match.range(at: 3), in: body),
                      let low = Int(body[lowRange], radix: 16),
                      let high = Int(body[highRange], radix: 16),
                      let start = UInt32(body[startRange], radix: 16)
                else { continue }
                for offset in 0...(max(high - low, 0)) {
                    guard let scalar = Unicode.Scalar(start + UInt32(offset)) else { continue }
                    table[low + offset] = String(Character(scalar))
                }
            }
        }
        return table
    }

    // MARK: - Callback plumbing

    private static func me(_ info: UnsafeMutableRawPointer?) -> PDFContentScanner? {
        info.map { Unmanaged<PDFContentScanner>.fromOpaque($0).takeUnretainedValue() }
    }

    private static func numbers(_ scanner: CGPDFScannerRef, _ count: Int) -> [CGFloat]? {
        var values: [CGFloat] = []
        for _ in 0..<count {
            var value: CGPDFReal = 0
            guard CGPDFScannerPopNumber(scanner, &value) else { return nil }
            values.append(value)
        }
        return values.reversed()
    }
}
