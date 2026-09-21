import CoreGraphics
import Foundation

/// A colour as four numbers, so the file format does not depend on a palette
/// that may grow, and so a shape's fill can carry its own translucency.
public struct SketchColor: Codable, Hashable, Sendable {
    public var red: CGFloat
    public var green: CGFloat
    public var blue: CGFloat
    public var alpha: CGFloat

    public init(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, alpha: CGFloat = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public var cgColor: CGColor {
        CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [red, green, blue, alpha])!
    }

    public func withAlpha(_ alpha: CGFloat) -> SketchColor {
        var copy = self
        copy.alpha = alpha
        return copy
    }

    /// The colour laid over white paper at its own alpha, made opaque — what
    /// the PDF copy gets, since a PDF annotation's interior colour has no
    /// alpha of its own.
    public var flattenedOnWhite: SketchColor {
        SketchColor(
            red + (1 - red) * (1 - alpha),
            green + (1 - green) * (1 - alpha),
            blue + (1 - blue) * (1 - alpha)
        )
    }

    /// The colour as the six hex digits a design tool shows: `1F5FFA`.
    public var hex: String {
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "%02X%02X%02X", byte(red), byte(green), byte(blue))
    }

    /// Reads `1F5FFA`, `#1f5ffa` or the short `F00`. The alpha is kept from
    /// the colour this is replacing, so typing a hex changes the hue alone.
    public init?(hex raw: String, alpha: CGFloat = 1) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(
            CGFloat((value >> 16) & 0xFF) / 255, CGFloat((value >> 8) & 0xFF) / 255, CGFloat(value & 0xFF) / 255,
            alpha: alpha
        )
    }

    /// True when two colours are the same to the eye — the file rounds.
    public func matches(_ other: SketchColor) -> Bool {
        abs(red - other.red) < 0.02 && abs(green - other.green) < 0.02
            && abs(blue - other.blue) < 0.02 && abs(alpha - other.alpha) < 0.02
    }

    // The pen's inks, the same seven the pen tool offers.
    public static let ink = SketchColor(0.10, 0.10, 0.12)
    public static let grey = SketchColor(0.55, 0.55, 0.58)
    public static let red = SketchColor(0.90, 0.20, 0.18)
    public static let orange = SketchColor(0.96, 0.55, 0.12)
    public static let green = SketchColor(0.16, 0.62, 0.32)
    public static let blue = SketchColor(0.12, 0.36, 0.98)
    public static let purple = SketchColor(0.52, 0.30, 0.88)

    /// What a line can be drawn in.
    public static let strokes: [SketchColor] = [.ink, .grey, .red, .orange, .green, .blue, .purple]

    // The fills: the highlighter's colours, pale — a card behind a note, a
    // wash inside a box. Translucent, so the paper's own words stay legible
    // under a shape drawn over them.
    public static let paleYellow = SketchColor(1.00, 0.90, 0.55, alpha: 0.6)
    public static let paleGreen = SketchColor(0.68, 0.90, 0.70, alpha: 0.6)
    public static let paleBlue = SketchColor(0.66, 0.83, 0.99, alpha: 0.6)
    public static let palePink = SketchColor(0.99, 0.75, 0.80, alpha: 0.6)
    public static let palePurple = SketchColor(0.85, 0.77, 0.98, alpha: 0.6)
    public static let paleGrey = SketchColor(0.80, 0.81, 0.84, alpha: 0.6)

    /// What a shape can be filled with. `nil` in a style means no fill.
    public static let fills: [SketchColor] = [.paleYellow, .paleGreen, .paleBlue, .palePink, .palePurple, .paleGrey]
}

/// How a shape is drawn: the choices Excalidraw puts in its side panel, and
/// nothing it does not — a reader should never be choosing between twelve
/// line widths.
public struct SketchStyle: Codable, Hashable, Sendable {
    public enum Dash: String, Codable, Sendable, CaseIterable {
        case solid, dashed, dotted
    }

    public enum Corners: String, Codable, Sendable, CaseIterable {
        case sharp, round
    }

    /// What an arrow ends in.
    public enum Head: String, Codable, Sendable, CaseIterable {
        /// Nothing: a plain line.
        case none
        /// An open V, the way a hand draws an arrowhead.
        case arrow
        /// A filled triangle.
        case triangle
        /// A short bar across the end.
        case bar
        /// A dot.
        case dot
    }

