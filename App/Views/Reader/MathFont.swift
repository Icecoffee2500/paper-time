#if os(macOS)
import AppKit
import CoreText

/// The maths font, and what it says about how to set mathematics.
///
/// A font meant for mathematics carries an OpenType `MATH` table: where the
/// axis of a fraction sits, how thick its bar is, how far a superscript rises,
/// how much smaller a script is set, and which larger glyphs to reach for when
/// a sum is set on a line of its own or a bracket has to grow around what it
/// holds. Those numbers are the difference between mathematics that looks set
/// and mathematics that looks assembled, and they belong to the font — so they
/// are read from it rather than guessed at.
struct MathFont: @unchecked Sendable {
    /// Read once. Everything in it is a constant, taken from the font file
    /// before anything else runs.
    static let shared = MathFont()

    /// The face itself, at one point. Sizes are taken from it as needed.
    let face: NSFont
    let unitsPerEm: CGFloat
    let constants: Constants
    /// Vertical variants: the larger cuts of a glyph, biggest last.
    private let verticalVariants: [CGGlyph: [Variant]]
    private let italicsCorrections: [CGGlyph: CGFloat]

    struct Variant {
        var glyph: CGGlyph
        /// How tall this cut is, in ems.
        var advance: CGFloat
    }

    /// The `MathConstants` table, in ems.
    struct Constants {
        var scriptPercentScaleDown: CGFloat = 0.7
        var scriptScriptPercentScaleDown: CGFloat = 0.55
        var displayOperatorMinHeight: CGFloat = 1.8
        var axisHeight: CGFloat = 0.25
        var accentBaseHeight: CGFloat = 0.48
        var subscriptShiftDown: CGFloat = 0.21
        var subscriptTopMax: CGFloat = 0.37
        var subscriptBaselineDropMin: CGFloat = 0.16
        var superscriptShiftUp: CGFloat = 0.36
        var superscriptBottomMin: CGFloat = 0.12
        var superscriptBaselineDropMax: CGFloat = 0.23
        var subSuperscriptGapMin: CGFloat = 0.15
        var spaceAfterScript: CGFloat = 0.04
        var upperLimitGapMin: CGFloat = 0.135
        var upperLimitBaselineRiseMin: CGFloat = 0.3
        var lowerLimitGapMin: CGFloat = 0.135
        var lowerLimitBaselineDropMin: CGFloat = 0.67
        var fractionNumeratorShiftUp: CGFloat = 0.585
        var fractionNumeratorDisplayStyleShiftUp: CGFloat = 0.64
        var fractionDenominatorShiftDown: CGFloat = 0.585
        var fractionDenominatorDisplayStyleShiftDown: CGFloat = 0.64
        var fractionNumeratorGapMin: CGFloat = 0.068
        var fractionNumDisplayStyleGapMin: CGFloat = 0.15
        var fractionRuleThickness: CGFloat = 0.068
        var fractionDenominatorGapMin: CGFloat = 0.068
        var fractionDenomDisplayStyleGapMin: CGFloat = 0.15
        var overbarVerticalGap: CGFloat = 0.175
        var overbarRuleThickness: CGFloat = 0.068
        var overbarExtraAscender: CGFloat = 0.068
        var radicalVerticalGap: CGFloat = 0.085
        var radicalDisplayStyleVerticalGap: CGFloat = 0.17
        var radicalRuleThickness: CGFloat = 0.068
        var radicalExtraAscender: CGFloat = 0.078
        var radicalKernBeforeDegree: CGFloat = 0.065
        var radicalKernAfterDegree: CGFloat = -0.335
    }

    // MARK: - Reading the font

    private init() {
        let font = NSFont(name: "STIXTwoMath-Regular", size: 1)
            ?? NSFont(name: "STIX Two Math", size: 1)
            ?? NSFont(name: "Times New Roman", size: 1)
            ?? .systemFont(ofSize: 1)
        face = font
        let em = CGFloat(CTFontGetUnitsPerEm(font as CTFont))
        unitsPerEm = em > 0 ? em : 1000

        guard let table = CTFontCopyTable(
            font as CTFont, CTFontTableTag(kCTFontTableMATH), []
        ) as Data? , table.count > 8 else {
            constants = Constants()
            verticalVariants = [:]
            italicsCorrections = [:]
            return
        }
        let reader = Reader(data: table, unitsPerEm: unitsPerEm)
        constants = reader.constants()
        verticalVariants = reader.verticalVariants()
        italicsCorrections = reader.italicsCorrections()
    }

    // MARK: - Asking

    func font(ofSize size: CGFloat) -> NSFont {
        NSFont(descriptor: face.fontDescriptor, size: size) ?? face
    }

