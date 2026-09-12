import CoreGraphics
import Foundation
import PDFKit

/// The colours offered for text markup.
///
/// Named rather than free-form so a highlight keeps its meaning across devices
/// and appearances, and so the library can filter by "everything I marked red".
public enum MarkupColor: String, Codable, Hashable, Sendable, CaseIterable {
    case yellow, green, blue, pink, purple

    public var components: (red: CGFloat, green: CGFloat, blue: CGFloat) {
        switch self {
        case .yellow: (1.00, 0.84, 0.25)
        case .green: (0.45, 0.83, 0.51)
        case .blue: (0.42, 0.71, 0.98)
        case .pink: (0.99, 0.56, 0.66)
        case .purple: (0.75, 0.60, 0.96)
        }
    }

    public var platformColor: PlatformColor {
        let parts = components
        return PlatformColor(red: parts.red, green: parts.green, blue: parts.blue, alpha: 1)
    }

    public var displayName: String {
        switch self {
        case .yellow: "Yellow"
        case .green: "Green"
        case .blue: "Blue"
        case .pink: "Pink"
        case .purple: "Purple"
        }
    }
}

/// A markup the user made, described independently of any `PDFAnnotation`.
///
/// Kept as plain data so a markup can be re-applied to a freshly reloaded
/// document when another device changed the file underneath us, and so the
/// notes list can show markups without holding the PDF open.
public struct MarkupDescriptor: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case highlight, underline, strikethrough, note
    }

    public var id: UUID
    public var kind: Kind
    public var pageIndex: Int
    /// Line rectangles in PDF page coordinates.
    public var rects: [CGRect]
    public var color: MarkupColor
    /// The text that was marked, kept for the notes list and for export.
    public var quotedText: String
    /// The user's own comment, when they added one.
    public var comment: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        kind: Kind,
        pageIndex: Int,
        rects: [CGRect],
        color: MarkupColor = .yellow,
        quotedText: String = "",
        comment: String = "",
        createdAt: Date = .now
    ) {
        self.id = id
        self.kind = kind
        self.pageIndex = pageIndex
        self.rects = rects
        self.color = color
        self.quotedText = quotedText
        self.comment = comment
        self.createdAt = createdAt
    }
}

/// Creates and removes the standard PDF annotations for text markup.
///
/// These are ordinary `Highlight`, `Underline`, `StrikeOut` and `Text`
/// annotations, so Preview, Acrobat, Zotero and anything else that opens the
/// file shows exactly what the user marked.
public enum TextMarkupWriter {
    static let idKey = PDFAnnotationKey(rawValue: "/PTMarkupID")
    /// The user's own words, kept apart from `contents` so a comment can be
    /// told from the quoted text every reader puts there by default.
    static let commentKey = PDFAnnotationKey(rawValue: "/PTComment")

