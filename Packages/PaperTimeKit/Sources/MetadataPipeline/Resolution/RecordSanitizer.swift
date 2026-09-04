import Bibliography
import Foundation
import PaperCore

/// Cleans up the text fields of a record fetched from a registrar.
///
/// DataCite and Crossref store titles exactly as the publisher submitted them,
/// which for machine-learning papers routinely means LaTeX: `$\pi_0$: A
/// Vision-Language-Action Flow Model` is a real title as filed. Left alone it
/// shows up in the library list, in citations, and in exported `.bib` files
/// with its delimiters intact.
public enum RecordSanitizer {
    public static func sanitized(_ item: CSLItem) -> CSLItem {
        var result = item
        result.title = result.title.map(clean)
        result.subtitle = result.subtitle.map(clean)
        result.shortTitle = result.shortTitle.map(clean)
        result.containerTitle = result.containerTitle.map(clean)
        result.collectionTitle = result.collectionTitle.map(clean)
        result.eventTitle = result.eventTitle.map(clean)
        result.publisher = result.publisher.map(clean)
        return result
    }

    static func clean(_ raw: String) -> String {
        var text = TextNormalization.collapsingWhitespace(raw)
        if text.contains("\\") || text.contains("{") {
            text = LaTeXEscaping.unescape(text)
        }
        text = strippingInlineMath(text)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes `$…$` delimiters while keeping what they wrapped.
    ///
    /// Only applied when the dollars are balanced, so a title that genuinely
    /// talks about money keeps its symbol.
    static func strippingInlineMath(_ raw: String) -> String {
        let dollars = raw.filter { $0 == "$" }.count
        guard dollars >= 2, dollars.isMultiple(of: 2) else { return raw }

        var result = ""
        var insideMath = false
        for character in raw {
            if character == "$" {
                insideMath.toggle()
                continue
            }
            // Subscript and superscript markers carry no meaning once the
            // surrounding math has been unwrapped.
            if insideMath, character == "_" || character == "^" {
                continue
            }
            result.append(character)
        }
        return TextNormalization.collapsingWhitespace(result)
    }
}
