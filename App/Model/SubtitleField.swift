import Foundation
import LibraryStore

/// A field that can appear under a paper's title in the list.
///
/// Which ones, and in what order, is the reader's choice: a library of
/// preprints wants the year and the arXiv id, one of journal articles wants
/// the venue, and somebody working through one author's papers wants none of
/// it. The setting is stored as an ordered list of raw values.
enum SubtitleField: String, CaseIterable, Identifiable, Sendable {
    case authors, year, venue, citationKey, fileName, pageCount, addedDate

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .authors: "Authors"
        case .year: "Year"
        case .venue: "Venue"
        case .citationKey: "Citation Key"
        case .fileName: "File Name"
        case .pageCount: "Pages"
        case .addedDate: "Date Added"
        }
    }

    func value(for paper: LoadedPaper) -> String? {
        switch self {
        case .authors:
            let authors = paper.meta.displayAuthors
            return authors.isEmpty ? nil : authors
        case .year:
            return paper.meta.csl.year.map(String.init)
        case .venue:
            let venue = paper.meta.csl.containerTitle ?? ""
            return venue.isEmpty ? nil : venue
        case .citationKey:
            return paper.meta.bibKey.isEmpty ? nil : paper.meta.bibKey
        case .fileName:
            let name = paper.meta.file.originalName
            return name.isEmpty ? nil : name
        case .pageCount:
            let pages = paper.meta.file.pageCount
            return pages > 0 ? "\(pages) pages" : nil
        case .addedDate:
            return paper.meta.addedAt.formatted(date: .abbreviated, time: .omitted)
        }
    }

    /// Parses the stored setting, keeping order and dropping anything unknown.
    static func parse(_ raw: String) -> [SubtitleField] {
        let fields = raw.split(separator: ",").compactMap {
            SubtitleField(rawValue: $0.trimmingCharacters(in: .whitespaces))
        }
        return fields.isEmpty ? [.authors, .year, .venue] : fields
    }

    static func encode(_ fields: [SubtitleField]) -> String {
        fields.map(\.rawValue).joined(separator: ",")
    }
}
