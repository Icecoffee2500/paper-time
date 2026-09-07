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

        // A selection spanning several lines has to become one rectangle per
        // line, or the highlight covers the whole block including its margins.
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let index = document.index(for: page)
                byPage[index, default: []].append(line.bounds(for: page))
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
