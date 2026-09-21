import Foundation
import PDFKit
import PaperCore

#if canImport(UIKit)
import UIKit
private typealias PlatformFont = UIFont
#else
import AppKit
private typealias PlatformFont = NSFont
#endif

/// Everything the resolver can learn from a PDF without going online.
public struct DocumentSignals: Hashable, Sendable {
    public var pageCount: Int
    /// The PDF's own `/Title`, when it is not a placeholder.
    public var embeddedTitle: String?
    /// The PDF's own `/Author`, split into names.
    public var embeddedAuthors: [String]
    /// The PDF's `/Subject`, which conference templates fill with the venue.
    public var embeddedSubject: String?
    public var embeddedKeywords: [String]
    /// First page, one entry per visual line, whitespace trimmed.
    public var firstPageLines: [String]
    /// Text of the first two pages, hyphenation repaired.
    public var openingText: String
    /// The text drawn in the largest font on page one, excluding stamps.
    public var largestFontText: String?
    public var hasTextLayer: Bool

    public init(
        pageCount: Int = 0,
        embeddedTitle: String? = nil,
        embeddedAuthors: [String] = [],
        embeddedSubject: String? = nil,
        embeddedKeywords: [String] = [],
        firstPageLines: [String] = [],
        openingText: String = "",
        largestFontText: String? = nil,
        hasTextLayer: Bool = false
    ) {
        self.pageCount = pageCount
        self.embeddedTitle = embeddedTitle
        self.embeddedAuthors = embeddedAuthors
        self.embeddedSubject = embeddedSubject
        self.embeddedKeywords = embeddedKeywords
        self.firstPageLines = firstPageLines
        self.openingText = openingText
        self.largestFontText = largestFontText
        self.hasTextLayer = hasTextLayer
    }
}

/// Pulls metadata signals out of a PDF.
///
/// Measured over a 62-paper machine-learning library, the PDF's own `/Title`
/// is present and correct for roughly half the corpus — far more often than the
/// reference managers this app replaces appear to assume. It is tried first for
/// that reason, then confirmed against a registrar rather than trusted blindly.
public enum DocumentSignalsExtractor {
    public static func extract(from document: PDFDocument) -> DocumentSignals {
        var signals = DocumentSignals(pageCount: document.pageCount)
        // Everything behind a lock is cipher, including the title. Taking it
        // gives a row named "OìáCµC˘-Ü˘°"; taking nothing gives a row named
        // after the file, which is what the person dropped in. A file with
        // only an owner password is not locked and reads normally — that is
        // most of the publishers — so this asks `PDFLock`, which knows the
        // difference.
        guard PDFLock.of(document: document, fileAt: document.documentURL) == nil else { return signals }

        let attributes = document.documentAttributes ?? [:]
        signals.embeddedTitle = cleanEmbeddedTitle(
            attributes[PDFDocumentAttribute.titleAttribute] as? String
        )
        signals.embeddedAuthors = splitAuthorField(
            attributes[PDFDocumentAttribute.authorAttribute] as? String
        )
        signals.embeddedSubject = nonEmpty(
            attributes[PDFDocumentAttribute.subjectAttribute] as? String
        )
        signals.embeddedKeywords = keywordList(attributes[PDFDocumentAttribute.keywordsAttribute])

        guard let firstPage = document.page(at: 0) else { return signals }

        let firstPageText = firstPage.string ?? ""
        signals.hasTextLayer = firstPageText.trimmingCharacters(in: .whitespacesAndNewlines).count > 200
        signals.firstPageLines = firstPageText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var opening = firstPageText
        if document.pageCount > 1, let secondPage = document.page(at: 1) {
            opening += "\n" + (secondPage.string ?? "")
        }
        signals.openingText = TextNormalization.repairingHyphenation(opening)
        signals.largestFontText = largestFontText(on: firstPage)

        return signals
    }

    public static func extract(fromFileAt url: URL) -> DocumentSignals? {
        guard let document = PDFDocument(url: url) else { return nil }
        return extract(from: document)
    }

    // MARK: - Embedded attribute cleaning

    /// Rejects the placeholder titles PDF producers leave behind.
    ///
    /// LaTeX writes the source file name, Word writes the first line of the
    /// document, and both are worse than having no title at all.
    static func cleanEmbeddedTitle(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = TextNormalization.collapsingWhitespace(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 12 else { return nil }

        let lowered = value.lowercased()
        let placeholders = [
            "untitled", "microsoft word", "no title", "paper", "manuscript",
            "main", "document", "template", "acm sig proceedings", "elsevier",
            "print", "output", "final", "camera ready", "camera-ready",
        ]
        if placeholders.contains(where: { lowered == $0 || lowered.hasPrefix("\($0) -") }) {
            return nil
        }
        for suffix in [".dvi", ".tex", ".pdf", ".doc", ".docx", ".ps"] where lowered.hasSuffix(suffix) {
            return nil
        }
        // A "title" with no spaces is a file name, not a title.
        guard value.contains(" ") else { return nil }
        return value
    }

    static func splitAuthorField(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        let value = TextNormalization.collapsingWhitespace(raw)
        guard !value.isEmpty else { return [] }
        // Producers use semicolons, commas, and " and " interchangeably.
        let separators: [String] = [";", " and ", ","]
        for separator in separators where value.contains(separator) {
            let parts = value.components(separatedBy: separator)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.count > 1 }
            // A comma split is only meaningful when it yields more than the
            // "Family, Given" of a single author.
            if separator == "," && parts.count == 2 { break }
            if parts.count > 1 { return parts }
        }
        return [value]
    }

