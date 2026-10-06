import SwiftUI

#if os(macOS)
import AppKit
import CoreText
typealias NoteFont = NSFont
typealias NoteColor = NSColor
typealias NoteAppearance = NSAppearance
#else
import UIKit
typealias NoteFont = UIFont
typealias NoteColor = UIColor
typealias NoteAppearance = UITraitCollection
#endif

/// What a note is set in.
///
/// The system face. A note is a thing you write, not a thing you publish, and
/// the writing apps on this machine — Notes, Mail, Messages — are all set in
/// it; a note that opens in a book face reads as a document you are meant to
/// be careful around. It was a serif here, chosen to match the mathematics,
/// and matching the mathematics turned out to be the wrong thing to optimise:
/// most of a note is sentences, and the sentences pay for it on every line.
///
/// Hangul still comes from Pretendard, cascaded onto the Latin face rather
/// than swapped in, so a line with both scripts keeps one set of metrics.
/// Pretendard was drawn to sit beside a face of this weight, which is why it
/// survives the change.
///
/// The mathematics stays in a maths face — see `mathSize(forBody:)` for how
/// the two are made to sit together.
enum NoteTypography {
    /// The Hangul face at a weight: Pretendard where it is installed, Apple
    /// SD Gothic Neo where it is not.
    ///
    /// By weight, because the cascade does not carry a weight across. It
    /// was one face — the regular — and a bold word set in it was bold in
    /// its Latin letters only: «**굵게**» came out exactly as heavy as the
    /// words around it, and so did every heading in Korean (measured: the
    /// cascade under SF Bold drew `PretendardVariable-Regular`).
    static func hangulNames(_ weight: NoteFont.Weight) -> [String] {
        let name = weight.rawValue >= NoteFont.Weight.bold.rawValue ? "Bold"
            : weight.rawValue >= NoteFont.Weight.semibold.rawValue ? "SemiBold" : "Regular"
        return ["PretendardVariable-\(name)", "Pretendard-\(name)", "AppleSDGothicNeo-\(name)"]
    }

    /// 16, not 15. A point larger than the app's controls, because this is the
    /// one surface in the app made of nothing but prose.
    static let baseSize: CGFloat = 16

    /// A face for the body of a note.
    static func body(size: CGFloat = baseSize, bold: Bool = false, italic: Bool = false) -> NoteFont {
        font(size: size, weight: bold ? .bold : .regular, italic: italic)
    }

    /// The ladder a note is written on, and it is short on purpose: a title, a
    /// heading, a subheading, and then the body. Six distinct sizes are for a
    /// specification, not for a thought.
    ///
    /// `bold` and `italic` are the heading's own words in `**…**` or `*…*`:
    /// they stay the heading's size — they were set at the body's, a small
    /// bold word in a large line.
    static func heading(level: Int, size: CGFloat = baseSize, bold: Bool = false, italic: Bool = false) -> NoteFont {
        font(size: size * scale(forHeading: level),
             weight: bold || level <= 1 ? .bold : .semibold, italic: italic)
    }

    /// What to set a formula at so it sits in a sentence rather than on it.
    ///
    /// Not the body's point size — that was the bug. Point size is a property
    /// of the metal, not of the letters: a maths face and a sans set at the
    /// same points do not have the same x-height, and the formula came out
    /// visibly small and low. The two are matched on the height of a lowercase
    /// letter instead, measured from the fonts themselves, so it holds if
    /// either face is ever changed.
    static func mathSize(forBody size: CGFloat = baseSize) -> CGFloat {
        let text = body(size: size)
        guard let maths = NoteFont(name: mathFaceName, size: size), maths.xHeight > 0
        else { return size }
        let matched = size * (text.xHeight / maths.xHeight)
        // Within reason: a face with odd metrics should not run away with it.
        return min(max(matched, size), size * 1.4)
    }

    static let mathFaceName = "STIXTwoMath-Regular"

    /// The note as it is written (`</>`), and a formula that could not be set.
    static func mono(size: CGFloat = baseSize) -> NoteFont {
        NoteFont.monospacedSystemFont(ofSize: size * 0.92, weight: .regular)
    }

