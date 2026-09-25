import Bibliography
import Foundation
import LibraryStore
import MetadataPipeline
import Observation
import PDFReader
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
        /// The papers open in this session, in the order they were opened —
        /// what a browser's tab strip is, as a shelf.
        case open
        /// The slip-box, which is not a filter over papers but a place of its
        /// own: all the notes, whichever paper they came from.
        case notes
        /// The results of a library-wide search, shown as its own source-list
        /// row so a search is somewhere you can be rather than a filter you
        /// have to remember you left on.
        case searchResults
        /// The three kinds, which only appear as rows once a library holds
        /// more than one of them: a shelf of papers that has never seen a
        /// manual should look exactly as it did.
        case papers
        case books
        case lectures
        case documents
        /// One of the folders the library is reading.
        case folder(URL)
        case unread
        case reading
        case read
        case favorites
        case needsReview
        case collection(UUID)
        case tag(UUID)
        /// Everything by one author, who is named rather than numbered because
        /// a person is not a record in this app — they are the name on a paper.
        case author(String)
        /// The library drawn as what is connected to what.
        case graph
    }

    public let store: LibraryStore
    public let location: LibraryLocation
    /// The folders opened beside the first one.
    ///
    /// Every folder is a library in its own right — its own `.papertime`, its
    /// own records beside its own PDFs — and they are read together into one
    /// list. Everything a folder's papers carry is kept in that folder: their
    /// records, their notes, and the tags and collections they wear. So a
    /// folder opened on another machine arrives whole, and disconnecting one
    /// here takes exactly that folder and leaves the rest alone.
    public private(set) var extraSources: [LibraryLocation] = []
    private var extraStores: [LibraryStore] = []

    /// Each folder's own vocabulary, as it is on disk. The lists the app
    /// shows — `manifest.tags`, `collections` — are these merged.
    private var manifests: [URL: LibraryManifest] = [:]
    private var collectionSets: [URL: CollectionSet] = [:]

    /// Every folder the library is reading, the first one first.
    public var sources: [LibraryLocation] { [location] + extraSources }
    private var allStores: [LibraryStore] { [store] + extraStores }

    /// Which folder a paper came from, and so which store writes it.
    /// Every open folder as (its path, its url), longest path first, so the
    /// first prefix that matches is the answer.
    ///
    /// Worked out when the folders change rather than per paper: this is
    /// asked once for every paper in the library on every read, and it used
    /// to build two arrays and re-encode every root's path each time.
    @ObservationIgnored private var rootPathsCache: [(path: String, url: URL)]?

    private var rootPaths: [(path: String, url: URL)] {
        if let rootPathsCache { return rootPathsCache }
        let made = sources
            .map { (path: $0.url.path(percentEncoded: false), url: $0.url) }
            .sorted { $0.path.count > $1.path.count }
        rootPathsCache = made
        return made
    }

    /// A folder inside the library, the way the sidebar shows one.
    public struct FolderNode: Identifiable, Hashable, Sendable {
        public let url: URL
        /// Papers at or under it.
        public let count: Int
        public var name: String { url.lastPathComponent }
        public var id: URL { url }
    }

    /// The folder whose inside is being shown, if the shelf is a folder.
    public var openFolder: URL? {
        if case let .folder(url) = scope { return url }
        return nil
    }

    /// Whether this paper sits at or under a folder.
    ///
    /// At **or under**: a folder shows everything beneath it, so pressing a
    /// term shows the term and pressing a week narrows to the week. The old
    /// test asked only which library root a paper belonged to, which is the
    /// same answer for a root and no answer at all for anything inside one.
    func isUnder(_ paper: LoadedPaper, _ folder: URL) -> Bool {
        let base = folder.path(percentEncoded: false)
        let path = paper.documentURL.path(percentEncoded: false)
        return path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }

    /// The folders directly inside this one that hold papers, and how many
    /// each holds counting everything beneath it.
    ///
    /// Read off the papers rather than off the disk. The tree is then always
    /// exactly what the list can show — a folder with nothing in it is not a
    /// place you can go and find nothing — and it costs no round trip on a
    /// cloud folder, which is the whole reason this app stopped walking them.
    public func subfolders(of folder: URL) -> [FolderNode] {
        let base = folder.path(percentEncoded: false)
        let prefix = base.hasSuffix("/") ? base : base + "/"
        var counts: [String: Int] = [:]
        for paper in papers where paper.meta.parentID == nil {
            let path = paper.documentURL.deletingLastPathComponent().path(percentEncoded: false)
            guard path.hasPrefix(prefix) else { continue }
            let rest = path.dropFirst(prefix.count)
            guard let head = rest.split(separator: "/").first.map(String.init), !head.isEmpty else { continue }
            counts[head, default: 0] += 1
        }
        return counts
            .map { FolderNode(url: folder.appending(path: $0.key, directoryHint: .isDirectory), count: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The visible papers gathered by the folder they sit in, when that is
    /// worth showing.
    ///
    /// A kind's shelf takes papers from every folder at once — the whole point
    /// of it — and sixty rows from four folders in one run is sixty rows you
    /// cannot place. Nil everywhere else: a folder's own shelf is already one
    /// folder, and a heading over one group is a label on a thing with no
    /// counterpart.
    /// The folder grouping, as identifiers — see `visiblePaperIDs`.
    @ObservationIgnored private var byFolderIDCache: [(folder: URL, ids: [UUID])]??
    public var visibleIDsByFolder: [(folder: URL, ids: [UUID])]? {
        if let byFolderIDCache { return byFolderIDCache }
        let made = visibleByFolder?.map { (folder: $0.folder, ids: $0.papers.map(\.id)) }
        byFolderIDCache = .some(made)
        return made
    }

    public var visibleByFolder: [(folder: URL, papers: [LoadedPaper])]? {
        switch scope {
        case .papers, .books, .lectures, .documents: break
        default: return nil
        }
        var groups: [URL: [LoadedPaper]] = [:]
        for paper in visiblePapers {
            groups[paper.documentURL.deletingLastPathComponent(), default: []].append(paper)
        }
        guard groups.count > 1 else { return nil }
        return groups
            .map { (folder: $0.key, papers: $0.value) }
            .sorted { folderLabel(for: $0.folder).localizedStandardCompare(folderLabel(for: $1.folder)) == .orderedAscending }
    }

    /// A folder said the way somebody would read it aloud: the library's name,
    /// then the way down. The whole path would be a line of machinery.
    public func folderLabel(for folder: URL) -> String {
        let trail = folderTrail(to: folder)
        return trail.map(\.lastPathComponent).joined(separator: " › ")
    }

    /// The way from the library root down to this folder, root first.
    public func folderTrail(to folder: URL) -> [URL] {
        guard let root = sources.map(\.url).first(where: {
            let base = $0.path(percentEncoded: false)
            let path = folder.path(percentEncoded: false)
            return path == base || path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
        }) else { return [folder] }

        var trail: [URL] = []
        var here = folder
        while here.path(percentEncoded: false) != root.path(percentEncoded: false) {
            trail.append(here)
            let up = here.deletingLastPathComponent()
            // A path that will not shorten is a path that would loop.
            guard up.path(percentEncoded: false).count < here.path(percentEncoded: false).count else { break }
            here = up
        }
        trail.append(root)
        return trail.reversed()
    }

    /// Where pressing an open folder again goes: out one level, and out of
    /// the folders altogether when it is a library root.
    public func folderAbove(_ folder: URL) -> URL? {
        if sources.contains(where: { $0.url.path(percentEncoded: false) == folder.path(percentEncoded: false) }) {
            return nil
        }
        let up = folder.deletingLastPathComponent()
        return up.path(percentEncoded: false).count < folder.path(percentEncoded: false).count ? up : nil
    }

    public func rootURL(of paper: LoadedPaper) -> URL {
        let path = paper.folder.url.path(percentEncoded: false)
        // The longest root that is a prefix: folders do not normally nest,
        // and when they do the inner one owns the paper.
        return rootPaths.first { path.hasPrefix($0.path) }?.url ?? location.url
    }

    func store(for paper: LoadedPaper) -> LibraryStore {
        let root = rootURL(of: paper)
        return allStores.first { $0.root == root } ?? store
    }

    /// The folder a file on disk belongs to — where a PDF dropped in is
    /// taken in, and where one added by hand is recorded.
    func source(containing url: URL) -> LibraryStore {
        let path = url.path(percentEncoded: false)
        return allStores
            .filter { path.hasPrefix($0.root.path(percentEncoded: false)) }
            .max { $0.root.path.count < $1.root.path.count }
            ?? store
    }

    /// Where a paper added from outside every folder goes: the folder being
    /// looked at, or the first one.
    var importDestination: LibraryStore {
        if case let .folder(root) = scope, let found = allStores.first(where: { $0.root == root }) {
            return found
        }
        return store
    }

    /// Opens another folder beside the ones already open.
    ///
    /// Nothing is copied or moved. The folder keeps its own `.papertime`, so
    /// disconnecting it later leaves it exactly as it was — which is the
    /// whole promise of a library that is a folder.
    public func addSource(_ location: LibraryLocation, store: LibraryStore) async {
        guard attachSource(location, store: store) else { return }
        stopWatchingFolder()
        await refresh()
    }

    /// Takes a folder in without reading anything.
    ///
    /// For assembling the library at launch, where one read at the end serves
    /// every folder: adding them one at a time re-read the whole library after
    /// each, so a library of three folders read itself three times before the
    /// window had anything in it — and the reads it threw away were the ones
    /// that had to wait for the cloud.
    @discardableResult
    func attachSource(_ location: LibraryLocation, store: LibraryStore) -> Bool {
        let root = location.url
        guard !sources.contains(where: { $0.url == root }) else { return false }
        extraSources.append(location)
        extraStores.append(store)
        rootPathsCache = nil
        return true
    }

    /// Stops reading a folder. Its files and its records stay where they are.
    public func removeSource(_ root: URL) async {
        guard let index = extraSources.firstIndex(where: { $0.url == root }) else { return }
        extraSources.remove(at: index)
        extraStores.removeAll { $0.root == root }
        rootPathsCache = nil
        if case let .folder(current) = scope, current == root { scope = .all }
        stopWatchingFolder()
        await refresh()
    }
    /// Every note in the library, and what points at what.
    public let notes: NotesModel
    /// What is connected to what.
    public let graph = GraphModel()

    public private(set) var papers: [LoadedPaper] = [] {
        didSet {
            rebuildDerivedIndexes()
            searchRevision &+= 1
        }
    }

    /// Where each paper's file stands against its import, once asked for
    /// (`provenance(of:)`), kept by the file's size and date.
    public internal(set) var provenances: [UUID: FileProvenance] = [:]
    @ObservationIgnored var provenanceStamps: [UUID: FileStamp] = [:]
    @ObservationIgnored var provenanceInProgress: Set<UUID> = []
    /// A restore of a paper's original text, waiting for a yes.
    public var restore: RestoreFlow?
    /// What the last restore came to — done, or why not — for an alert.
    public var restoreNotice: String?
    @ObservationIgnored public internal(set) var lastRestore: PaperRestore.Report?

    /// Bumped whenever anything Search Everything ranks changes — a paper, a
    /// tag, a collection — so what it folded when the palette opened can be
    /// told from what is there now. A number and not the folding itself:
    /// derived state kept in here would be written on every change to the
    /// papers, and every write here is a write the views are watching.
    @ObservationIgnored public private(set) var searchRevision = 0

    /// Row lookups by identifier, so a list of sixty papers does not do sixty
    /// linear scans every time one of them changes.
    /// The list the middle column shows, filtered and sorted once per change
    /// rather than once per redraw. `@ObservationIgnored` because filling a
    /// cache while a view is being built must not invalidate that view.
    @ObservationIgnored private var visibleCache: [LoadedPaper]?
    private var indexByID: [UUID: Int] = [:]
    private var attachmentIDsByParent: [UUID: [UUID]] = [:]
    public private(set) var counts = ScopeCounts()
    /// Every paper that stands on its own, in title order — see
    /// `attachmentCandidates(for:)`.
    @ObservationIgnored private var attachableCache: [LoadedPaper]?
    private var attachable: [LoadedPaper] {
        if let attachableCache { return attachableCache }
        let made = papers
            .filter { $0.meta.parentID == nil }
            .sorted { $0.meta.displayTitle < $1.meta.displayTitle }
        attachableCache = made
        return made
    }

    /// How many papers each source-list row stands for.
    ///
    /// Computed once per change to `papers` rather than per row, and counted
    /// over exactly the papers the list would show — supplements travel with
    /// their parent, so counting them would promise rows that never appear.
    public struct ScopeCounts: Equatable, Sendable {
        public var all = 0
        public var papers = 0
        public var books = 0
        public var lectures = 0
        public var documents = 0
        /// How many papers each folder holds, by its root.
        public var folders: [URL: Int] = [:]
        public var unread = 0
        public var reading = 0
        public var read = 0
        public var favorites = 0
        public var needsReview = 0
        /// Per collection and per tag, keyed by identifier.
        public var collections: [UUID: Int] = [:]
        public var tags: [UUID: Int] = [:]
    }
    public private(set) var manifest: LibraryManifest {
        didSet {
            tagByIDCache = nil
            searchRevision &+= 1
        }
    }
    public private(set) var collections = CollectionSet() {
        didSet {
            collectionByIDCache = nil
            searchRevision &+= 1
        }
    }

    /// The tags and the collections by identifier.
    ///
    /// Both lists are short and both were being scanned linearly from inside
    /// loops over the library: every row in the list looked up each of its
    /// tags, and counting the collections looked up the collection once per
    /// paper per collection.
    @ObservationIgnored private var tagByIDCache: [UUID: Tag]?
    @ObservationIgnored private var collectionByIDCache: [UUID: Collection]?

    private var tagByID: [UUID: Tag] {
        if let tagByIDCache { return tagByIDCache }
        let made = Dictionary(manifest.tags.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        tagByIDCache = made
        return made
    }

    private var collectionByID: [UUID: Collection] {
        if let collectionByIDCache { return collectionByIDCache }
        let made = Dictionary(
            collections.collections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )
        collectionByIDCache = made
        return made
    }
    /// Records the folders hold and the last read could not get at.
    ///
    /// `loadAll()` has always skipped a record it could not read and handed
    /// back what failed, which is why one half-arrived `meta.json` never took
    /// a Mac library down. What was missing was anybody saying so: this was
    /// collected and read by nothing, so a library quietly short by a paper
    /// looked exactly like a library that was not. The list says it now, and
    /// while it has anything in it the folder's loose PDFs are not offered.
    public private(set) var loadFailures: [String] = []
    public private(set) var isScanning = false
    /// PDFs sitting in the library folder that are not part of a paper yet.
    public private(set) var looseDocuments: [URL] = []
    /// Whether the folder's PDFs are being taken in right now, and how many.
    ///
    /// The count is what this pass was handed — not `looseDocuments`, which is
    /// empty when the watcher started this on its own and would have the row
    /// saying it was adding nothing.
    public private(set) var isAdopting = false
    public private(set) var adoptingCount = 0
    /// Whether a second request arrived while the first was running.
    @ObservationIgnored private var adoptAgain = false
    /// The ones the last adoption could not take in.
    ///
    /// Reading a PDF can fail — a cloud file that has not come down, a file
    /// whose permissions changed — and a failure that says nothing is a button
    /// that does nothing. Cleared at the start of each adoption, so it always
    /// describes the last press.
    public private(set) var adoptFailures: [String] = []

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

    private var openPaperID: UUID? {
        didSet { if scope == .open, openPaperID != oldValue { invalidateVisibleCache() } }
    }

    /// The paper the reader is showing. Setting it is how everything outside
    /// the list — the search palette, a supplement, a menu — opens a paper.
    public var selectedPaperID: UUID? {
        get { openPaperID }
        set {
            openPaperID = newValue
            let wanted = newValue.map { Set([$0]) } ?? []
            if selection != wanted { selection = wanted }
            openPaperID = newValue
            if !isTravellingHistory { remember(newValue) }
        }
    }

    /// The papers kept open in this session, in the order they were kept.
    ///
    /// Not every paper looked at: walking down the list shows each paper in
    /// turn, and a shelf that kept all of them would be the list again. A
    /// paper is kept when it is *used* — clicked into, drawn on, put beside
    /// another — the way an editor's preview tab becomes a real tab once you
    /// start typing in it. The one merely showing is on the shelf too, as a
    /// preview, and leaves when the next one is shown.
    public private(set) var openPaperIDs: [UUID] = [] {
        didSet { if scope == .open { invalidateVisibleCache() } }
    }

    public func isOpenPaper(_ id: UUID) -> Bool { openPaperIDs.contains(id) }

    /// The ones somebody pinned, as against the ones the app kept because
    /// they were used.
    ///
    /// Both sit on the open shelf, and for a while both lit the pin at the
    /// head of the row — so reading a paper pinned it, which is not what a
    /// pin is. A pin is something you do. What the app does on its own
    /// belongs on the shelf, where it is visible as what it is, and nowhere
    /// else.
    public private(set) var pinnedPaperIDs: Set<UUID> = []

    public func isPinned(_ id: UUID) -> Bool { pinnedPaperIDs.contains(id) }

    /// Keeps a paper on the open shelf.
    ///
    /// - Parameter byHand: somebody asked for this — the pin, the row's menu,
    ///   a paper put beside another. Clicking into a paper is not that.
    public func keepOpen(_ id: UUID, byHand: Bool = false) {
        guard paper(id) != nil else { return }
        if byHand { pinnedPaperIDs.insert(id) }
        guard !openPaperIDs.contains(id) else { return }
        openPaperIDs.append(id)
    }

    /// Takes the pin out, leaving the paper where it is.
    public func unpin(_ id: UUID) { pinnedPaperIDs.remove(id) }

    /// Takes a paper off the open shelf. If it was the one showing, its
    /// neighbour on the shelf comes forward; with the shelf empty, nothing
    /// is showing.
    public func closeOpenPaper(_ id: UUID) {
        pinnedPaperIDs.remove(id)
        let at = openPaperIDs.firstIndex(of: id)
        if let at { openPaperIDs.remove(at: at) }
        guard selectedPaperID == id else { return }
        let next: UUID? = if let at, openPaperIDs.indices.contains(at) {
            openPaperIDs[at]
        } else {
            openPaperIDs.last
        }
        selectedPaperID = next
    }

    public func closeOtherOpenPapers(keeping id: UUID) {
        pinnedPaperIDs = pinnedPaperIDs.filter { $0 == id }
        openPaperIDs = openPaperIDs.filter { $0 == id }
        if selectedPaperID != id { selectedPaperID = id }
    }

    // MARK: - Where you have been

    /// The papers opened, in order, and where in that trail the reader is —
    /// what a browser's back and forward are, for papers. Opening a paper
    /// adds it after the current place and forgets what lay beyond it, the
    /// way a browser does.
    public private(set) var trail: [UUID] = []
    public private(set) var trailIndex = -1
    private var isTravellingHistory = false

    private func remember(_ id: UUID?) {
        guard let id, trail.indices.contains(trailIndex) == false || trail[trailIndex] != id else { return }
        if trailIndex < trail.count - 1 { trail.removeSubrange((trailIndex + 1)...) }
        trail.append(id)
        trailIndex = trail.count - 1
    }

    public var canGoBack: Bool { trailIndex > 0 }
    public var canGoForward: Bool { trailIndex < trail.count - 1 }

    public func goBack() {
        guard canGoBack else { return }
        travel(to: trailIndex - 1)
    }

    public func goForward() {
        guard canGoForward else { return }
        travel(to: trailIndex + 1)
    }

    private func travel(to index: Int) {
        trailIndex = index
        isTravellingHistory = true
        selectedPaperID = trail[index]
        isTravellingHistory = false
    }

    /// Papers currently being resolved, so rows can show a spinner.
    ///
    /// Brought up to date with the rest of a batch rather than on every
    /// insert and removal: the list reads this set, so a library resolving
    /// six hundred papers one after another asked the whole list to look at
    /// itself twelve hundred times.
    public private(set) var resolving: Set<UUID> = []
    /// The truth behind `resolving`, which is what the guard against running
    /// a paper twice reads. Not observed: nobody draws from it.
    @ObservationIgnored private var resolvingNow: Set<UUID> = []
    public private(set) var resolutionQueueDepth = 0

    /// Metadata that has come back and is waiting to go into `papers`.
    ///
    /// Writing one paper's answer into the array rebuilds every derived index
    /// and asks SwiftUI to consider the whole list again, and an import
    /// resolves once per paper. Measured on a generated library of six
    /// hundred: 284 index rebuilds during a single scroll, a scroll step of
    /// five seconds at the ninety-fifth percentile and a worst step of sixty.
    /// Nobody can tell whether a row settled now or a quarter of a second
    /// ago, so the answers are gathered and put in together.
    ///
    /// Only the resolver's writes are gathered. What somebody did by hand —
    /// naming a kind, renaming a file, attaching a supplement — goes in at
    /// once, because a hand that acted is a hand waiting to see it.
    @ObservationIgnored private var pendingResolved: [UUID: PaperMeta] = [:]
    @ObservationIgnored private var resolvedFlush: Task<Void, Never>?
    /// How long answers wait for company. Long enough to gather a batch out
    /// of a fast registrar, short enough that a single paper resolved by hand
    /// still feels immediate.
    private static let resolvedFlushDelay = Duration.milliseconds(250)
    public private(set) var onDeviceModelMessage: String

    private let resolver: MetadataResolver
    private let onDeviceExtractor = OnDeviceHeaderExtractor()
    /// Watches the library folder so a PDF put there from outside the app
    /// shows up without the user having to ask for it.
    private var watchers: [FolderWatcher] = []
    private var folderCheck: Task<Void, Never>?
    private var pendingPositions: [UUID: Int] = [:]
    private var positionFlush: Task<Void, Never>?

    /// Whether metadata is looked up automatically for papers as they arrive.
    ///
    /// `--papertime-no-lookup=1` turns it off **for one run** rather than in
    /// the settings: a probe that filled a test folder would otherwise spend
    /// minutes on the registrars, and a probe must not remember anything —
    /// the app is sandboxed per bundle id, so writing the setting would write
    /// it for the copy the reader uses.
    private var resolvesOnImport: Bool {
        if Boot.isSet("PAPERTIME_NO_LOOKUP") { return false }
        return UserDefaults.standard.object(forKey: "resolveMetadataOnImport") as? Bool ?? true
    }

    /// `notes` arrives already pointed at the right box for the notes about
    /// no paper — the app decides that before anything is read, because a
    /// first reading of the wrong box is a slip-box that briefly has the
    /// wrong notes in it. No default, on purpose: a default would be the
    /// app's own folder, which is the reader's real notes, and a probe that
    /// forgot to say otherwise would read and write them.
    public init(
        store: LibraryStore,
        location: LibraryLocation,
        manifest: LibraryManifest,
        notes: NotesModel
    ) {
        self.store = store
        self.location = location
        self.manifest = manifest
        self.notes = notes
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

        let stores = allStores
        // All the folders at once. They are different disks as often as not —
        // one on a cloud drive that has to wake up should not hold up the one
        // on this machine, and read one after another the slowest folder set
        // the time for all of them.
        var gathered = [(papers: [LoadedPaper], failures: [String], loose: [URL])](
            repeating: ([], [], []), count: stores.count
        )
        await Trace.time("library: read \(stores.count) folder(s)") {
            await withTaskGroup(of: (Int, [LoadedPaper], [String], [URL]).self) { group in
                for (position, source) in stores.enumerated() {
                    group.addTask {
                        let result = try? await source.loadAll()
                        let papers = result?.papers ?? []
                        let failures = (result?.failures ?? []).map {
                            "\($0.0.lastPathComponent): \($0.1.localizedDescription)"
                        }
                        // The records have just been read, and each one says
                        // which PDF it claims. Asking the folder for its loose
                        // documents used to read every record again from disk
                        // to work that out — the whole library decoded twice
                        // for one refresh, on a folder that may be in the
                        // cloud.
                        let claimed = Set(papers.map(\.meta.file.relativePath))
                        // Nothing, when a record in this folder would not be
                        // read. A record that failed is a paper whose PDF is
                        // still spoken for, so `claimed` is short by exactly
                        // that paper and its file looks free — and offering it
                        // takes the same paper in a second time, under a second
                        // identifier, with none of its marks. Not knowing which
                        // PDFs are claimed is not the same as knowing one is
                        // free, and this is the answer nobody can take back.
                        let loose = failures.isEmpty
                            ? await source.unclaimedDocumentURLs(claiming: claimed)
                            : []
                        return (position, papers, failures, loose)
                    }
                }
                // By position, so the first folder's papers stay first however
                // the reads finish.
                for await (position, papers, failures, loose) in group {
                    gathered[position] = (papers, failures, loose)
                }
            }
        }

        loadFailures = gathered.flatMap(\.failures)
        looseDocuments = gathered.flatMap(\.loose)
        // The vocabulary before the papers: setting `papers` rebuilds the
        // derived indexes, and the collection counts are counted against the
        // collections. Loaded the other way round they were built once
        // against the old vocabulary and once again against the new one.
        await Trace.time("library: read the vocabulary") { await loadVocabulary() }
        papers = gathered.flatMap(\.papers)
        notes.read(folders: stores, of: { [weak self] id in self?.folder(ofPaper: id) })
        await Trace.time("library: read the notes") { await notes.load() }
        await settleVocabulary()
        startWatchingFolder()
    }

    /// Asks the cloud for whatever it has not brought yet, then reads the
    /// folder again.
    ///
    /// The folder is watched and polled already, but iCloud does not announce
    /// what it is carrying and will not carry what nobody asked for: a mark
    /// made on another device can take several seconds to arrive. Several
    /// seconds with nothing to press is a wait that reads as a fault, so
    /// there is something to press.
    public func pullFromCloud() async {
        let url = location.url
        await Task.detached(priority: .userInitiated) {
            FileOperations.requestPendingDownloads(in: url)
        }.value
        await refresh()
    }

    // MARK: - Watching the folder

    /// Starts reacting to changes made to the library folder from outside.
    public func startWatchingFolder() {
        guard watchers.isEmpty else { return }
        // One watcher per folder: each is a library of its own, and a PDF
        // dropped into any of them is a paper in this one.
        watchers = sources.map { source in
            FolderWatcher(url: source.url) { [weak self] in
                Task { @MainActor [weak self] in await self?.folderDidChange() }
            }
        }
        for watcher in watchers { watcher.start() }
    }

    public func stopWatchingFolder() {
        for watcher in watchers { watcher.stop() }
        watchers = []
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
            // As in `refresh`: taking a PDF in on the app's own account is
            // only safe when every record answered, because the check for a
            // paper already here is a check against the records. Nothing is
            // lost by waiting — this runs again on the next change to the
            // folder, and on every reload.
            guard loadFailures.isEmpty else { return }
            let claimed = Set(papers.map(\.meta.file.relativePath))
            var unclaimed: [URL] = []
            for source in allStores {
                unclaimed += await source.unclaimedDocumentURLs(claiming: claimed)
            }
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
        // One at a time. The folder is watched, and taking papers in changes
        // the folder, so a press of the row and the watcher's own answer to it
        // can be in here together — both holding the same list of unclaimed
        // files, both recording every one of them.
        //
        // The one that arrives second is not thrown away, though. It is
        // remembered and the folder is read again at the end: a PDF dropped in
        // while two hundred others are being taken in is a PDF nobody would
        // ever be offered, because the row it would appear on is the row that
        // is busy.
        guard !isAdopting else {
            adoptAgain = true
            return 0
        }
        adoptFailures = []
        isAdopting = true
        adoptingCount = urls.count
        defer {
            isAdopting = false
            adoptingCount = 0
        }
        var digests: [String: PaperFolder] = [:]
        for paper in papers where !paper.meta.file.importDigest.isEmpty {
            digests[paper.meta.file.importDigest] = paper.folder
        }

        // Files a record already speaks for. `looseDocuments` is a list from
        // the last read of the folder, and papers can be taken in between that
        // read and this press — by dragging one in from the library folder
        // itself, or by choosing it in Add PDFs. A file already inside the
        // folder no longer answers the digest check (that is what lets a
        // second copy be taken in), so without this the stale entry becomes a
        // second record for a file that already has one: two rows, two record
        // folders, and two mark journals writing back into one PDF.
        var claimed: Set<String> = []
        for paper in papers { claimed.insert(LibraryStore.normalizedPath(paper.documentURL)) }

        var added: [LoadedPaper] = []
        // Taken in a handful at a time rather than one at a time. Appending to
        // `papers` rebuilds every derived index and asks SwiftUI to look at
        // the whole list again, so a folder of six hundred did that six
        // hundred times — measured, a scroll during an import had a worst step
        // of sixty seconds. A chunk is small enough that the list still fills
        // in front of you and large enough that the rebuilds are a rounding
        // error.
        var waiting: [LoadedPaper] = []
        var struck: Set<String> = []
        func putIn() {
            guard !waiting.isEmpty else { return }
            papers.append(contentsOf: waiting)
            waiting.removeAll(keepingCapacity: true)
            // The count on the row comes down with each handful rather than
            // all at once at the end: taking in two hundred files is a wait,
            // and a number that does not move for the whole of it is a button
            // that looks stuck.
            looseDocuments.removeAll { struck.contains($0.path(percentEncoded: false)) }
            struck.removeAll(keepingCapacity: true)
        }
        // Only what was actually taken in comes off the list, and by its whole
        // path. Both halves of that were wrong: every URL the loop was handed
        // was struck off whether or not it got a record, so a PDF that could
        // not be read vanished from the count and came back on the next read of
        // the folder — pressed, it appeared to do something, and did nothing —
        // and striking off by file name alone took `2026-2학기/slides.pdf` off
        // the list because `2026-1학기/slides.pdf` had been taken in.
        var refused: [String] = []
        for url in urls {
            guard !claimed.contains(LibraryStore.normalizedPath(url)) else { continue }
            // Into the folder the file is already in: adopting a PDF must
            // never move it to another folder.
            let into = self.source(containing: url)
            do {
                if case let .imported(paper) = try await into.importDocument(
                    at: url,
                    knownDigests: digests
                ) {
                    waiting.append(paper)
                    added.append(paper)
                    digests[paper.meta.file.importDigest] = paper.folder
                    claimed.insert(LibraryStore.normalizedPath(paper.documentURL))
                    struck.insert(url.path(percentEncoded: false))
                    if waiting.count >= 25 { putIn() }
                } else {
                    refused.append(url.lastPathComponent)
                }
            } catch {
                refused.append(url.lastPathComponent)
            }
        }
        putIn()

        // What could not be taken in, so that the row says so rather than
        // sitting there with the same number on it.
        adoptFailures = refused
        resolveInBackground(added.map(\.id))

        // Whatever arrived while this was running. Read the folder rather than
        // trusting a list taken before any of this: the folder is what the
        // question is about.
        if adoptAgain {
            adoptAgain = false
            isAdopting = false
            adoptingCount = 0
            await folderDidChange()
        }
        return added.count
    }

    // MARK: - Derived indexes

    private func rebuildDerivedIndexes() {
        Trace.time("library: index \(papers.count) papers") { rebuildDerivedIndexesNow() }
    }

    private func rebuildDerivedIndexesNow() {
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
            switch paper.meta.effectiveKind {
            case .paper: counts.papers += 1
            case .book: counts.books += 1
            case .lecture: counts.lectures += 1
            case .document: counts.documents += 1
            }
            counts.folders[rootURL(of: paper), default: 0] += 1
            switch paper.state.readingStatus {
            case .unread: counts.unread += 1
            case .reading: counts.reading += 1
            case .read: counts.read += 1
            }
            if paper.state.isFavorite { counts.favorites += 1 }
            // Only a paper: the shelf means "the registrar's answer might be
            // wrong", and a book or a document was never asked.
            if paper.meta.effectiveKind.isLookedUp,
               paper.meta.confidence == .needsReview || paper.meta.confidence == .unparsed {
                counts.needsReview += 1
            }
            for id in paper.meta.tagIDs { counts.tags[id, default: 0] += 1 }
        }

        // Smart collections are a rule over the whole library, so they are
        // counted by asking the rule rather than by reading memberships. The
        // collection itself, not its identifier: looking it up by identifier
        // scanned the collections once per paper per collection, and building
        // an array to take the count of it allocated one per collection.
        for collection in collections.collections {
            counts.collections[collection.id] = papers.count {
                $0.meta.parentID == nil && matches(collection, paper: $0)
            }
        }

        indexByID = index
        attachmentIDsByParent = attachments
        self.counts = counts
        rebuildAuthorRanking()
        // A new paper is a new node and, once its references are read, new
        // connections: the graph should not have to be asked.
        graph.markStale()
    }

    /// The papers a drag beginning on `id` carries.
    ///
    /// Dragging one of several selected rows takes the whole selection, which
    /// is what makes filing a dozen papers into a collection one gesture.
    public func draggedPapers(startingAt id: UUID) -> [UUID] {
        selection.contains(id) ? Array(selection) : [id]
    }

    /// One paper by identifier, without scanning the library.
    /// Every paper's citation key, as the BibTeX export would write it —
    /// the paper's own where it has one, made up where it has not, and
    /// unique across the library.
    public func citationKeys() -> [UUID: String] {
        CitationKey.assignKeys(to: papers.map {
            (id: $0.id, item: $0.meta.csl, preferred: $0.meta.bibKey.isEmpty ? nil : $0.meta.bibKey)
        })
    }

    public func paper(_ id: UUID) -> LoadedPaper? {
        guard let position = indexByID[id], position < papers.count else { return nil }
        return papers[position]
    }

    // MARK: - Presentation

    /// Supplements travel with their parent, so the library lists only the
    /// papers that stand on their own.
    private func invalidateVisibleCache() {
        visibleCache = nil
        visibleIDCache = nil
        byFolderIDCache = nil
        attachableCache = nil
    }

    public var visiblePapers: [LoadedPaper] {
        if let visibleCache { return visibleCache }
        let result = computeVisiblePapers()
        visibleCache = result
        return result
    }

    /// The same list, as identifiers.
    ///
    /// What the list iterates over. `ForEach` builds its view list from the
    /// whole collection on every update, and a `LoadedPaper` is a struct full
    /// of strings and arrays — so walking six hundred of them is six hundred
    /// retain/release storms for a scroll that draws twelve rows. A `UUID` is
    /// sixteen bytes and owns nothing.
    @ObservationIgnored private var visibleIDCache: [UUID]?
    public var visiblePaperIDs: [UUID] {
        if let visibleIDCache { return visibleIDCache }
        let made = visiblePapers.map(\.id)
        visibleIDCache = made
        return made
    }

    private func computeVisiblePapers() -> [LoadedPaper] {
        var result = papers.filter { $0.meta.parentID == nil && matchesScope($0) }
        if scope == .open {
            // In the order they were kept, not the list's sort: this shelf
            // is a row of tabs. The preview — showing, not kept — is last.
            let order = Dictionary(uniqueKeysWithValues: openPaperIDs.enumerated().map { ($1, $0) })
            return result.sorted { (order[$0.id] ?? Int.max) < (order[$1.id] ?? Int.max) }
        }
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
        withAnimation(Motion.move) { scope = .searchResults }
    }

    public func clearSearchResults() {
        searchQuery = ""
        invalidateVisibleCache()
        if scope == .searchResults {
            withAnimation(Motion.move) { scope = .all }
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
    /// The papers something could be attached to: everything that stands on
    /// its own, in title order, less the one being attached.
    ///
    /// The order is worked out once per change to the library rather than per
    /// ask. It used to sort the whole library on every call, and the call was
    /// made twice by every row in the list — sixty-two rows, a hundred and
    /// twenty-four sorts, before anybody had opened a menu.
    public func attachmentCandidates(for paperID: UUID) -> [LoadedPaper] {
        attachable.filter { $0.id != paperID }
    }

    /// Whether there is anything to attach this to — asked by the menu item,
    /// which only needs to know if the list would be empty and should not
    /// build and filter that list to find out.
    public func hasAttachmentCandidates(for paperID: UUID) -> Bool {
        attachable.contains { $0.id != paperID }
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
        if let saved = try? await store(for: child).save(meta: meta, in: child.folder, baseline: child.meta) {
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
        if let saved = try? await store(for: child).save(meta: meta, in: child.folder, baseline: child.meta) {
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

    /// Who appears on the most papers in this library.
    ///
    /// Counted over papers rather than authorships, so a name is ranked by how
    /// much of the shelf it is on, and the same person written two ways —
    /// "Yann LeCun" and "Y. LeCun" — is counted once, by surname and initial.
    public struct AuthorRank: Identifiable, Hashable, Sendable {
        public var key: String
        public var name: String
        public var count: Int
        public var id: String { key }
    }

    public private(set) var authorRanking: [AuthorRank] = []

    /// The keys a paper contributes: one per distinct author on it.
    nonisolated static func authorKeys(of paper: LoadedPaper) -> Set<String> {
        Set(paper.meta.csl.author.compactMap(authorKey))
    }

    /// One person, however their name was written on the paper.
    nonisolated static func authorKey(_ name: CSLName) -> String? {
        PaperGraphBuilder.authorKey(name)
    }

    private func rebuildAuthorRanking() {
        var counts: [String: Int] = [:]
        var names: [String: String] = [:]
        for paper in papers where paper.meta.parentID == nil {
            for author in paper.meta.csl.author {
                guard let key = Self.authorKey(author) else { continue }
                counts[key, default: 0] += 1
                let display = author.displayName
                // Keep the fullest spelling seen: "Yann LeCun" over "Y. LeCun".
                if display.count > (names[key]?.count ?? 0) { names[key] = display }
            }
        }
        authorRanking = counts
            .map { AuthorRank(key: $0.key, name: names[$0.key] ?? $0.key, count: $0.value) }
            .sorted {
                $0.count == $1.count
                    ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                    : $0.count > $1.count
            }
    }

    public func tag(for id: UUID) -> Tag? { tagByID[id] }

    private func matchesScope(_ paper: LoadedPaper) -> Bool {
        switch scope {
        case .all, .searchResults: true
        case .open: openPaperIDs.contains(paper.id) || openPaperID == paper.id
        // These two are places of their own, not filters over papers.
        case .notes, .graph: false
        case .papers: paper.meta.effectiveKind == .paper
        case .books: paper.meta.effectiveKind == .book
        case .lectures: paper.meta.effectiveKind == .lecture
        case .documents: paper.meta.effectiveKind == .document
        case let .folder(root): isUnder(paper, root)
        case .unread: paper.state.readingStatus == .unread
        case .reading: paper.state.readingStatus == .reading
        case .read: paper.state.readingStatus == .read
        case .favorites: paper.state.isFavorite
        case .needsReview:
            paper.meta.effectiveKind.isLookedUp
                && (paper.meta.confidence == .needsReview || paper.meta.confidence == .unparsed)
        case let .collection(id): matchesCollection(id, paper: paper)
        case let .tag(id): paper.meta.tagIDs.contains(id)
        case let .author(key): Self.authorKeys(of: paper).contains(key)
        }
    }

    private func matchesCollection(_ id: UUID, paper: LoadedPaper) -> Bool {
        guard let collection = collectionByID[id] else { return false }
        return matches(collection, paper: paper)
    }

    private func matches(_ collection: Collection, paper: LoadedPaper) -> Bool {
        guard let rule = collection.rule else {
            return paper.meta.collectionIDs.contains(collection.id)
        }
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

        // A file already in one of the folders is now given a record even when
        // another paper has the same bytes — that is what lets a second copy
        // sitting in the folder be taken in. Which means this path has to say
        // for itself that a file *already recorded* is not taken in twice:
        // dragging a paper out of the library window and back into it would
        // otherwise leave two records claiming one file.
        // Compared the way the store compares them — symlinks resolved, no
        // trailing separator. A URL from a drop, an open panel and the Finder
        // are three spellings of one file, and `importDocument` decides
        // "already inside" with this same normalization: a check that used the
        // raw string would pass a file straight through to a second record.
        var claimed: Set<String> = []
        for paper in papers { claimed.insert(LibraryStore.normalizedPath(paper.documentURL)) }
        var taken: Set<String> = []

        var added: [LoadedPaper] = []
        var duplicates = 0
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard !claimed.contains(LibraryStore.normalizedPath(url)) else {
                duplicates += 1
                continue
            }
            guard let outcome = try? await importDestination.importDocument(at: url, knownDigests: digests) else {
                continue
            }
            switch outcome {
            case let .imported(paper):
                papers.append(paper)
                added.append(paper)
                digests[paper.meta.file.importDigest] = paper.folder
                claimed.insert(LibraryStore.normalizedPath(paper.documentURL))
                // It was one of the folder's own PDFs and now it is a paper,
                // so the row that offers it has one fewer to offer. Left
                // standing, that row would hand the same file to `adopt` and
                // make a second record for it.
                taken.insert(LibraryStore.normalizedPath(paper.documentURL))
            case .duplicate:
                duplicates += 1
            }
        }
        looseDocuments.removeAll { taken.contains(LibraryStore.normalizedPath($0)) }
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
            // Whatever the last batch gathered goes in now rather than
            // waiting out a delay nobody is filling any more.
            self?.flushResolved()
        }
    }

    /// Runs the resolution pipeline for one paper and stores the outcome.
    public func resolveMetadata(for paperID: UUID) async {
        guard let index = papers.firstIndex(where: { $0.id == paperID }) else { return }
        let paper = papers[index]
        guard paper.meta.confidence != .manual else { return }
        guard !resolvingNow.contains(paperID) else { return }

        resolvingNow.insert(paperID)
        resolutionQueueDepth += 1
        scheduleResolvedFlush()
        defer {
            resolvingNow.remove(paperID)
            resolutionQueueDepth = max(0, resolutionQueueDepth - 1)
            scheduleResolvedFlush()
        }

        let url = paper.documentURL
        // Opening a PDF and pulling text out of its first pages takes long
        // enough to drop frames, and this runs once per paper on a fresh
        // library. It has no business on the main actor.
        let extraction = Task.detached(priority: .utility) {
            DocumentSignalsExtractor.extract(fromFileAt: url)
        }
        guard let signals = await extraction.value else { return }

        // What this looks like, before anything is asked of a registrar.
        //
        // A document that shows no sign of being a paper is not looked up at
        // all: Crossref has nothing to say about a lease agreement, and
        // sending its title out to ask is both useless and somebody's
        // business but ours. The inspector asks what the file is, with this
        // as the offered answer.
        let guess = signals.guess
        var meta = paper.meta
        if meta.guessedKind == nil { meta.guessedKind = guess.kind }
        if !meta.effectiveKind.isLookedUp {
            if let saved = try? await store(for: paper).save(meta: meta, in: paper.folder, baseline: paper.meta) {
                stageResolved(meta: saved, to: paperID)
            }
            return
        }

        let result = await resolver.resolve(
            signals: signals,
            originalFileName: paper.meta.file.originalName
        )

        meta.csl = result.csl
        meta.identifiers = result.identifiers
        meta.confidence = result.confidence
        meta.provenance = result.provenance
        meta.candidates = result.candidates
        meta.bibKey = CitationKey.make(for: result.csl, fallback: meta.file.originalName)
        meta.csl.id = meta.bibKey

        if let saved = try? await store(for: paper).save(
            meta: meta,
            in: paper.folder,
            baseline: paper.meta
        ) {
            stageResolved(meta: saved, to: paperID)
        }
    }

    /// Records the answer to "what is this?" — and looks the paper up when
    /// the answer turns a document into one.
    public func setKind(_ kind: DocumentKind, for paperID: UUID) async {
        guard let paper = papers.first(where: { $0.id == paperID }) else { return }
        var meta = paper.meta
        guard meta.kind != kind else { return }
        let wasUnlookedUp = !meta.effectiveKind.isLookedUp && meta.confidence == .unparsed
        meta.kind = kind
        if !kind.isLookedUp {
            // Nothing to review about a document or a book: neither has a
            // registrar to disagree with, so the "needs review" shelf lets it
            // go.
            meta.candidates = []
            if meta.confidence == .needsReview { meta.confidence = .unparsed }
        }
        if kind == .book {
            // Called a book, it is written down as one — so the export says
            // `@book` and the citation prints a publisher rather than a
            // journal. Only when it is not already some kind of book: a
            // chapter somebody typed in themselves is their answer, not ours.
            if meta.csl.type != .book, meta.csl.type != .chapter { meta.csl.type = .book }
            // The journal's fields belong to a journal. Left on, they print
            // in the export and read as a book with a volume and an issue —
            // which is how a textbook ends up cited as pages 1054–1054 of an
            // IEEE transaction.
            meta.csl.containerTitle = nil
            meta.csl.containerTitleShort = nil
            meta.csl.volume = nil
            meta.csl.issue = nil
            meta.csl.page = nil
            meta.csl.issn = nil
        }
        if let saved = try? await store(for: paper).save(meta: meta, in: paper.folder, baseline: paper.meta) {
            applyLocally(meta: saved, to: paperID)
        }
        if kind == .paper, wasUnlookedUp { await resolveMetadata(for: paperID) }
    }

    /// Re-runs resolution for everything that is not yet confirmed.
    public func resolveAllPending() async {
        let pending = papers
            .filter { $0.meta.effectiveKind.isLookedUp }
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
        if let saved = try? await store(for: paper).save(meta: meta, in: paper.folder, baseline: paper.meta) {
            applyLocally(meta: saved, to: paperID)
        }
    }

    public func update(meta: PaperMeta, for paperID: UUID) async {
        guard let paper = papers.first(where: { $0.id == paperID }) else { return }
        var edited = meta
        edited.confidence = .manual
        edited.candidates = []
        if let saved = try? await store(for: paper).save(meta: edited, in: paper.folder, baseline: paper.meta) {
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

        if let saved = try? await store(for: paper).save(
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
        if let saved = try? await store(for: paper).save(
            state: state,
            in: paper.folder,
            baseline: paper.state
        ), let currentIndex = papers.firstIndex(where: { $0.id == paperID }) {
            papers[currentIndex].state = saved
        }
    }

    public func moveToTrash(_ paperID: UUID) async {
        guard let paper = papers.first(where: { $0.id == paperID }) else { return }
        _ = try? await store(for: paper).moveToTrash(paper)
        papers.removeAll { $0.id == paperID }
        if selectedPaperID == paperID { selectedPaperID = nil }
        // The words that were read out of it go with it: nothing will ask for
        // them again, and a cache that only grows is a folder that only grows.
        await PaperTextIndex.shared.forget(paperID)
    }

    private func applyLocally(meta: PaperMeta, to paperID: UUID) {
        guard let index = papers.firstIndex(where: { $0.id == paperID }) else { return }
        papers[index].meta = meta
    }

    /// The same, for an answer the resolver found rather than a person: it
    /// waits for the others. See `pendingResolved`.
    private func stageResolved(meta: PaperMeta, to paperID: UUID) {
        pendingResolved[paperID] = meta
        scheduleResolvedFlush()
    }

    private func scheduleResolvedFlush() {
        guard resolvedFlush == nil else { return }
        resolvedFlush = Task { [weak self] in
            try? await Task.sleep(for: Self.resolvedFlushDelay)
            guard let self else { return }
            resolvedFlush = nil
            flushResolved()
        }
    }

    /// Puts a batch of answers in with one write to `papers`, and brings the
    /// spinners up to date in the same breath.
    private func flushResolved() {
        if !pendingResolved.isEmpty {
            var updated = papers
            var changed = false
            for (id, meta) in pendingResolved {
                guard let index = indexByID[id], updated[index].meta != meta else { continue }
                updated[index].meta = meta
                changed = true
            }
            pendingResolved.removeAll(keepingCapacity: true)
            // One assignment, so the derived indexes are rebuilt once for the
            // batch rather than once for every paper in it.
            if changed { papers = updated }
        }
        if resolving != resolvingNow { resolving = resolvingNow }
    }

    // MARK: - The file's name

    /// Renames the PDF on disk.
    ///
    /// The name in the app and the name in Finder are meant to be the same
    /// name, so this moves the file. Whoever has the paper open is written
    /// out first and then told where it went: a session saves its marks back
    /// to the path it opened from, and one that was never told would put the
    /// paper back under its old name a highlight later.
    public func rename(paperID: UUID, to name: String) async throws {
        guard let paper = papers.first(where: { $0.id == paperID }) else { return }
        for session in DocumentSession.open(forPaper: paperID) { await session.flush() }
        let renamed = try await store(for: paper).rename(paper, to: name)
        if let index = papers.firstIndex(where: { $0.id == paperID }) {
            papers[index].meta = renamed.meta
            papers[index].documentURL = renamed.documentURL
        }
        for session in DocumentSession.open(forPaper: paperID) {
            session.documentMoved(to: renamed.documentURL, meta: renamed.meta)
        }
    }

    /// What each folder actually holds, written to stderr.
    ///
    /// `--papertime-folders=1`. Everything a folder's papers carry is kept in
    /// that folder now — their records, their notes, and the tags and
    /// collections they wear — and the only way to see that without a hand on
    /// the machine is to ask each folder what is written in it.
    public func reportFolders() async {
        var report = ""
        for source in allStores {
            let mine = papers.filter { rootURL(of: $0) == source.root }
            let folderManifest = try? await source.loadManifest()
            let set = try? await source.loadCollections()
            let box = await source.loadNotes()
            report += "folder \(source.root.lastPathComponent):"
            report += " papers=\(mine.count)"
            report += " tags=[\((folderManifest?.tags ?? []).map(\.name).joined(separator: ","))]"
            report += " collections=[\((set?.collections ?? []).map(\.name).joined(separator: ","))]"
            report += " notes=[\(box.map(\.id).joined(separator: ","))]\n"
        }
        // The whole path, and whose folder it is: with a folder chosen for
        // them the notes about no paper can be anywhere, and a probe's own
        // box has to be seen not to be the reader's.
        let whose = notes.looseBoxIsChosen
            ? "chosen"
            : (notes.chosenFolderWentAway ? "app folder (chosen one away)" : "app folder")
        report += "loose box \(notes.looseBox.path(percentEncoded: false)) [\(whose)]:"
        report += " notes=[\(await notes.looseNoteIDs().joined(separator: ","))]\n"
        if notes.looseBoxIsChosen {
            report += "app folder \(notes.appFolderURL.path(percentEncoded: false)):"
            report += " notes=[\(await notes.appFolderNoteIDs().joined(separator: ","))]\n"
        }
        let twice = notes.notesInTwoBoxes
        if !twice.isEmpty {
            report += "same name in two boxes: ["
            report += twice.map { "\($0.id) shown from \($0.shownFrom.lastPathComponent)" }.joined(separator: ", ")
            report += "]\n"
        }
        // What the folder holds that the library has not taken in, and what
        // the last press of the button could not take: the only way to see
        // from here whether that row is telling the truth.
        // Two records naming one file is the accident this whole area is
        // about, so the report says whether it has happened rather than
        // leaving it to be noticed.
        let files = papers.map { LibraryStore.normalizedPath($0.documentURL) }
        report += "papers: \(papers.count) on \(Set(files).count) file(s)\n"
        report += "loose: \(looseDocuments.count)"
        report += " [\(looseDocuments.prefix(6).map(\.lastPathComponent).joined(separator: ","))]"
        report += " refused=\(adoptFailures.count)"
        report += " [\(adoptFailures.prefix(6).joined(separator: ","))]\n"
        report += "shown: tags=[\(manifest.tags.map(\.name).joined(separator: ","))]"
        report += " collections=[\(collections.collections.map(\.name).joined(separator: ","))]"
        report += " notes=\(notes.notes.count)\n"
        FileHandle.standardError.write(Data(report.utf8))
    }

    // MARK: - The vocabulary, folder by folder

    /// The folder a paper is in, as a store — nil when no folder claims it.
    func folder(ofPaper id: UUID) -> LibraryStore? {
        guard let paper = papers.first(where: { $0.id == id }) else { return nil }
        let root = rootURL(of: paper)
        return allStores.first { $0.root == root }
    }

    /// Reads every folder's tags and collections.
    ///
    /// A tag and a collection are names the reader gave a shelf, and they are
    /// kept in the folder whose papers wear them rather than in one folder
    /// for all of them. A folder is then whole on its own: carry it to
    /// another machine and its papers arrive still tagged and still filed.
    /// A name two folders use is written in both under the same identifier,
    /// and shows once here.
    private func loadVocabulary() async {
        var readManifests: [URL: LibraryManifest] = [:]
        var readCollections: [URL: CollectionSet] = [:]
        // Two small files per folder, and every folder at once, for the same
        // reason the records are read that way.
        await withTaskGroup(of: (URL, LibraryManifest?, CollectionSet?).self) { group in
            for source in allStores {
                group.addTask {
                    async let manifest = try? await source.loadManifest()
                    async let collections = try? await source.loadCollections()
                    return await (source.root, manifest, collections)
                }
            }
            for await (root, manifest, collections) in group {
                readManifests[root] = manifest
                readCollections[root] = collections
            }
        }
        manifests = readManifests
        collectionSets = readCollections
        mergeVocabulary()
    }

    /// One list of tags and one of collections, out of all the folders'.
    private func mergeVocabulary() {
        var tags: [Tag] = []
        var seenTags: Set<UUID> = []
        var found: [Collection] = []
        var seenCollections: Set<UUID> = []
        for source in sources {
            for tag in manifests[source.url]?.tags ?? [] where seenTags.insert(tag.id).inserted {
                tags.append(tag)
            }
            for collection in collectionSets[source.url]?.collections ?? []
            where seenCollections.insert(collection.id).inserted {
                found.append(collection)
            }
        }
        var home = manifests[location.url] ?? manifest
        home.tags = tags
        manifest = home
        var set = collectionSets[location.url] ?? collections
        // The name breaks a tie: every folder numbers its own collections
        // from nought, so without it the order of two folders' collections
        // would depend on how the sort happened to fall and the list would
        // rearrange itself between reads.
        set.collections = found.sorted {
            $0.sortIndex == $1.sortIndex ? $0.name < $1.name : $0.sortIndex < $1.sortIndex
        }
        collections = set
    }

    /// Writes each folder's vocabulary into it.
    ///
    /// A library that was one folder kept all of it in that folder, and a tag
    /// put on a paper while its folder was unplugged was written where the
    /// paper was not. Both are mended by the same pass, which runs on every
    /// read and does nothing at all once every folder has what it needs.
    private func settleVocabulary() async {
        // Sorted into folders in one pass. Asking each paper which folder it
        // belongs to once per folder walked the whole library as many times
        // as there are folders, and `rootURL(of:)` is not free — it compares
        // the paper's path against every root.
        var byRoot: [URL: (tags: [UUID], collections: [UUID])] = [:]
        for paper in papers {
            var mine = byRoot[rootURL(of: paper)] ?? ([], [])
            mine.tags += paper.meta.tagIDs
            mine.collections += paper.meta.collectionIDs
            byRoot[rootURL(of: paper)] = mine
        }
        for source in allStores {
            guard let mine = byRoot[source.root] else { continue }
            await define(tags: mine.tags, collections: mine.collections, in: source)
        }
    }

    /// Puts the definitions a paper's folder is missing into it.
    private func settleVocabulary(forPaper id: UUID) async {
        guard let paper = papers.first(where: { $0.id == id }) else { return }
        let root = rootURL(of: paper)
        guard let target = allStores.first(where: { $0.root == root }) else { return }
        await define(tags: paper.meta.tagIDs, collections: paper.meta.collectionIDs, in: target)
    }

    /// A folder's manifest as last read, read now if this is the first time.
    private func manifest(of target: LibraryStore) async -> LibraryManifest {
        if let known = manifests[target.root] { return known }
        let read = (try? await target.loadManifest())
            ?? LibraryManifest(displayName: target.root.lastPathComponent)
        manifests[target.root] = read
        return read
    }

    private func collectionSet(of target: LibraryStore) async -> CollectionSet {
        if let known = collectionSets[target.root] { return known }
        let read = (try? await target.loadCollections()) ?? CollectionSet()
        collectionSets[target.root] = read
        return read
    }

    private func define(tags: [UUID], collections ids: [UUID], in target: LibraryStore) async {
        let root = target.root
        var folderManifest = await manifest(of: target)
        var manifestChanged = false
        for id in tags where !folderManifest.tags.contains(where: { $0.id == id }) {
            guard let tag = manifest.tags.first(where: { $0.id == id }) else { continue }
            folderManifest.tags.append(tag)
            manifestChanged = true
        }
        if manifestChanged {
            manifests[root] = folderManifest
            try? await target.saveManifest(folderManifest)
        }

        var set = await collectionSet(of: target)
        var setChanged = false
        for id in ids where !set.collections.contains(where: { $0.id == id }) {
            guard let collection = collections.collections.first(where: { $0.id == id }) else { continue }
            set.collections.append(collection)
            setChanged = true
        }
        if setChanged {
            collectionSets[root] = set
            try? await target.saveCollections(set)
        }
        if manifestChanged || setChanged { mergeVocabulary() }
    }

    // MARK: - Tags and collections

    /// A new tag goes into the folder being looked at — the one a paper added
    /// now would go into — and travels to the others as papers there wear it.
    public func addTag(named name: String, color: Tag.Color) async -> Tag {
        let tag = Tag(name: name, color: color)
        let target = importDestination
        var folderManifest = await manifest(of: target)
        folderManifest.tags.append(tag)
        manifests[target.root] = folderManifest
        try? await target.saveManifest(folderManifest)
        mergeVocabulary()
        return tag
    }

    public func setTags(_ ids: [UUID], for paperID: UUID) async {
        guard let paper = papers.first(where: { $0.id == paperID }) else { return }
        var meta = paper.meta
        meta.tagIDs = ids
        if let saved = try? await store(for: paper).save(
            meta: meta,
            in: paper.folder,
            baseline: paper.meta
        ) {
            applyLocally(meta: saved, to: paperID)
            // The folder holding the paper holds the names it wears, so a
            // tag put on here is written there too, once.
            await settleVocabulary(forPaper: paperID)
        }
    }

    public func addCollection(named name: String, rule: Collection.SmartRule? = nil) async {
        let target = importDestination
        var set = await collectionSet(of: target)
        set.collections.append(
            Collection(name: name, rule: rule, sortIndex: collections.collections.count)
        )
        collectionSets[target.root] = set
        try? await target.saveCollections(set)
        mergeVocabulary()
        rebuildDerivedIndexes()
    }

    /// Adds one paper to one collection, leaving its other memberships alone.
    public func addToCollection(_ collectionID: UUID, paperID: UUID) async {
        guard let paper = papers.first(where: { $0.id == paperID }) else { return }
        guard !paper.meta.collectionIDs.contains(collectionID) else { return }
        var meta = paper.meta
        meta.collectionIDs.append(collectionID)
        if let saved = try? await store(for: paper).save(
            meta: meta,
            in: paper.folder,
            baseline: paper.meta
        ) {
            applyLocally(meta: saved, to: paperID)
            // The folder holding the paper holds the names it wears, so a
            // tag put on here is written there too, once.
            await settleVocabulary(forPaper: paperID)
        }
    }

    public func addTag(_ tagID: UUID, to paperID: UUID) async {
        guard let paper = papers.first(where: { $0.id == paperID }) else { return }
        guard !paper.meta.tagIDs.contains(tagID) else { return }
        var meta = paper.meta
        meta.tagIDs.append(tagID)
        if let saved = try? await store(for: paper).save(
            meta: meta,
            in: paper.folder,
            baseline: paper.meta
        ) {
            applyLocally(meta: saved, to: paperID)
            // The folder holding the paper holds the names it wears, so a
            // tag put on here is written there too, once.
            await settleVocabulary(forPaper: paperID)
        }
    }

    public func setCollections(_ ids: [UUID], for paperID: UUID) async {
        guard let paper = papers.first(where: { $0.id == paperID }) else { return }
        var meta = paper.meta
        meta.collectionIDs = ids
        if let saved = try? await store(for: paper).save(
            meta: meta,
            in: paper.folder,
            baseline: paper.meta
        ) {
            applyLocally(meta: saved, to: paperID)
            // The folder holding the paper holds the names it wears, so a
            // tag put on here is written there too, once.
            await settleVocabulary(forPaper: paperID)
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
