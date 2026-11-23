import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// What a run of a note's words is set in beyond what Markdown can say: a
/// colour, a size, a face, an underline, a line through.
///
/// A note is a Markdown file and stays one. Markdown has bold, italic and
/// code and nothing else, so the rest is written the way Markdown itself
/// allows it to be — as HTML, in the line:
///
///     <span style="color:#d62e54;font-size:20px">these words</span>
///
/// Obsidian and every Markdown reader that renders HTML show such a span as
/// it is meant; one that does not shows the tag. The style is the handful of
/// CSS properties below and no others: what is written here is read back
/// here, and a property nobody set is not written.
struct NoteSpanStyle: Equatable {
    /// `#rrggbb`.
    var color: String?
    /// In points.
    var size: Double?
    var family: String?
    var bold = false
    var italic = false
    var underline = false
    var strike = false
    /// Highlighted, in one of the five colours by name — the same highlight
    /// `==words==` is, said here when the words are set some other way too.
    var highlight: String?

    init() {}

    /// What a highlight is written as in a span: a pale ground. Read back
    /// by the same table — and a ground somebody else wrote, by whichever of
    /// these it is nearest.
    static let grounds: [(name: String, hex: String)] = [
        ("yellow", "#fff3b0"), ("green", "#cfeedd"), ("blue", "#cfe2fb"), ("pink", "#fbd3dc"), ("purple", "#e6d7f8"),
    ]

    /// The five colours words are offered in — the inks a highlight's own
    /// words take, by the highlighters' names, so the two rows of dots are
    /// one palette. Written as the hex; drawn from the name, which has a
    /// lighter shade for a dark page.
    static let inks: [(name: String, hex: String)] = [
        ("yellow", "#c78005"), ("green", "#219959"), ("blue", "#1f70d9"), ("pink", "#d62e54"), ("purple", "#8c47d1"),
    ]

    static func ink(named name: String) -> String? { inks.first { $0.name == name }?.hex }
    static func inkName(of hex: String?) -> String? { hex.flatMap { value in inks.first { $0.hex == value }?.name } }

    static func highlight(forGround value: String) -> String? {
        guard let hex = hex(value), let wanted = Int(hex.dropFirst(), radix: 16) else { return nil }
        func distance(_ other: String) -> Int {
            let v = Int(other.dropFirst(), radix: 16) ?? 0
            return [16, 8, 0].reduce(0) { sum, shift in
                let d = ((wanted >> shift) & 0xFF) - ((v >> shift) & 0xFF)
                return sum + d * d
            }
        }
        return grounds.min { distance($0.hex) < distance($1.hex) }?.name
    }

    /// Whether all of it is a highlight, which Markdown-as-we-write-it says
    /// with `==`.
    var isOnlyHighlight: Bool {
        var rest = self
        rest.highlight = nil
        return highlight != nil && rest.isEmpty
    }

    var isEmpty: Bool { self == NoteSpanStyle() }

    /// Whether Markdown's own marks can say all of it.
    var isOnlyEmphasis: Bool {
        color == nil && size == nil && family == nil && !underline && !strike && highlight == nil
    }

    init(css: String) {
        for declaration in css.split(separator: ";") {
            let parts = declaration.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2 else { continue }
            let value = parts[1]
            switch parts[0].lowercased() {
            case "color":
                if let hex = Self.hex(value) { color = hex }
            case "background-color", "background":
                highlight = Self.highlight(forGround: value)
            case "font-size":
                let number = value.lowercased().replacingOccurrences(of: "px", with: "").replacingOccurrences(of: "pt", with: "")
                if let points = Double(number), points >= 4, points <= 400 { size = points }
            case "font-family":
                let name = value.split(separator: ",").first.map(String.init)?
                    .trimmingCharacters(in: CharacterSet(charactersIn: "'\" ")) ?? ""
                if !name.isEmpty { family = name }
            case "font-weight":
                bold = value.lowercased() == "bold" || (Int(value) ?? 0) >= 600
            case "font-style":
                italic = value.lowercased() == "italic" || value.lowercased() == "oblique"
            case "text-decoration", "text-decoration-line":
                underline = value.lowercased().contains("underline")
                strike = value.lowercased().contains("line-through")
            default:
                break
            }
        }
    }