    /// Where the lines of a text card sit within it.
    public enum TextAlign: String, Codable, Sendable, CaseIterable {
        case left, center, right
    }

    /// Three sizes of lettering, in page points. A paper's body is about ten.
    public enum TextSize: String, Codable, Sendable, CaseIterable {
        case small, medium, large

        public var points: CGFloat {
            switch self {
            case .small: 9
            case .medium: 12
            case .large: 17
            }
        }
    }

    public var stroke: SketchColor
    /// Nothing, or a pale wash.
    public var fill: SketchColor?
    /// The line's width in page points: thin, regular, bold.
    public var width: CGFloat
    public var dash: Dash
    public var corners: Corners
    public var startHead: Head
    public var endHead: Head
    /// The whole shape's opacity, 0...1.
    public var opacity: CGFloat
    public var textSize: TextSize
    /// For a text card: whether its edge is drawn. A box always has one.
    public var border: Bool
    /// For a box, an oval or a frame: whether its edge is left undrawn.
    /// The opposite sense to `border` so that files written before this
    /// existed — where every box has an edge — still read as they did.
    public var strokeHidden: Bool
    /// The corner radius in page points, when one has been set by hand.
    /// Nil is the automatic one: a share of the smaller side.
    public var cornerRadius: CGFloat?
    /// Lettering in exact points, when set by hand; nil is `textSize`.
    public var fontSize: CGFloat?
    public var textAlign: TextAlign

    public static let widths: [CGFloat] = [1, 2, 3.5]

    enum CodingKeys: String, CodingKey {
        case stroke, fill, width, dash, corners, startHead, endHead, opacity, textSize, border
        case strokeHidden, cornerRadius, fontSize, textAlign
    }

    /// The size the words are set in.
    public var points: CGFloat { fontSize ?? textSize.points }

    /// Whether this kind of element draws its outline in this style.
    public func drawsOutline(for kind: SketchElement.Kind) -> Bool {
        switch kind {
        case .text: border
        case .rectangle, .ellipse, .frame: !strokeHidden
        case .line, .arrow: true
        case .group: false
        }
    }

    public init(
        stroke: SketchColor = .ink,
        fill: SketchColor? = nil,
        width: CGFloat = 2,
        dash: Dash = .solid,
        corners: Corners = .round,
        startHead: Head = .none,
        endHead: Head = .arrow,
        opacity: CGFloat = 1,
        textSize: TextSize = .medium,
        border: Bool = false,
        strokeHidden: Bool = false,
        cornerRadius: CGFloat? = nil,
        fontSize: CGFloat? = nil,
        textAlign: TextAlign = .left
    ) {
        self.stroke = stroke
        self.fill = fill
        self.width = width
        self.dash = dash
        self.corners = corners
        self.startHead = startHead
        self.endHead = endHead
        self.opacity = opacity
        self.textSize = textSize
        self.border = border
        self.strokeHidden = strokeHidden
        self.cornerRadius = cornerRadius
        self.fontSize = fontSize
        self.textAlign = textAlign
    }