    /// Words in `` `…` ``: a little smaller than the line they are in, as
    /// Notion sets them (85%) — a monospaced face at the line's size reads a
    /// size larger than the words beside it.
    ///
    /// Hangul in it is the note's own Hangul face, cascaded as it is onto
    /// the body; the monospaced face has none and borrowed Apple SD Gothic
    /// Neo, a second Korean face in one line.
    static func code(size: CGFloat = baseSize) -> NoteFont {
        let key = "code|\(size)"
        if let cached = cache[key] { return cached }
        let face = NoteFont.monospacedSystemFont(ofSize: size * 0.85, weight: .regular)
        var made = face
        if let hangul = resolve(names: hangulNames(.regular), size: face.pointSize) {
            let descriptor = face.fontDescriptor.addingAttributes([.cascadeList: [hangul.fontDescriptor]])
            #if os(macOS)
            made = NoteFont(descriptor: descriptor, size: face.pointSize) ?? face
            #else
            made = NoteFont(descriptor: descriptor, size: face.pointSize)
            #endif
        }
        cache[key] = made
        return made
    }

    static func scale(forHeading level: Int) -> CGFloat {
        switch level {
        case 1: 1.5
        case 2: 1.25
        case 3: 1.09
        case 4...6: 1
        default: 1
        }
    }

    // MARK: - Building the face

    private nonisolated(unsafe) static var cache: [String: NoteFont] = [:]

