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
enum NoteCode {
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
