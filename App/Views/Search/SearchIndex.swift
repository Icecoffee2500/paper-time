import Foundation
import LibraryStore
import PaperCore

/// A place inside a note, in the note's words made plain: which note, the
/// paper it is about if any, and where in the words. `location`/`length`
/// are UTF-16 offsets into the plain text the index cut, which is not the
/// Markdown the editor shows — so going there is done by the words, not the
/// offset (`NotesModel.reveal`).
struct NotePassage: Hashable, Sendable {
    var noteID: String
    var paperID: UUID?
    var location: Int
    var length: Int
}

/// One candidate the search palette can show: a paper, a collection, a tag,
/// or a fixed action.
struct SearchResult: Identifiable, Hashable {
    enum Kind: Hashable {
        /// Show every paper that matches, in the library list, rather than
        /// jumping to one of them.
        case showAll(String)
        case paper(UUID)
        /// A place inside a paper: the word was in the text, not the title.
        case passage(PaperTextIndex.Passage)
        /// A place inside a paper that says what was typed in other words:
        /// found by the meaning, not the letters.
        case meaning(PaperTextIndex.Passage)
        /// The same, inside a note: the person's own words on a paper, or
        /// a thought of their own, found by what it means.
        case meaningNote(NotePassage)
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
            case .addPDFs: L("PDF 더하기…", "Add PDFs…")
            case .exportBibTeX: L("BibTeX 내보내기…", "Export BibTeX…")
            case .resolveMetadata: L("빠진 서지 채우기", "Resolve Missing Metadata")
            case .refresh: L("라이브러리 다시 읽기", "Refresh Library")
            case .importLibrary: L("기존 라이브러리 들여오기…", "Import Existing Library…")
            case .settings: L("설정…", "Settings…")
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

extension SearchResult {
    /// A row for a word found inside a paper. The passage leads and the
    /// paper follows it: the sentence is what was being looked for, and the
    /// title is how you know which paper it is in.
    init(hit: PaperTextIndex.Hit) {
        let page = ReleaseNotes.string("\(hit.passage.pageIndex + 1)쪽",
                                       "p. \(hit.passage.pageIndex + 1)")
        let more = hit.count > 1
            ? ReleaseNotes.string(" · \(hit.count)번", " · \(hit.count) matches") : ""
        self.init(
            kind: .passage(hit.passage),
            title: hit.snippet,
            subtitle: "\(hit.title) · \(page)\(more)",
            symbolName: "text.magnifyingglass",
            score: 0
        )
    }
}

#if os(macOS)
extension SearchResult {
    /// A row for a passage that says what was typed in other words. The
    /// passage leads as a literal hit's does; there is no count, because
    /// "close in meaning" is not a thing that happens three times.
    init(meaning hit: SemanticIndex.Hit) {
        switch hit.origin {
        case let .paper(passage):
            let page = ReleaseNotes.string("\(passage.pageIndex + 1)쪽", "p. \(passage.pageIndex + 1)")
            self.init(
                kind: .meaning(passage),
                title: hit.snippet,
                subtitle: "\(hit.title) · \(page)",
                symbolName: "sparkle.magnifyingglass",
                score: Double(hit.score)
            )
        case let .note(place):
            // The note's name and then the word the exact search's note
            // rows wear, so a note reads as a note wherever it stands.
            self.init(
                kind: .meaningNote(place),
                title: hit.snippet,
                subtitle: "\(hit.title) · \(L("노트", "Note"))",
                symbolName: "note.text",
                score: Double(hit.score)
            )
        }
    }
}
#endif

/// Opens the paper a word was found in and sends the reader to the line.
///
/// The rectangle is worked out only now, by opening that one file: the index
/// keeps the page and the range of characters, which is small, and turns them
/// into a place on the page when somebody actually asks to go there.
///
/// Here rather than in the palette because two places ask for it now — the
/// palette, and the list of search results, which groups the papers that say
/// the word in their text under the ones that say it in their titles.
/// Opens the note a passage was found in and asks the editor to show the
/// passage's words. The slip-box shows the note whether it is about a
/// paper or not; the passage is found again by its words, since the index
/// cut the plain text and the editor holds the Markdown.
@MainActor
func openNotePassage(_ place: NotePassage, words: String, in model: LibraryModel) {
    model.scope = .notes
    model.notes.reveal = words
    model.notes.openNoteID = place.noteID
}

@MainActor
func openPassage(_ passage: PaperTextIndex.Passage, in model: LibraryModel, link: ReaderLink) {
    guard let paper = model.paper(passage.paperID) else { return }
    model.selectedPaperID = passage.paperID
    Task {
        let rect = await PaperTextIndex.shared.rect(for: passage, at: paper.documentURL)
        link.anchorRequest = ReaderLink.Anchor(
            pageIndex: passage.pageIndex, rect: rect ?? .zero, paperID: passage.paperID
        )
    }
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
            case 0: return L("오늘", "today")
            case 1: return L("어제", "yesterday")
            case 2..<14: return L("\(days)일 전", "\(days) days ago")
            case 14..<60: return L("\(days / 7)주 전", "\(days / 7) weeks ago")
            default: return L("\(days / 30)달 전", "\(days / 30) months ago")
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
            groups.append(Group(title: L("이어서 읽기", "Continue"), results: unfinished.map { paper in
                let pages = paper.meta.file.pageCount
                let left = pages - 1 - paper.state.lastPageIndex
                let progress = Double(paper.state.lastPageIndex + 1) / Double(pages)
                let reason = L("\(Int(progress * 100))% · \(left)쪽 남음 · \(ago(paper.state.lastOpenedAt ?? now))", "\(Int(progress * 100))% · \(left == 1 ? "1 page" : "\(left) pages") left · \(ago(paper.state.lastOpenedAt ?? now))")
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
                    return row(paper, L("“\(short)…”에도 나오는 말: \(match.shared.prefix(2).joined(separator: " · "))", "shares \(match.shared.prefix(2).joined(separator: " · ")) with “\(short)…”"), symbol: "waveform")
                }
                if !rows.isEmpty { groups.append(Group(title: L("읽은 논문과 울리는", "Because you read"), results: rows)) }
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
            groups.append(Group(title: L("다시 보기", "Revisit"), results: toRevisit.map { paper in
                let count = model.notes.notes(forPaper: paper.id).count
                return row(paper, L("\(ago(paper.state.lastOpenedAt ?? now)) 읽음 · 노트 \(count)개 — 지금 한 번 보면 남아요", "read \(ago(paper.state.lastOpenedAt ?? now)) · \(count == 1 ? "1 note" : "\(count) notes") — a look now keeps it"), symbol: "arrow.counterclockwise")
            }))
        }

        // New this week, unread.
        let fresh = papers.filter { now.timeIntervalSince($0.meta.addedAt) < 7 * 86_400 && $0.state.lastOpenedAt == nil && !taken.contains($0.id) }
            .sorted { $0.meta.addedAt > $1.meta.addedAt }
            .prefix(2)
        if !fresh.isEmpty {
            groups.append(Group(title: L("이번 주 새 논문", "New this week"), results: fresh.map { row($0, L("\(ago($0.meta.addedAt)) 더함", "added \(ago($0.meta.addedAt))"), symbol: "sparkles") }))
        }
        return groups
    }
}

/// Builds and ranks the palette's results for one query.
///
/// Scoring is deliberately simple and title-first: Spotlight reads as
/// predictable because a prefix match always beats a fuzzy one, not because
/// the ranking is clever.
///
/// The library is folded once, into a `Prepared`, and each keystroke only
/// compares against it. It used to fold everything — titles, authors, venues,
/// the first two hundred characters of every note — on every keystroke: 6 ms
/// at sixty papers, 63 ms at six hundred, 796 ms at six hundred and a thousand
/// notes. The answers are the same answers: the same folded strings, compared
/// the same way, in the same order.
@MainActor
enum SearchIndex {
    static func results(for query: String, in model: LibraryModel) -> [SearchResult] {
        results(for: query, in: prepared(for: model))
    }

