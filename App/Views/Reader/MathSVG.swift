#if os(macOS)
import AppKit
import CoreText

/// A formula MathJax set, as something Core Graphics can draw.
///
/// MathJax's SVG output is a small language — groups with transforms, paths
/// for every glyph (the fonts come as outlines, so nothing is to be loaded),
/// rectangles for bars and backgrounds, lines for a table's rules, now and
/// then a piece of text for a letter its fonts do not have — and this reads
/// exactly that much of it, once, into a list of shapes, and draws them in
/// whatever colour the note is written in. `currentColor` means nothing
/// outside a browser, and a picture drawn as paths stays sharp at any zoom.
///
/// A displayed formula with numbers — `\tag`, an `align` — is set by MathJax
/// for a web page: as wide as the page, the formula centred in it and the
/// numbers at the right-hand edge, by nested `<svg>`s that each fill the page
/// and place their content by `preserveAspectRatio`. That is read the same way
/// here, with the width the note gives it.
///
/// What a browser shows is not always inside the box MathJax declares — the
/// label of a `CD` arrow, a `\llap` — because a browser does not clip it. The
/// picture here is the box and whatever ink falls outside it, so nothing is
/// cut off either.
struct MathSVG {
    /// The formula's size in points, and how far of it is below the baseline.
    let size: CGSize
    let descent: CGFloat

    private let shapes: [Shape]
    /// How many points one of the root's user units is.
    private let unit: CGFloat
    /// What is drawn, in the root's user units (y down): the declared box and
    /// any ink outside it.
    private let extent: CGRect

    /// MathJax's `ex`, in its own pixels, with no page to measure it on.
    static let exPixels: CGFloat = 8
    /// And its `em`: an `ex` is 0.442 em in the TeX fonts.
    static let emPixels: CGFloat = 8 / 0.442

    /// One thing to draw, in the root's user space once `transform` is applied.
    private struct Shape {
        enum Figure {
            case path(CGPath)
            case text(String, size: CGFloat, sans: Bool)
        }
        var figure: Figure
        var transform: CGAffineTransform
        var fill: Paint?
        var stroke: Paint?
        var strokeWidth: CGFloat
    }

    /// A colour: the note's own, or one the formula names.
    private enum Paint {
        case current
        case fixed(CGColor)
    }

    /// Reads MathJax's markup for a formula set at `pointSize`. `width`, in
    /// points, is the room a formula with numbers is laid out in; without it,
    /// one is as wide as its content.
    init?(markup: String, pointSize: CGFloat, width: CGFloat?) {
        guard let root = Self.parse(markup), root.name == "svg" else { return nil }
        let attributes = root.attributes
        let unit: CGFloat
        let viewport: CGRect
        let baseline: CGFloat
        if let box = Self.numbers(attributes["viewBox"]), box.count == 4, box[2] > 0, box[3] > 0 {
            // An ordinary formula: its view box is in MathJax's units, a
            // thousandth of an em, with the baseline at zero.
            unit = pointSize / 1000
            viewport = CGRect(x: box[0], y: box[1], width: box[2], height: box[3])
            baseline = 0
        } else {
            // A formula with numbers: the root is a viewport in MathJax's
            // pixels, as wide as the page — here, the room it is given — and
            // never narrower than its own content.
            guard let heightEx = Self.ex(attributes["height"]) else { return nil }
            unit = pointSize / Self.emPixels
            let minimum = (Self.property("min-width", in: attributes["style"]) ?? 0) * Self.exPixels
            let wide = max(minimum, (width ?? 0) / unit)
            let high = heightEx * Self.exPixels
            guard wide > 0, high > 0 else { return nil }
            viewport = CGRect(x: 0, y: 0, width: wide, height: high)
            let depth = -(Self.property("vertical-align", in: attributes["style"]) ?? 0) * Self.exPixels
            baseline = high - depth
        }

        var shapes: [Shape] = []
        let walker = Walker(viewport: viewport)
        let style = Walker.Style(fill: .current, stroke: .current, strokeWidth: 0)
        for child in root.children {
            walker.walk(child, transform: .identity, style: style, into: &shapes)
        }

        var ink = CGRect.null
        for shape in shapes {
            let box: CGRect
            switch shape.figure {
            case .path(let path):
                box = path.boundingBoxOfPath
            case .text(let text, let size, let sans):
                let line = CTLineCreateWithAttributedString(Self.attributed(text, size: size, sans: sans, color: nil))
                let bounds = CTLineGetBoundsWithOptions(line, [])
                // Drawn with its y flipped (see `draw`).
                box = CGRect(x: bounds.minX, y: -bounds.maxY, width: bounds.width, height: bounds.height)
            }
            guard !box.isNull, box.minX.isFinite, box.minY.isFinite, box.width.isFinite, box.height.isFinite
            else { continue }
            let pad = shape.stroke != nil ? shape.strokeWidth / 2 : 0
            ink = ink.union(box.insetBy(dx: -pad, dy: -pad).applying(shape.transform))
        }
        // Ink outside the declared box by more than a hair is drawn, not cut:
        // a fiftieth of an em, so a glyph's own overshoot changes nothing.
        var extent = viewport
        if !ink.isNull, ink.minX.isFinite, ink.width.isFinite, ink.height.isFinite {
            let slack = pointSize / 50 / unit
            if ink.minX < viewport.minX - slack || ink.maxX > viewport.maxX + slack
                || ink.minY < viewport.minY - slack || ink.maxY > viewport.maxY + slack {
                extent = viewport.union(ink)
            }
        }
        guard extent.width > 0, extent.height > 0, extent.width.isFinite, extent.height.isFinite else { return nil }

        self.shapes = shapes
        self.unit = unit
        self.extent = extent
        self.size = CGSize(width: extent.width * unit, height: extent.height * unit)
        self.descent = (extent.maxY - baseline) * unit
    }

