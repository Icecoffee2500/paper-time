import Foundation
import PaperCore
import LibraryStore
#if os(macOS)
import AppKit
#endif

/// Reading plans: which papers, in what order, on which day, with what
/// beside them. The rules are `ReadingPlan.swift`'s; this is where the
/// library keeps them and writes them back.
@MainActor
extension LibraryModel {
    // MARK: Looking

    /// A shelf seen as a list beside the page, as a table, or — a plan only —
    /// as a calendar.
    public enum ShelfView: String, Hashable, Sendable {
        case list, table, calendar

        var label: String {
            switch self {
            case .list: L("목록", "List")
            case .table: L("표", "Table")
            case .calendar: L("달력", "Calendar")
            }
        }

        var symbol: String {
            switch self {
            case .list: "list.bullet"
            case .table: "tablecells"
            case .calendar: "calendar"
            }
        }
    }

    nonisolated static func storedShelfViews() -> [String: String] {
        guard Boot.setting("PAPERTIME_LIBRARY") == nil else { return [:] }
        return UserDefaults.standard.dictionary(forKey: "shelfViews") as? [String: String] ?? [:]
    }

    /// The key a shelf's view is kept under.
    static func shelfKey(_ scope: Scope) -> String? {
        switch scope {
        case .notes, .graph: nil
        case .all: "all"
        case .open: "open"
        case .searchResults: "search"
        case .papers: "papers"
        case .documents: "documents"
        case let .folder(url): "folder:" + url.path(percentEncoded: false)
        case .unread: "unread"
        case .reading: "reading"
        case .read: "read"
        case .favorites: "favorites"
        case .needsReview: "review"
        case let .collection(id): "collection:" + id.uuidString
        case let .tag(id): "tag:" + id.uuidString
        case let .author(key): "author:" + key
        case let .plan(id): "plan:" + id.uuidString
        case .thisWeek: "week"
        }
    }

    /// What the shelf is seen as now. Plans and the week open as tables.
    public func shelfView(for scope: Scope) -> ShelfView {
        guard let key = Self.shelfKey(scope) else { return .list }
        let stored = shelfViews[key].flatMap(ShelfView.init(rawValue:))
        guard Legacy.paperList else {
            // The table is the list now; only a plan has a second way to be seen.
            if case .plan = scope { return stored == .calendar ? .calendar : .table }
            return .table
        }
        if let stored {
            if case .plan = scope { return stored }
            return stored == .calendar ? .table : stored
        }
        switch scope {
        case .plan, .thisWeek: return .table
        default: return .list
        }
    }

    public func setShelfView(_ view: ShelfView, for scope: Scope) {
        guard let key = Self.shelfKey(scope) else { return }
        shelfViews[key] = view.rawValue
    }

    /// Whether the shelf in front takes the room of the list and the page —
    /// a plan's calendar, which needs the width. (With the old list back,
    /// `Legacy.paperList`, every table did.)
    public var showsBoard: Bool {
        if Legacy.paperList { return shelfView(for: scope) != .list }
        if case .plan = scope { return shelfView(for: scope) == .calendar }
        return false
    }

    /// Whether the list column holds the board's table, with the page beside
    /// it. Search results keep their list of passages, and a library with no
    /// papers keeps its setup screens.
    public var boardInListColumn: Bool {
        guard !Legacy.paperList, Self.shelfKey(scope) != nil, scope != .searchResults else { return false }
        return !papers.isEmpty
    }

    /// Opens a paper from a board: picked, on the page, kept on the open
    /// shelf. From the calendar, the plan turns back into its table so the
    /// page has room beside it.
    public func openFromBoard(_ id: UUID) {
        if Legacy.paperList {
            setShelfView(.list, for: scope)
        } else if showsBoard {
            setShelfView(.table, for: scope)
        }
        selection = [id]
        keepOpen(id)
    }

    // MARK: Reading

    public func plan(_ id: UUID) -> ReadingPlan? { plans.first { $0.id == id } }