    static func results(for query: String, in prepared: Prepared) -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let folded = SearchRanking.Folded(trimmed)
        let foldedQuery = folded.text
        guard !foldedQuery.isEmpty else { return [] }

        var results: [SearchResult] = []
        var matchedPapers = 0

        for paper in prepared.papers where paper.isTopLevel {
            if paper.everything.contains(foldedQuery) { matchedPapers += 1 }
        }
        if matchedPapers > 1 {
            // Searching for an author is searching for a body of work, not for
            // one paper. This row is what turns a lookup into a place.
            results.append(
                SearchResult(
                    kind: .showAll(trimmed),
                    title: L("\u{201C}\(trimmed)\u{201D}에 맞는 논문 모두 보기", "Show All Results for \u{201C}\(trimmed)\u{201D}"),
                    subtitle: L("논문 \(matchedPapers)편", "\(matchedPapers) papers"),
                    symbolName: "line.3.horizontal.decrease.circle",
                    score: 2
                )
            )
        }

        for paper in prepared.papers {
            guard let score = paperScore(folded, paper: paper) else { continue }
            // The paper you had open this morning comes before the one you
            // read in March: the same title match, and recency decides.
            let recency = paper.lastOpenedAt.map { max(0, 0.15 - Date.now.timeIntervalSince($0) / (30 * 86_400) * 0.15) } ?? 0
            results.append(
                SearchResult(
                    kind: .paper(paper.id),
                    title: paper.title,
                    subtitle: paper.subtitle,
                    symbolName: "doc.text",
                    score: score + recency
                )
            )
        }

