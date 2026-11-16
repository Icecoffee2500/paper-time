import Foundation
import PaperCore

/// Where a paper was published, read off its own first page.
///
/// A camera-ready paper says where it appeared, in words its venue's style
/// file prints and nothing else does: «Published as a conference paper at
/// ICLR 2024», «37th Conference on Neural Information Processing Systems
/// (NeurIPS 2023)», «Proceedings of the 40th International Conference on
/// Machine Learning … PMLR 202, 2023». Those venues have no DOI, so no
/// registrar can say it — and the arXiv copy a reader downloads very often
/// still carries the line. The phrasings are the final ones only: «Under
/// review as a conference paper at ICLR», «Submitted to 37th Conference…»,
/// «Preprint. Under review.» and the workshops say nothing here.
public struct VenueStamp: Hashable, Sendable, Codable {
    /// The venue as a table names it: «ICLR».
    public var short: String
    /// The venue as a citation names it.
    public var containerTitle: String
    public var type: CSLType
    public var year: Int?
    /// The proceedings series, for PMLR venues.
    public var collectionTitle: String?
    public var volume: String?

    public init(short: String, containerTitle: String, type: CSLType, year: Int?,
                collectionTitle: String? = nil, volume: String? = nil) {
        self.short = short
        self.containerTitle = containerTitle
        self.type = type
        self.year = year
        self.collectionTitle = collectionTitle
        self.volume = volume
    }

    /// The stamp on a page's text, if it carries one.
    public static func find(in text: String) -> VenueStamp? {
        let page = TextNormalization.collapsingWhitespace(text)
        guard !page.isEmpty else { return nil }
        for rule in rules {
            if let found = rule(page) { return found }
        }
        return nil
    }

    /// The record a preprint becomes once its venue is known: the same paper,
    /// its type and container from the stamp, its year from the stamp when
    /// it says one.
    public func applied(to item: CSLItem) -> CSLItem {
        var made = item
        made.type = type
        made.containerTitle = containerTitle
        made.containerTitleShort = nil
        if let collectionTitle { made.collectionTitle = collectionTitle }
        if let volume { made.volume = volume }
        if let year { made.issued = CSLDate(year: year) }
        if made.publisher?.localizedCaseInsensitiveContains("arxiv") == true { made.publisher = nil }
        // arXiv's DOI names the preprint, not the paper at the venue; a
        // citation of the paper must not carry it. The identifier stays with
        // the record's identifiers, where lookups find it.
        if let doi = made.doi, doi.lowercased().hasPrefix("10.48550/arxiv.") { made.doi = nil }
        return made
    }

    // MARK: - The phrasings

    private typealias Rule = @Sendable (String) -> VenueStamp?