    /// Every plan a paper is in.
    public func plans(containing paperID: UUID) -> [ReadingPlan] {
        plans.filter { $0.contains(paperID) }
    }

    func loadPlans() async {
        var found: [ReadingPlan] = []
        var roots: [UUID: URL] = [:]
        for source in allStores {
            for plan in await source.loadPlans() where roots[plan.id] == nil {
                found.append(plan)
                roots[plan.id] = source.root
            }
        }
        planRoots = roots
        // Oldest first; two made in the same second by name, then by id, so
        // the order is the same on every read.
        let sorted = found.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            if $0.name != $1.name { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return $0.id.uuidString < $1.id.uuidString
        }
        if sorted != plans { plans = sorted }
        if case let .plan(id) = scope, plan(id) == nil { scope = .thisWeek }
    }

    /// Plan files and the per-paper files that something else changed.
    nonisolated static func planningChanges(of paths: [String], under roots: [URL]) -> (plans: Bool, papers: Set<UUID>) {
        let support = LibraryLayout.supportDirectoryName
        var plans = false
        var papers: Set<UUID> = []
        for path in paths {
            guard let root = roots.map(LibraryStore.normalizedPath).first(where: { path.hasPrefix($0 + "/") }) else { continue }
            let parts = path.dropFirst(root.count + 1).split(separator: "/").map(String.init)
            guard parts.count >= 2, parts[0] == support else { continue }
            if parts[1] == LibraryLayout.plansDirectoryName {
                plans = true
            } else if parts[1] == LibraryLayout.papersDirectoryName, parts.count == 4,
                      parts[3] == LibraryLayout.scheduleFileName || parts[3] == LibraryLayout.linksFileName,
                      let id = UUID(uuidString: parts[2]) {
                papers.insert(id)
            }
        }
        return (plans, papers)
    }

    func reloadPlanning(plans reread: Bool, papers ids: Set<UUID>) async {
        if reread { await loadPlans() }
        for id in ids {
            guard let paper = paper(id) else { continue }
            let source = store(for: paper)
            let day = await source.loadSchedule(paper.folder)
            let links = await source.loadLinks(paper.folder)
            guard let index = papers.firstIndex(where: { $0.id == id }) else { continue }
            if papers[index].schedule != day { papers[index].schedule = day }
            if papers[index].links != links { papers[index].links = links }
        }
    }

    // MARK: This week

    /// Due this week, or behind: a day before today and not read yet.
    public func isThisWeek(_ paper: LoadedPaper) -> Bool {
        guard let day = paper.schedule else { return false }
        return day.monday == today.monday || isBehind(paper)
    }

    public func isBehind(_ paper: LoadedPaper) -> Bool {
        guard let day = paper.schedule else { return false }
        return day < today && paper.state.readingStatus != .read
    }

    /// Behind first, oldest first; then the week, day by day.
    func weekPapers() -> [LoadedPaper] {
        papers.filter(isThisWeek).sorted { lhs, rhs in
            let left = isBehind(lhs), right = isBehind(rhs)
            if left != right { return left }
            let a = lhs.schedule ?? today, b = rhs.schedule ?? today
            if a != b { return a < b }
            return lhs.meta.displayTitle.localizedCaseInsensitiveCompare(rhs.meta.displayTitle) == .orderedAscending
        }
    }

    /// What the «This Week» row counts: the papers still to read.
    public var thisWeekCount: Int {
        papers.reduce(0) { $0 + (isThisWeek($1) && $1.state.readingStatus != .read ? 1 : 0) }
    }

    // MARK: Plans

    /// Where a new plan goes: the folder being looked at, or the first one.
    private var planDestination: LibraryStore {
        if case let .folder(url) = scope { return source(containing: url) }
        return store
    }

    private func planStore(_ id: UUID) -> LibraryStore {
        let root = planRoots[id]
        return allStores.first { $0.root == root } ?? store
    }