    /// `#rrggbb` from `#rgb` or `#rrggbb`, lowercased; nil for anything else.
    static func hex(_ value: String) -> String? {
        var digits = value.lowercased()
        guard digits.hasPrefix("#") else { return nil }
        digits.removeFirst()
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard digits.count == 6, digits.allSatisfy(\.isHexDigit) else { return nil }
        return "#" + digits
    }

    /// The declarations, in one order, so the same style is the same bytes.
    var css: String {
        var parts: [String] = []
        if let color { parts.append("color:\(color)") }
        if let highlight, let ground = Self.grounds.first(where: { $0.name == highlight }) {
            parts.append("background-color:\(ground.hex)")
        }
        if let size {
            let text = size == size.rounded() ? String(Int(size)) : String(format: "%.1f", size)
            parts.append("font-size:\(text)px")
        }
        if let family { parts.append("font-family:\(family)") }
        if bold { parts.append("font-weight:bold") }
        if italic { parts.append("font-style:italic") }
        if underline || strike {
            parts.append("text-decoration:" + [underline ? "underline" : nil, strike ? "line-through" : nil]
                .compactMap { $0 }.joined(separator: " "))
        }
        return parts.joined(separator: ";")
    }

    var open: String { "<span style=\"\(css)\">" }
    static let close = "</span>"

    /// The words in this style, as the note holds them: a span, Markdown's
    /// own marks when those say all of it, or the words alone.
    func wrapping(_ words: String) -> String {
        if isEmpty || words.isEmpty { return words }
        // A highlight and nothing else is `==`, with its colour named: that
        // form reads wherever it stands, inside a word too.
        if isOnlyHighlight, let highlight, !words.contains("=="), !words.hasPrefix("="), !words.hasSuffix("="),
           words.first?.isWhitespace == false, words.last?.isWhitespace == false {
            return "=={\(highlight)}" + words + "=="
        }
        if isOnlyEmphasis {
            let mark = bold && italic ? "***" : bold ? "**" : "*"
            // Markdown's marks do not hold a star, or a space at either end.
            if !words.contains("*"), words.first?.isWhitespace == false, words.last?.isWhitespace == false {
                return mark + words + mark
            }
        }
        return open + words + Self.close
    }
}

/// How a paragraph of a note is set across the line. Left is what a line is
/// without being told; the others are written round the line's words:
/// `<p align="center">…</p>`.
enum NoteAlignment: String, CaseIterable {
    case left, center, right, justify

    var open: String { "<p align=\"\(rawValue)\">" }
    static let close = "</p>"

    #if os(macOS)
    var textAlignment: NSTextAlignment {
        switch self {
        case .left: .left
        case .center: .center
        case .right: .right
        case .justify: .justified
        }
    }
    #endif

    private static let pattern = try! NSRegularExpression(pattern: #"^<p align="(left|center|right|justify)">"#)

    /// The alignment a line's words are wrapped in, and where the words
    /// themselves are in it. Nil for a line that is not wrapped.
    static func read(_ content: String) -> (alignment: NoteAlignment, inner: NSRange)? {
        let text = content as NSString
        guard content.hasPrefix("<p align="), content.hasSuffix(close),
              let match = pattern.firstMatch(in: content, range: NSRange(location: 0, length: text.length)),
              let alignment = NoteAlignment(rawValue: text.substring(with: match.range(at: 1))),
              text.length >= match.range.length + (close as NSString).length
        else { return nil }
        return (alignment, NSRange(location: match.range.length,
                                   length: text.length - match.range.length - (close as NSString).length))
    }
}

#if os(macOS)
extension NoteColor {
    /// A colour from `#rrggbb`.
    convenience init?(noteHex: String) {
        guard let hex = NoteSpanStyle.hex(noteHex), let value = Int(hex.dropFirst(), radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    /// `#rrggbb`, in sRGB.
    var noteHex: String? {
        guard let rgb = usingColorSpace(.sRGB) else { return nil }
        let (r, g, b) = (rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
        return String(format: "#%02x%02x%02x", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }
}
#endif
