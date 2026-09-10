import SwiftUI

#if os(macOS)
import AppKit
typealias NoteFont = NSFont
typealias NoteColor = NSColor
#else
import UIKit
typealias NoteFont = UIFont
typealias NoteColor = UIColor
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
    /// The Hangul face.
    static let hangulNames = ["PretendardVariable-Regular", "Pretendard-Regular",
                              "AppleSDGothicNeo-Regular"]

    /// 16, not 15. A point larger than the app's controls, because this is the
    /// one surface in the app made of nothing but prose.
    static let baseSize: CGFloat = 16

    /// A face for the body of a note.
    static func body(size: CGFloat = baseSize, bold: Bool = false, italic: Bool = false) -> NoteFont {
        font(names: [], size: size, bold: bold, italic: italic)
    }

    /// The ladder a note is written on, and it is short on purpose: a title, a
    /// heading, a subheading, and then the body. Six distinct sizes are for a
    /// specification, not for a thought.
    static func heading(level: Int, size: CGFloat = baseSize) -> NoteFont {
        font(names: [], size: size * scale(forHeading: level),
             bold: false, italic: false, weight: level <= 1 ? .bold : .semibold)
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

    static func mono(size: CGFloat = baseSize) -> NoteFont {
        #if os(macOS)
        NoteFont.monospacedSystemFont(ofSize: size * 0.92, weight: .regular)
        #else
        NoteFont.monospacedSystemFont(ofSize: size * 0.92, weight: .regular)
        #endif
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

    private static func font(
        names: [String], size: CGFloat, bold: Bool, italic: Bool,
        weight: NoteFont.Weight = .regular
    ) -> NoteFont {
        let key = "\(names.first ?? "")|\(size)|\(bold)|\(italic)|\(weight.rawValue)"
        if let cached = cache[key] { return cached }

        let base = resolve(names: names, size: size)
            ?? NoteFont.systemFont(ofSize: size, weight: weight)
        var descriptor = base.fontDescriptor

        #if os(macOS)
        var traits: NSFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        if !traits.isEmpty { descriptor = descriptor.withSymbolicTraits(traits) }
        // Hangul is cascaded onto the Latin face rather than swapped in, so a
        // line with both scripts keeps one set of metrics.
        if let hangul = resolve(names: hangulNames, size: size) {
            descriptor = descriptor.addingAttributes([
                .cascadeList: [hangul.fontDescriptor],
            ])
        }
        let made = NoteFont(descriptor: descriptor, size: size) ?? base
        #else
        var traits: UIFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        if let updated = descriptor.withSymbolicTraits(traits) { descriptor = updated }
        if let hangul = resolve(names: hangulNames, size: size) {
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

    /// Whether the reader's Mac has the faces this is meant to be set in.
    ///
    /// Only two are worth asking about now. The body comes from the system, so
    /// it is always there; Pretendard sets the Hangul and the maths face sets
    /// the formulas, and a Mac without either still reads, just not as well.
    static var missingFaces: [String] {
        var missing: [String] = []
        if resolve(names: hangulNames, size: 12) == nil { missing.append("Pretendard") }
        if NoteFont(name: mathFaceName, size: 12) == nil { missing.append("STIX Two Math") }
        return missing
    }
}