    @discardableResult
    public func createPlan(named name: String, papers ids: [UUID] = []) async -> UUID? {
        var plan = ReadingPlan(name: name)
        plan.add(ids)
        let target = planDestination
        do {
            try await target.savePlan(plan)
        } catch {
            return nil
        }
        planRoots[plan.id] = target.root
        plans.append(plan)
        return plan.id
    }

    /// Edits a plan against its file as it is now.
    public func editPlan(_ id: UUID, _ change: @escaping @Sendable (inout ReadingPlan) -> Void) async {
        // Straight away on screen; the file follows.
        if let index = plans.firstIndex(where: { $0.id == id }) {
            var local = plans[index]
            change(&local)
            if local != plans[index] { plans[index] = local }
        }
        guard let saved = try? await planStore(id).updatePlan(id, change) else { return }
        if let index = plans.firstIndex(where: { $0.id == id }), plans[index] != saved { plans[index] = saved }
    }

    public func renamePlan(_ id: UUID, to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await editPlan(id) { $0.name = trimmed }
    }

    public func deletePlan(_ id: UUID) async {
        try? await planStore(id).deletePlan(id, toTrash: Boot.setting("PAPERTIME_LIBRARY") == nil)
        plans.removeAll { $0.id == id }
        planRoots[id] = nil
        if scope == .plan(id) { scope = .thisWeek }
    }

    public func addToPlan(_ id: UUID, papers ids: [UUID], section: UUID? = nil) async {
        await editPlan(id) { $0.add(ids, to: section) }
    }

    // MARK: Days

    /// Gives papers their days (nil takes the day away) and answers the days
    /// they had, for an undo.
    @discardableResult
    public func setDays(_ days: [UUID: PlanDay?]) async -> [UUID: PlanDay?] {
        var before: [UUID: PlanDay?] = [:]
        for (id, day) in days {
            guard let index = papers.firstIndex(where: { $0.id == id }) else { continue }
            before[id] = papers[index].schedule
            if papers[index].schedule != day { papers[index].schedule = day }
        }
        for (id, day) in days {
            guard let paper = paper(id) else { continue }
            try? await store(for: paper).saveSchedule(day, in: paper.folder)
        }
        return before
    }

    public func setDay(_ day: PlanDay?, for id: UUID) async -> [UUID: PlanDay?] {
        await setDays([id: day])
    }

    /// The papers of a plan still to read: reading ones first, then in the
    /// plan's order.
    public func unreadInPlan(_ id: UUID) -> [UUID] {
        guard let plan = plan(id) else { return [] }
        let order = plan.readingOrder.compactMap(paper).filter { $0.state.readingStatus != .read }
        return order.filter { $0.state.readingStatus == .reading }.map(\.id)
            + order.filter { $0.state.readingStatus != .reading }.map(\.id)
    }

    /// The days «Spread Evenly» would give.
    public func spread(_ id: UUID, weekdays: Set<Int>, perDay: Int, from start: PlanDay) -> [(UUID, PlanDay)] {
        let todo = unreadInPlan(id)
        return Array(zip(todo, PlanSpread.days(count: todo.count, weekdays: weekdays, perDay: perDay, from: start)))
    }

    /// Every unread paper with a day in the plan, a week later.
    public func pushedAWeek(_ id: UUID) -> [UUID: PlanDay?] {
        guard let plan = plan(id) else { return [:] }
        var out: [UUID: PlanDay?] = [:]
        for paper in plan.readingOrder.compactMap(paper) where paper.state.readingStatus != .read {
            if let day = paper.schedule { out[paper.id] = day.adding(days: 7) }
        }
        return out
    }

    /// Every paper behind, moved to today.
    public func behindToToday() -> [UUID: PlanDay?] {
        Dictionary(uniqueKeysWithValues: papers.filter(isBehind).map { ($0.id, Optional(today)) })
    }

    // MARK: Materials

    public enum MaterialOutcome: Equatable { case added(MaterialKind), notAnAddress, failed }

    public func addLink(_ text: String, to paperID: UUID) async -> MaterialOutcome {
        guard let address = MaterialLink.address(text) else { return .notAnAddress }
        guard let paper = paper(paperID) else { return .failed }
        let link = PaperMaterial(kind: MaterialLink.kind(ofAddress: address), url: address)
        return await changeLinks(of: paper) { $0.append(link) } ? .added(link.kind) : .failed
    }