    private static func font(size: CGFloat, weight: NoteFont.Weight, italic: Bool) -> NoteFont {
        let key = "\(size)|\(weight.rawValue)|\(italic)"
        if let cached = cache[key] { return cached }

        let base = NoteFont.systemFont(ofSize: size, weight: weight)
        var descriptor = base.fontDescriptor
        let heavier = weight.rawValue > NoteFont.Weight.regular.rawValue

        #if os(macOS)
        // Asked for alone, the italic trait takes a weighted system face back
        // to its regular italic — a semibold heading made italic was
        // `.SFNS-RegularItalic`. With the bold trait beside it the weight
        // stays: semibold italic, bold italic (measured).
        if italic { descriptor = descriptor.withSymbolicTraits(heavier ? [.bold, .italic] : [.italic]) }
        // Hangul is cascaded onto the Latin face rather than swapped in, so a
        // line with both scripts keeps one set of metrics.
        if let hangul = resolve(names: hangulNames(weight), size: size) {
            descriptor = descriptor.addingAttributes([
                .cascadeList: [hangul.fontDescriptor],
            ])
        }
        let made = NoteFont(descriptor: descriptor, size: size) ?? base
        #else
        var traits: UIFontDescriptor.SymbolicTraits = []
        if heavier { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        if !traits.isEmpty, let updated = descriptor.withSymbolicTraits(traits) { descriptor = updated }
        if let hangul = resolve(names: hangulNames(weight), size: size) {
            descriptor = descriptor.addingAttributes([
                .cascadeList: [hangul.fontDescriptor],
            ])
        }
        let made = NoteFont(descriptor: descriptor, size: size)
        #endif

        cache[key] = made
        return made
    }

    private static func resolve(names: [String], size: CGFloat) -> NoteFont? {
        for name in names {
            if let font = NoteFont(name: name, size: size) { return font }
        }
        return nil
    }

    #if os(macOS)
    // MARK: - Hangul in italics

    /// How far an italic leans: the system italic's own angle (12.5°), so a
    /// Korean word in italics leans with the Latin beside it.
    static let italicAngle: CGFloat = {
        let upright = NoteFont.systemFont(ofSize: baseSize)
        let italic = NoteFont(descriptor: upright.fontDescriptor.withSymbolicTraits(.italic), size: baseSize)
        let angle = abs(italic?.italicAngle ?? 0)
        return angle > 1 && angle < 30 ? angle : 12
    }()

    private nonisolated(unsafe) static var slanted: [String: NoteFont] = [:]

    /// Leans the Hangul of every italic run in `range`.
    ///
    /// Pretendard has no italic, and the cascade cannot lean it — a matrix
    /// on a cascaded descriptor is dropped (measured), as is `.obliqueness`
    /// in TextKit 2 — so «*기울여*» stood upright between letters that
    /// leaned. The characters the italic face has no glyph for and the
    /// Hangul face does are given that Hangul face, sheared by the italic's
    /// angle: what a browser does for a face with no italic, and what the
    /// Windows and Linux build already showed. The weight is the cascade's
    /// own, so bold italic Hangul is the bold face leaning.
    static func slantHangul(in text: NSMutableAttributedString, range: NSRange) {
        guard range.length > 0 else { return }
        let string = text.string as NSString
        var changes: [(NSRange, NoteFont)] = []
        text.enumerateAttribute(.font, in: range) { value, run, _ in
            guard let font = value as? NoteFont,
                  font.fontDescriptor.symbolicTraits.contains(.italic),
                  let cascade = (font.fontDescriptor.object(forKey: .cascadeList) as? [NSFontDescriptor])?.first,
                  let leaning = slanted(cascade, size: font.pointSize)
            else { return }
            var units = [UniChar](repeating: 0, count: run.length)
            string.getCharacters(&units, range: run)
            var mine = [CGGlyph](repeating: 0, count: run.length)
            var theirs = [CGGlyph](repeating: 0, count: run.length)
            CTFontGetGlyphsForCharacters(font as CTFont, units, &mine, run.length)
            CTFontGetGlyphsForCharacters(leaning as CTFont, units, &theirs, run.length)
            var start: Int?
            for index in 0...run.length {
                // A surrogate pair is looked up as one: its glyph is at the
                // first unit and nought at the second.
                let lean = index < run.length && mine[index] == 0 && (theirs[index] != 0
                    || (index > 0 && UTF16.isTrailSurrogate(units[index]) && theirs[index - 1] != 0 && mine[index - 1] == 0))
                if lean, start == nil { start = index }
                if !lean, let from = start {
                    changes.append((NSRange(location: run.location + from, length: index - from), leaning))
                    start = nil
                }
            }
        }
        for (range, font) in changes { text.addAttribute(.font, value: font, range: range) }
    }

    /// Whether a run is set in italics: an italic face, or Hangul leaned to
    /// stand beside one.
    static func isItalic(_ font: NoteFont) -> Bool {
        font.fontDescriptor.symbolicTraits.contains(.italic) || font.textTransform.m21 != 0
    }

    private static func slanted(_ upright: NSFontDescriptor, size: CGFloat) -> NoteFont? {
        let key = "\(upright.postscriptName ?? "")|\(size)"
        if let cached = slanted[key] { return cached }
        var transform = AffineTransform(scaleByX: size, byY: size)
        transform.m21 = size * tan(italicAngle * .pi / 180)
        guard let font = NoteFont(descriptor: upright, textTransform: transform) else { return nil }
        slanted[key] = font
        return font
    }
    #endif

    /// Whether the reader's Mac has the faces this is meant to be set in.
    ///
    /// Only two are worth asking about now. The body comes from the system, so
    /// it is always there; Pretendard sets the Hangul and the maths face sets
    /// the formulas, and a Mac without either still reads, just not as well.
    static var missingFaces: [String] {
        var missing: [String] = []
        if resolve(names: hangulNames(.regular), size: 12) == nil { missing.append("Pretendard") }
        if NoteFont(name: mathFaceName, size: 12) == nil { missing.append("STIX Two Math") }
        return missing
    }
}

/// Words in backticks, set the way Notion sets them: a monospaced face a
/// size below the line (`NoteTypography.code`), in a warm red, on a rounded
/// warm grey that reaches a little past the letters.
///
/// It had been the monospaced face on the system's faintest grey, a
/// rectangle cut tight to the letters — which read as a selection somebody
/// forgot, not as code.
enum NoteCodeStyle {
    #if os(macOS)
    /// Marks a run as code; the value is the code face's point size, which
    /// the tint is measured from. Painted by `NoteLayoutFragment`.
    static let attribute = NSAttributedString.Key("PaperTimeCode")
    #endif

    /// Notion's red: on a white page #EB5757, on a dark one a lighter
    /// #FF7369, so it reads the same on both.
    static var ink: NoteColor {
        #if os(macOS)
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(srgbRed: 255 / 255, green: 115 / 255, blue: 105 / 255, alpha: 1)
                : NSColor(srgbRed: 235 / 255, green: 87 / 255, blue: 87 / 255, alpha: 1)
        }
        #else
        UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 255 / 255, green: 115 / 255, blue: 105 / 255, alpha: 1)
                : UIColor(red: 235 / 255, green: 87 / 255, blue: 87 / 255, alpha: 1)
        }
        #endif
    }

    /// The warm grey behind it, translucent so the page shows through: the
    /// same on a light page and a dark one.
    static var fill: NoteColor {
        #if os(macOS)
        NSColor(srgbRed: 135 / 255, green: 131 / 255, blue: 120 / 255, alpha: 0.15)
        #else
        UIColor(red: 135 / 255, green: 131 / 255, blue: 120 / 255, alpha: 0.15)
        #endif
    }

    static let radius: CGFloat = 4

    /// How far the tint reaches past the letters, in ems of the code face:
    /// 0.4 across, 0.2 up and down.
    static let padding = CGSize(width: 0.4, height: 0.2)
}