    func glyph(for scalar: Unicode.Scalar, size: CGFloat) -> CGGlyph? {
        var characters = Array(String(scalar).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        let ok = CTFontGetGlyphsForCharacters(
            font(ofSize: size) as CTFont, &characters, &glyphs, characters.count
        )
        guard ok, let first = glyphs.first, first != 0 else { return nil }
        return first
    }

    /// The italic correction for a glyph, in ems: how far the ink of a slanted
    /// letter leans past where the next thing would be set, which is the room
    /// a superscript needs so it does not sit on the letter's shoulder.
    func italicCorrection(of glyph: CGGlyph) -> CGFloat {
        italicsCorrections[glyph] ?? 0
    }

    /// The smallest cut of a glyph that reaches `height` ems, if the font has
    /// one. A sum on a line of its own, a bracket around a fraction.
    func variant(of glyph: CGGlyph, reaching height: CGFloat) -> CGGlyph? {
        guard let cuts = verticalVariants[glyph] else { return nil }
        return cuts.first { $0.advance >= height }?.glyph ?? cuts.last?.glyph
    }

    func height(of variant: CGGlyph, from glyph: CGGlyph) -> CGFloat? {
        verticalVariants[glyph]?.first { $0.glyph == variant }?.advance
    }

    // MARK: - The table

    private struct Reader {
        let data: Data
        let unitsPerEm: CGFloat

        func u16(_ offset: Int) -> Int {
            guard offset >= 0, offset + 1 < data.count else { return 0 }
            return Int(data[data.startIndex + offset]) << 8 | Int(data[data.startIndex + offset + 1])
        }

        func i16(_ offset: Int) -> Int {
            let value = u16(offset)
            return value >= 0x8000 ? value - 0x10000 : value
        }

        func em(_ offset: Int) -> CGFloat { CGFloat(i16(offset)) / unitsPerEm }

        func constants() -> Constants {
            let base = u16(4)
            guard base > 0 else { return Constants() }
            // Two percentages, two heights, then a run of value records four
            // bytes wide — a value and an offset to a device table nobody uses.
            func record(_ index: Int) -> CGFloat { em(base + 8 + index * 4) }
            var result = Constants()
            result.scriptPercentScaleDown = CGFloat(i16(base)) / 100
            result.scriptScriptPercentScaleDown = CGFloat(i16(base + 2)) / 100
            result.displayOperatorMinHeight = CGFloat(u16(base + 6)) / unitsPerEm
            result.axisHeight = record(1)
            result.accentBaseHeight = record(2)
            result.subscriptShiftDown = record(4)
            result.subscriptTopMax = record(5)
            result.subscriptBaselineDropMin = record(6)
            result.superscriptShiftUp = record(7)
            result.superscriptBottomMin = record(9)
            result.superscriptBaselineDropMax = record(10)
            result.subSuperscriptGapMin = record(11)
            result.spaceAfterScript = record(13)
            result.upperLimitGapMin = record(14)
            result.upperLimitBaselineRiseMin = record(15)
            result.lowerLimitGapMin = record(16)
            result.lowerLimitBaselineDropMin = record(17)
            result.fractionNumeratorShiftUp = record(28)
            result.fractionNumeratorDisplayStyleShiftUp = record(29)
            result.fractionDenominatorShiftDown = record(30)
            result.fractionDenominatorDisplayStyleShiftDown = record(31)
            result.fractionNumeratorGapMin = record(32)
            result.fractionNumDisplayStyleGapMin = record(33)
            result.fractionRuleThickness = record(34)
            result.fractionDenominatorGapMin = record(35)
            result.fractionDenomDisplayStyleGapMin = record(36)
            result.overbarVerticalGap = record(39)
            result.overbarRuleThickness = record(40)
            result.overbarExtraAscender = record(41)
            result.radicalVerticalGap = record(45)
            result.radicalDisplayStyleVerticalGap = record(46)
            result.radicalRuleThickness = record(47)
            result.radicalExtraAscender = record(48)
            result.radicalKernBeforeDegree = record(49)
            result.radicalKernAfterDegree = record(50)
            return result
        }

        /// The glyphs a coverage table covers, in the order the table lists
        /// them — which is the order the arrays beside it are indexed by.
        func coverage(at offset: Int) -> [CGGlyph] {
            guard offset > 0 else { return [] }
            switch u16(offset) {
            case 1:
                let count = u16(offset + 2)
                return (0..<count).map { CGGlyph(u16(offset + 4 + $0 * 2)) }
            case 2:
                let count = u16(offset + 2)
                var glyphs: [CGGlyph] = []
                for index in 0..<count {
                    let record = offset + 4 + index * 6
                    let start = u16(record), end = u16(record + 2)
                    guard end >= start, end - start < 0xFFFF else { continue }
                    glyphs += (start...end).map { CGGlyph($0) }
                }
                return glyphs
            default:
                return []
            }
        }

        func verticalVariants() -> [CGGlyph: [Variant]] {
            let base = u16(8)
            guard base > 0 else { return [:] }
            let covered = coverage(at: base + u16(base + 2))
            let count = u16(base + 6)
            var result: [CGGlyph: [Variant]] = [:]
            for index in 0..<min(count, covered.count) {
                let construction = u16(base + 10 + index * 2)
                guard construction > 0 else { continue }
                let at = base + construction
                let variantCount = u16(at + 2)
                var cuts: [Variant] = []
                for cut in 0..<variantCount {
                    let record = at + 4 + cut * 4
                    cuts.append(Variant(
                        glyph: CGGlyph(u16(record)),
                        advance: CGFloat(u16(record + 2)) / unitsPerEm
                    ))
                }
                if !cuts.isEmpty { result[covered[index]] = cuts }
            }
            return result
        }

        func italicsCorrections() -> [CGGlyph: CGFloat] {
            let info = u16(6)
            guard info > 0 else { return [:] }
            let corrections = u16(info)
            guard corrections > 0 else { return [:] }
            let at = info + corrections
            let covered = coverage(at: at + u16(at))
            let count = u16(at + 2)
            var result: [CGGlyph: CGFloat] = [:]
            for index in 0..<min(count, covered.count) {
                result[covered[index]] = em(at + 4 + index * 4)
            }
            return result
        }
    }
}
#endif
