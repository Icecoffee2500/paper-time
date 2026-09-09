import Foundation
import PaperCore

#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension NSAttributedString.Key {
    /// The Markdown a run stands for, when the run is not its own source: a
    /// heading whose `##` is not shown, a formula set as mathematics, a link
    /// shown as what it points at. Plain text is its own source.
    static let paperTimeSource = NSAttributedString.Key("PaperTimeSource")
}

/// Turns a note between the Markdown that is stored and the text that is read.
///
/// The file on disk stays ordinary Markdown — links are links, formulas are
/// `$…$` — so a note can be read, searched and kept without this app. On screen
/// it is shown the way it reads: headings large, list markers as bullets,
/// formulas set as mathematics.
///
/// The one exception is the line the caret is on, which is always shown exactly
/// as it is written. That is what makes the thing editable: you can only change
/// what you can see, so the line being worked on shows its own syntax and every
/// other line shows its meaning.
enum NoteMarkdown {
    /// A note as it is shown, with the thread back to the Markdown it came
    /// from so the caret can be put back where the typist left it.
    struct Rendered {
        var text: NSAttributedString
        /// Display range and the source range it stands for, in order.
        var pieces: [(display: NSRange, source: NSRange)]

        func displayIndex(forSource index: Int) -> Int {
            for piece in pieces {
                let end = piece.source.location + piece.source.length
                if index < piece.source.location { return piece.display.location }
                if index <= end {
                    if piece.display.length == piece.source.length {
                        return piece.display.location + (index - piece.source.location)
                    }
                    return index >= end
                        ? piece.display.location + piece.display.length
                        : piece.display.location
                }
            }
            return text.length
        }
    }

    /// Stands in for syntax that is not shown, so the run has something to hang
    /// its source on and the caret has somewhere to be.
    static let hiddenMarker = "\u{200B}"

    /// The room a line has while a note is being rendered. Set for the length
    /// of a render rather than passed down through every kind of token, which
    /// only formulas care about. Rendering happens on the main thread, one
    /// note at a time, which is what makes a single value enough.
    private nonisolated(unsafe) static var available: CGFloat?

    // MARK: - Reading the source back

    static func markdown(from attributed: NSAttributedString) -> String {
        var result = ""
        attributed.enumerateAttributes(
            in: NSRange(location: 0, length: attributed.length)
        ) { attributes, range, _ in
            if let source = attributes[.paperTimeSource] as? String {
                result += source
                return
            }
            result += attributed.attributedSubstring(from: range).string
        }
        return result
    }

    /// Where the caret sits in the source, given where it sits on screen.
    static func sourceIndex(in attributed: NSAttributedString, displayIndex: Int) -> Int {
        var source = 0
        var display = 0
        attributed.enumerateAttributes(
            in: NSRange(location: 0, length: attributed.length)
        ) { attributes, range, stop in
            let text = attributes[.paperTimeSource] as? String
                ?? attributed.attributedSubstring(from: range).string
            let sourceLength = (text as NSString).length

            if displayIndex >= display + range.length {
                source += sourceLength
                display += range.length
                return
            }
            if sourceLength == range.length {
                source += displayIndex - display
            } else if displayIndex > display {
                source += sourceLength
            }
            stop.pointee = true
        }
        return source
    }

    // MARK: - Colours and attributes

    static var bodyFont: NoteFont { NoteTypography.body() }