    // Every field has a default, so a file written by a later version with a
    // field this one does not know still reads, and a field this version
    // added still reads from an older file.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let base = SketchStyle()
        stroke = try c.decodeIfPresent(SketchColor.self, forKey: .stroke) ?? base.stroke
        fill = try c.decodeIfPresent(SketchColor.self, forKey: .fill)
        width = try c.decodeIfPresent(CGFloat.self, forKey: .width) ?? base.width
        dash = try c.decodeIfPresent(Dash.self, forKey: .dash) ?? base.dash
        corners = try c.decodeIfPresent(Corners.self, forKey: .corners) ?? base.corners
        startHead = try c.decodeIfPresent(Head.self, forKey: .startHead) ?? base.startHead
        endHead = try c.decodeIfPresent(Head.self, forKey: .endHead) ?? base.endHead
        opacity = try c.decodeIfPresent(CGFloat.self, forKey: .opacity) ?? base.opacity
        textSize = try c.decodeIfPresent(TextSize.self, forKey: .textSize) ?? base.textSize
        border = try c.decodeIfPresent(Bool.self, forKey: .border) ?? base.border
        strokeHidden = try c.decodeIfPresent(Bool.self, forKey: .strokeHidden) ?? false
        cornerRadius = try c.decodeIfPresent(CGFloat.self, forKey: .cornerRadius)
        fontSize = try c.decodeIfPresent(CGFloat.self, forKey: .fontSize)
        textAlign = try c.decodeIfPresent(TextAlign.self, forKey: .textAlign) ?? .left
    }

    // Absent rather than false, so a file this version merely opened is
    // written back byte for byte — and so the Windows build, which keeps
    // the fields it does not know, has nothing new to keep.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(stroke, forKey: .stroke)
        try c.encodeIfPresent(fill, forKey: .fill)
        try c.encode(width, forKey: .width)
        try c.encode(dash, forKey: .dash)
        try c.encode(corners, forKey: .corners)
        try c.encode(startHead, forKey: .startHead)
        try c.encode(endHead, forKey: .endHead)
        try c.encode(opacity, forKey: .opacity)
        try c.encode(textSize, forKey: .textSize)
        try c.encode(border, forKey: .border)
        if strokeHidden { try c.encode(true, forKey: .strokeHidden) }
        try c.encodeIfPresent(cornerRadius, forKey: .cornerRadius)
        try c.encodeIfPresent(fontSize, forKey: .fontSize)
        if textAlign != .left { try c.encode(textAlign, forKey: .textAlign) }
    }

    /// The dash pattern for a line of this width, in page points. Dashes
    /// grow with the line so a bold dashed line is not a bold dotted one.
    public var dashPattern: [CGFloat]? {
        switch dash {
        case .solid: nil
        case .dashed: [max(width * 3, 4), max(width * 2.2, 3)]
        case .dotted: [0.01, max(width * 2, 2.5)]
        }
    }
}

