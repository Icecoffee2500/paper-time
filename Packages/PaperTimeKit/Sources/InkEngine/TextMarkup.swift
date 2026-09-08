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

    /// Where a line's words actually sit, found by looking at the ink.
    ///
    /// A line carrying inline mathematics reports a box tall enough for its
    /// tallest glyph, so a highlight drawn on that box stands two or three
    /// times the height of the words around it.
    ///
    /// PDFKit will not say where within a line its glyphs are:
    /// `characterBounds(at:)` disagrees with the line's own rectangle by whole
    /// lines on some documents and reports 4-point heights for 10-point text,
    /// and a per-character selection just reports the whole line again. So the
    /// line is drawn into a small bitmap and the rows of pixels are counted.
    /// The band with the most ink is the body text; its bottom is the
    /// baseline. The offset from a baseline to the bottom of an ordinary line's
    /// box is measured the same way, on the same page, so a trimmed line lands
    /// exactly where its neighbours do.
    struct LineMetrics {
        private let typicalLine: CGFloat
        private let descender: CGFloat

        init(page: PDFPage) {
            let lines = page.selection(for: page.bounds(for: .cropBox))?
                .selectionsByLine() ?? []
            let rects = lines.map { $0.bounds(for: page) }.filter { $0.height > 0 }
            let heights = rects.map(\.height).sorted()
            // Fewer than a handful of lines is not enough to say what this
            // page's ordinary line looks like, so nothing is trimmed.
            typicalLine = heights.count >= 4 ? heights[heights.count / 2] : 0

            guard typicalLine > 0 else {
                descender = 0
                return
            }
            var drops: [CGFloat] = []
            for rect in rects
            where abs(rect.height - typicalLine) <= typicalLine * 0.1 && rect.width > 40 {
                guard let baseline = Self.baseline(of: rect, on: page) else { continue }
                drops.append(baseline - rect.minY)
                if drops.count == 6 { break }
            }
            descender = drops.isEmpty
                ? typicalLine * 0.2
                : drops.sorted()[drops.count / 2]
        }

        func tightened(_ rect: CGRect, on page: PDFPage) -> CGRect {
            guard typicalLine > 0, rect.height > typicalLine * 1.4 else { return rect }

            var band = CGRect(
                x: rect.minX,
                y: (Self.baseline(of: rect, on: page) ?? (rect.midY + typicalLine / 2 - descender))
                    - descender,
                width: rect.width,
                height: typicalLine
            )
            // Never leave the line it belongs to, whatever the ink said.
            band.origin.y = min(max(band.minY, rect.minY), rect.maxY - band.height)
            return band
        }

        /// The baseline of the body text inside a line's rectangle.
        ///
        /// Returns nil when there is nothing to measure — a blank strip, or a
        /// rectangle too large to be worth rasterising.
        static func baseline(of rect: CGRect, on page: PDFPage) -> CGFloat? {
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

            guard let peak = ink.indices.max(by: { ink[$0] < ink[$1] }), ink[peak] > 0
            else { return nil }
            // The rows around the densest one are the body text; the tall
            // glyphs that stretched the line are sparse by comparison.
            let threshold = max(1, ink[peak] / 4)
            var bottom = peak
            while bottom + 1 < height, ink[bottom + 1] >= threshold { bottom += 1 }

            // Row 0 of the bitmap is the top of the rectangle.
            return rect.maxY - CGFloat(bottom + 1) / scale
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

    public static func remove(id: UUID, from page: PDFPage) {
        for annotation in page.annotations
        where annotation.value(forAnnotationKey: idKey) as? String == id.uuidString {
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
                let identifier = annotation.value(forAnnotationKey: idKey) as? String
                let key = identifier ?? "\(annotation.type ?? "?")-\(annotation.bounds.integral)"

                if var existing = grouped[key] {
                    existing.rects.append(annotation.bounds)
                    grouped[key] = existing
                } else {
                    grouped[key] = MarkupDescriptor(
                        id: identifier.flatMap(UUID.init(uuidString:)) ?? UUID(),
                        kind: kind,
                        pageIndex: index,
                        rects: [annotation.bounds],
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