    static var bodyAttributes: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: NoteColor.labelColor]
    }

    static var rawAttributes: [NSAttributedString.Key: Any] {
        [.font: NoteTypography.mono(), .foregroundColor: NoteColor.labelColor]
    }

    /// Links into the paper carry the app's accent rather than the system's
    /// link blue: they point inside this document, not out to the web.
    static var accent: NoteColor {
        #if os(macOS)
        NSColor.controlAccentColor
        #else
        UIColor.tintColor
        #endif
    }

    static func linkAttributes(_ url: URL) -> [NSAttributedString.Key: Any] {
        [
            .font: bodyFont,
            .link: url,
            .foregroundColor: accent,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
    }

    private static var syntaxColor: NoteColor { .tertiaryLabelColor }

    // MARK: - Writing links

    static func noteURL(id: String) -> URL {
        let escaped = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id
        return URL(string: "papertime://note?id=\(escaped)")!
    }

    static func noteID(from url: URL) -> String? {
        guard url.scheme == "papertime", url.host == "note" else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "id" }?.value
    }

    /// A link to a place in the paper, ready to drop at the cursor.
    static func link(for anchor: NoteAnchor) -> NSAttributedString {
        let source = "[\(escape(anchor.label))](\(anchor.url.absoluteString))"
        let piece = NSMutableAttributedString(
            string: anchor.label, attributes: linkAttributes(anchor.url)
        )
        piece.addAttribute(.paperTimeSource, value: source,
                           range: NSRange(location: 0, length: piece.length))
        piece.append(NSAttributedString(string: " ", attributes: bodyAttributes))
        return piece
    }

    /// Brackets and backslashes in a label would end the link early, so they
    /// travel escaped — which is what any Markdown reader expects of them.
    static func escape(_ text: String) -> String {
        var result = ""
        for character in text {
            if character == "\\" || character == "[" || character == "]" { result.append("\\") }
            result.append(character)
        }
        return result
    }

    static func unescape(_ text: String) -> String {
        var result = ""
        var escaped = false
        for character in text {
            if escaped {
                result.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        if escaped { result.append("\\") }
        return result
    }

    // MARK: - Rendering

    static func attributed(from markdown: String) -> NSAttributedString {
        render(markdown).text
    }

    /// The whole note, laid out. `caret` is where the typist is, in source
    /// coordinates: the line it falls on is shown as it is written.
    /// Renders a note.
    ///
    /// `width` is the room a line has, which formulas need: one that does not
    /// fit is broken across lines rather than run off the edge of the pane.
    static func render(
        _ source: String, caret: Int? = nil, raw: Bool = false, width: CGFloat? = nil
    ) -> Rendered {
        available = width
        let text = source as NSString
        if raw {
            let whole = NSMutableAttributedString(string: source, attributes: rawAttributes)
            return Rendered(
                text: whole,
                pieces: [(NSRange(location: 0, length: whole.length),
                          NSRange(location: 0, length: text.length))]
            )
        }

        let result = NSMutableAttributedString()
        var pieces: [(display: NSRange, source: NSRange)] = []

        func append(_ piece: NSAttributedString, source range: NSRange) {
            guard piece.length > 0 else { return }
            let start = result.length
            result.append(piece)
            pieces.append((NSRange(location: start, length: piece.length), range))
        }

        for lineRange in lines(of: text) {
            let line = text.substring(with: lineRange)
            let revealed = caret.map {
                $0 >= lineRange.location && $0 <= lineRange.location + lineRange.length
            } ?? false
            let block = Block(line: line)
            let style = block.paragraphStyle
            let markerLength = (block.marker as NSString).length

            if markerLength > 0 {
                let shown = revealed ? block.marker : block.shownMarker
                var attributes: [NSAttributedString.Key: Any] = revealed
                    ? [.font: block.font, .foregroundColor: syntaxColor]
                    : [.font: block.markerFont, .foregroundColor: block.markerColor]
                attributes[.paragraphStyle] = style
                let piece = NSMutableAttributedString(string: shown, attributes: attributes)
                if shown != block.marker {
                    piece.addAttribute(.paperTimeSource, value: block.marker,
                                       range: NSRange(location: 0, length: piece.length))
                }
                append(piece, source: NSRange(location: lineRange.location, length: markerLength))
            }

            let contentStart = lineRange.location + markerLength
            let content = block.content as NSString
            var index = 0
            while index < content.length {
                let rest = NSRange(location: index, length: content.length - index)
                guard !revealed, let token = nextToken(in: content, from: index) else {
                    append(
                        NSAttributedString(string: content.substring(with: rest),
                                           attributes: block.attributes(style: style)),
                        source: NSRange(location: contentStart + index, length: rest.length)
                    )
                    break
                }
                if token.range.location > index {
                    let plain = NSRange(location: index, length: token.range.location - index)
                    append(
                        NSAttributedString(string: content.substring(with: plain),
                                           attributes: block.attributes(style: style)),
                        source: NSRange(location: contentStart + plain.location,
                                        length: plain.length)
                    )
                }
                append(
                    piece(for: token, block: block, style: style),
                    source: NSRange(location: contentStart + token.range.location,
                                    length: token.range.length)
                )
                index = token.range.location + token.range.length
            }

            let newline = lineRange.location + lineRange.length
            if newline < text.length {
                append(
                    NSAttributedString(string: "\n", attributes: [
                        .font: bodyFont,
                        .foregroundColor: NoteColor.labelColor,
                        .paragraphStyle: style,
                    ]),
                    source: NSRange(location: newline, length: 1)
                )
            }
        }

        return Rendered(text: result, pieces: pieces)
    }

    // MARK: - Blocks

    /// What kind of line this is, and what the characters at its head mean.
    struct Block {
        enum Kind: Equatable { case plain, heading(Int), quote, bullet, ordered(Int), task(Bool) }

        var kind: Kind = .plain
        var marker = ""
        var content = ""
        var indent = 0

        init(line: String) {
            let text = line as NSString
            var spaces = 0
            while spaces < text.length,
                  text.substring(with: NSRange(location: spaces, length: 1)) == " " {
                spaces += 1
            }
            indent = spaces / 2
            let body = text.substring(from: spaces) as NSString
            let lead = String(repeating: " ", count: spaces)
            let whole = NSRange(location: 0, length: body.length)

            func take(_ pattern: NSRegularExpression) -> NSTextCheckingResult? {
                pattern.firstMatch(in: body as String, range: whole)
            }

            if let match = take(Self.taskPattern) {
                marker = lead + body.substring(with: match.range)
                content = body.substring(from: match.range.length)
                kind = .task(body.substring(with: match.range(at: 2)).lowercased() == "x")
            } else if let match = take(Self.headingPattern) {
                marker = lead + body.substring(with: match.range)
                content = body.substring(from: match.range.length)
                kind = .heading(body.substring(with: match.range(at: 1)).count)
            } else if let match = take(Self.bulletPattern) {
                marker = lead + body.substring(with: match.range)
                content = body.substring(from: match.range.length)
                kind = .bullet
            } else if let match = take(Self.orderedPattern) {
                marker = lead + body.substring(with: match.range)
                content = body.substring(from: match.range.length)
                kind = .ordered(Int(body.substring(with: match.range(at: 1))) ?? 1)
            } else if body.hasPrefix(">") {
                let after = body.hasPrefix("> ") ? 2 : 1
                marker = lead + body.substring(to: after)
                content = body.substring(from: after)
                kind = .quote
            } else {
                marker = ""
                content = line
            }
        }

        /// What stands in for the marker when the line is not being edited.
        var shownMarker: String {
            switch kind {
            case .plain: ""
            case .heading, .quote: NoteMarkdown.hiddenMarker
            case .bullet: "•\t"
            case .ordered(let number): "\(number).\t"
            case .task(let done): done ? "☑\t" : "☐\t"
            }
        }

        var font: NoteFont {
            switch kind {
            case .heading(let level): NoteTypography.heading(level: level)
            case .quote: NoteTypography.body(italic: true)
            default: NoteTypography.body()
            }
        }

        var markerFont: NoteFont {
            switch kind {
            case .heading(let level): NoteTypography.heading(level: level)
            default: NoteTypography.body()
            }
        }

        var markerColor: NoteColor {
            switch kind {
            case .task(let done): done ? .secondaryLabelColor : .labelColor
            default: .secondaryLabelColor
            }
        }

        var colour: NoteColor {
            switch kind {
            case .quote: .secondaryLabelColor
            case .task(let done): done ? .secondaryLabelColor : .labelColor
            default: .labelColor
            }
        }

        func attributes(style: NSParagraphStyle) -> [NSAttributedString.Key: Any] {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: colour,
                .paragraphStyle: style,
            ]
            if case .task(true) = kind {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            return attributes
        }

        /// Wrapped lines of a list item line up under the first word rather
        /// than under the bullet — what every outliner does and no plain text
        /// view does by itself.
        var paragraphStyle: NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 2
            style.paragraphSpacing = 3
            let step = NoteTypography.baseSize * 1.5
            switch kind {
            case .bullet, .ordered, .task:
                let base = step * CGFloat(indent + 1)
                style.firstLineHeadIndent = base - step * 0.62
                style.headIndent = base
                style.tabStops = [NSTextTab(textAlignment: .left, location: base)]
            case .quote:
                style.firstLineHeadIndent = step * 0.8
                style.headIndent = step * 0.8
            case .heading:
                style.paragraphSpacing = 5
                style.paragraphSpacingBefore = 9
            case .plain:
                break
            }
            return style
        }

        static let headingPattern = try! NSRegularExpression(pattern: #"^(#{1,6})\s+"#)
        static let bulletPattern = try! NSRegularExpression(pattern: #"^[-*+]\s+"#)
        static let orderedPattern = try! NSRegularExpression(pattern: #"^(\d{1,3})[.)]\s+"#)
        static let taskPattern = try! NSRegularExpression(pattern: #"^([-*+])\s+\[([ xX])\]\s+"#)
    }

    // MARK: - Lines

    static func lines(of text: NSString) -> [NSRange] {
        var result: [NSRange] = []
        var start = 0
        while start <= text.length {
            let searchRange = NSRange(location: start, length: text.length - start)
            let newline = text.range(of: "\n", range: searchRange)
            if newline.location == NSNotFound {
                result.append(searchRange)
                break
            }
            result.append(NSRange(location: start, length: newline.location - start))
            start = newline.location + 1
            if start == text.length {
                result.append(NSRange(location: start, length: 0))
                break
            }
        }
        return result
    }

    // MARK: - Inline

    private enum Kind {
        case anchorLink(label: String, url: URL)
        case noteLink(id: String, title: String)
        case math(latex: String, display: Bool)
        case emphasis(text: String, bold: Bool, italic: Bool, mono: Bool, source: String)
    }

    private struct Token {
        var range: NSRange
        var kind: Kind
    }

    private static let linkPattern = try! NSRegularExpression(
        pattern: #"\[((?:\\.|[^\\\]\n]|\](?!\())*)\]\((papertime://[^)\s]+)\)"#
    )
    private static let wikiPattern = try! NSRegularExpression(
        pattern: #"\[\[([^\]|\n]+)(?:\|([^\]\n]*))?\]\]"#
    )
    private static let mathPattern = try! NSRegularExpression(
        pattern: #"(\$\$)([^$]+)(\$\$)|(\$)([^$\n]+)(\$)"#
    )
    private static let emphasisPattern = try! NSRegularExpression(
        pattern: #"(\*\*)([^*\n]+)(\*\*)|(\*)([^*\n]+)(\*)|(`)([^`\n]+)(`)"#
    )

    private static func nextToken(in line: NSString, from index: Int) -> Token? {
        let range = NSRange(location: index, length: line.length - index)
        var best: Token?

        func consider(_ token: Token?) {
            guard let token else { return }
            if best == nil || token.range.location < best!.range.location { best = token }
        }

        if let match = linkPattern.firstMatch(in: line as String, range: range),
           let url = URL(string: line.substring(with: match.range(at: 2))) {
            consider(Token(range: match.range, kind: .anchorLink(
                label: unescape(line.substring(with: match.range(at: 1))), url: url
            )))
        }
        if let match = wikiPattern.firstMatch(in: line as String, range: range) {
            let target = line.substring(with: match.range(at: 1))
            let shown = match.range(at: 2).location == NSNotFound
                ? target : line.substring(with: match.range(at: 2))
            consider(Token(range: match.range, kind: .noteLink(id: target, title: shown)))
        }
        if let match = mathPattern.firstMatch(in: line as String, range: range) {
            let display = match.range(at: 2).location != NSNotFound
            let body = display ? match.range(at: 2) : match.range(at: 5)
            if body.location != NSNotFound {
                consider(Token(range: match.range, kind: .math(
                    latex: line.substring(with: body), display: display
                )))
            }
        }
        if let match = emphasisPattern.firstMatch(in: line as String, range: range) {
            let groups = [(2, true, false, false), (5, false, true, false), (8, false, false, true)]
            for (group, bold, italic, mono) in groups
            where match.range(at: group).location != NSNotFound {
                consider(Token(range: match.range, kind: .emphasis(
                    text: line.substring(with: match.range(at: group)),
                    bold: bold, italic: italic, mono: mono,
                    source: line.substring(with: match.range)
                )))
                break
            }
        }
        return best
    }

    private static func piece(
        for token: Token, block: Block, style: NSParagraphStyle
    ) -> NSAttributedString {
        switch token.kind {
        case .anchorLink(let label, let url):
            return atomic(label, source: "[\(escape(label))](\(url.absoluteString))",
                          attributes: linkAttributes(url), style: style)

        case .noteLink(let id, let title):
            let shown = title.isEmpty ? id : title
            let source = title.isEmpty ? "[[\(id)]]" : "[[\(id)|\(title)]]"
            return atomic(shown, source: source,
                          attributes: linkAttributes(noteURL(id: id)), style: style)

        case .math(let latex, let display):
            #if os(macOS)
            if let piece = mathPiece(latex: latex, display: display,
                                     size: NoteTypography.baseSize, style: style,
                                     width: available) {
                return piece
            }
            #endif
            let marker = display ? "$$" : "$"
            return NSAttributedString(string: "\(marker)\(latex)\(marker)", attributes: [
                .font: NoteTypography.mono(),
                .foregroundColor: NoteColor.secondaryLabelColor,
                .paragraphStyle: style,
            ])

        case .emphasis(let text, let bold, let italic, let mono, let source):
            var attributes: [NSAttributedString.Key: Any] = [
                .font: mono ? NoteTypography.mono()
                            : NoteTypography.body(bold: bold, italic: italic),
                .foregroundColor: NoteColor.labelColor,
            ]
            if mono { attributes[.backgroundColor] = NoteColor.quaternaryLabelColor }
            return atomic(text, source: source, attributes: attributes, style: style)
        }
    }

    private static func atomic(
        _ shown: String, source: String,
        attributes: [NSAttributedString.Key: Any], style: NSParagraphStyle
    ) -> NSAttributedString {
        var attributes = attributes
        attributes[.paragraphStyle] = style
        let piece = NSMutableAttributedString(string: shown, attributes: attributes)
        piece.addAttribute(.paperTimeSource, value: source,
                           range: NSRange(location: 0, length: piece.length))
        return piece
    }

    #if os(macOS)
    /// Formulas are drawn once and kept as images. The attachment around an
    /// image is made fresh every time: one attachment shared between two text
    /// storages is one attachment too few for TextKit.
    private nonisolated(unsafe) static var mathCache: [String: (image: NSImage, descent: CGFloat)] = [:]

    private static func mathPiece(
        latex: String, display: Bool, size: CGFloat, style: NSParagraphStyle,
        width: CGFloat?
    ) -> NSAttributedString? {
        // Rounded, so nudging the pane by a point does not redraw every
        // formula in the note.
        let room = width.map { max(80, ($0 / 8).rounded(.down) * 8) }
        let key = "\(display ? "D" : "I")|\(size)|\(room ?? 0)|\(latex)"
        let drawn: (image: NSImage, descent: CGFloat)
        if let cached = mathCache[key] {
            drawn = cached
        } else {
            guard let made = MathTypesetter.image(
                latex: latex, display: display,
                pointSize: size * (display ? 1.15 : 1), color: .labelColor,
                maxWidth: room
            ) else { return nil }
            if mathCache.count > 400 { mathCache.removeAll() }
            mathCache[key] = made
            drawn = made
        }

        let attachment = NSTextAttachment()
        attachment.image = drawn.image
        attachment.bounds = CGRect(x: 0, y: -drawn.descent,
                                   width: drawn.image.size.width,
                                   height: drawn.image.size.height)
        let piece = NSMutableAttributedString(attachment: attachment)
        let marker = display ? "$$" : "$"
        piece.addAttributes([
            .paperTimeSource: "\(marker)\(latex)\(marker)",
            .font: NoteTypography.body(),
            .foregroundColor: NoteColor.labelColor,
            .paragraphStyle: style,
        ], range: NSRange(location: 0, length: piece.length))
        return piece
    }
    #endif
}