    /// Builds a descriptor from a text selection.
    public static func descriptor(
        for selection: PDFSelection,
        kind: MarkupDescriptor.Kind,
        color: MarkupColor,
        in document: PDFDocument
    ) -> [MarkupDescriptor] {
        var byPage: [Int: [CGRect]] = [:]
        var textByPage: [Int: String] = [:]
        var metricsByPage: [Int: LineMetrics] = [:]

        // A selection spanning several lines has to become one rectangle per
        // line, or the highlight covers the whole block including its margins.
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let index = document.index(for: page)
                let metrics = metricsByPage[index] ?? LineMetrics(page: page)
                metricsByPage[index] = metrics
                byPage[index, default: []].append(
                    metrics.tightened(line.bounds(for: page), on: page)
                )
                let existing = textByPage[index] ?? ""
                let addition = line.string ?? ""
                textByPage[index] = existing.isEmpty ? addition : "\(existing) \(addition)"
            }
        }

        return byPage.keys.sorted().map { index in
            MarkupDescriptor(
                kind: kind,
                pageIndex: index,
                rects: byPage[index] ?? [],
                color: color,
                quotedText: (textByPage[index] ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    /// Where a line's words actually are, found by looking at the ink.
    ///
    /// A highlight should cover the letters, not the box PDFKit draws around
    /// them: that box is a typographic line, tall enough for the tallest glyph
    /// on the line, and on a line carrying inline mathematics it stands two or
    /// three times the height of the words. Asking PDFKit where the glyphs sit
    /// is no help — `characterBounds(at:)` disagrees with the line's own
    /// rectangle by whole lines on some documents and reports 4-point heights
    /// for 10-point text, and a per-character selection just reports the whole
    /// line again.
    ///
    /// So the line is drawn into a small greyscale bitmap and its rows of
    /// pixels are counted. The rows with ink are the letters; the mark covers
    /// exactly those, with a hair of margin. The result is clamped inside the
    /// reported rectangle, so it cannot stray onto a neighbouring line.
    struct LineMetrics {
        private let typicalLine: CGFloat

        init(page: PDFPage) {
            let heights = (page.selection(for: page.bounds(for: .cropBox))?
                .selectionsByLine() ?? [])
                .map { $0.bounds(for: page).height }
                .filter { $0 > 0 }
                .sorted()
            typicalLine = heights.count >= 4 ? heights[heights.count / 2] : 0
        }

        func tightened(_ rect: CGRect, on page: PDFPage) -> CGRect {
            guard let ink = Self.inkExtent(of: rect, on: page) else { return rect }

            // Something too thin to be a line of text — a rule, a fragment of a
            // figure — is left alone.
            let floor = typicalLine > 0 ? typicalLine * 0.25 : 2
            guard ink.height >= floor else { return rect }

            let padding = max(ink.height * 0.16, 0.6)
            var band = CGRect(
                x: rect.minX,
                y: ink.minY - padding,
                width: rect.width,
                height: ink.height + padding * 2
            )
            guard band.height < rect.height else { return rect }
            band.origin.y = min(max(band.minY, rect.minY), rect.maxY - band.height)
            return band
        }

        /// The top and bottom of the ink belonging to this line.
        static func inkExtent(of rect: CGRect, on page: PDFPage) -> (minY: CGFloat, height: CGFloat)? {
            let scale: CGFloat = 3
            let width = Int((rect.width * scale).rounded(.up))
            let height = Int((rect.height * scale).rounded(.up))
            guard width > 0, height > 2, width * height <= 4_000_000 else { return nil }

            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return nil }

            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: scale, y: scale)
            let box = page.bounds(for: .cropBox)
            context.translateBy(x: -(rect.minX - box.minX), y: -(rect.minY - box.minY))
            page.draw(with: .cropBox, to: context)

            guard let data = context.data else { return nil }
            let pixels = data.assumingMemoryBound(to: UInt8.self)
            var ink = [Int](repeating: 0, count: height)
            for row in 0..<height {
                let start = row * width
                var count = 0
                for column in 0..<width where pixels[start + column] < 160 { count += 1 }
                ink[row] = count
            }

            guard let densest = ink.max(), densest > 0 else { return nil }

            // A stretched line's rectangle reaches into its neighbours, so the
            // strip usually holds more than one band of text — and the
            // neighbour's is often the darker. The one belonging to this line
            // is the one nearest the middle of its own rectangle, because that
            // is what the rectangle was drawn around.
            let solid = max(1, densest / 4)
            var bands: [(first: Int, last: Int)] = []
            var start: Int?
            for row in 0..<height {
                if ink[row] >= solid {
                    if start == nil { start = row }
                } else if let began = start {
                    bands.append((began, row - 1))
                    start = nil
                }
            }
            if let began = start { bands.append((began, height - 1)) }
            guard let core = bands.min(by: {
                abs(Double($0.first + $0.last) / 2 - Double(height) / 2)
                    < abs(Double($1.first + $1.last) / 2 - Double(height) / 2)
            }) else { return nil }

            // Reach out from the body of the line to take in its ascenders and
            // descenders, which are far fainter, and stop at the white space
            // that separates this line from the next.
            let faint = max(1, densest / 40)
            let gap = 3
            var top = core.first
            var blank = 0
            var row = core.first - 1
            while row >= 0, blank < gap {
                blank = ink[row] >= faint ? 0 : blank + 1
                if ink[row] >= faint { top = row }
                row -= 1
            }
            var bottom = core.last
            blank = 0
            row = core.last + 1
            while row < height, blank < gap {
                blank = ink[row] >= faint ? 0 : blank + 1
                if ink[row] >= faint { bottom = row }
                row += 1
            }

            // Row 0 of the bitmap is the top of the rectangle.
            let maxY = rect.maxY - CGFloat(top) / scale
            let minY = rect.maxY - CGFloat(bottom + 1) / scale
            return (minY, maxY - minY)
        }
    }

    @discardableResult
    public static func apply(_ descriptor: MarkupDescriptor, to page: PDFPage) -> [PDFAnnotation] {
        var created: [PDFAnnotation] = []
        switch descriptor.kind {
        case .highlight, .underline, .strikethrough:
            for rect in descriptor.rects where rect.width > 0.5 && rect.height > 0.5 {
                let annotation = PDFAnnotation(
                    bounds: rect,
                    forType: subtype(for: descriptor.kind),
                    withProperties: nil
                )
                annotation.color = descriptor.color.platformColor
                annotation.contents = descriptor.comment.isEmpty
                    ? descriptor.quotedText
                    : descriptor.comment
                annotation.setValue(descriptor.id.uuidString, forAnnotationKey: idKey)
                if !descriptor.comment.isEmpty {
                    annotation.setValue(descriptor.comment, forAnnotationKey: commentKey)
                }
                page.addAnnotation(annotation)
                created.append(annotation)
            }
        case .note:
            guard let anchor = descriptor.rects.first else { break }
            // A note is anchored at the start of what it refers to.
            let bounds = CGRect(x: anchor.minX, y: anchor.maxY - 20, width: 20, height: 20)
            let annotation = PDFAnnotation(bounds: bounds, forType: .text, withProperties: nil)
            annotation.color = descriptor.color.platformColor
            annotation.contents = descriptor.comment
            annotation.setValue(descriptor.id.uuidString, forAnnotationKey: idKey)
            page.addAnnotation(annotation)
            created.append(annotation)
        }
        return created
    }

    /// The identifier of a markup, whoever made it.
    ///
    /// A markup this app wrote carries its own. One made in Preview, Zotero or
    /// on an iPad carries nothing, so it is given an identifier derived from
    /// where it sits on the page — the same annotation answers to the same
    /// identifier every time the file is opened, which is what lets it be
    /// listed, selected, recoloured and deleted like any other.
    public static func identifier(of annotation: PDFAnnotation) -> UUID? {
        if let own = annotation.value(forAnnotationKey: idKey) as? String,
           let id = UUID(uuidString: own) {
            return id
        }
        guard kind(for: annotation) != nil else { return nil }
        let page = annotation.page
        let index = page.flatMap { $0.document?.index(for: $0) } ?? -1
        return derivedIdentifier(of: annotation, pageIndex: index)
    }

    /// An identifier made from what the file already says: the subtype, the
    /// page, and the rectangle rounded to the point. Nothing about it changes
    /// unless the annotation itself moves.
    static func derivedIdentifier(of annotation: PDFAnnotation, pageIndex index: Int) -> UUID {
        let box = annotation.bounds
        let seed = "\(annotation.type ?? "?")|\(index)|"
            + "\(Int(box.minX.rounded()))|\(Int(box.minY.rounded()))|"
            + "\(Int(box.width.rounded()))|\(Int(box.height.rounded()))"
        return uuid(from: seed)
    }

    /// A UUID that depends only on the text given, so it is the same on every
    /// device and every launch.
    static func uuid(from seed: String) -> UUID {
        // FNV-1a, twice over, with different offsets: enough to keep the
        // markups of one page apart, which is all this has to do.
        var low: UInt64 = 0xcbf2_9ce4_8422_2325
        var high: UInt64 = 0x9e37_79b9_7f4a_7c15
        for byte in Array(seed.utf8) {
            low = (low ^ UInt64(byte)) &* 0x100_0000_01b3
            high = (high &+ UInt64(byte)) &* 0x9e37_79b9_7f4a_7c15
            high ^= high >> 29
        }
        var bytes = [UInt8]()
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8(truncatingIfNeeded: low >> UInt64(shift)))
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8(truncatingIfNeeded: high >> UInt64(shift)))
        }
        // Stamped as a version-4 UUID so nothing downstream is surprised.
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5],
                           bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// Takes a markup made elsewhere into the app's care: from here on it
    /// carries an identifier of its own, so moving or recolouring it does not
    /// lose track of it. Called the first time the reader acts on one.
    @discardableResult
    public static func adopt(_ annotation: PDFAnnotation) -> UUID? {
        guard kind(for: annotation) != nil else { return nil }
        if let own = annotation.value(forAnnotationKey: idKey) as? String,
           let id = UUID(uuidString: own) {
            return id
        }
        guard let id = identifier(of: annotation) else { return nil }
        annotation.setValue(id.uuidString, forAnnotationKey: idKey)
        return id
    }

    public static func remove(id: UUID, from page: PDFPage) {
        // Both kinds of markup answer here: the ones this app wrote, and the
        // ones it only recognised.
        for annotation in page.annotations where identifier(of: annotation) == id {
            page.removeAnnotation(annotation)
        }
    }

    /// Reads back every markup in a document, including ones made elsewhere.
    ///
    /// Annotations added in Preview have no Paper Time identifier, so they get
    /// a fresh one derived from their position — the app must show what is in
    /// the file, not only what it wrote itself.
    public static func descriptors(in document: PDFDocument) -> [MarkupDescriptor] {
        var result: [MarkupDescriptor] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            var grouped: [String: MarkupDescriptor] = [:]

            for annotation in page.annotations {
                guard let kind = kind(for: annotation) else { continue }
                let stored = (annotation.value(forAnnotationKey: idKey) as? String)
                    .flatMap(UUID.init(uuidString:))
                let id = stored ?? derivedIdentifier(of: annotation, pageIndex: index)
                let key = id.uuidString

                if var existing = grouped[key] {
                    existing.rects += lineRects(of: annotation)
                    grouped[key] = existing
                } else {
                    grouped[key] = MarkupDescriptor(
                        id: id,
                        kind: kind,
                        pageIndex: index,
                        rects: lineRects(of: annotation),
                        color: nearestColor(annotation.color),
                        quotedText: quotedText(for: annotation, on: page),
                        comment: comment(for: annotation, on: page)
                    )
                }
            }
            result += grouped.values.sorted { lhs, rhs in
                (lhs.rects.first?.maxY ?? 0) > (rhs.rects.first?.maxY ?? 0)
            }
        }
        return result
    }

    /// What the user wrote, as opposed to what they marked.
    ///
    /// Marks made in this app carry the comment in their own key. Marks made
    /// elsewhere only have `contents`, which readers fill with the quoted text
    /// by default — so that counts as a comment only when it differs from what
    /// is actually under the mark.
    /// The lines a markup actually covers.
    ///
    /// A markup that runs over three lines is one annotation with three
    /// quadrilaterals in it, and the box around them takes in the ends of
    /// lines that were never marked. Reading the quadrilaterals back is what
    /// keeps a recoloured markup the shape it was. PDFKit gives their corners
    /// relative to the annotation's own box, so they are put back on the page.
    static func lineRects(of annotation: PDFAnnotation) -> [CGRect] {
        guard let quads = annotation.quadrilateralPoints, quads.count >= 4 else {
            return [annotation.bounds]
        }
        let origin = annotation.bounds.origin
        var rects: [CGRect] = []
        for start in stride(from: 0, to: quads.count - 3, by: 4) {
            let corners = (0..<4).map { quads[start + $0].pointValue }
            let minX = corners.map(\.x).min() ?? 0, maxX = corners.map(\.x).max() ?? 0
            let minY = corners.map(\.y).min() ?? 0, maxY = corners.map(\.y).max() ?? 0
            let rect = CGRect(x: origin.x + minX, y: origin.y + minY,
                              width: maxX - minX, height: maxY - minY)
            if rect.width > 0.5, rect.height > 0.5 { rects.append(rect) }
        }
        return rects.isEmpty ? [annotation.bounds] : rects
    }

    static func comment(for annotation: PDFAnnotation, on page: PDFPage) -> String {
        if let own = annotation.value(forAnnotationKey: commentKey) as? String, !own.isEmpty {
            return own
        }
        let contents = (annotation.contents ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !contents.isEmpty else { return "" }
        if annotation.type == "Text" { return contents }
        return contents == quotedText(for: annotation, on: page) ? "" : contents
    }

    static func quotedText(for annotation: PDFAnnotation, on page: PDFPage) -> String {
        guard annotation.type != "Text" else { return "" }
        let selection = page.selection(for: annotation.bounds)
        return (selection?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func kind(for annotation: PDFAnnotation) -> MarkupDescriptor.Kind? {
        switch annotation.type {
        case "Highlight": .highlight
        case "Underline": .underline
        case "StrikeOut": .strikethrough
        case "Text": .note
        default: nil
        }
    }

    static func subtype(for kind: MarkupDescriptor.Kind) -> PDFAnnotationSubtype {
        switch kind {
        case .highlight: .highlight
        case .underline: .underline
        case .strikethrough: .strikeOut
        case .note: .text
        }
    }

    /// Maps an arbitrary annotation colour onto the app's palette so markup
    /// made in another reader still groups and filters sensibly.
    static func nearestColor(_ color: PlatformColor?) -> MarkupColor {
        guard let components = rgbComponents(color) else { return .yellow }
        var best = MarkupColor.yellow
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for candidate in MarkupColor.allCases {
            let parts = candidate.components
            let distance = pow(parts.red - components.0, 2)
                + pow(parts.green - components.1, 2)
                + pow(parts.blue - components.2, 2)
            if distance < bestDistance {
                bestDistance = distance
                best = candidate
            }
        }
        return best
    }

    static func rgbComponents(_ color: PlatformColor?) -> (CGFloat, CGFloat, CGFloat)? {
        guard let color else { return nil }
        #if canImport(UIKit)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        return (red, green, blue)
        #else
        guard let converted = color.usingColorSpace(.sRGB) else { return nil }
        return (converted.redComponent, converted.greenComponent, converted.blueComponent)
        #endif
    }
}
