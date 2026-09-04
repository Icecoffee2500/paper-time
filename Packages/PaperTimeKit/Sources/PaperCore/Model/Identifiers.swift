import Foundation

/// External identifiers for a paper, kept outside the CSL record.
///
/// CSL-JSON has a field only for DOI and ISBN, but the pipeline needs arXiv,
/// PubMed, OpenAlex and Semantic Scholar IDs to re-query APIs later, so they
/// live here instead of being smuggled into `note`.
public struct Identifiers: Codable, Hashable, Sendable {
    public var doi: String?
    public var arxiv: String?
    public var pmid: String?
    public var openAlex: String?
    public var semanticScholar: String?
    public var isbn: String?

    public init(
        doi: String? = nil,
        arxiv: String? = nil,
        pmid: String? = nil,
        openAlex: String? = nil,
        semanticScholar: String? = nil,
        isbn: String? = nil
    ) {
        self.doi = doi.flatMap(Identifiers.normalizeDOI)
        self.arxiv = arxiv.flatMap(Identifiers.normalizeArxiv)
        self.pmid = pmid
        self.openAlex = openAlex
        self.semanticScholar = semanticScholar
        self.isbn = isbn
    }

    public var isEmpty: Bool {
        doi == nil && arxiv == nil && pmid == nil && openAlex == nil
            && semanticScholar == nil && isbn == nil
    }

    /// Strips the many prefixes a DOI arrives with and lowercases it.
    ///
    /// DOIs are case-insensitive by specification, and registrars mix cases, so
    /// comparing raw strings produces false "different paper" results.
    public static func normalizeDOI(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in [
            "https://doi.org/", "http://doi.org/",
            "https://dx.doi.org/", "http://dx.doi.org/",
            "doi:", "DOI:", "doi.org/",
        ] where value.lowercased().hasPrefix(prefix.lowercased()) {
            value = String(value.dropFirst(prefix.count))
        }
        value = value.trimmingCharacters(in: .whitespaces)
        // Trailing sentence punctuation is a frequent artefact of text extraction.
        while let last = value.last, ".,;)]>".contains(last) {
            value = String(value.dropLast())
        }
        guard value.hasPrefix("10."), value.contains("/"), value.count > 7 else { return nil }
        return value.lowercased()
    }

    /// Normalizes "arXiv:2403.18293v1", "arxiv.org/abs/2403.18293" and bare IDs
    /// to the canonical `2403.18293v1` form. Legacy IDs (`cs/0501001`) are kept.
    public static func normalizeArxiv(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in [
            "https://arxiv.org/abs/", "http://arxiv.org/abs/",
            "https://arxiv.org/pdf/", "http://arxiv.org/pdf/",
            "arxiv.org/abs/", "arXiv:", "arxiv:",
        ] where value.lowercased().hasPrefix(prefix.lowercased()) {
            value = String(value.dropFirst(prefix.count))
        }
        if value.lowercased().hasSuffix(".pdf") { value = String(value.dropLast(4)) }
        value = value.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }

        let modern = /^\d{4}\.\d{4,5}(v\d+)?$/
        let legacy = /^[a-z-]+(\.[A-Z]{2})?\/\d{7}(v\d+)?$/
        if value.wholeMatch(of: modern) != nil || value.wholeMatch(of: legacy) != nil {
            return value
        }
        return nil
    }

    /// The arXiv ID without its version suffix, for matching across versions.
    public var arxivBaseID: String? {
        guard let arxiv else { return nil }
        guard let range = arxiv.range(of: "v[0-9]+$", options: .regularExpression) else {
            return arxiv
        }
        return String(arxiv[arxiv.startIndex..<range.lowerBound])
    }
}
