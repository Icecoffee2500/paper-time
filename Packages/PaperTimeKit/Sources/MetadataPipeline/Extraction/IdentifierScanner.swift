import Foundation
import PaperCore

/// Finds DOIs, arXiv IDs and PubMed IDs in the text of a paper's opening pages.
public enum IdentifierScanner {
    /// Deliberately scoped to the first two pages.
    ///
    /// A paper's reference list is full of other papers' DOIs; scanning the
    /// whole document would confidently resolve half the library to whichever
    /// work happened to be cited first.
    public static func scan(_ text: String) -> Identifiers {
        Identifiers(
            doi: dois(in: text).first,
            arxiv: arxivIDs(in: text).first,
            pmid: pubmedID(in: text)
        )
    }

    public static func dois(in text: String) -> [String] {
        let pattern = /10\.\d{4,9}\/[-._;()\/:A-Za-z0-9]+/
        var found: [String] = []
        var seen = Set<String>()
        for match in text.matches(of: pattern) {
            guard let normalised = Identifiers.normalizeDOI(String(match.output)) else { continue }
            // Registrars never mint a DOI ending in a sentence separator, but
            // extracted text routinely glues one on.
            guard seen.insert(normalised).inserted else { continue }
            found.append(normalised)
        }
        return found
    }

    public static func arxivIDs(in text: String) -> [String] {
        var found: [String] = []
        var seen = Set<String>()

        let labelled = /(?i)arxiv[:\s]\s*(\d{4}\.\d{4,5}(?:v\d+)?)/
        for match in text.matches(of: labelled) {
            let value = String(match.output.1)
            if let normalised = Identifiers.normalizeArxiv(value), seen.insert(normalised).inserted {
                found.append(normalised)
            }
        }

        let legacy = /(?i)arxiv[:\s]\s*([a-z-]+(?:\.[A-Z]{2})?\/\d{7}(?:v\d+)?)/
        for match in text.matches(of: legacy) {
            let value = String(match.output.1)
            if let normalised = Identifiers.normalizeArxiv(value), seen.insert(normalised).inserted {
                found.append(normalised)
            }
        }

        let absURL = /arxiv\.org\/(?:abs|pdf)\/([^\s,)]+)/
        for match in text.matches(of: absURL) {
            let value = String(match.output.1)
            if let normalised = Identifiers.normalizeArxiv(value), seen.insert(normalised).inserted {
                found.append(normalised)
            }
        }
        return found
    }

    public static func pubmedID(in text: String) -> String? {
        let pattern = /(?i)pmid[:\s]\s*(\d{6,9})/
        guard let match = text.firstMatch(of: pattern) else { return nil }
        return String(match.output.1)
    }

    /// arXiv IDs can also be recovered from the file name of a downloaded PDF.
    public static func arxivID(fromFileName name: String) -> String? {
        let stem = (name as NSString).deletingPathExtension
        let pattern = /^(\d{4}\.\d{4,5}(?:v\d+)?)$/
        guard let match = stem.wholeMatch(of: pattern) else { return nil }
        return Identifiers.normalizeArxiv(String(match.output.1))
    }
}