#if os(macOS)
extension NoteCodeStyle {
    /// A fenced block, drawn as a small code editor: a rounded box on a cool
    /// wash of the page, with the code's language as a chip, a pill to copy
    /// it, line numbers down the side, and the code coloured as Xcode colours
    /// it, light and dark.
    ///
    /// It had been the table's box — the page's faint grey, an outline, a
    /// rule under the header, the table's tight corner — and every edge of
    /// it was a line, so it read as a form to fill in rather than as code
    /// somebody wrote. Nothing in it is a line now: the box is a tint with
    /// an editor's corner, the language is a chip as a passage is, and the
    /// copy button is a pill as a button on a surface is.
    ///
    /// The lines stay text — they wrap, select, search and copy as words —
    /// and the box is painted behind them a line at a time by
    /// `NoteLayoutFragment.drawCodeBlock`, the way a quotation's rule is.
    enum Block {
        /// Marks a line of a block. The value is `Row.raw`: what the line is
        /// and, for a line of code, its number.
        static let attribute = NSAttributedString.Key("PaperTimeCodeBlock")
        /// On a header for a moment after its code was copied.
        static let copied = NSAttributedString.Key("PaperTimeCodeCopied")

        enum Role: Int {
            /// The opening fence: the language and the copy button, or the
            /// fence as written when the caret is on it.
            case header = 0
            case line = 1
            /// The closing fence: the box's foot, or the fence as written.
            case close = 2
        }

        struct Row: Equatable {
            var role: Role
            /// A line of code's number, from 1.
            var number: Int
            /// The block's last row: its foot, or — in a block never closed —
            /// its last line of code, or its header when it has none.
            var isLast: Bool

            var raw: Int { number << 3 | (isLast ? 4 : 0) | role.rawValue }

            init(role: Role, number: Int = 0, isLast: Bool = false) {
                self.role = role
                self.number = number
                self.isLast = isLast
            }

            init?(_ value: Any?) {
                guard let raw = value as? Int, let role = Role(rawValue: raw & 3) else { return nil }
                self.init(role: role, number: raw >> 3, isLast: raw & 4 != 0)
            }
        }

        /// An editor's corner (`Corner.popover`): the block is a small editor
        /// set into the note, and the table's tight corner made it a form.
        static let radius: CGFloat = Corner.popover
        /// Room inside the box, left and right of the code.
        static let inset: CGFloat = 14
        static let headerHeight: CGFloat = 34
        /// The box's foot under the last line, when the closing fence is out
        /// of sight: as tall as the corner, so the corner is all the foot's
        /// and turns without a step where the row above it ends.
        static let footHeight: CGFloat = 14
        /// Above and below the block, so it does not sit on the words around it.
        static let margin: CGFloat = 6
        /// Between the header and the first line of code: the pills have
        /// their own room round them, and there is no rule to clear.
        static let firstLineGap: CGFloat = 2

        /// The language's chip and the copy pill: how tall, how far in from
        /// the box's edges (the same on top as at the side, so each sits
        /// square in its corner), and the room either side of their words.
        static let pillHeight: CGFloat = 22
        static let pillInset: CGFloat = 6
        static let pillPadding: CGFloat = 9
        /// Where the header's words start: inside the chip.
        static var labelIndent: CGFloat { pillInset + pillPadding }
        /// What the header keeps clear at its right end for the copy pill:
        /// "복사했어요" with its tick, and the room round it.
        static let copyRoom: CGFloat = 100

