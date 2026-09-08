import Bibliography
import Foundation
import LibraryStore
import MetadataPipeline
import Observation
import PaperCore
import SwiftUI

/// The open library: the papers in it, what is selected, and what is being
/// worked on in the background.
@MainActor
@Observable
public final class LibraryModel {
    public enum SortOrder: String, CaseIterable, Identifiable, Sendable {
        case dateAdded, title, firstAuthor, year, lastOpened
        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .dateAdded: "Date Added"
            case .title: "Title"
            case .firstAuthor: "Author"
            case .year: "Year"
            case .lastOpened: "Last Opened"
            }
        }
    }

    public enum Scope: Hashable, Sendable {
        case all
        /// The results of a library-wide search, shown as its own source-list
        /// row so a search is somewhere you can be rather than a filter you
        /// have to remember you left on.
        case searchResults
        case unread
        case reading
        case read
        case favorites
        case needsReview
        case collection(UUID)
        case tag(UUID)
    }

    public let store: LibraryStore
    public let location: LibraryLocation

    public private(set) var papers: [LoadedPaper] = [] {
        didSet { rebuildDerivedIndexes() }
    }

    /// Row lookups by identifier, so a list of sixty papers does not do sixty
    /// linear scans every time one of them changes.
    /// The list the middle column shows, filtered and sorted once per change
    /// rather than once per redraw. `@ObservationIgnored` because filling a
    /// cache while a view is being built must not invalidate that view.
    @ObservationIgnored private var visibleCache: [LoadedPaper]?
    private var indexByID: [UUID: Int] = [:]
    private var attachmentIDsByParent: [UUID: [UUID]] = [:]
    public private(set) var counts = ScopeCounts()

    /// How many papers each source-list row stands for.
    ///
    /// Computed once per change to `papers` rather than per row, and counted
    /// over exactly the papers the list would show — supplements travel with
    /// their parent, so counting them would promise rows that never appear.
    public struct ScopeCounts: Equatable, Sendable {
        public var all = 0
        public var unread = 0
        public var reading = 0
        public var read = 0
        public var favorites = 0
        public var needsReview = 0
        /// Per collection and per tag, keyed by identifier.
        public var collections: [UUID: Int] = [:]
        public var tags: [UUID: Int] = [:]
    }
    public private(set) var manifest: LibraryManifest
    public private(set) var collections = CollectionSet()
    public private(set) var loadFailures: [String] = []
    public private(set) var isScanning = false
    /// PDFs sitting in the library folder that are not part of a paper yet.
    public private(set) var looseDocuments: [URL] = []

    public var scope: Scope = .all { didSet { invalidateVisibleCache() } }
    public var searchText = "" { didSet { invalidateVisibleCache() } }
    /// The query behind the `searchResults` scope, kept apart from the list's
    /// own filter field so leaving the scope does not silently keep filtering.
    public private(set) var searchQuery = ""
    public var sortOrder: SortOrder = .dateAdded { didSet { invalidateVisibleCache() } }
    public var sortAscending = false { didSet { invalidateVisibleCache() } }
    /// Every paper picked out in the list.
    ///
    /// A set rather than one identifier, so the list can offer the selection a
    /// Mac user expects — shift for a run, command for one at a time — and so a
    /// drag can carry all of them into a collection at once.
    public var selection: Set<UUID> = [] {
        didSet {
            guard selection != oldValue else { return }
            if selection.count == 1 {
                openPaperID = selection.first
            } else if selection.isEmpty {
                openPaperID = nil
            } else if let open = openPaperID, !selection.contains(open) {
                openPaperID = selection.first
            }
        }
    }

    private var openPaperID: UUID?

    /// The paper the reader is showing. Setting it is how everything outside
    /// the list — the search palette, a supplement, a menu — opens a paper.
    public var selectedPaperID: UUID? {
        get { openPaperID }
        set {
            openPaperID = newValue
            let wanted = newValue.map { Set([$0]) } ?? []
            if selection != wanted { selection = wanted }
            openPaperID = newValue
        }
    }

    /// Papers currently being resolved, so rows can show a spinner.
    public private(set) var resolving: Set<UUID> = []
    public private(set) var resolutionQueueDepth = 0
    public private(set) var onDeviceModelMessage: String

    private let resolver: MetadataResolver
    private let onDeviceExtractor = OnDeviceHeaderExtractor()
    /// Watches the library folder so a PDF put there from outside the app
    /// shows up without the user having to ask for it.
    private var watcher: FolderWatcher?
    private var folderCheck: Task<Void, Never>?
    private var pendingPositions: [UUID: Int] = [:]
    private var positionFlush: Task<Void, Never>?

    /// Whether metadata is looked up automatically for papers as they arrive.
    private var resolvesOnImport: Bool {
        UserDefaults.standard.object(forKey: "resolveMetadataOnImport") as? Bool ?? true
    }

    public init(store: LibraryStore, location: LibraryLocation, manifest: LibraryManifest) {
        self.store = store
        self.location = location
        self.manifest = manifest
        let contact = UserDefaults.standard.string(forKey: "metadataContactEmail")
        let network = NetworkService(contactEmail: contact?.isEmpty == false ? contact : nil)
        // The on-device model is tried first where it exists and simply reports
        // itself unavailable elsewhere, so the same code path serves every
        // device the user owns.
        self.resolver = MetadataResolver(
            network: network,
            contactEmail: contact?.isEmpty == false ? contact : nil,
            headerExtractor: CompositeHeaderExtractor([
                OnDeviceHeaderExtractor(),
                HeuristicHeaderExtractor(),
            ])
        )
        self.onDeviceModelMessage = OnDeviceHeaderExtractor().availability.message
    }

    // MARK: - Loading

    public func refresh() async {
        isScanning = true
        defer { isScanning = false }

        let result = try? await store.loadAll()
        papers = result?.papers ?? []
        loadFailures = (result?.failures ?? []).map {
            "\($0.0.lastPathComponent): \($0.1.localizedDescription)"
        }
        collections = (try? await store.loadCollections()) ?? CollectionSet()
        rebuildDerivedIndexes()
        manifest = (try? await store.loadManifest()) ?? manifest
        looseDocuments = await store.looseDocumentURLs()
        startWatchingFolder()
    }

    // MARK: - Watching the folder

    /// Starts reacting to changes made to the library folder from outside.
    public func startWatchingFolder() {
        guard watcher == nil else { return }
        let watcher = FolderWatcher(url: location.url) { [weak self] in
            Task { @MainActor [weak self] in await self?.folderDidChange() }
        }
        self.watcher = watcher
        watcher.start()
    }

    public func stopWatchingFolder() {
        watcher?.stop()
        watcher = nil
        folderCheck?.cancel()
        folderCheck = nil
    }

    /// Brings the library back in line with the folder.
    ///
    /// A PDF that appears in the library folder is a paper in the library —
    /// that is what choosing a folder means — so it is taken in rather than
    /// queued behind a prompt. Nothing is moved, renamed or rewritten: the new
    /// paper is a record beside the file that arrived.
    ///
    /// Papers that were sitting in the folder when it was first opened are a
    /// different matter and still wait to be offered, because the user has not
    /// yet said that folder full of PDFs is their library.
    public func folderDidChange() async {
        folderCheck?.cancel()
        folderCheck = Task { [weak self] in
            guard let self else { return }
            let claimed = Set(papers.map(\.meta.file.relativePath))
            let unclaimed = await store.unclaimedDocumentURLs(claiming: claimed)
            guard !Task.isCancelled else { return }

            if await store.documentsAreMissing(among: claimed) {
                // Something was renamed, moved or removed outside the app. A
                // full reload relinks records to their files by content.
                await refresh()
                return
            }
            guard !unclaimed.isEmpty else { return }

            if papers.isEmpty {
                // Still the opening offer, not an arrival.
                looseDocuments = unclaimed
                return
            }
            await adopt(unclaimed)
        }
        await folderCheck?.value
    }

    /// Gives the PDFs already sitting in the library folder a record.
    ///
    /// Nothing is moved or renamed: the file stays exactly where it is, and
    /// only the bibliographic record beside it is new.
    @discardableResult
    public func adoptLooseDocuments() async -> Int {
        await adopt(looseDocuments)
    }

    @discardableResult
    private func adopt(_ urls: [URL]) async -> Int {
        var digests: [String: PaperFolder] = [:]
        for paper in papers where !paper.meta.file.importDigest.isEmpty {
            digests[paper.meta.file.importDigest] = paper.folder
        }

        var added: [LoadedPaper] = []
        for url in urls {
            guard let outcome = try? await store.importDocument(
                at: url,
                knownDigests: digests
            ) else { continue }
            if case let .imported(paper) = outcome {
                papers.append(paper)
                added.append(paper)
                digests[paper.meta.file.importDigest] = paper.folder
            }
        }

        let adopted = Set(urls.map { $0.lastPathComponent })
        looseDocuments.removeAll { adopted.contains($0.lastPathComponent) }
        resolveInBackground(added.map(\.id))
        return added.count
    }

    // MARK: - Derived indexes

    private func rebuildDerivedIndexes() {
        visibleCache = nil
        var index: [UUID: Int] = [:]
        index.reserveCapacity(papers.count)
        var attachments: [UUID: [UUID]] = [:]
        var counts = ScopeCounts()

        for (position, paper) in papers.enumerated() {
            index[paper.id] = position
            if let parentID = paper.meta.parentID {
                attachments[parentID, default: []].append(paper.id)
                continue
            }
            counts.all += 1
            switch paper.state.readingStatus {
            case .unread: counts.unread += 1
            case .reading: counts.reading += 1
            case .read: counts.read += 1
            }
            if paper.state.isFavorite { counts.favorites += 1 }
            if paper.meta.confidence == .needsReview || paper.meta.confidence == .unparsed {
                counts.needsReview += 1
            }
            for id in paper.meta.tagIDs { counts.tags[id, default: 0] += 1 }
        }

        // Smart collections are a rule over the whole library, so they are
        // counted by asking the rule rather than by reading memberships.
        for collection in collections.collections {
            counts.collections[collection.id] = papers.filter {
                $0.meta.parentID == nil && matchesCollection(collection.id, paper: $0)
            }.count
        }

        indexByID = index
        attachmentIDsByParent = attachments
        self.counts = counts
    }

    /// The papers a drag beginning on `id` carries.
    ///
    /// Dragging one of several selected rows takes the whole selection, which
    /// is what makes filing a dozen papers into a collection one gesture.
    public func draggedPapers(startingAt id: UUID) -> [UUID] {
        selection.contains(id) ? Array(selection) : [id]
    }

    /// One paper by identifier, without scanning the library.
    public func paper(_ id: UUID) -> LoadedPaper? {
        guard let position = indexByID[id], position < papers.count else { return nil }
        return papers[position]
    }

    // MARK: - Presentation

    /// Supplements travel with their parent, so the library lists only the
    /// papers that stand on their own.
    private func invalidateVisibleCache() { visibleCache = nil }

    public var visiblePapers: [LoadedPaper] {
        if let visibleCache { return visibleCache }
        let result = computeVisiblePapers()
        visibleCache = result
        return result
    }

    private func computeVisiblePapers() -> [LoadedPaper] {
        var result = papers.filter { $0.meta.parentID == nil && matchesScope($0) }
        let query = scope == .searchResults
            ? searchQuery
            : searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            let folded = TextNormalization.foldedTitle(query)
            result = result.filter { Self.matches(folded: folded, paper: $0) }
        }
        return result.sorted(by: comparator)
    }

    /// Everything a person might type when they are looking for a paper they
    /// remember. Authors go in both orders because "LeCun Yann" is how a
    /// citation prints the same name the reader thinks of as "Yann LeCun".
    static func matches(folded query: String, paper: LoadedPaper) -> Bool {
        var haystack = [
            paper.meta.displayTitle,
            paper.meta.csl.containerTitle ?? "",
            paper.meta.csl.year.map(String.init) ?? "",
            paper.meta.bibKey,
            paper.meta.file.originalName,
        ]
        for author in paper.meta.csl.author {
            haystack.append(author.displayName)
            haystack.append("\(author.family ?? "") \(author.given ?? "")")
        }
        return TextNormalization.foldedTitle(haystack.joined(separator: " ")).contains(query)
    }

    public var reviewCount: Int { counts.needsReview }

    /// What to call the open library.
    ///
    /// The folder's own name, because every library is called "Paper Time"
    /// otherwise — which makes two different libraries look like one, and a
    /// collection that lives in the other one look like a collection that has
    /// been lost.
    public var displayName: String {
        let folder = location.url.lastPathComponent
        return folder.isEmpty ? manifest.displayName : folder
    }

    public var selectedPaper: LoadedPaper? {
        guard let selectedPaperID else { return nil }
        return paper(selectedPaperID)
    }

    // MARK: - Searching

    /// Puts the library into the search scope, which the sidebar shows as its
    /// own row.
    public func showSearchResults(for query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        searchQuery = trimmed
        invalidateVisibleCache()
        withAnimation(.snappy(duration: 0.2)) { scope = .searchResults }
    }

    public func clearSearchResults() {
        searchQuery = ""
        invalidateVisibleCache()
        if scope == .searchResults {
            withAnimation(.snappy(duration: 0.2)) { scope = .all }
        }
    }

    /// How many papers the current search would show, for the sidebar badge.
    public var searchResultCount: Int {
        guard !searchQuery.isEmpty else { return 0 }
        let folded = TextNormalization.foldedTitle(searchQuery)
        return papers.filter { $0.meta.parentID == nil && Self.matches(folded: folded, paper: $0) }
            .count
    }

    // MARK: - Supplements

    public func attachments(of paperID: UUID) -> [LoadedPaper] {
        (attachmentIDsByParent[paperID] ?? [])
            .compactMap { paper($0) }
            .sorted { $0.meta.displayTitle < $1.meta.displayTitle }
    }

    public func attachmentCount(of paperID: UUID) -> Int {
        attachmentIDsByParent[paperID]?.count ?? 0
    }

    public func parent(of paperID: UUID) -> LoadedPaper? {
        guard let parentID = paper(paperID)?.meta.parentID else { return nil }
        return paper(parentID)
    }

    /// Papers a given document could be attached to.
    ///
    /// Only top-level papers, and never itself: a supplement of a supplement
    /// would be unreachable in a list that shows neither.
    public func attachmentCandidates(for paperID: UUID) -> [LoadedPaper] {
        papers
            .filter { $0.id != paperID && $0.meta.parentID == nil }
            .filter { attachments(of: $0.id).isEmpty || true }
            .sorted { $0.meta.displayTitle < $1.meta.displayTitle }
    }

    public func attach(_ childID: UUID, to parentID: UUID) async {
        guard childID != parentID else { return }
        guard let child = papers.first(where: { $0.id == childID }),
              let parent = papers.first(where: { $0.id == parentID })
        else { return }
        // Attaching a paper that already has supplements would orphan them.
        guard attachments(of: childID).isEmpty, parent.meta.parentID == nil else { return }

        var meta = child.meta
        meta.parentID = parentID
        if let saved = try? await store.save(meta: meta, in: child.folder, baseline: child.meta) {
            applyLocally(meta: saved, to: childID)
        }
        if selectedPaperID == childID { selectedPaperID = parentID }
    }

    public func detach(_ childID: UUID) async {
        guard let child = papers.first(where: { $0.id == childID }),
              child.meta.parentID != nil
        else { return }
        var meta = child.meta
        meta.parentID = nil
        if let saved = try? await store.save(meta: meta, in: child.folder, baseline: child.meta) {
            applyLocally(meta: saved, to: childID)
        }
    }

    /// The paper a document looks like a supplement to, if any.
    public func suggestedParent(for paperID: UUID) -> LoadedPaper? {
        guard let paper = papers.first(where: { $0.id == paperID }),
              paper.meta.parentID == nil,
              attachments(of: paperID).isEmpty,
              SupplementDetector.looksLikeSupplement(
                  fileName: paper.meta.file.originalName,
                  title: paper.meta.csl.fullTitle
              )
        else { return nil }

        let candidates = papers
            .filter { $0.id != paperID && $0.meta.parentID == nil }
            .map { (id: $0.id, title: $0.meta.displayTitle) }
        guard let parentID = SupplementDetector.bestParent(
            forFileName: paper.meta.file.originalName,
            title: paper.meta.csl.fullTitle,
            among: candidates
        ) else { return nil }
        return papers.first { $0.id == parentID }
    }

    public func tag(for id: UUID) -> Tag? {
        manifest.tags.first { $0.id == id }
    }

    private func matchesScope(_ paper: LoadedPaper) -> Bool {
        switch scope {
        case .all, .searchResults: true
        case .unread: paper.state.readingStatus == .unread
        case .reading: paper.state.readingStatus == .reading
        case .read: paper.state.readingStatus == .read
        case .favorites: paper.state.isFavorite
        case .needsReview:
            paper.meta.confidence == .needsReview || paper.meta.confidence == .unparsed
        case let .collection(id): matchesCollection(id, paper: paper)
        case let .tag(id): paper.meta.tagIDs.contains(id)
        }
    }

    private func matchesCollection(_ id: UUID, paper: LoadedPaper) -> Bool {
        guard let collection = collections.collections.first(where: { $0.id == id }) else {
            return false
        }
        guard let rule = collection.rule else { return paper.meta.collectionIDs.contains(id) }
        return SmartRuleEvaluator.matches(rule, paper: paper, tags: manifest.tags)
    }

    private func comparator(_ lhs: LoadedPaper, _ rhs: LoadedPaper) -> Bool {
        let ascending = sortAscending
        func order(_ result: Bool) -> Bool { ascending ? result : !result }

        switch sortOrder {
        case .dateAdded:
            return order(lhs.meta.addedAt < rhs.meta.addedAt)
        case .title:
            return order(
                lhs.meta.displayTitle.localizedCaseInsensitiveCompare(rhs.meta.displayTitle)
                    == .orderedAscending
            )
        case .firstAuthor:
            let left = lhs.meta.csl.author.first?.sortingSurname ?? "zzz"
            let right = rhs.meta.csl.author.first?.sortingSurname ?? "zzz"
            return order(left.localizedCaseInsensitiveCompare(right) == .orderedAscending)
        case .year:
            return order((lhs.meta.csl.year ?? 0) < (rhs.meta.csl.year ?? 0))
        case .lastOpened:
            return order(
                (lhs.state.lastOpenedAt ?? .distantPast) < (rhs.state.lastOpenedAt ?? .distantPast)
            )
        }
    }

    // MARK: - Import

    @discardableResult
    public func importDocuments(at urls: [URL]) async -> (added: Int, duplicates: Int) {
        var digests: [String: PaperFolder] = [:]
        for paper in papers where !paper.meta.file.importDigest.isEmpty {
            digests[paper.meta.file.importDigest] = paper.folder
        }

        var added: [LoadedPaper] = []
        var duplicates = 0
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let outcome = try? await store.importDocument(at: url, knownDigests: digests) else {
                continue
            }
            switch outcome {
            case let .imported(paper):
                papers.append(paper)
                added.append(paper)
                digests[paper.meta.file.importDigest] = paper.folder
            case .duplicate:
                duplicates += 1
            }
        }
        resolveInBackground(added.map(\.id))
        return (added.count, duplicates)
    }

    // MARK: - Metadata

    /// Looks papers up one after another, off the back of the current action.
    ///
    /// One task rather than one per paper: sixty concurrent lookups saturate
    /// both the network services (which then rate-limit us) and the main actor
    /// they report back to, and the list stutters for a minute.
    private func resolveInBackground(_ ids: [UUID]) {
        guard resolvesOnImport, !ids.isEmpty else { return }
        Task { [weak self] in
            for id in ids {
                guard let self else { return }
                await resolveMetadata(for: id)
            }
        }
    }

    /// Runs the resolution pipeline for one paper and stores the outcome.
    public func resolveMetadata(for paperID: UUID) async {
        guard let index = papers.firstIndex(where: { $0.id == paperID }) else { return }
        let paper = papers[index]
        guard paper.meta.confidence != .manual else { return }
        guard !resolving.contains(paperID) else { return }

        resolving.insert(paperID)
        resolutionQueueDepth += 1
        defer {
            resolving.remove(paperID)
            resolutionQueueDepth = max(0, resolutionQueueDepth - 1)
        }

        let url = paper.documentURL
        // Opening a PDF and pulling text out of its first pages takes long
        // enough to drop frames, and this runs once per paper on a fresh
        // library. It has no business on the main actor.
        let extraction = Task.detached(priority: .utility) {
            DocumentSignalsExtractor.extract(fromFileAt: url)
        }
        guard let signals = await extraction.value else { return }
        let result = await resolver.resolve(
            signals: signals,
            originalFileName: paper.meta.file.originalName
        )

        var meta = paper.meta
        meta.csl = result.csl
        meta.identifiers = result.identifiers
        meta.confidence = result.confidence
        meta.provenance = result.provenance
        meta.candidates = result.candidates
        meta.bibKey = CitationKey.make(for: result.csl, fallback: meta.file.originalName)
        meta.csl.id = meta.bibKey

        if let saved = try? await store.save(
            meta: meta,
            in: paper.folder,
            baseline: paper.meta
        ) {
            applyLocally(meta: saved, to: paperID)
        }
    }

    /// Re-runs resolution for everything that is not yet confirmed.
    public func resolveAllPending() async {
        let pending = papers
            .filter { $0.meta.confidence == .unparsed || $0.meta.confidence == .needsReview }
            .map(\.id)
        for id in pending {
            await resolveMetadata(for: id)
        }
    }

    /// Accepts one of the offered candidates as the record for a paper.
    public func acceptCandidate(_ candidate: MetadataCandidate, for paperID: UUID) async {
        guard let paper = papers.first(where: { $0.id == paperID }) else { return }
        var meta = paper.meta
        meta.csl = candidate.csl
        meta.identifiers = candidate.identifiers
        meta.confidence = .manual
        meta.provenance = Provenance(
            source: candidate.provenance.source,
            detail: "confirmed by you"
        )
        meta.candidates = []
        meta.bibKey = CitationKey.make(for: candidate.csl, fallback: meta.file.originalName)
        meta.csl.id = meta.bibKey
        if let saved = try? await store.save(meta: meta, in: paper.folder, baseline: paper.meta) {
            applyLocally(meta: saved, to: paperID)
        }
    }

    public func update(meta: PaperMeta, for paperID: UUID) async {
        guard let paper = papers.first(where: { $0.id == paperID }) else { return }
        var edited = meta
        edited.confidence = .manual
        edited.candidates = []
        if let saved = try? await store.save(meta: edited, in: paper.folder, baseline: paper.meta) {
            applyLocally(meta: saved, to: paperID)
        }
    }

    // MARK: - Reading state
    //
    // Every one of these reads the current value out of `papers` rather than
    // trusting a copy the caller is holding. A view keeps a snapshot of a paper
    // for as long as it is on screen, and writing a change derived from a stale
    // snapshot quietly reverts whatever else changed in the meantime.

    public func setReadingStatus(_ status: PaperState.ReadingStatus, for paperID: UUID) async {
        await mutateState(paperID) { $0.readingStatus = status }
    }

    public func setFavorite(_ isFavorite: Bool, for paperID: UUID) async {
        await mutateState(paperID) { $0.isFavorite = isFavorite }
    }

    public func toggleFavorite(for paperID: UUID) async {
        await mutateState(paperID) { $0.isFavorite.toggle() }
    }

    public func setRating(_ rating: Int?, for paperID: UUID) async {
        await mutateState(paperID) { $0.rating = rating }
    }

    public func setSummaryNote(_ note: String, for paperID: UUID) async {
        await mutateState(paperID) { $0.summaryNote = note }
    }

    public func recordOpened(_ paperID: UUID) async {
        await mutateState(paperID) { $0.lastOpenedAt = .now }
    }

    public func recordReadingPosition(page: Int, for paperID: UUID) async {
        await mutateState(paperID) {
            $0.lastPageIndex = page
            $0.lastOpenedAt = .now
        }
    }

    /// Applies a change to the paper's current state and writes it, passing the
    /// version it started from so an ordinary save is never mistaken for a
    /// conflict.
    private func mutateState(
        _ paperID: UUID,
        _ change: (inout PaperState) -> Void
    ) async {
        guard let index = papers.firstIndex(where: { $0.id == paperID }) else { return }
        let paper = papers[index]
        var updated = paper.state
        change(&updated)
        guard updated != paper.state else { return }

        // Show the change straight away; the write is a few milliseconds of
        // file I/O and the interface should not wait on it.
        papers[index].state = updated

        if let saved = try? await store.save(
            state: updated,
            in: paper.folder,
            baseline: paper.state
        ), let currentIndex = papers.firstIndex(where: { $0.id == paperID }) {
            papers[currentIndex].state = saved
        }
    }

    /// Kept for the inspector, which edits several fields at once.
    /// Remembers where the reader is, without writing a file per page turn.
    ///
    /// Turning a page used to save immediately, which meant a JSON write and a
    /// full list refresh for every flick of the wrist. The position only has to
    /// be right by the time the paper is closed or the app leaves the screen.
    public func recordReadingPosition(_ index: Int, for paperID: UUID) {
        pendingPositions[paperID] = index
        positionFlush?.cancel()
        positionFlush = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            await self?.flushReadingPositions()
        }
    }

    /// Writes any remembered position now. Called when a paper closes.
    public func flushReadingPositions() async {
        positionFlush?.cancel()
        positionFlush = nil
        let pending = pendingPositions
        pendingPositions.removeAll()
        for (paperID, index) in pending {
            guard let paper = paper(paperID) else { continue }
            var state = paper.state
            state.lastPageIndex = index
            state.lastOpenedAt = .now
            await update(state: state, for: paperID)
        }
    }

    public func update(state: PaperState, for paperID: UUID) async {
        guard let index = papers.firstIndex(where: { $0.id == paperID }) else { return }
        let paper = papers[index]
        guard state != paper.state else { return }
        papers[index].state = state
        if let saved = try? await store.save(
            state: state,
            in: paper.folder,
            baseline: paper.state
        ), let currentIndex = papers.firstIndex(where: { $0.id == paperID }) {
            papers[currentIndex].state = saved
        }
    }

    public func moveToTrash(_ paperID: UUID) async {
        guard let paper = papers.first(where: { $0.id == paperID }) else { return }
        _ = try? await store.moveToTrash(paper)
        papers.removeAll { $0.id == paperID }
        if selectedPaperID == paperID { selectedPaperID = nil }
    }

    private func applyLocally(meta: PaperMeta, to paperID: UUID) {
        guard let index = papers.firstIndex(where: { $0.id == paperID }) else { return }
        papers[index].meta = meta
    }

    // MARK: - Tags and collections

    public func addTag(named name: String, color: Tag.Color) async -> Tag {
        let tag = Tag(name: name, color: color)
        manifest.tags.append(tag)
        try? await store.saveManifest(manifest)
        return tag
    }

    public func setTags(_ ids: [UUID], for paperID: UUID) async {
        guard let paper = papers.first(where: { $0.id == paperID }) else { return }
        var meta = paper.meta
        meta.tagIDs = ids
        if let saved = try? await store.save(
            meta: meta,
            in: paper.folder,
            baseline: paper.meta
        ) {
            applyLocally(meta: saved, to: paperID)
        }
    }

    public func addCollection(named name: String, rule: Collection.SmartRule? = nil) async {
        var set = collections
        set.collections.append(
            Collection(name: name, rule: rule, sortIndex: set.collections.count)
        )
        collections = set
        rebuildDerivedIndexes()
        try? await store.saveCollections(set)
    }

    /// Adds one paper to one collection, leaving its other memberships alone.
    public func addToCollection(_ collectionID: UUID, paperID: UUID) async {
        guard let paper = papers.first(where: { $0.id == paperID }) else { return }
        guard !paper.meta.collectionIDs.contains(collectionID) else { return }
        var meta = paper.meta
        meta.collectionIDs.append(collectionID)
        if let saved = try? await store.save(
            meta: meta,
            in: paper.folder,
            baseline: paper.meta
        ) {
            applyLocally(meta: saved, to: paperID)
        }
    }

    public func addTag(_ tagID: UUID, to paperID: UUID) async {
        guard let paper = papers.first(where: { $0.id == paperID }) else { return }
        guard !paper.meta.tagIDs.contains(tagID) else { return }
        var meta = paper.meta
        meta.tagIDs.append(tagID)
        if let saved = try? await store.save(
            meta: meta,
            in: paper.folder,
            baseline: paper.meta
        ) {
            applyLocally(meta: saved, to: paperID)
        }
    }

    public func setCollections(_ ids: [UUID], for paperID: UUID) async {
        guard let paper = papers.first(where: { $0.id == paperID }) else { return }
        var meta = paper.meta
        meta.collectionIDs = ids
        if let saved = try? await store.save(
            meta: meta,
            in: paper.folder,
            baseline: paper.meta
        ) {
            applyLocally(meta: saved, to: paperID)
        }
    }
}

