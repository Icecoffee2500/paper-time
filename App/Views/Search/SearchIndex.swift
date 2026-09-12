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
        case note(String)
        case collection(UUID)
        case tag(UUID)
        case action(Action)
    }

    /// Why a paper is being suggested, when it is: the field is empty and
    /// the palette is offering rather than finding.
    struct Reason: Hashable {
        var text: String
        /// How far through the paper the reader is, for a bar; nil for none.
        var progress: Double?
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
    var reason: Reason? = nil
}

/// What the palette offers when nothing has been typed: not a blank, but
/// the papers the reader is most likely to want next, each with its reason.
///
/// The reasons are borrowed from how people actually come back to reading.
/// An unfinished paper nags (Zeigarnik) and the last stretch pulls hardest
/// (the goal gradient), so "Continue" leads, with how little is left. A
/// paper read a few weeks ago is about to be forgotten (Ebbinghaus's curve)
/// and a short revisit at that moment keeps it — so "Revisit" surfaces the
/// ones with notes, once a week or so has passed. And an unread paper is
/// more inviting when it is named as a neighbour of one just read
/// (Loewenstein's information gap: the shared words show a known thing
/// from a new side), so "Because you read …" says which words they share.
/// New arrivals close the list. Three or four, never a wall.
struct SearchSuggestions {
    struct Group: Identifiable {
        let title: String
        let results: [SearchResult]
        var id: String { title }
    }

    @MainActor
    static func groups(in model: LibraryModel) -> [Group] {
        let papers = model.papers.filter { $0.meta.parentID == nil }
        let now = Date.now
        var taken = Set<UUID>()
        var groups: [Group] = []

        func row(_ paper: LoadedPaper, _ reason: String, progress: Double? = nil, symbol: String = "doc.text") -> SearchResult {
            taken.insert(paper.id)
            return SearchResult(
                kind: .paper(paper.id), title: paper.meta.displayTitle,
                subtitle: paper.meta.displayAuthors, symbolName: symbol, score: 0,
                reason: SearchResult.Reason(text: reason, progress: progress)
            )
        }
        func ago(_ date: Date) -> String {
            let days = Int(now.timeIntervalSince(date) / 86_400)
            switch days {
            case 0: return "today"
            case 1: return "yesterday"
            case 2..<14: return "\(days) days ago"
            case 14..<60: return "\(days / 7) weeks ago"
            default: return "\(days / 30) months ago"
            }
        }

        // Continue: opened, not finished, most recent first.
        let unfinished = papers.filter { paper in
            let pages = paper.meta.file.pageCount
            return paper.state.lastOpenedAt != nil && pages > 1
                && paper.state.lastPageIndex > 0 && paper.state.lastPageIndex < pages - 1
                && paper.state.readingStatus != .read
        }
        .sorted { ($0.state.lastOpenedAt ?? .distantPast) > ($1.state.lastOpenedAt ?? .distantPast) }
        .prefix(3)
        if !unfinished.isEmpty {
            groups.append(Group(title: "Continue", results: unfinished.map { paper in
                let pages = paper.meta.file.pageCount
                let left = pages - 1 - paper.state.lastPageIndex
                let progress = Double(paper.state.lastPageIndex + 1) / Double(pages)
                let reason = "\(Int(progress * 100))% · \(left == 1 ? "1 page" : "\(left) pages") left · \(ago(paper.state.lastOpenedAt ?? now))"
                return row(paper, reason, progress: progress, symbol: "book.pages")
            }))
        }

        // Because you read …: the unread neighbours of the last paper read.
        if let recent = papers.filter({ $0.state.lastOpenedAt != nil })
            .max(by: { ($0.state.lastOpenedAt ?? .distantPast) < ($1.state.lastOpenedAt ?? .distantPast) }) {
            let text: (LoadedPaper) -> String = { paper in
                [paper.meta.displayTitle, paper.meta.csl.abstract ?? "", paper.meta.csl.containerTitle ?? ""]
                    .joined(separator: "\n")
                    + "\n" + model.notes.notes(forPaper: paper.id).map { $0.title + " " + $0.body }.joined(separator: "\n")
            }
            let unread = papers.filter { $0.state.lastOpenedAt == nil && !taken.contains($0.id) }
            if !unread.isEmpty {
                let index = Resonance.Index(notes: unread.map { (id: $0.id.uuidString, text: text($0)) })
                let neighbours = index.matches(for: text(recent), limit: 3)
                let rows = neighbours.compactMap { match -> SearchResult? in
                    guard let id = UUID(uuidString: match.id), let paper = papers.first(where: { $0.id == id }) else { return nil }
                    let short = recent.meta.displayTitle.split(separator: " ").prefix(4).joined(separator: " ")
                    return row(paper, "shares \(match.shared.prefix(2).joined(separator: " · ")) with “\(short)…”", symbol: "waveform")
                }
                if !rows.isEmpty { groups.append(Group(title: "Because you read", results: rows)) }
            }
        }

        // Revisit: read a week or more ago, with notes — before it fades.
        let toRevisit = papers.filter { paper in
            guard let opened = paper.state.lastOpenedAt, !taken.contains(paper.id) else { return false }
            let days = now.timeIntervalSince(opened) / 86_400
            return days >= 7 && days <= 90 && !model.notes.notes(forPaper: paper.id).isEmpty
        }
        .sorted { model.notes.notes(forPaper: $0.id).count > model.notes.notes(forPaper: $1.id).count }
        .prefix(2)
        if !toRevisit.isEmpty {
            groups.append(Group(title: "Revisit", results: toRevisit.map { paper in
                let count = model.notes.notes(forPaper: paper.id).count
                return row(paper, "read \(ago(paper.state.lastOpenedAt ?? now)) · \(count == 1 ? "1 note" : "\(count) notes") — a look now keeps it", symbol: "arrow.counterclockwise")
            }))
        }

        // New this week, unread.
        let fresh = papers.filter { now.timeIntervalSince($0.meta.addedAt) < 7 * 86_400 && $0.state.lastOpenedAt == nil && !taken.contains($0.id) }
            .sorted { $0.meta.addedAt > $1.meta.addedAt }
            .prefix(2)
        if !fresh.isEmpty {
            groups.append(Group(title: "New this week", results: fresh.map { row($0, "added \(ago($0.meta.addedAt))", symbol: "sparkles") }))
        }
        return groups
    }
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
            // The paper you had open this morning comes before the one you
            // read in March: the same title match, and recency decides.
            let recency = paper.state.lastOpenedAt.map { max(0, 0.15 - Date.now.timeIntervalSince($0) / (30 * 86_400) * 0.15) } ?? 0
            results.append(
                SearchResult(
                    kind: .paper(paper.id),
                    title: paper.meta.displayTitle,
                    subtitle: paperSubtitle(paper),
                    symbolName: "doc.text",
                    score: score + recency
                )
            )
        }

        for note in model.notes.notes where !note.isEmpty {
            let folded = TextNormalization.foldedTitle(note.displayTitle + " " + note.preview.prefix(200))
            guard let score = matchScore(foldedQuery: foldedQuery, foldedText: folded) else { continue }
            results.append(
                SearchResult(
                    kind: .note(note.id),
                    title: note.displayTitle,
                    subtitle: note.kind == .map ? "Map" : note.kind == .draft ? "Draft" : "Note",
                    symbolName: note.kind == .map ? "map" : note.kind == .draft ? "doc.text" : "note.text",
                    score: score - 0.05
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