    static func keywordList(_ raw: Any?) -> [String] {
        if let list = raw as? [String] { return list }
        guard let text = raw as? String else { return [] }
        return text
            .components(separatedBy: CharacterSet(charactersIn: ",;"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func nonEmpty(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = TextNormalization.collapsingWhitespace(raw)
        return value.isEmpty ? nil : value
    }

    // MARK: - Typography

    /// Text set in the largest font on the page, which on a paper's first page
    /// is almost always the title.
    ///
    /// The font size only locates the title; the text is then taken from the
    /// whole lines it falls on. Titles are often typeset in small caps, where
    /// only the leading capital of each word is set in the large font — reading
    /// the large runs alone yields "MPOWERING ACHINE NLEARNING" instead of
    /// "Empowering Machine Unlearning".
    ///
    /// Two things must also be filtered out or the signal is worse than
    /// useless: the rotated arXiv stamp down the left margin, which is often
    /// set larger than the body, and decorative drop caps, a single glyph.
    static func largestFontText(on page: PDFPage) -> String? {
        guard let attributed = page.attributedString else { return nil }
        let fullText = attributed.string
        guard !fullText.isEmpty else { return nil }

        var runs: [(size: CGFloat, range: NSRange)] = []
        attributed.enumerateAttribute(
            .font,
            in: NSRange(location: 0, length: attributed.length),
            options: []
        ) { value, range, _ in
            guard let font = value as? PlatformFont else { return }
            let text = attributed.attributedSubstring(from: range).string
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            runs.append((font.pointSize, range))
        }
        guard !runs.isEmpty else { return nil }

        // Runs are bucketed with a tolerance because a title's second line is
        // often typeset a fraction of a point away from its first, and an exact
        // size comparison then truncates the title at the line break.
        let distinctSizes = Set(runs.map { ($0.size * 10).rounded() / 10 }).sorted(by: >)
        for size in distinctSizes {
            let group = runs.filter { $0.size >= size * 0.97 }
            guard !group.isEmpty else { continue }

            let rawText = TextNormalization.collapsingWhitespace(
                group.map { (fullText as NSString).substring(with: $0.range) }
                    .joined(separator: " ")
            )
            // A single decorative glyph is not a title.
            guard rawText.count >= 2 else { continue }
            guard !isStamp(rawText) else { continue }

            let expanded = expandToLines(group.map(\.range), in: fullText)
            let candidate = TextNormalization.collapsingWhitespace(expanded)
            guard candidate.count >= 12, !isStamp(candidate) else { continue }
            return candidate
        }
        return nil
    }

    /// Grows a set of character ranges out to the full lines that contain them.
    static func expandToLines(_ ranges: [NSRange], in text: String) -> String {
        guard let lower = ranges.map(\.location).min(),
              let upper = ranges.map({ $0.location + $0.length }).max()
        else { return "" }

        let nsText = text as NSString
        let clampedLower = max(0, min(lower, nsText.length))
        let clampedUpper = max(clampedLower, min(upper, nsText.length))
        var lineRange = nsText.lineRange(for: NSRange(location: clampedLower, length: 0))
        let endLine = nsText.lineRange(
            for: NSRange(location: max(clampedLower, clampedUpper - 1), length: 0)
        )
        lineRange.length = (endLine.location + endLine.length) - lineRange.location

        // Many templates set the author block in the same size as the title, so
        // the run range runs straight through it. Stop at the first line that
        // reads like names and affiliations rather than truncating by count.
        let block = nsText.substring(with: lineRange)
        var kept: [String] = []
        for line in block.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if !kept.isEmpty, isLikelyAuthorOrAffiliationLine(trimmed) { break }
            kept.append(trimmed)
            if kept.count == 4 { break }
        }
        return kept.joined(separator: " ")
    }

    /// Recognises the author and affiliation block under a paper's title.
    static func isLikelyAuthorOrAffiliationLine(_ line: String) -> Bool {
        if line.contains("@") { return true }
        if line.contains(where: { "∗†‡§¶→".contains($0) }) { return true }

        let lowered = line.lowercased()
        let affiliationWords = [
            "university", "institute", "laborator", "inc.", "corporation",
            "research", "college", "school of", "department", "academy",
            "google", "microsoft", "meta ai", "openai", "nvidia", "deepmind",
        ]
        if affiliationWords.contains(where: lowered.contains) { return true }

        let tokens = line.split(separator: " ").map(String.init)
        guard tokens.count >= 2 else { return false }

        // "Lin1", "Kim∗,1" and "1SenseTime": a digit fused to a word is an
        // affiliation marker, never part of a title.
        for token in tokens {
            let characters = Array(token)
            for index in characters.indices.dropFirst() where characters[index].isNumber {
                if characters[index - 1].isLetter { return true }
            }
            if let first = characters.first, first.isNumber, characters.count > 2,
               characters[1].isUppercase {
                return true
            }
        }

        // A comma-separated list of short capitalised tokens is a name list.
        let commas = line.filter { $0 == "," }.count
        if commas >= 2 {
            let capitalised = tokens.filter { $0.first?.isUppercase == true }.count
            if capitalised * 2 >= tokens.count { return true }
        }
        return false
    }

    /// Matches the preprint-server stamp and open-access watermarks.
    static func isStamp(_ text: String) -> Bool {
        let lowered = text.lowercased()
        if lowered.hasPrefix("arxiv:") { return true }
        if lowered.contains("this iccv paper is the open access version") { return true }
        if lowered.contains("this cvpr paper is the open access version") { return true }
        if lowered.contains("this wacv paper is the open access version") { return true }
        if lowered.contains("provided by the computer vision foundation") { return true }
        if lowered.contains("except for this watermark") { return true }
        if lowered.contains("preprint. under review") { return true }
        if lowered.contains("biorxiv preprint") { return true }
        return false
    }
}
