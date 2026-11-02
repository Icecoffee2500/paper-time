import CoreGraphics

/// How a highlight colours what it covers, the way Apple Notes does it: the
/// words themselves turn a deep shade of the highlighter's colour, and a pale
/// band of the same colour lies under them.
///
/// Two colours from one name, on every platform the same (Portable's
/// `shared/marks.ts` has `highlightInk`/`highlightBand`, value for value):
/// the ink is a vivid shade of the highlighter's colour picked for each of
/// the five, and the band is the highlighter's colour taken most of the way
/// to white, to be multiplied onto the paper — the look of a quotation chip,
/// pale ground and coloured words. On a dark ground (a note at night) the
/// ink is a lighter shade and the band is the colour let through at a
/// fifth.
public enum HighlightTone {
    public struct RGB: Equatable, Sendable {
        public var red: CGFloat, green: CGFloat, blue: CGFloat
        public init(red: CGFloat, green: CGFloat, blue: CGFloat) {
            self.red = red; self.green = green; self.blue = blue
        }
    }

    /// Relative luminance, Rec. 709 weights on the gamma-encoded values —
    /// a reading, not a measurement; the same reading on both builds.
    public static func luminance(_ c: RGB) -> CGFloat {
        0.2126 * c.red + 0.7152 * c.green + 0.0722 * c.blue
    }

    /// How far the band goes toward white, resting and under the pointer:
    /// as pale as a quotation chip's tint, so the words carry the colour.
    public static let bandShare: CGFloat = 0.80
    public static let bandShareHovered: CGFloat = 0.88
    /// The band's opacity on a dark ground, where nothing multiplies.
    public static let bandAlphaOnDark: CGFloat = 0.22

    /// The words' colour for each of the five, light and dark: the vivid
    /// shades Apple Notes gives highlighted words (red-pink on pink, a true
    /// blue on blue, a violet on lavender), picked by hand rather than
    /// derived — a yellow taken down by a formula was an ochre nobody would
    /// call a colour; this amber reads as "the yellow one" and still reads
    /// on paper.
    public static func ink(_ color: MarkupColor, dark: Bool = false) -> RGB {
        switch (color, dark) {
        case (.yellow, false): RGB(red: 0.78, green: 0.50, blue: 0.02)
        case (.green, false): RGB(red: 0.13, green: 0.60, blue: 0.35)
        case (.blue, false): RGB(red: 0.12, green: 0.44, blue: 0.85)
        case (.pink, false): RGB(red: 0.84, green: 0.18, blue: 0.33)
        case (.purple, false): RGB(red: 0.55, green: 0.28, blue: 0.82)
        case (.yellow, true): RGB(red: 0.98, green: 0.76, blue: 0.28)
        case (.green, true): RGB(red: 0.42, green: 0.85, blue: 0.58)
        case (.blue, true): RGB(red: 0.48, green: 0.70, blue: 1.00)
        case (.pink, true): RGB(red: 1.00, green: 0.50, blue: 0.62)
        case (.purple, true): RGB(red: 0.76, green: 0.60, blue: 0.98)
        }
    }

    /// The words' colour on paper for any highlighter colour — another
    /// reader's, say — by the nearest of the five.
    /// The colour a highlighter is *shown* as — the dot in a bar, an
    /// underline, a strike: Apple's own five (the system colours, light),
    /// bright, not the deep ink its words become. The dots were once the
    /// ink, and next to the system's blue every one of them read as muddy.
    public static func swatch(_ color: MarkupColor) -> RGB {
        switch color {
        case .yellow: RGB(red: 1.00, green: 0.80, blue: 0.00)
        case .green: RGB(red: 0.20, green: 0.78, blue: 0.35)
        case .blue: RGB(red: 0.00, green: 0.48, blue: 1.00)
        case .pink: RGB(red: 1.00, green: 0.18, blue: 0.33)
        case .purple: RGB(red: 0.69, green: 0.32, blue: 0.87)
        }
    }

    /// The same for any highlighter colour, by the nearest of the five — what
    /// a line (underline, strike) is drawn in. A line is thin and has no area
    /// to carry a pale tint, so it is the swatch itself.
    public static func line(_ c: RGB) -> RGB {
        swatch(MarkupColor.nearest(red: c.red, green: c.green, blue: c.blue))
    }

    public static func ink(_ c: RGB) -> RGB {
        ink(MarkupColor.nearest(red: c.red, green: c.green, blue: c.blue))
    }

    /// The words' colour on a dark ground.
    public static func inkOnDark(_ c: RGB) -> RGB {
        ink(MarkupColor.nearest(red: c.red, green: c.green, blue: c.blue), dark: true)
    }

    /// The band's paint, to be multiplied onto white paper.
    public static func band(_ c: RGB, hovered: Bool = false) -> RGB {
        let share = hovered ? bandShareHovered : bandShare
        return RGB(red: c.red + (1 - c.red) * share, green: c.green + (1 - c.green) * share, blue: c.blue + (1 - c.blue) * share)
    }

    /// How far the band reaches below the words, as a share of its height:
    /// a highlighter's band hangs a little under the letters.
    public static let bandDrop: CGFloat = 0.08
}

extension MarkupColor {
    public var rgb: HighlightTone.RGB {
        let parts = components
        return HighlightTone.RGB(red: parts.red, green: parts.green, blue: parts.blue)
    }
    /// A name as written in a note (`=={pink}…==`), or nil for a name that is
    /// not one of the five.
    public static func named(_ name: String) -> MarkupColor? { MarkupColor(rawValue: name) }
}