        for entry in prepared.entries {
            guard let score = SearchRanking.score(folded, against: entry.folded) else { continue }
            results.append(
                SearchResult(
                    kind: entry.kind,
                    title: entry.title,
                    subtitle: entry.subtitle,
                    symbolName: entry.symbolName,
                    score: score + entry.bonus
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

    /// Everything a keystroke is compared with, folded when the palette opens
    /// and kept while nothing it was made from has changed.
    struct Prepared {
        struct Paper {
            let id: UUID
            /// Whether it stands on its own rather than hanging off another
            /// paper as a supplement.
            let isTopLevel: Bool
            let title: String
            let subtitle: String
            let lastOpenedAt: Date?
            let foldedTitle: SearchRanking.Folded
            /// The authors, the venue, the year, the cite key and the file,
            /// folded — what a paper also answers to when its title does not.
            let fields: String
            /// Everything `LibraryModel.matches` looks through, folded: what
            /// decides how many papers "Show All" promises.
            let everything: String
        }

        /// A note, a collection, a tag or an action: a name, and what to call
        /// it in a row.
        struct Entry {
            let kind: SearchResult.Kind
            let title: String
            let subtitle: String
            let symbolName: String
            let folded: SearchRanking.Folded
            /// Added to the score. A note sits a little below what it ties
            /// with: a paper called what you typed is the surer answer.
            let bonus: Double
        }

        let papers: [Paper]
        /// Notes, then collections, then tags, then actions — the order they
        /// were always ranked in, which is the order a tie keeps.
        let entries: [Entry]

        @MainActor init(model: LibraryModel) {
            papers = model.papers.map { paper in
                var everything = [
                    paper.meta.displayTitle,
                    paper.meta.csl.containerTitle ?? "",
                    paper.meta.csl.year.map(String.init) ?? "",
                    paper.meta.bibKey,
                    paper.meta.file.originalName,
                ]
                for author in paper.meta.csl.author {
                    everything.append(author.displayName)
                    everything.append("\(author.family ?? "") \(author.given ?? "")")
                }
                let fields = [
                    paper.meta.csl.author.map(\.displayName).joined(separator: " "),
                    paper.meta.csl.containerTitle ?? "",
                    paper.meta.csl.year.map(String.init) ?? "",
                    paper.meta.bibKey,
                    paper.meta.file.originalName,
                ]
                return Paper(
                    id: paper.id,
                    isTopLevel: paper.meta.parentID == nil,
                    title: paper.meta.displayTitle,
                    subtitle: SearchIndex.paperSubtitle(paper),
                    lastOpenedAt: paper.state.lastOpenedAt,
                    foldedTitle: SearchRanking.Folded(paper.meta.displayTitle),
                    fields: TextNormalization.foldedTitle(fields.joined(separator: " ")),
                    everything: TextNormalization.foldedTitle(everything.joined(separator: " "))
                )
            }

            var entries: [Entry] = []
            for note in model.notes.notes {
                let searchable = model.notes.searchable(note)
                guard !searchable.isEmpty else { continue }
                entries.append(Entry(
                    kind: .note(note.id),
                    title: searchable.displayTitle,
                    subtitle: note.kind == .map ? L("지도", "Map") : note.kind == .draft ? L("초안", "Draft") : L("노트", "Note"),
                    symbolName: note.kind == .map ? "map" : note.kind == .draft ? "doc.text" : "note.text",
                    folded: searchable.folded,
                    bonus: -0.05
                ))
            }
            for collection in model.collections.collections {
                entries.append(Entry(
                    kind: .collection(collection.id),
                    title: collection.name,
                    subtitle: collection.isSmart ? L("스마트 컬렉션", "Smart Collection") : L("컬렉션", "Collection"),
                    symbolName: collection.symbolName,
                    folded: SearchRanking.Folded(collection.name),
                    bonus: 0
                ))
            }
            for tag in model.manifest.tags {
                entries.append(Entry(
                    kind: .tag(tag.id),
                    title: tag.name,
                    subtitle: L("태그", "Tag"),
                    symbolName: "tag",
                    folded: SearchRanking.Folded(tag.name),
                    bonus: 0
                ))
            }
            for action in SearchResult.Action.allCases {
                entries.append(Entry(
                    kind: .action(action),
                    title: action.title,
                    subtitle: L("동작", "Action"),
                    symbolName: action.symbolName,
                    folded: SearchRanking.Folded(action.title),
                    bonus: 0
                ))
            }
            self.entries = entries
        }
    }

    /// The library as it was last folded, and what it was folded from. Here
    /// rather than in the model — see `LibraryModel.searchRevision`. The
    /// model is held weakly and compared by identity: a library opened after
    /// another starts its counts again, and must not find the last one's.
    private final class Kept {
        weak var model: LibraryModel?
        let revision: Int
        let notes: Int
        let language: String
        let prepared: Prepared

        @MainActor init(model: LibraryModel, language: String, prepared: Prepared) {
            self.model = model
            revision = model.searchRevision
            notes = model.notes.revision
            self.language = language
            self.prepared = prepared
        }
    }
    private static var kept: Kept?

    /// The library folded for ranking: the one made last time, while the
    /// papers, the notes, the tags, the collections and the language are all
    /// as they were then.
    static func prepared(for model: LibraryModel) -> Prepared {
        let language = L("ko", "en")
        if let kept, kept.model === model, kept.revision == model.searchRevision,
           kept.notes == model.notes.revision, kept.language == language {
            return kept.prepared
        }
        let made = Trace.time("palette: fold the library") { Prepared(model: model) }
        kept = Kept(model: model, language: language, prepared: made)
        return made
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
    private static func paperScore(_ query: SearchRanking.Folded, paper: Prepared.Paper) -> Double? {
        let titleScore = SearchRanking.score(query, against: paper.foldedTitle)
        let subtitleScore = (!paper.fields.isEmpty && paper.fields.contains(query.text)) ? 0.6 : nil

        switch (titleScore, subtitleScore) {
        case let (.some(title), .some(subtitle)): return max(title, subtitle)
        case let (.some(title), nil): return title
        case let (nil, .some(subtitle)): return subtitle
        case (nil, nil): return nil
        }
    }
}
