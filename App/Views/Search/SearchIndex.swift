import Foundation
import LibraryStore
import PaperCore

/// One candidate the search palette can show: a paper, a collection, a tag,
/// or a fixed action.
struct SearchResult: Identifiable, Hashable {
    enum Kind: Hashable {
        /// Show every paper that matches, in the library list, rather than
        /// jumping to one of them.
        case showAll(String)
        case paper(UUID)
        case collection(UUID)
        case tag(UUID)
        case action(Action)
    }

    /// Commands the palette can surface without any query context.
    enum Action: String, CaseIterable, Hashable {
        case addPDFs, exportBibTeX, resolveMetadata, refresh, importLibrary, settings

        var title: String {
            switch self {
            case .addPDFs: "Add PDFs…"
            case .exportBibTeX: "Export BibTeX…"
            case .resolveMetadata: "Resolve Missing Metadata"
            case .refresh: "Refresh Library"
            case .importLibrary: "Import Existing Library…"
            case .settings: "Settings…"
            }
        }

        var symbolName: String {
            switch self {
            case .addPDFs: "doc.badge.plus"
            case .exportBibTeX: "square.and.arrow.up"
            case .resolveMetadata: "arrow.triangle.2.circlepath"
            case .refresh: "arrow.clockwise"
            case .importLibrary: "tray.and.arrow.down"
            case .settings: "gearshape"
            }
        }
    }

    var id: Kind { kind }
    var kind: Kind
    var title: String
    var subtitle: String
    var symbolName: String
    var score: Double
}

/// Builds and ranks the palette's results for one query.
///
/// Scoring is deliberately simple and title-first: Spotlight reads as
/// predictable because a prefix match always beats a fuzzy one, not because
/// the ranking is clever.
@MainActor
enum SearchIndex {
    private static let fuzzyThreshold = 0.82

    static func results(for query: String, in model: LibraryModel) -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let foldedQuery = TextNormalization.foldedTitle(trimmed)
        guard !foldedQuery.isEmpty else { return [] }

        var results: [SearchResult] = []
        var matchedPapers = 0

        for paper in model.papers where paper.meta.parentID == nil {
            if LibraryModel.matches(folded: foldedQuery, paper: paper) { matchedPapers += 1 }
        }
        if matchedPapers > 1 {
            // Searching for an author is searching for a body of work, not for
            // one paper. This row is what turns a lookup into a place.
            results.append(
                SearchResult(
                    kind: .showAll(trimmed),
                    title: "Show All Results for \u{201C}\(trimmed)\u{201D}",
                    subtitle: "\(matchedPapers) papers",
                    symbolName: "line.3.horizontal.decrease.circle",
                    score: 2
                )
            )
        }

        for paper in model.papers {
            guard let score = paperScore(foldedQuery: foldedQuery, paper: paper) else { continue }
            results.append(
                SearchResult(
                    kind: .paper(paper.id),
                    title: paper.meta.displayTitle,
                    subtitle: paperSubtitle(paper),
                    symbolName: "doc.text",
                    score: score
                )
            )
        }

        for collection in model.collections.collections {
            guard let score = matchScore(foldedQuery: foldedQuery, foldedText: TextNormalization.foldedTitle(collection.name))
            else { continue }
            results.append(
                SearchResult(
                    kind: .collection(collection.id),
                    title: collection.name,
                    subtitle: collection.isSmart ? "Smart Collection" : "Collection",
                    symbolName: collection.symbolName,
                    score: score
                )
            )
        }

        for tag in model.manifest.tags {
            guard let score = matchScore(foldedQuery: foldedQuery, foldedText: TextNormalization.foldedTitle(tag.name))
            else { continue }
            results.append(
                SearchResult(
                    kind: .tag(tag.id),
                    title: tag.name,
                    subtitle: "Tag",
                    symbolName: "tag",
                    score: score
                )
            )
        }

        for action in SearchResult.Action.allCases {
            guard let score = matchScore(foldedQuery: foldedQuery, foldedText: TextNormalization.foldedTitle(action.title))
            else { continue }
            results.append(
                SearchResult(
                    kind: .action(action),
                    title: action.title,
                    subtitle: "Action",
                    symbolName: action.symbolName,
                    score: score
                )
            )
        }

        return Array(
            results.sorted { lhs, rhs in
                lhs.score != rhs.score
                    ? lhs.score > rhs.score
                    : lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
            .prefix(20)
        )
    }

    private static func paperSubtitle(_ paper: LoadedPaper) -> String {
        var parts: [String] = []
        let authors = paper.meta.displayAuthors
        if !authors.isEmpty { parts.append(authors) }
        if let year = paper.meta.csl.year { parts.append(String(year)) }
        if let venue = paper.meta.csl.containerTitle, !venue.isEmpty { parts.append(venue) }
        return parts.joined(separator: " · ")
    }

    /// A paper matches on its title first; failing that, on the fields a
    /// person would actually type when they remember the paper but not its
    /// exact title (an author's name, the venue, the year, the cite key, or
    /// the file they dragged in).
    private static func paperScore(foldedQuery: String, paper: LoadedPaper) -> Double? {
        let titleScore = matchScore(
            foldedQuery: foldedQuery,
            foldedText: TextNormalization.foldedTitle(paper.meta.displayTitle)
        )

        let subtitleFields = [
            paper.meta.csl.author.map(\.displayName).joined(separator: " "),
            paper.meta.csl.containerTitle ?? "",
            paper.meta.csl.year.map(String.init) ?? "",
            paper.meta.bibKey,
            paper.meta.file.originalName,
        ]
        let foldedSubtitle = TextNormalization.foldedTitle(subtitleFields.joined(separator: " "))
        let subtitleScore = (!foldedSubtitle.isEmpty && foldedSubtitle.contains(foldedQuery)) ? 0.6 : nil

        switch (titleScore, subtitleScore) {
        case let (.some(title), .some(subtitle)): return max(title, subtitle)
        case let (.some(title), nil): return title
        case let (nil, .some(subtitle)): return subtitle
        case (nil, nil): return nil
        }
    }

    /// Prefix match on the whole string, then prefix match on any word, then
    /// substring anywhere, then a fuzzy fallback for typos.
    private static func matchScore(foldedQuery: String, foldedText: String) -> Double? {
        guard !foldedText.isEmpty else { return nil }

        if foldedText.hasPrefix(foldedQuery) { return 1.0 }
        if foldedText.split(separator: " ").contains(where: { $0.hasPrefix(foldedQuery) }) { return 0.9 }
        if foldedText.contains(foldedQuery) { return 0.75 }

        let similarity = StringSimilarity.jaroWinkler(foldedQuery, foldedText)
        return similarity > fuzzyThreshold ? similarity : nil
    }
}
