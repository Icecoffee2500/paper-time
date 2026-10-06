#if os(macOS)
import AppKit
import PaperCore

/// A note's table, drawn: what `NoteMarkdown` shows in place of its lines
/// while the caret is somewhere else.
enum NoteTableDrawing {
    static let padding = CGSize(width: 9, height: 5)

    /// The table at no more than `width` points wide; columns share the room
    /// in proportion to what they hold and wrap when they have to.
    static func image(_ table: NoteTable.Table, width: CGFloat, appearance: NSAppearance) -> NSImage? {
        let columns = table.header.count
        guard columns > 0 else { return nil }
        var ink = NSColor.labelColor, rule = NSColor.separatorColor, ground = NSColor.quaternaryLabelColor
        appearance.performAsCurrentDrawingAppearance {
            ink = NSColor(cgColor: NSColor.labelColor.cgColor) ?? .labelColor
            rule = NSColor(cgColor: NSColor.separatorColor.cgColor) ?? .separatorColor
            ground = NSColor(cgColor: NSColor.labelColor.withAlphaComponent(0.05).cgColor) ?? .clear
        }
        var code = NoteCodeStyle.ink, codeFill = NoteCodeStyle.fill
        appearance.performAsCurrentDrawingAppearance {
            code = NSColor(cgColor: NoteCodeStyle.ink.cgColor) ?? NoteCodeStyle.ink
            codeFill = NSColor(cgColor: NoteCodeStyle.fill.cgColor) ?? NoteCodeStyle.fill
        }
        let body = NoteTypography.body()
        let rows = [table.header] + table.rows

        func text(_ cell: String, header: Bool, column: Int) -> NSAttributedString {
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byWordWrapping
            style.lineBreakStrategy = .standard
            switch column < table.alignments.count ? table.alignments[column] : .none {
            case .center: style.alignment = .center
            case .right: style.alignment = .right
            default: style.alignment = .natural
            }
            // The cell's emphasis as emphasis: it was only taken out, so
            // `*기울*` stayed as written.
            let words = NSMutableAttributedString()
            for piece in NoteMarkdown.emphasisPieces(lines(cell)) {
                var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: ink, .paragraphStyle: style]
                if piece.mono {
                    attributes[.font] = NoteTypography.code(size: body.pointSize)
                    attributes[.foregroundColor] = code
                    attributes[.backgroundColor] = codeFill
                } else {
                    attributes[.font] = NoteTypography.body(bold: header || piece.bold, italic: piece.italic)
                }
                words.append(NSAttributedString(string: piece.text, attributes: attributes))
            }
            NoteTypography.slantHangul(in: words, range: NSRange(location: 0, length: words.length))
            return words
        }

        // What each column would like, on one line, and what it gets.
        var natural = [CGFloat](repeating: 0, count: columns)
        for (index, row) in rows.enumerated() {
            for column in 0..<columns {
                let cell = column < row.count ? row[column] : ""
                let size = text(cell, header: index == 0, column: column).size()
                natural[column] = max(natural[column], ceil(size.width) + padding.width * 2)
            }
        }
        // Room shared the way a browser shares it: a column that asks for
        // less than its share gets what it asks for, and what is left is
        // split among the ones that ask for more — so a year stays on one
        // line and the long sentence beside it wraps.
        var widths = natural
        if natural.reduce(0, +) > width {
            var open = Set(0..<columns)
            var room = width
            var settled = true
            repeat {
                settled = true
                let share = room / CGFloat(max(open.count, 1))
                for column in open where natural[column] <= share {
                    widths[column] = natural[column]
                    room -= natural[column]
                    open.remove(column)
                    settled = false
                }
            } while !settled && !open.isEmpty
            let share = max(48, room / CGFloat(max(open.count, 1)))
            for column in open { widths[column] = share }
        }
        let tableWidth = ceil(widths.reduce(0, +))

        var heights: [CGFloat] = []
        for (index, row) in rows.enumerated() {
            var tallest: CGFloat = 0
            for column in 0..<columns {
                let cell = column < row.count ? row[column] : ""
                let bounds = text(cell, header: index == 0, column: column).boundingRect(
                    with: CGSize(width: widths[column] - padding.width * 2, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading]
                )
                tallest = max(tallest, ceil(bounds.height))
            }
            heights.append(max(tallest, ceil(body.ascender - body.descender + body.leading)) + padding.height * 2)
        }
        let size = CGSize(width: tableWidth + 1, height: ceil(heights.reduce(0, +)) + 1)

        let image = NSImage(size: size, flipped: true) { _ in
            let frame = CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)
            let outline = NSBezierPath(roundedRect: frame, xRadius: Corner.row - 2, yRadius: Corner.row - 2)
            NSGraphicsContext.saveGraphicsState()
            outline.addClip()
            ground.setFill()
            CGRect(x: 0, y: 0, width: size.width, height: heights[0]).fill()
            rule.setFill()
            var y: CGFloat = 0
            for (index, height) in heights.enumerated() {
                if index > 0 { CGRect(x: 0, y: y, width: size.width, height: 1).fill() }
                var x: CGFloat = 0
                for column in 0..<columns {
                    if column > 0 { CGRect(x: x, y: y, width: 1, height: height).fill() }
                    let row = rows[index]
                    let cell = column < row.count ? row[column] : ""
                    text(cell, header: index == 0, column: column).draw(
                        with: CGRect(x: x + padding.width, y: y + padding.height,
                                     width: widths[column] - padding.width * 2, height: height - padding.height * 2),
                        options: [.usesLineFragmentOrigin, .usesFontLeading]
                    )
                    rule.setFill()
                    x += widths[column]
                }
                y += height
            }
            NSGraphicsContext.restoreGraphicsState()
            rule.setStroke()
            outline.lineWidth = 1
            outline.stroke()
            return true
        }
        return image
    }

    /// A cell's line breaks, which a table writes as `<br>`.
    static func lines(_ cell: String) -> String {
        cell.replacingOccurrences(of: "<br>", with: "\n").replacingOccurrences(of: "<br/>", with: "\n")
    }
}
#endif