        /// A cool wash rather than a grey. On a white page the faintest
        /// blue; in the dark the slate of Xcode's own dark editor, which the
        /// code's colours were made for. Translucent, so the page — glass, or
        /// paper in a PDF — shows through. The grey it replaced was the
        /// page's colour made dirtier, and read as dull. The Portable build's
        /// `--codeblock-fill` is the same two colours.
        static var fill: NSColor {
            NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    ? NSColor(srgbRed: 140 / 255, green: 170 / 255, blue: 255 / 255, alpha: 0.085)
                    : NSColor(srgbRed: 30 / 255, green: 90 / 255, blue: 200 / 255, alpha: 0.05)
            }
        }
        /// The copy pill: white on the wash by day, with a hairline so the
        /// white has an edge; a lighter shade of the wash at night, where a
        /// lighter shade is edge enough.
        static var pillFill: NSColor {
            NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    ? NSColor(white: 1, alpha: 0.08)
                    : NSColor(white: 1, alpha: 0.85)
            }
        }
        static var pillEdge: NSColor {
            NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    ? .clear
                    : NSColor(white: 0, alpha: 0.06)
            }
        }
        static var lineNumber: NSColor { .tertiaryLabelColor }
        /// The language's name: the accent — and in the dark the accent
        /// lifted toward white, as the Portable build's `--accent-text` is:
        /// the accent itself is too deep to read on a tint of itself there.
        static var labelInk: NSColor {
            NSColor(name: nil) { appearance in
                var ink = NSColor.controlAccentColor
                appearance.performAsCurrentDrawingAppearance {
                    ink = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
                }
                guard appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua else { return ink }
                return ink.blended(withFraction: 0.35, of: .white) ?? ink
            }
        }

        /// The language's name, in its chip: the accent over a tint of it,
        /// as a passage reads (`NoteChip`).
        static func headerFont(size: CGFloat = NoteTypography.baseSize) -> NSFont {
            NSFont.systemFont(ofSize: size * 0.75, weight: .semibold)
        }

        /// The copy pill's words.
        static func copyFont(size: CGFloat = NoteTypography.baseSize) -> NSFont {
            NSFont.systemFont(ofSize: size * 0.72, weight: .regular)
        }

        /// How far words on the header are lifted to stand in its middle —
        /// the middle of their capitals on the middle of the header, where
        /// the chip's is. A line taller than its words is filled from the
        /// top, so they sit at its foot; centring their whole height instead
        /// left the name a few points low in its chip.
        static func headerLift(for font: NSFont) -> CGFloat {
            max(0, headerHeight / 2 + font.descender - font.capHeight / 2)
        }

        static func numberFont(size: CGFloat = NoteTypography.baseSize) -> NSFont {
            NSFont.monospacedDigitSystemFont(ofSize: size * 0.72, weight: .regular)
        }

        /// A line of code's height: the code face's own, and 15% more — in
        /// whole points. Every row is its own layer, set down on a whole
        /// pixel; a row 18.4 points tall ended a fraction past where the next
        /// one began, and that pixel row was painted by both.
        static func lineHeight(size: CGFloat = NoteTypography.baseSize) -> CGFloat {
            let font = NoteTypography.code(size: size)
            return ((font.ascender - font.descender + font.leading) * 1.15).rounded()
        }

        /// The room the line numbers take, for a block of this many lines:
        /// two digits at least, so a block that grows past nine lines does
        /// not shift its code.
        static func gutter(lines: Int, size: CGFloat = NoteTypography.baseSize) -> CGFloat {
            let digits = max(2, String(max(lines, 1)).count)
            let width = ("0" as NSString).size(withAttributes: [.font: numberFont(size: size)]).width
            return ceil(CGFloat(digits) * width) + 14
        }

        /// Xcode's colours for a role, light and dark — the same palette as
        /// the Portable build's `CODE_PALETTE`.
        static func ink(_ role: CodeHighlighter.Role) -> NSColor {
            let (light, dark): (UInt32, UInt32) = switch role {
            case .keyword: (0x9B2393, 0xFC5FA3)
            case .string: (0xC41A16, 0xFC6A5D)
            case .number: (0x1C00CF, 0xD0BF69)
            case .comment: (0x5D6C79, 0x7F8C98)
            case .type: (0x0B4F79, 0x5DD8FF)
            case .function: (0x326D74, 0x67B7A4)
            case .builtIn: (0x6C36A9, 0xA167E6)
            case .meta: (0x643820, 0xFD8F3F)
            case .attribute: (0x815F03, 0xBF8555)
            }
            func color(_ hex: UInt32) -> NSColor {
                NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                        blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
            }
            return NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? color(dark) : color(light)
            }
        }
    }
}
#endif