/// One thing drawn on a page that is not a pen stroke: a box, an oval, a
/// line, an arrow, or a piece of text — the vocabulary of Excalidraw and of a
/// mind map, on a paper.
///
/// Everything is in PDF page coordinates, so an element means the same on
/// every device and can be written into the file as a standard annotation.
public struct SketchElement: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case rectangle, ellipse, line, arrow, text
        /// A container with a box of its own — Figma's frame. Its children
        /// lie inside it, it can hide what spills past its edge, and it can
        /// lay its children out in a row or a column.
        case frame
        /// A container with no box of its own: its bounds are its children's.
        /// Selected, moved, restyled as one thing.
        case group
    }

    /// How a text card takes its size, as Figma names the two: as wide as
    /// its longest line, or as wide as it was made and as tall as its lines.
    public enum TextSizing: String, Codable, Sendable, CaseIterable {
        case autoWidth, autoHeight
    }

    public var id: UUID
    public var kind: Kind
    /// Two points. For a box, an oval and text: two opposite corners. For a
    /// line and an arrow: where it starts and where it ends.
    public var points: [CGPoint]
    /// For a line or an arrow: how far the middle is pulled from the
    /// straight path, as an offset from the midpoint. Nil is straight.
    public var bend: CGPoint?
    public var style: SketchStyle
    /// The words: a text element's whole content, or the label inside a box.
    public var text: String
    public var createdAt: Date
    /// The frame or group this lies in, when it lies in one. Coordinates
    /// stay the page's either way — a child is not relative to its parent —
    /// so every renderer and every PDF copy reads it as before.
    public var parent: UUID?
    /// What a frame or a group is called, when it has been named.
    public var name: String?
    /// For a frame: whether what spills past its edge is hidden.
    public var clips: Bool
    /// For a frame: how its children are arranged, when they are arranged.
    public var layout: SketchLayout?
    /// For a text card. Nil in files from before there was a choice, which
    /// were all as wide as they were made.
    public var textSizing: TextSizing?

    enum CodingKeys: String, CodingKey {
        case id, kind, points, bend, style, text, createdAt
        case parent, name, clips, layout, textSizing
    }

    public init(
        id: UUID = UUID(),
        kind: Kind,
        points: [CGPoint],
        bend: CGPoint? = nil,
        style: SketchStyle = SketchStyle(),
        text: String = "",
        createdAt: Date = .now,
        parent: UUID? = nil,
        name: String? = nil,
        clips: Bool = false,
        layout: SketchLayout? = nil,
        textSizing: TextSizing? = nil
    ) {
        self.id = id
        self.kind = kind
        self.points = points
        self.bend = bend
        self.style = style
        self.text = text
        self.createdAt = createdAt
        self.parent = parent
        self.name = name
        self.clips = clips
        self.layout = layout
        self.textSizing = textSizing
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decode(Kind.self, forKey: .kind)
        points = try c.decode([CGPoint].self, forKey: .points)
        bend = try c.decodeIfPresent(CGPoint.self, forKey: .bend)
        style = try c.decodeIfPresent(SketchStyle.self, forKey: .style) ?? SketchStyle()
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        parent = try c.decodeIfPresent(UUID.self, forKey: .parent)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        clips = try c.decodeIfPresent(Bool.self, forKey: .clips) ?? false
        layout = try c.decodeIfPresent(SketchLayout.self, forKey: .layout)
        textSizing = try c.decodeIfPresent(TextSizing.self, forKey: .textSizing)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(points, forKey: .points)
        try c.encodeIfPresent(bend, forKey: .bend)
        try c.encode(style, forKey: .style)
        try c.encode(text, forKey: .text)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(parent, forKey: .parent)
        try c.encodeIfPresent(name, forKey: .name)
        if clips { try c.encode(true, forKey: .clips) }
        try c.encodeIfPresent(layout, forKey: .layout)
        try c.encodeIfPresent(textSizing, forKey: .textSizing)
    }

    /// A box, an oval, a text card or a frame — anything its two corners
    /// describe.
    public var isBox: Bool { kind == .rectangle || kind == .ellipse || kind == .text || kind == .frame }
    /// A line or an arrow.
    public var isConnector: Bool { kind == .line || kind == .arrow }
    /// A frame or a group: something with children.
    public var isContainer: Bool { kind == .frame || kind == .group }
    /// How a text card sizes itself. Files from before the choice existed
    /// were all made to a width, and keep it.
    public var sizing: TextSizing { textSizing ?? .autoHeight }

    public var start: CGPoint { points.first ?? .zero }
    public var end: CGPoint { points.count > 1 ? points[1] : start }

    /// The box the two corners describe, normalised.
    public var rect: CGRect {
        get {
            CGRect(
                x: min(start.x, end.x), y: min(start.y, end.y),
                width: abs(end.x - start.x), height: abs(end.y - start.y)
            )
        }
        set {
            points = [CGPoint(x: newValue.minX, y: newValue.minY), CGPoint(x: newValue.maxX, y: newValue.maxY)]
        }
    }

    /// Where a curved connector's control point is, in page coordinates.
    public var control: CGPoint? {
        guard isConnector, let bend, hypot(bend.x, bend.y) > 0.5 else { return nil }
        return CGPoint(x: (start.x + end.x) / 2 + bend.x, y: (start.y + end.y) / 2 + bend.y)
    }

    /// The point a connector passes through at its middle — where the bend
    /// handle sits. On a straight line it is the midpoint.
    public var midpoint: CGPoint {
        guard let control else { return CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2) }
        // The quadratic curve at t = 0.5.
        return CGPoint(
            x: 0.25 * start.x + 0.5 * control.x + 0.25 * end.x,
            y: 0.25 * start.y + 0.5 * control.y + 0.25 * end.y
        )
    }

    /// Sets the bend so that the curve passes through the given point.
    public mutating func setMidpoint(_ point: CGPoint) {
        // Inverting the quadratic at t = 0.5: control = 2·mid − (start+end)/2.
        let control = CGPoint(
            x: 2 * point.x - (start.x + end.x) / 2,
            y: 2 * point.y - (start.y + end.y) / 2
        )
        let offset = CGPoint(x: control.x - (start.x + end.x) / 2, y: control.y - (start.y + end.y) / 2)
        bend = hypot(offset.x, offset.y) < 1 ? nil : offset
    }

    /// The connector as a polyline: one segment when straight, a sampled
    /// curve when bent. What hit-testing and the PDF's copy both use.
    public func polyline(samples: Int = 24) -> [CGPoint] {
        guard isConnector else { return [] }
        guard let control else { return [start, end] }
        return (0...samples).map { step in
            let t = CGFloat(step) / CGFloat(samples)
            let u = 1 - t
            return CGPoint(
                x: u * u * start.x + 2 * u * t * control.x + t * t * end.x,
                y: u * u * start.y + 2 * u * t * control.y + t * t * end.y
            )
        }
    }

    /// The direction the connector leaves its start in, and arrives at its
    /// end in — for the heads.
    public var startDirection: CGPoint {
        let toward = control ?? end
        return Self.unit(CGPoint(x: start.x - toward.x, y: start.y - toward.y))
    }

    public var endDirection: CGPoint {
        let from = control ?? start
        return Self.unit(CGPoint(x: end.x - from.x, y: end.y - from.y))
    }

    static func unit(_ v: CGPoint) -> CGPoint {
        let length = hypot(v.x, v.y)
        guard length > 0.0001 else { return CGPoint(x: 1, y: 0) }
        return CGPoint(x: v.x / length, y: v.y / length)
    }

    /// How long an arrowhead is for a line of this width.
    public var headLength: CGFloat { max(8, style.width * 4.5) }

    /// The corner radius a rounded box takes: a share of its smaller side,
    /// so a small box is not all corner, and never more than a card's.
    public var cornerRadius: CGFloat {
        if let set = style.cornerRadius { return max(0, min(set, min(rect.width, rect.height) / 2)) }
        guard style.corners == .round else { return 0 }
        return min(min(rect.width, rect.height) * 0.22, 10)
    }

    /// Everything the element covers, including its heads and half its line
    /// width — the box to redraw, and the one a marquee has to touch.
    public var bounds: CGRect {
        var box: CGRect
        if isConnector {
            box = polyline().reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
            let reach = headLength
            box = box.insetBy(dx: -reach, dy: -reach)
        } else {
            box = rect
        }
        let pad = style.width / 2 + 1
        return box.insetBy(dx: -pad, dy: -pad)
    }

    /// Whether a point on the page is on the element.
    ///
    /// A line is hit along its length, a box along its edge and — when it is
    /// filled or has words in it — anywhere inside; a text card anywhere on
    /// it. The tolerance is in page points and grows as the reader zooms out,
    /// so the target under the pointer stays the same size on screen.
    public func hits(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        let reach = tolerance + style.width / 2
        switch kind {
        case .line, .arrow:
            let line = polyline()
            for index in 1..<line.count where Self.distance(from: point, toSegment: line[index - 1], line[index]) <= reach {
                return true
            }
            return false
        case .text:
            return rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        case .group:
            // A group is never hit for itself; a click on one of its
            // children is what selects it.
            return false
        case .rectangle, .frame:
            let outer = rect.insetBy(dx: -reach, dy: -reach)
            guard outer.contains(point) else { return false }
            if style.fill != nil || !text.isEmpty { return true }
            let inner = rect.insetBy(dx: reach, dy: reach)
            return !(inner.width > 0 && inner.height > 0 && inner.contains(point))
        case .ellipse:
            let r = rect
            guard r.width > 0, r.height > 0 else { return false }
            let dx = (point.x - r.midX) / (r.width / 2), dy = (point.y - r.midY) / (r.height / 2)
            let radial = hypot(dx, dy)
            // The reach in the ellipse's own normalised units, along the
            // smaller axis, which is the strict one.
            let band = reach / max(min(r.width, r.height) / 2, 0.001)
            if style.fill != nil || !text.isEmpty { return radial <= 1 + band }
            return abs(radial - 1) <= band
        }
    }

    public static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = dx * dx + dy * dy
        guard length > 0.0001 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    public func translated(by offset: CGPoint) -> SketchElement {
        var copy = self
        copy.points = points.map { CGPoint(x: $0.x + offset.x, y: $0.y + offset.y) }
        return copy
    }

    /// The element scaled into a new box, as the resize handles do it. A
    /// connector's ends move with the corners they are nearest.
    public func fitted(to box: CGRect, from old: CGRect) -> SketchElement {
        var copy = self
        guard old.width > 0.001, old.height > 0.001 else { return copy }
        func map(_ p: CGPoint) -> CGPoint {
            CGPoint(
                x: box.minX + (p.x - old.minX) / old.width * box.width,
                y: box.minY + (p.y - old.minY) / old.height * box.height
            )
        }
        copy.points = points.map(map)
        if let bend {
            copy.bend = CGPoint(x: bend.x / old.width * box.width, y: bend.y / old.height * box.height)
        }
        return copy
    }
}

extension CGRect {
    /// The box around several rectangles, or `.null` when there are none.
    public static func union(of rects: [CGRect]) -> CGRect {
        rects.reduce(CGRect.null) { $0.union($1) }
    }
}