    /// Whether any of the files is a PDF — which is not taken as a material:
    /// copied into the library folder it would be taken in as a paper of its
    /// own. A PDF belongs under the paper as a supplement.
    public static func holdsPDF(_ urls: [URL]) -> Bool {
        urls.contains { $0.pathExtension.lowercased() == "pdf" }
    }

    /// Copies the files beside the paper's PDF and keeps them as materials.
    /// PDFs are left out (`holdsPDF`).
    @discardableResult
    public func attachFiles(_ urls: [URL], to paperID: UUID) async -> Int {
        guard let paper = paper(paperID) else { return 0 }
        let urls = urls.filter { $0.pathExtension.lowercased() != "pdf" }
        var added: [PaperMaterial] = []
        for url in urls {
            guard let relative = try? await store(for: paper).copyMaterial(from: url, beside: paper) else { continue }
            added.append(PaperMaterial(kind: MaterialLink.kind(ofFileName: url.lastPathComponent), file: relative))
        }
        guard !added.isEmpty else { return 0 }
        let made = added
        return await changeLinks(of: paper) { $0.append(contentsOf: made) } ? made.count : 0
    }

    /// Takes a material off the paper. A copied file stays in the folder.
    public func removeLink(_ linkID: UUID, from paperID: UUID) async {
        guard let paper = paper(paperID) else { return }
        _ = await changeLinks(of: paper) { $0.removeAll { $0.id == linkID } }
    }

    public func renameLink(_ linkID: UUID, of paperID: UUID, to name: String) async {
        guard let paper = paper(paperID) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = await changeLinks(of: paper) { links in
            guard let index = links.firstIndex(where: { $0.id == linkID }) else { return }
            links[index].title = trimmed.isEmpty ? nil : trimmed
        }
    }

    private func changeLinks(of paper: LoadedPaper, _ change: @escaping @Sendable (inout [PaperMaterial]) -> Void) async -> Bool {
        if let index = papers.firstIndex(where: { $0.id == paper.id }) {
            var local = papers[index].links
            change(&local)
            papers[index].links = local
        }
        guard let saved = try? await store(for: paper).updateLinks(in: paper.folder, change) else { return false }
        if let index = papers.firstIndex(where: { $0.id == paper.id }), papers[index].links != saved {
            papers[index].links = saved
        }
        return true
    }

    /// The paper's own address, from its identifiers, shown first among its
    /// materials and not removable.
    public func paperLink(of paper: LoadedPaper) -> String? {
        MaterialLink.paperAddress(arxiv: paper.meta.identifiers.arxiv, doi: paper.meta.identifiers.doi)
    }

    /// Where a material that is a file is.
    public func materialURL(_ link: PaperMaterial, of paper: LoadedPaper) -> URL? {
        guard let file = link.file else { return nil }
        return rootURL(of: paper).appending(path: file)
    }

    #if os(macOS)
    public func open(_ link: PaperMaterial, of paper: LoadedPaper) {
        if let url = materialURL(link, of: paper) {
            NSWorkspace.shared.open(url)
        } else if let address = link.url, let url = URL(string: address),
                  url.scheme == "https" || url.scheme == "http" {
            NSWorkspace.shared.open(url)
        }
    }

    public func openAddress(_ address: String) {
        guard let url = URL(string: address), url.scheme == "https" || url.scheme == "http" else { return }
        NSWorkspace.shared.open(url)
    }
    #endif

    // MARK: Progress

    /// How far through: the last page read over the pages, 1 when read.
    public func progress(of paper: LoadedPaper) -> Double {
        if paper.state.readingStatus == .read { return 1 }
        let pages = paper.meta.file.pageCount
        let last = paper.state.lastPageIndex
        guard pages > 0, last > 0 else { return 0 }
        return min(1, Double(last + 1) / Double(pages))
    }
}
