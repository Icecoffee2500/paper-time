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
        ///
        /// Every TeX extension font is built this way, not only Computer
        /// Modern's: Latin Modern's, the tx and px fonts', Euler's, Fourier's,
        /// MathTime's and esint's. Reading only CMEX as one put the limits of
        /// a displayed sum set in Times on the line above.
        ///
        /// The symbol fonts' radical sign is drawn the same way — its point is
        /// at the top, by the rule it holds up — and so it counts as one.
        ///
        /// Euler's extension font also keeps its arrows and its ∞, which are
        /// set on the line like any other glyph.
        var isExtension: Bool {
            Self.remembered(fontName, glyphName) { Self.extensionFont(fontName: $0, glyphName: $1) }
        }

        /// The answer for a font and a glyph name, kept: `rect` asks it of
        /// every glyph every time a formula is looked at, and working it out
        /// is a split, an upper-casing and a dozen prefixes.
        private struct Name: Hashable { var font: String; var glyph: String? }
        nonisolated(unsafe) private static var known: [Name: Bool] = [:]
        private static let lock = NSLock()

        private static func remembered(_ font: String, _ glyph: String?, _ work: (String, String?) -> Bool) -> Bool {
            let key = Name(font: font, glyph: glyph)
            lock.lock()
            if let value = known[key] { lock.unlock(); return value }
            lock.unlock()
            let value = work(font, glyph)
            lock.lock()
            known[key] = value
            lock.unlock()
            return value
        }

        private static func extensionFont(fontName: String, glyphName: String?) -> Bool {
            let family = (fontName.split(separator: "+").last.map(String.init) ?? fontName).uppercased()
            if Self.extensionFamilies.contains(where: { family.hasPrefix($0) }) {
                guard let name = glyphName else { return true }
                if name == "infinity" { return false }
                // newtx's own pieces for a bracket built up tall — "tpA",
                // "exA", "btA" — stand on their point, as ordinary glyphs do.
                if ["tpA", "exA", "btA", "midA"].contains(where: { name.hasSuffix($0) }) { return false }
                if name.hasPrefix("arrow"), !name.hasSuffix("half"), !name.hasSuffix("vertex"),
                   !name.hasSuffix("tp"), !name.hasSuffix("bt") { return false }
                return true
            }
            guard let name = glyphName, name.hasPrefix("radical"), !name.hasPrefix("radicalvertex")
            else { return false }
            return Self.symbolFamilies.contains { family.hasPrefix($0) }
        }

        private static let symbolFamilies = [
            "CMSY", "CMBSY", "LMMATHSYMBOLS", "TXSY", "PXSY", "NEWTXSY", "NEWPXSY", "MTSY",
            "EUSM", "EUSB", "FOURIER-MATH-SYMBOLS",
        ]

        private static let extensionFamilies = [
            "CMEX", "LMMATHEXTENSION", "TXEX", "PXEX", "EUEX", "FOURIER-MATH-EXTENSION",
            "MTEX", "MT2EX", "ESINT",
        ]

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
        private static func reach(of name: String?) -> CGFloat {
            guard let name else { return 1 }
            // newtx names its display-size signs by their code point with
            // ".dsp" after it — "uni222B.dsp" is the displayed ∫.
            if name.hasSuffix(".dsp") { return 1.5 }
            // "summationdisplay.1" is the display sum from a second font, and
            // newtx names its pieces "parenlefttpA".
            var glyphName = name.firstIndex(of: ".").map { String(name[..<$0]) } ?? name
            if glyphName.hasSuffix("A"),
               ["tpA", "btA", "exA", "midA"].contains(where: { glyphName.hasSuffix($0) }) {
                glyphName.removeLast()
            }
            // The top and bottom pieces of a bracket built up for a matrix.
            if glyphName.hasPrefix("paren") || glyphName.hasPrefix("bracket") {
                if glyphName.hasSuffix("tp") || glyphName.hasSuffix("bt") { return 1.8 }
            }
            if glyphName.hasPrefix("brace"), glyphName.hasSuffix("tp") || glyphName.hasSuffix("bt") { return 0.9 }
            // The middle of a brace is its point and the stretch either side
            // of it; the pieces that fill between are short — a brace's a
            // third of an em, a bracket's and a bar's three fifths. Boxed a
            // whole em, the filler after a brace's middle stood 9 points
            // clear of it, and one brace was taken for two.
            if glyphName.hasPrefix("brace"), glyphName.hasSuffix("mid") { return 1.8 }
            if glyphName == "braceex" { return 0.3 }
            if glyphName.hasSuffix("ex"),
               ["paren", "bracket", "arrowvert", "Arrowvert", "vextend"].contains(where: { glyphName.hasPrefix($0) }) {
                return 0.6
            }
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
        /// How many bytes of a string make one glyph: one for the simple
        /// fonts TeX writes, two for a composite (Type0) font with an
        /// Identity CMap — what Word and every "Save as PDF" write. Reading
        /// those a byte at a time split every glyph in two, and a formula
        /// from an MDPI paper came out as "$)/(385DCCCiHE WVV U)u!ull…".
        var bytesPerCode = 1
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
        let step = currentFont?.bytesPerCode ?? 1
        for index in stride(from: 0, to: length - (step - 1), by: step) {
            var code = 0
            for byte in 0..<step { code = code << 8 | Int(bytes[index + byte]) }
            let width = (currentFont?.widths[code] ?? currentFont?.defaultWidth ?? 500) / 1000

            let placement = CGAffineTransform(a: fontSize * horizontalScale, b: 0, c: 0,
                                              d: fontSize, tx: 0, ty: rise)
                .concatenating(textMatrix)
                .concatenating(ctm)
            let origin = CGPoint(x: placement.tx, y: placement.ty)
            let scale = sqrt(abs(placement.a * placement.d - placement.b * placement.c))

            // A zero in a composite font's ToUnicode says the file does not
            // know what the glyph is — Word writes one for every letter of an
            // equation it set in Cambria Math. (TeX writes zeros for symbols
            // it reads from their code, and those keep the zero: the code is
            // how they are read.)
            var meaning = currentFont?.toUnicode[code]
            if step > 1, meaning?.unicodeScalars.allSatisfy({ $0.value == 0 }) == true { meaning = nil }
            glyphs.append(Glyph(
                // A composite font's code is a glyph number and never a
                // character code; -1 keeps anything from reading it as one
                // (the Cambria Math of a Word equation otherwise spelled its
                // glyphs "( )*+$,-#", ASCII for their numbers).
                code: step > 1 ? -1 : code,
                fontName: currentFont?.name ?? "",
                unicode: meaning
                    ?? currentFont.flatMap { Self.decode(code, with: $0.baseEncoding) },
                glyphName: currentFont?.glyphNames[code],
                // A composite font's codes are glyph numbers, never letters
                // of a standard encoding, so what it means is only what its
                // ToUnicode says — and a glyph that is not symbolic is read
                // that way first. Taken as a standard encoding, a figure's
                // Arial came out "6WHS" for "Step".
                isSymbolic: step > 1 ? false : currentFont?.isSymbolic ?? true,
                size: scale,
                origin: origin,
                width: width * scale
            ))

            var advance = width * fontSize + charSpacing
            // Word spacing is for the single byte 32 only (ISO 32000 §9.3.3).
            if code == 32, step == 1 { advance += wordSpacing }
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
            // A composite font: two bytes a glyph, and its widths and its
            // descriptor are on the one font it descends to.
            var subtype: UnsafePointer<Int8>?
            var descendant: CGPDFDictionaryRef?
            if CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype,
               String(cString: subtype) == "Type0" {
                var encodingName: UnsafePointer<Int8>?
                let cmap = CGPDFDictionaryGetName(dictionary, "Encoding", &encodingName)
                    ? encodingName.map { String(cString: $0) } : nil
                // The Identity CMaps and the UCS-2/UTF-16 ones are two bytes
                // throughout; a font with any other CMap is two bytes too in
                // every paper seen, and one byte would be wrong for all of them.
                font.bytesPerCode = 2
                _ = cmap
                var descendants: CGPDFArrayRef?
                if CGPDFDictionaryGetArray(dictionary, "DescendantFonts", &descendants), let descendants {
                    CGPDFArrayGetDictionary(descendants, 0, &descendant)
                }
                if let descendant {
                    var defaultWidth: CGPDFReal = 1000
                    CGPDFDictionaryGetNumber(descendant, "DW", &defaultWidth)
                    font.defaultWidth = defaultWidth
                    var widths: CGPDFArrayRef?
                    if CGPDFDictionaryGetArray(descendant, "W", &widths), let widths {
                        font.widths = Self.parseCIDWidths(widths)
                    }
                }
            }
            var descriptorDictionary: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(descendant ?? dictionary, "FontDescriptor", &descriptorDictionary),
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

    /// A composite font's `/W`: `c [w₁ w₂ …]` gives widths from `c` on, and
    /// `c₁ c₂ w` gives one width to the whole run.
    private static func parseCIDWidths(_ array: CGPDFArrayRef) -> [Int: CGFloat] {
        var widths: [Int: CGFloat] = [:]
        var index = 0
        let count = CGPDFArrayGetCount(array)
        while index < count {
            var first: CGPDFInteger = 0
            guard CGPDFArrayGetInteger(array, index, &first) else { index += 1; continue }
            var run: CGPDFArrayRef?
            if index + 1 < count, CGPDFArrayGetArray(array, index + 1, &run), let run {
                for offset in 0..<CGPDFArrayGetCount(run) {
                    var width: CGPDFReal = 0
                    if CGPDFArrayGetNumber(run, offset, &width) { widths[Int(first) + offset] = width }
                }
                index += 2
                continue
            }
            var last: CGPDFInteger = 0
            var width: CGPDFReal = 0
            if index + 2 < count, CGPDFArrayGetInteger(array, index + 1, &last),
               CGPDFArrayGetNumber(array, index + 2, &width), last >= first, last - first < 65_536 {
                for code in Int(first)...Int(last) { widths[code] = width }
            }
            index += 3
        }
        return widths
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

        return toUnicodeTable(text)
    }

    /// A ToUnicode CMap's `bfchar` and `bfrange` sections, read the way ISO
    /// 32000 §9.10.3 writes them.
    ///
    /// Every value is UTF-16, four hex digits a unit — so a letter outside
    /// the first plane is two of them (𝒒 is D835 DC92). A range either gives
    /// the first value and counts up from it, the *last unit* counting — so
    /// `<04F6> <04F9> <D835DC34>` is 𝐴 to 𝐷 — or gives one value per code in
    /// an array. XeTeX writes the italic alphabet of a maths font as ranges
    /// like that one; reading the first value as one 32-bit number made
    /// every letter of every formula it set mean nothing.
    static func toUnicodeTable(_ text: String) -> [Int: String] {
        var table: [Int: String] = [:]
        func units(_ hex: Substring) -> [UInt16]? {
            var out: [UInt16] = []
            var index = hex.startIndex
            while let end = hex.index(index, offsetBy: 4, limitedBy: hex.endIndex), index < end {
                guard let value = UInt16(hex[index..<end], radix: 16) else { return nil }
                out.append(value)
                index = end
            }
            // Two digits is one byte: a single-byte value, which a few
            // writers use for plain ASCII.
            if out.isEmpty, hex.count == 2, let value = UInt16(hex, radix: 16) { out = [value] }
            return out.isEmpty ? nil : out
        }
        func string(_ units: [UInt16]) -> String {
            String(utf16CodeUnits: units, count: units.count)
        }

        // The CMap as a list of hex strings, brackets and words.
        enum Token { case hex(Substring), open, close, word(Substring) }
        var tokens: [Token] = []
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "<" {
                let from = text.index(after: index)
                guard let close = text[from...].firstIndex(of: ">") else { break }
                let hex = text[from..<close].filter { !$0.isWhitespace }
                tokens.append(.hex(Substring(hex)))
                index = text.index(after: close)
            } else if character == "[" {
                tokens.append(.open); index = text.index(after: index)
            } else if character == "]" {
                tokens.append(.close); index = text.index(after: index)
            } else if character.isLetter {
                let from = index
                while index < text.endIndex, text[index].isLetter { index = text.index(after: index) }
                tokens.append(.word(text[from..<index]))
            } else {
                index = text.index(after: index)
            }
        }

        var position = 0
        func hex() -> Substring? {
            guard position < tokens.count, case .hex(let value) = tokens[position] else { return nil }
            position += 1
            return value
        }
        while position < tokens.count {
            guard case .word(let word) = tokens[position] else { position += 1; continue }
            position += 1
            if word == "beginbfchar" {
                while position < tokens.count {
                    if case .word = tokens[position] { break }
                    guard let codeHex = hex(), let valueHex = hex() else { position += 1; continue }
                    if let code = Int(codeHex, radix: 16), let value = units(valueHex) {
                        table[code] = string(value)
                    }
                }
            } else if word == "beginbfrange" {
                while position < tokens.count {
                    if case .word = tokens[position] { break }
                    guard let lowHex = hex(), let highHex = hex(),
                          let low = Int(lowHex, radix: 16), let high = Int(highHex, radix: 16),
                          high >= low, high - low < 65536
                    else { position += 1; continue }
                    if position < tokens.count, case .open = tokens[position] {
                        position += 1
                        var code = low
                        while position < tokens.count {
                            if case .close = tokens[position] { position += 1; break }
                            if let valueHex = hex() {
                                if code <= high, let value = units(valueHex) { table[code] = string(value) }
                                code += 1
                            } else {
                                position += 1
                            }
                        }
                    } else if let startHex = hex(), var value = units(startHex) {
                        for code in low...high {
                            table[code] = string(value)
                            value[value.count - 1] &+= 1
                        }
                    }
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
