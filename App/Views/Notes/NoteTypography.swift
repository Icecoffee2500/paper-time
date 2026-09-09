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
/// A note about a paper should look like the paper: a text face from the same
/// family as the mathematics, so a formula in a sentence sits on the same
/// baseline and shares the same colour of ink. Hangul comes from Pretendard,
/// which was drawn to sit beside Latin text at the same optical weight.
///
/// Neither face is required. Each one falls back to what macOS has always had,
/// so a library opened on a Mac without them still reads properly.
enum NoteTypography {
    /// The Latin and mathematical face: the text companion of the maths font.
    static let serifNames = ["STIXTwoText-Regular", "STIX Two Text", "NewYork-Regular",
                             "TimesNewRomanPSMT"]
    /// The Hangul face.
    static let hangulNames = ["PretendardVariable-Regular", "Pretendard-Regular",
                              "AppleSDGothicNeo-Regular"]

    static let baseSize: CGFloat = 15

    /// A face for the body of a note: serif Latin, Pretendard Hangul.
    static func body(size: CGFloat = baseSize, bold: Bool = false, italic: Bool = false) -> NoteFont {
        font(names: serifNames, size: size, bold: bold, italic: italic)
    }

    /// Headings are set in the same serif, larger and darker, so a note reads
    /// as one document rather than two typefaces having an argument.
    static func heading(level: Int, size: CGFloat = baseSize) -> NoteFont {
        body(size: size * scale(forHeading: level), bold: true)
    }

    static func mono(size: CGFloat = baseSize) -> NoteFont {
        #if os(macOS)
        NoteFont.monospacedSystemFont(ofSize: size * 0.92, weight: .regular)
        #else
        NoteFont.monospacedSystemFont(ofSize: size * 0.92, weight: .regular)
        #endif
    }

    static func scale(forHeading level: Int) -> CGFloat {
        switch level {
        case 1: 1.62
        case 2: 1.36
        case 3: 1.18
        case 4...6: 1.06
        default: 1
        }
    }

    // MARK: - Building the face

    private nonisolated(unsafe) static var cache: [String: NoteFont] = [:]

    private static func font(
        names: [String], size: CGFloat, bold: Bool, italic: Bool
    ) -> NoteFont {
        let key = "\(names.first ?? "")|\(size)|\(bold)|\(italic)"
        if let cached = cache[key] { return cached }

        let base = resolve(names: names, size: size)
            ?? NoteFont.systemFont(ofSize: size)
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
    static var missingFaces: [String] {
        var missing: [String] = []
        if resolve(names: serifNames, size: 12) == nil { missing.append("STIX Two Text") }
        if resolve(names: hangulNames, size: 12) == nil { missing.append("Pretendard") }
        return missing
    }
}