    private static let rules: [Rule] = [
        // ICLR's camera-ready header. Its submission header is «Under review
        // as a conference paper at ICLR 2024», which this does not match.
        { page in
            guard let match = first(#"Published as a conference paper at ICLR (\d{4})"#, in: page),
                  !page.localizedCaseInsensitiveContains("Under review as a conference paper")
            else { return nil }
            return VenueStamp(short: "ICLR", containerTitle: "International Conference on Learning Representations",
                              type: .paperConference, year: Int(match[1]))
        },
        // NeurIPS's camera-ready footnote, the main track and the datasets
        // track; not «Submitted to …», and not a workshop.
        { page in
            guard let match = first(#"(Submitted to )?\d+\s?(?:st|nd|rd|th) Conference on Neural Information Processing Systems \((?:NeurIPS|NIPS) (\d{4})\)( Workshop)?"#, in: page),
                  match[1].isEmpty, match[3].isEmpty
            else { return nil }
            return VenueStamp(short: "NeurIPS", containerTitle: "Advances in Neural Information Processing Systems",
                              type: .paperConference, year: Int(match[2]))
        },
        // ICML and the other PMLR conferences print their proceedings line
        // with the volume. ICML's preprint line («Under review by the
        // International Conference on Machine Learning») has no volume.
        { page in
            guard let match = first(#"Proceedings of the \d+\s?(?:st|nd|rd|th) International Conference on Machine Learning,.{0,80}?PMLR (\d+), (\d{4})"#, in: page)
            else { return nil }
            return VenueStamp(short: "ICML", containerTitle: "International Conference on Machine Learning",
                              type: .paperConference, year: Int(match[2]),
                              collectionTitle: "Proceedings of Machine Learning Research", volume: match[1])
        },
        { page in
            guard let match = first(#"Proceedings of the \d+\s?(?:st|nd|rd|th) International Conference on Artificial Intelligence and Statistics \(AISTATS\) (\d{4}).{0,80}?PMLR:? Volume (\d+)"#, in: page)
            else { return nil }
            return VenueStamp(short: "AISTATS", containerTitle: "International Conference on Artificial Intelligence and Statistics",
                              type: .paperConference, year: Int(match[1]),
                              collectionTitle: "Proceedings of Machine Learning Research", volume: match[2])
        },
        { page in
            guard let match = first(#"\d+\s?(?:st|nd|rd|th) Conference on Robot Learning \(CoRL (\d{4})\)"#, in: page)
            else { return nil }
            return VenueStamp(short: "CoRL", containerTitle: "Conference on Robot Learning",
                              type: .paperConference, year: Int(match[1]),
                              collectionTitle: "Proceedings of Machine Learning Research")
        },
        // The Computer Vision Foundation's open-access watermark names the
        // conference, sometimes with its year.
        { page in
            guard let match = first(#"This (CVPR|ICCV|WACV)( \d{4})? (?:paper|workshop paper) is the Open Access version, provided by the Computer Vision Foundation"#, in: page)
            else { return nil }
            let venue = match[1]
            let year = Int(match[2].trimmingCharacters(in: .whitespaces))
            if page.range(of: "This \(venue)\(match[2]) workshop paper", options: .caseInsensitive) != nil { return nil }
            let name = switch venue {
            case "CVPR": "Proceedings of the IEEE/CVF Conference on Computer Vision and Pattern Recognition (CVPR)"
            case "ICCV": "Proceedings of the IEEE/CVF International Conference on Computer Vision (ICCV)"
            default: "Proceedings of the IEEE/CVF Winter Conference on Applications of Computer Vision (WACV)"
            }
            return VenueStamp(short: venue, containerTitle: name, type: .paperConference, year: year)
        },
        // AAAI's first-page banner: «The Thirty-Eighth AAAI Conference on
        // Artificial Intelligence (AAAI-24)».
        { page in
            guard let match = first(#"AAAI Conference on Artificial Intelligence \(AAAI-(\d{2})\)"#, in: page),
                  let two = Int(match[1])
            else { return nil }
            return VenueStamp(short: "AAAI", containerTitle: "Proceedings of the AAAI Conference on Artificial Intelligence",
                              type: .paperConference, year: 2000 + two)
        },
        { page in
            guard let match = first(#"\(IJCAI-(\d{2})\)"#, in: page),
                  page.localizedCaseInsensitiveContains("International Joint Conference on Artificial Intelligence"),
                  let two = Int(match[1])
            else { return nil }
            return VenueStamp(short: "IJCAI", containerTitle: "Proceedings of the International Joint Conference on Artificial Intelligence",
                              type: .paperConference, year: 2000 + two)
        },
        // The ACL Anthology's first-page footers.
        { page in
            guard let match = first(#"Findings of the Association for Computational Linguistics: (ACL|EMNLP|NAACL|EACL|AACL)[- ]?(?:IJCNLP )?(\d{4})"#, in: page)
            else { return nil }
            return VenueStamp(short: "Findings of \(match[1])",
                              containerTitle: "Findings of the Association for Computational Linguistics: \(match[1]) \(match[2])",
                              type: .paperConference, year: Int(match[2]))
        },
        { page in
            guard let match = first(#"Proceedings of the (\d{4}) Conference on Empirical Methods in Natural Language Processing"#, in: page)
            else { return nil }
            return VenueStamp(short: "EMNLP", containerTitle: "Proceedings of the \(match[1]) Conference on Empirical Methods in Natural Language Processing",
                              type: .paperConference, year: Int(match[1]))
        },
        { page in
            guard let match = first(#"Proceedings of the (\d{4}) Conference of the North American Chapter of the Association for Computational Linguistics"#, in: page)
            else { return nil }
            return VenueStamp(short: "NAACL", containerTitle: "Proceedings of the \(match[1]) Conference of the North American Chapter of the Association for Computational Linguistics",
                              type: .paperConference, year: Int(match[1]))
        },
        { page in
            guard let match = first(#"Proceedings of the \d+\s?(?:st|nd|rd|th) Annual Meeting of the Association for Computational Linguistics(?: \(Volume \d+: [A-Za-z ]+\))?,? pages .{0,60}?(\d{4})"#, in: page)
            else { return nil }
            return VenueStamp(short: "ACL", containerTitle: "Proceedings of the Annual Meeting of the Association for Computational Linguistics",
                              type: .paperConference, year: Int(match[1]))
        },
        // Journals that print themselves on the paper.
        { page in
            guard let match = first(#"Published in Transactions on Machine Learning Research \(\d{1,2}/(\d{4})\)"#, in: page)
            else { return nil }
            return VenueStamp(short: "TMLR", containerTitle: "Transactions on Machine Learning Research",
                              type: .articleJournal, year: Int(match[1]))
        },
        { page in
            guard let match = first(#"Journal of Machine Learning Research (\d+) \((\d{4})\) \d+-\d+ Submitted .{0,40}?Published"#, in: page)
            else { return nil }
            return VenueStamp(short: "JMLR", containerTitle: "Journal of Machine Learning Research",
                              type: .articleJournal, year: Int(match[2]), volume: match[1])
        },
    ]

    /// The first match of a pattern, case aside, as its groups (0 is the
    /// whole match; a group that did not take part is empty).
    private static func first(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        return (0..<match.numberOfRanges).map { index in
            guard let range = Range(match.range(at: index), in: text) else { return "" }
            return String(text[range])
        }
    }
}