    /// Draws the formula with its lower-left corner at `origin`, in a context
    /// whose y runs up, in `color` wherever the formula names no colour.
    func draw(in context: CGContext, at origin: CGPoint, color: CGColor) {
        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y)
        // From the SVG's coordinates, whose y runs down, to the context's.
        context.scaleBy(x: unit, y: -unit)
        context.translateBy(x: -extent.minX, y: -extent.maxY)
        for shape in shapes {
            context.saveGState()
            context.concatenate(shape.transform)
            switch shape.figure {
            case .path(let path):
                if let fill = shape.fill {
                    context.addPath(path)
                    context.setFillColor(Self.resolve(fill, color))
                    context.fillPath()
                }
                if let stroke = shape.stroke, shape.strokeWidth > 0 {
                    context.addPath(path)
                    context.setStrokeColor(Self.resolve(stroke, color))
                    context.setLineWidth(shape.strokeWidth)
                    context.strokePath()
                }
            case .text(let text, let size, let sans):
                guard let fill = shape.fill else { break }
                let line = CTLineCreateWithAttributedString(
                    Self.attributed(text, size: size, sans: sans, color: Self.resolve(fill, color))
                )
                // The text's own transform turns it upright in the SVG's
                // coordinates, whose y runs down; Core Text draws with y up.
                context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
                context.textPosition = .zero
                CTLineDraw(line, context)
            }
            context.restoreGState()
        }
        context.restoreGState()
    }

    private static func resolve(_ paint: Paint, _ current: CGColor) -> CGColor {
        switch paint {
        case .current: return current
        case .fixed(let color): return color
        }
    }

    /// A letter MathJax's fonts do not have — a word of Korean in `\text` —
    /// set in the system's font at MathJax's size for it.
    private static func attributed(_ text: String, size: CGFloat, sans: Bool, color: CGColor?) -> NSAttributedString {
        let font = sans
            ? CTFontCreateUIFontForLanguage(.system, size, nil)
            : CTFontCreateWithName("Times New Roman" as CFString, size, nil)
        var attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font as Any,
        ]
        if let color { attributes[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = color }
        return NSAttributedString(string: text, attributes: attributes)
    }

    // MARK: - Walking the tree

    private struct Walker {
        /// The root's viewport, which a nested `<svg>` fills.
        let viewport: CGRect

        struct Style {
            var fill: Paint?
            var stroke: Paint?
            var strokeWidth: CGFloat
        }

        func walk(_ node: Node, transform inherited: CGAffineTransform, style inheritedStyle: Style,
                  into shapes: inout [Shape]) {
            var style = inheritedStyle
            let attributes = node.attributes
            if let fill = attributes["fill"] { style.fill = MathSVG.paint(fill) }
            if let stroke = attributes["stroke"] { style.stroke = MathSVG.paint(stroke) }
            if let width = attributes["stroke-width"], let value = MathSVG.number(width) { style.strokeWidth = value }
            var transform = inherited
            if let written = attributes["transform"] {
                // Applied inside what is already there.
                transform = MathSVG.transform(written).concatenating(transform)
            }

            switch node.name {
            case "svg":
                // A nested viewport as wide and tall as the page: its view box
                // placed in it by its `preserveAspectRatio`, as a browser would.
                let x = MathSVG.number(attributes["x"] ?? "0") ?? 0
                let y = MathSVG.number(attributes["y"] ?? "0") ?? 0
                let width = MathSVG.length(attributes["width"], of: viewport.width)
                let height = MathSVG.length(attributes["height"], of: viewport.height)
                var inner = CGAffineTransform(translationX: x, y: y)
                if let box = MathSVG.numbers(attributes["viewBox"]), box.count == 4, box[2] > 0, box[3] > 0 {
                    let scale = min(width / box[2], height / box[3])
                    let align = attributes["preserveAspectRatio"] ?? "xMidYMid"
                    let slackX = width - box[2] * scale, slackY = height - box[3] * scale
                    let dx = align.hasPrefix("xMin") ? 0 : align.hasPrefix("xMax") ? slackX : slackX / 2
                    let dy = align.contains("YMin") ? 0 : align.contains("YMax") ? slackY : slackY / 2
                    inner = CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                                              tx: dx - box[0] * scale, ty: dy - box[1] * scale)
                        .concatenating(inner)
                }
                let placed = inner.concatenating(transform)
                for child in node.children { walk(child, transform: placed, style: style, into: &shapes) }

            case "path":
                guard let data = attributes["d"], let path = MathSVG.path(data) else { return }
                add(.path(path), transform, style, &shapes)

            case "rect":
                let rect = CGRect(x: MathSVG.number(attributes["x"] ?? "0") ?? 0,
                                  y: MathSVG.number(attributes["y"] ?? "0") ?? 0,
                                  width: MathSVG.number(attributes["width"] ?? "0") ?? 0,
                                  height: MathSVG.number(attributes["height"] ?? "0") ?? 0)
                guard rect.width >= 0, rect.height >= 0 else { return }
                add(.path(CGPath(rect: rect, transform: nil)), transform, style, &shapes)

            case "line":
                let path = CGMutablePath()
                path.move(to: CGPoint(x: MathSVG.number(attributes["x1"] ?? "0") ?? 0,
                                      y: MathSVG.number(attributes["y1"] ?? "0") ?? 0))
                path.addLine(to: CGPoint(x: MathSVG.number(attributes["x2"] ?? "0") ?? 0,
                                         y: MathSVG.number(attributes["y2"] ?? "0") ?? 0))
                var line = style
                // A table's rules get their width from MathJax's style sheet,
                // which is not in the markup: 70 of its units.
                if attributes["stroke-width"] == nil, attributes["data-line"] != nil { line.strokeWidth = 70 }
                line.fill = nil
                add(.path(path), transform, line, &shapes)

            case "ellipse", "circle":
                let cx = MathSVG.number(attributes["cx"] ?? "0") ?? 0
                let cy = MathSVG.number(attributes["cy"] ?? "0") ?? 0
                let rx = MathSVG.number(attributes["rx"] ?? attributes["r"] ?? "0") ?? 0
                let ry = MathSVG.number(attributes["ry"] ?? attributes["r"] ?? "0") ?? 0
                let path = CGPath(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2),
                                  transform: nil)
                add(.path(path), transform, style, &shapes)

            case "polygon", "polyline":
                let values = MathSVG.numbers(attributes["points"]) ?? []
                guard values.count >= 4 else { return }
                let path = CGMutablePath()
                path.move(to: CGPoint(x: values[0], y: values[1]))
                var index = 2
                while index + 1 < values.count {
                    path.addLine(to: CGPoint(x: values[index], y: values[index + 1]))
                    index += 2
                }
                if node.name == "polygon" { path.closeSubpath() }
                add(.path(path), transform, style, &shapes)

            case "text":
                let text = node.text
                guard !text.isEmpty else { return }
                let size = MathSVG.number(attributes["font-size"] ?? "") ?? 1000
                let sans = (attributes["font-family"] ?? "").contains("sans")
                add(.text(text, size: size, sans: sans), transform, style, &shapes)

            case "defs", "title", "desc", "style", "clipPath", "mask", "metadata", "symbol":
                return

            default:
                // A group, and a reference — a link around its number — is
                // drawn as one.
                for child in node.children { walk(child, transform: transform, style: style, into: &shapes) }
            }
        }

        private func add(_ figure: Shape.Figure, _ transform: CGAffineTransform, _ style: Style,
                         _ shapes: inout [Shape]) {
            shapes.append(Shape(figure: figure, transform: transform, fill: style.fill,
                                stroke: style.stroke, strokeWidth: style.strokeWidth))
        }
    }

    // MARK: - Reading the markup

    /// One element: its name, its attributes, and what is inside it.
    private final class Node {
        let name: String
        let attributes: [String: String]
        var children: [Node] = []
        var text = ""
        init(name: String, attributes: [String: String]) {
            self.name = name
            self.attributes = attributes
        }
    }

    /// MathJax's markup is regular and always well formed — elements,
    /// double-quoted attributes, a little text, the five entities and the
    /// numeric ones — so it is read here a byte at a time. Foundation's XML
    /// parser took half a millisecond a formula, and a note of two hundred
    /// formulas felt that.
    private static func parse(_ markup: String) -> Node? {
        let bytes = Array(markup.utf8)
        let count = bytes.count
        var index = 0
        var stack: [Node] = []
        var root: Node?
        func text(_ range: Range<Int>) -> String {
            let raw = String(decoding: bytes[range], as: UTF8.self)
            return raw.contains("&") ? unescaped(raw) : raw
        }
        func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 }
        let open = UInt8(ascii: "<"), close = UInt8(ascii: ">"), slash = UInt8(ascii: "/")
        let equals = UInt8(ascii: "=")
        while index < count {
            guard bytes[index] == open else {
                let start = index
                while index < count, bytes[index] != open { index += 1 }
                stack.last?.text += text(start..<index)
                continue
            }
            index += 1
            guard index < count else { break }
            if bytes[index] == slash {
                while index < count, bytes[index] != close { index += 1 }
                index += 1
                _ = stack.popLast()
                continue
            }
            if bytes[index] == UInt8(ascii: "!") || bytes[index] == UInt8(ascii: "?") {
                // A comment or a declaration: nothing to draw.
                let comment = index + 2 < count && bytes[index + 1] == UInt8(ascii: "-")
                while index < count {
                    if bytes[index] == close, !comment || (index >= 2 && bytes[index - 1] == UInt8(ascii: "-")
                                                            && bytes[index - 2] == UInt8(ascii: "-")) { break }
                    index += 1
                }
                index += 1
                continue
            }
            let nameStart = index
            while index < count, !isSpace(bytes[index]), bytes[index] != close, bytes[index] != slash { index += 1 }
            let name = String(decoding: bytes[nameStart..<index], as: UTF8.self)
            var attributes: [String: String] = [:]
            var closed = false
            while index < count {
                while index < count, isSpace(bytes[index]) { index += 1 }
                guard index < count else { break }
                if bytes[index] == close { index += 1; break }
                if bytes[index] == slash { closed = true; index += 1; continue }
                let keyStart = index
                while index < count, bytes[index] != equals, !isSpace(bytes[index]),
                      bytes[index] != close, bytes[index] != slash { index += 1 }
                let key = String(decoding: bytes[keyStart..<index], as: UTF8.self)
                while index < count, isSpace(bytes[index]) { index += 1 }
                guard index < count, bytes[index] == equals else {
                    attributes[key] = ""
                    continue
                }
                index += 1
                while index < count, isSpace(bytes[index]) { index += 1 }
                guard index < count else { break }
                let quote = bytes[index]
                index += 1
                let valueStart = index
                while index < count, bytes[index] != quote { index += 1 }
                attributes[key] = text(valueStart..<min(index, count))
                index += 1
            }
            let node = Node(name: name, attributes: attributes)
            if let parent = stack.last { parent.children.append(node) } else if root == nil { root = node }
            if !closed { stack.append(node) }
        }
        return root
    }

    /// `&amp;` and its kind, and `&#…;`.
    private static func unescaped(_ text: String) -> String {
        var result = ""
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            result += rest[..<amp]
            guard let semicolon = rest[amp...].firstIndex(of: ";") else {
                result += rest[amp...]
                return result
            }
            let entity = rest[rest.index(after: amp)..<semicolon]
            switch entity {
            case "amp": result += "&"
            case "lt": result += "<"
            case "gt": result += ">"
            case "quot": result += "\""
            case "apos": result += "'"
            default:
                var scalar: UInt32?
                if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                    scalar = UInt32(entity.dropFirst(2), radix: 16)
                } else if entity.hasPrefix("#") {
                    scalar = UInt32(entity.dropFirst())
                }
                if let scalar, let character = Unicode.Scalar(scalar) {
                    result.unicodeScalars.append(character)
                } else {
                    result += rest[amp...semicolon]
                }
            }
            rest = rest[rest.index(after: semicolon)...]
        }
        result += rest
        return result
    }

    private static func paint(_ value: String) -> Paint? {
        let written = value.trimmingCharacters(in: .whitespaces)
        switch written.lowercased() {
        case "none", "transparent": return nil
        case "currentcolor", "": return .current
        default:
            return color(written).map(Paint.fixed) ?? .current
        }
    }

    /// A colour as CSS writes it: `#rgb`, `#rrggbb`, `rgb(…)`, or a name.
    static func color(_ written: String) -> CGColor? {
        let text = written.trimmingCharacters(in: .whitespaces).lowercased()
        func rgb(_ value: Int) -> CGColor {
            CGColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                    blue: CGFloat(value & 0xFF) / 255, alpha: 1)
        }
        if text.hasPrefix("#") {
            let digits = String(text.dropFirst())
            if digits.count == 3, let value = Int(digits, radix: 16) {
                let r = (value >> 8) & 0xF, g = (value >> 4) & 0xF, b = value & 0xF
                return rgb((r * 17) << 16 | (g * 17) << 8 | (b * 17))
            }
            if digits.count == 6, let value = Int(digits, radix: 16) { return rgb(value) }
            return nil
        }
        if text.hasPrefix("rgb") {
            let inside = text.drop { $0 != "(" }.dropFirst().prefix { $0 != ")" }
            let parts = inside.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 3 else { return nil }
            func channel(_ part: String) -> CGFloat {
                part.hasSuffix("%") ? CGFloat(Double(part.dropLast()) ?? 0) / 100 : CGFloat(Double(part) ?? 0) / 255
            }
            let alpha = parts.count > 3 ? CGFloat(Double(parts[3]) ?? 1) : 1
            return CGColor(srgbRed: channel(parts[0]), green: channel(parts[1]), blue: channel(parts[2]), alpha: alpha)
        }
        return namedColors[text].map(rgb)
    }

    /// CSS's colour names, which is what `\color{red}` reaches an SVG as.
    private static let namedColors: [String: Int] = [
        "aliceblue": 0xF0F8FF, "antiquewhite": 0xFAEBD7, "aqua": 0x00FFFF, "aquamarine": 0x7FFFD4,
        "azure": 0xF0FFFF, "beige": 0xF5F5DC, "bisque": 0xFFE4C4, "black": 0x000000,
        "blanchedalmond": 0xFFEBCD, "blue": 0x0000FF, "blueviolet": 0x8A2BE2, "brown": 0xA52A2A,
        "burlywood": 0xDEB887, "cadetblue": 0x5F9EA0, "chartreuse": 0x7FFF00, "chocolate": 0xD2691E,
        "coral": 0xFF7F50, "cornflowerblue": 0x6495ED, "cornsilk": 0xFFF8DC, "crimson": 0xDC143C,
        "cyan": 0x00FFFF, "darkblue": 0x00008B, "darkcyan": 0x008B8B, "darkgoldenrod": 0xB8860B,
        "darkgray": 0xA9A9A9, "darkgreen": 0x006400, "darkgrey": 0xA9A9A9, "darkkhaki": 0xBDB76B,
        "darkmagenta": 0x8B008B, "darkolivegreen": 0x556B2F, "darkorange": 0xFF8C00, "darkorchid": 0x9932CC,
        "darkred": 0x8B0000, "darksalmon": 0xE9967A, "darkseagreen": 0x8FBC8F, "darkslateblue": 0x483D8B,
        "darkslategray": 0x2F4F4F, "darkslategrey": 0x2F4F4F, "darkturquoise": 0x00CED1, "darkviolet": 0x9400D3,
        "deeppink": 0xFF1493, "deepskyblue": 0x00BFFF, "dimgray": 0x696969, "dimgrey": 0x696969,
        "dodgerblue": 0x1E90FF, "firebrick": 0xB22222, "floralwhite": 0xFFFAF0, "forestgreen": 0x228B22,
        "fuchsia": 0xFF00FF, "gainsboro": 0xDCDCDC, "ghostwhite": 0xF8F8FF, "gold": 0xFFD700,
        "goldenrod": 0xDAA520, "gray": 0x808080, "green": 0x008000, "greenyellow": 0xADFF2F,
        "grey": 0x808080, "honeydew": 0xF0FFF0, "hotpink": 0xFF69B4, "indianred": 0xCD5C5C,
        "indigo": 0x4B0082, "ivory": 0xFFFFF0, "khaki": 0xF0E68C, "lavender": 0xE6E6FA,
        "lavenderblush": 0xFFF0F5, "lawngreen": 0x7CFC00, "lemonchiffon": 0xFFFACD, "lightblue": 0xADD8E6,
        "lightcoral": 0xF08080, "lightcyan": 0xE0FFFF, "lightgoldenrodyellow": 0xFAFAD2, "lightgray": 0xD3D3D3,
        "lightgreen": 0x90EE90, "lightgrey": 0xD3D3D3, "lightpink": 0xFFB6C1, "lightsalmon": 0xFFA07A,
        "lightseagreen": 0x20B2AA, "lightskyblue": 0x87CEFA, "lightslategray": 0x778899, "lightslategrey": 0x778899,
        "lightsteelblue": 0xB0C4DE, "lightyellow": 0xFFFFE0, "lime": 0x00FF00, "limegreen": 0x32CD32,
        "linen": 0xFAF0E6, "magenta": 0xFF00FF, "maroon": 0x800000, "mediumaquamarine": 0x66CDAA,
        "mediumblue": 0x0000CD, "mediumorchid": 0xBA55D3, "mediumpurple": 0x9370DB, "mediumseagreen": 0x3CB371,
        "mediumslateblue": 0x7B68EE, "mediumspringgreen": 0x00FA9A, "mediumturquoise": 0x48D1CC,
        "mediumvioletred": 0xC71585, "midnightblue": 0x191970, "mintcream": 0xF5FFFA, "mistyrose": 0xFFE4E1,
        "moccasin": 0xFFE4B5, "navajowhite": 0xFFDEAD, "navy": 0x000080, "oldlace": 0xFDF5E6,
        "olive": 0x808000, "olivedrab": 0x6B8E23, "orange": 0xFFA500, "orangered": 0xFF4500,
        "orchid": 0xDA70D6, "palegoldenrod": 0xEEE8AA, "palegreen": 0x98FB98, "paleturquoise": 0xAFEEEE,
        "palevioletred": 0xDB7093, "papayawhip": 0xFFEFD5, "peachpuff": 0xFFDAB9, "peru": 0xCD853F,
        "pink": 0xFFC0CB, "plum": 0xDDA0DD, "powderblue": 0xB0E0E6, "purple": 0x800080,
        "rebeccapurple": 0x663399, "red": 0xFF0000, "rosybrown": 0xBC8F8F, "royalblue": 0x4169E1,
        "saddlebrown": 0x8B4513, "salmon": 0xFA8072, "sandybrown": 0xF4A460, "seagreen": 0x2E8B57,
        "seashell": 0xFFF5EE, "sienna": 0xA0522D, "silver": 0xC0C0C0, "skyblue": 0x87CEEB,
        "slateblue": 0x6A5ACD, "slategray": 0x708090, "slategrey": 0x708090, "snow": 0xFFFAFA,
        "springgreen": 0x00FF7F, "steelblue": 0x4682B4, "tan": 0xD2B48C, "teal": 0x008080,
        "thistle": 0xD8BFD8, "tomato": 0xFF6347, "turquoise": 0x40E0D0, "violet": 0xEE82EE,
        "wheat": 0xF5DEB3, "white": 0xFFFFFF, "whitesmoke": 0xF5F5F5, "yellow": 0xFFFF00,
        "yellowgreen": 0x9ACD32,
    ]

    private static func number(_ text: String) -> CGFloat? {
        var trimmed = text.trimmingCharacters(in: .whitespaces)
        for unit in ["px", "ex", "em"] where trimmed.hasSuffix(unit) { trimmed.removeLast(unit.count) }
        return Double(trimmed).map { CGFloat($0) }
    }

    private static func numbers(_ text: String?) -> [CGFloat]? {
        guard let text else { return nil }
        let values = text.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
        return values.map { CGFloat($0) }
    }

    private static func ex(_ text: String?) -> CGFloat? {
        guard let text, text.hasSuffix("ex") else { return nil }
        return number(text)
    }

    private static func length(_ text: String?, of whole: CGFloat) -> CGFloat {
        guard let text, !text.isEmpty else { return whole }
        if text.hasSuffix("%") { return whole * (CGFloat(Double(text.dropLast()) ?? 100) / 100) }
        if text.hasSuffix("ex") { return (number(text) ?? 0) * exPixels }
        return number(text) ?? whole
    }

    private static func property(_ name: String, in style: String?) -> CGFloat? {
        guard let style, let range = style.range(of: name + ":") else { return nil }
        let rest = style[range.upperBound...].prefix { $0 != ";" }
        return number(String(rest))
    }

    /// An SVG transform list — translate, scale, matrix, rotate — as one
    /// affine transform, the first written applied last, as SVG means it.
    static func transform(_ text: String) -> CGAffineTransform {
        var result = CGAffineTransform.identity
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "("), let close = rest[open...].firstIndex(of: ")") {
            let name = rest[..<open].trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
            let values = rest[rest.index(after: open)..<close]
                .split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }.map { CGFloat($0) }
            var step = CGAffineTransform.identity
            switch name {
            case "translate":
                step = CGAffineTransform(translationX: values.first ?? 0, y: values.count > 1 ? values[1] : 0)
            case "scale":
                let x = values.first ?? 1
                step = CGAffineTransform(scaleX: x, y: values.count > 1 ? values[1] : x)
            case "matrix" where values.count == 6:
                step = CGAffineTransform(a: values[0], b: values[1], c: values[2], d: values[3],
                                         tx: values[4], ty: values[5])
            case "rotate":
                step = CGAffineTransform(rotationAngle: (values.first ?? 0) * .pi / 180)
            default:
                break
            }
            // Each later transform applies first, inside the earlier ones.
            result = step.concatenating(result)
            rest = rest[rest.index(after: close)...]
        }
        return result
    }

    /// SVG path data: the commands MathJax's outlines use, and the rest of
    /// the language but arcs. Read over the bytes: a formula's glyphs are
    /// a few kilobytes of numbers.
    static func path(_ data: String) -> CGPath? {
        let path = CGMutablePath()
        let bytes = Array(data.utf8)
        let count = bytes.count
        var index = 0
        func isDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }
        func skipSeparators() {
            while index < count, bytes[index] == 0x20 || bytes[index] == 0x2C || bytes[index] == 0x0A
                    || bytes[index] == 0x0D || bytes[index] == 0x09 { index += 1 }
        }
        func number() -> CGFloat? {
            skipSeparators()
            guard index < count else { return nil }
            let start = index
            var sign: Double = 1
            if bytes[index] == 0x2D { sign = -1; index += 1 } else if bytes[index] == 0x2B { index += 1 }
            var value: Double = 0
            var digits = 0
            while index < count, isDigit(bytes[index]) {
                value = value * 10 + Double(bytes[index] - 0x30)
                index += 1
                digits += 1
            }
            if index < count, bytes[index] == 0x2E {
                index += 1
                var place = 0.1
                while index < count, isDigit(bytes[index]) {
                    value += Double(bytes[index] - 0x30) * place
                    place *= 0.1
                    index += 1
                    digits += 1
                }
            }
            guard digits > 0 else {
                index = start
                return nil
            }
            if index < count, bytes[index] == 0x65 || bytes[index] == 0x45 {
                var ahead = index + 1
                var negative = false
                if ahead < count, bytes[ahead] == 0x2D { negative = true; ahead += 1 }
                else if ahead < count, bytes[ahead] == 0x2B { ahead += 1 }
                var exponent = 0
                var exponentDigits = 0
                while ahead < count, isDigit(bytes[ahead]) {
                    exponent = exponent * 10 + Int(bytes[ahead] - 0x30)
                    ahead += 1
                    exponentDigits += 1
                }
                if exponentDigits > 0 {
                    value *= pow(10, Double(negative ? -exponent : exponent))
                    index = ahead
                }
            }
            return CGFloat(sign * value)
        }
        func isCommand(_ byte: UInt8) -> Bool {
            (byte >= 0x41 && byte <= 0x5A || byte >= 0x61 && byte <= 0x7A) && byte != 0x65 && byte != 0x45
        }

        var command: UInt8 = 0x4D  // M
        var point = CGPoint.zero, start = CGPoint.zero
        var control: CGPoint?
        var lastCommand: UInt8 = 0x4D
        while true {
            skipSeparators()
            guard index < count else { break }
            if isCommand(bytes[index]) {
                command = bytes[index]
                index += 1
                if command == 0x5A || command == 0x7A {  // Z z
                    path.closeSubpath()
                    point = start
                    lastCommand = command
                    control = nil
                    continue
                }
            }
            let relative = command >= 0x61
            func absolute(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                relative ? CGPoint(x: point.x + x, y: point.y + y) : CGPoint(x: x, y: y)
            }
            let before = index
            switch command | 0x20 {  // lower case
            case 0x6D:  // m
                guard let x = number(), let y = number() else { return path }
                point = absolute(x, y)
                start = point
                path.move(to: point)
                // Pairs after a move are lines.
                command = relative ? 0x6C : 0x4C
                control = nil
            case 0x6C:  // l
                guard let x = number(), let y = number() else { return path }
                point = absolute(x, y)
                path.addLine(to: point)
                control = nil
            case 0x68:  // h
                guard let x = number() else { return path }
                point = CGPoint(x: relative ? point.x + x : x, y: point.y)
                path.addLine(to: point)
                control = nil
            case 0x76:  // v
                guard let y = number() else { return path }
                point = CGPoint(x: point.x, y: relative ? point.y + y : y)
                path.addLine(to: point)
                control = nil
            case 0x71:  // q
                guard let x1 = number(), let y1 = number(), let x = number(), let y = number() else { return path }
                let c = absolute(x1, y1)
                point = absolute(x, y)
                path.addQuadCurve(to: point, control: c)
                control = c
            case 0x74:  // t
                guard let x = number(), let y = number() else { return path }
                let smooth = lastCommand | 0x20 == 0x71 || lastCommand | 0x20 == 0x74
                let reflected = smooth ? control.map { CGPoint(x: 2 * point.x - $0.x, y: 2 * point.y - $0.y) } ?? point : point
                point = absolute(x, y)
                path.addQuadCurve(to: point, control: reflected)
                control = reflected
            case 0x63:  // c
                guard let x1 = number(), let y1 = number(), let x2 = number(), let y2 = number(),
                      let x = number(), let y = number() else { return path }
                let c1 = absolute(x1, y1), c2 = absolute(x2, y2)
                point = absolute(x, y)
                path.addCurve(to: point, control1: c1, control2: c2)
                control = c2
            case 0x73:  // s
                guard let x2 = number(), let y2 = number(), let x = number(), let y = number() else { return path }
                let smooth = lastCommand | 0x20 == 0x63 || lastCommand | 0x20 == 0x73
                let c1 = smooth ? control.map { CGPoint(x: 2 * point.x - $0.x, y: 2 * point.y - $0.y) } ?? point : point
                let c2 = absolute(x2, y2)
                point = absolute(x, y)
                path.addCurve(to: point, control1: c1, control2: c2)
                control = c2
            case 0x61:  // a — not in MathJax's outlines; the end point is kept.
                guard number() != nil, number() != nil, number() != nil, number() != nil, number() != nil,
                      let x = number(), let y = number() else { return path }
                point = absolute(x, y)
                path.addLine(to: point)
                control = nil
            default:
                index += 1
            }
            if index == before { index += 1 }
            lastCommand = command
        }
        return path
    }
}
#endif