/// Evaluates a smart collection's rule against a paper.
enum SmartRuleEvaluator {
    static func matches(_ rule: Collection.SmartRule, paper: LoadedPaper, tags: [Tag]) -> Bool {
        let results = rule.conditions.map { evaluate($0, paper: paper, tags: tags) }
        guard !results.isEmpty else { return true }
        return rule.matchAll ? results.allSatisfy { $0 } : results.contains(true)
    }

    private static func evaluate(
        _ condition: Collection.SmartRule.Condition,
        paper: LoadedPaper,
        tags: [Tag]
    ) -> Bool {
        let actual: String = switch condition.field {
        case .title: paper.meta.displayTitle
        case .author: paper.meta.csl.author.map(\.displayName).joined(separator: " ")
        case .year: String(paper.meta.csl.year ?? 0)
        case .venue: paper.meta.csl.containerTitle ?? ""
        case .tag: paper.meta.tagIDs
            .compactMap { id in tags.first { $0.id == id }?.name }
            .joined(separator: " ")
        case .readingStatus: paper.state.readingStatus.rawValue
        case .confidence: paper.meta.confidence.rawValue
        case .dateAdded: ISO8601DateFormat.string(from: paper.meta.addedAt)
        }

        switch condition.comparison {
        case .contains:
            return actual.localizedCaseInsensitiveContains(condition.value)
        case .equals:
            return actual.compare(condition.value, options: .caseInsensitive) == .orderedSame
        case .notEquals:
            return actual.compare(condition.value, options: .caseInsensitive) != .orderedSame
        case .greaterThan:
            return (Double(actual) ?? 0) > (Double(condition.value) ?? 0)
        case .lessThan:
            return (Double(actual) ?? 0) < (Double(condition.value) ?? 0)
        }
    }
}

enum ISO8601DateFormat {
    static func string(from date: Date) -> String {
        date.formatted(.iso8601.year().month().day())
    }
}
