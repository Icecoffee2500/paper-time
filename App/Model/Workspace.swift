import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// The window's panes (1.1, 2026-11-18).
///
/// The window was four columns that each showed one fixed thing, and then a
/// fifth — the «곁 칸» — at the far end, remembered place by place. The user,
/// with a plan open beside a paper: «"계획"-"Machine Unlearning"을 잡아서 논문
/// 창 쪽에다가 놓으면 … 그 논문 창쪽에 뜨는 걸 말한거야. 그리고 지금 x를 눌러서
/// 창을 끄면 뭔가 그 다음에 어떻게 다시 키는지도 모르겠고, 불편해.» So now:
///
/// - the window is the sidebar, a row of one to four *content panes*, and the
///   inspector — docked at the right, or floating over the window;
/// - a pane holds one `PaneContent`: the shelf the sidebar is on (`list`),
///   the page (`page`), one sidebar item pinned where it is (`shelf`), or a
///   note (`note`);
/// - anything in the sidebar, and any pane by its head, can be dragged onto
///   a pane — its middle to show it there, its edges to put a new pane
///   beside it;
/// - closing a pane says so at the foot of the window and offers it back,
///   ⌘Z and ⇧⌘T bring it back, and a «+» at the end of the row opens
///   anything again.
///
/// One arrangement for the window, kept in the settings — not one per place,
/// which made the window change shape under somebody who only went to read
/// their notes.
enum PaneContent: Hashable, Codable, Sendable {
    /// Whatever the sidebar is on — the table of a shelf, the notes, the
    /// projects. At most one.
    case list
    /// The page: the paper, the note, the project. At most one.
    case page
    /// One sidebar item, pinned: it does not follow the sidebar. Named by
    /// `LibraryModel.Scope.paneKey`.
    case shelf(String)
    /// One note — a picker until one is chosen.
    case note(String?)
}

struct ContentPane: Hashable, Codable, Identifiable, Sendable {
    var id: UUID
    var content: PaneContent
    /// The width it was given by hand; nil for the content's own.
    var width: Double?

    init(id: UUID = UUID(), content: PaneContent, width: Double? = nil) {
        self.id = id
        self.content = content
        self.width = width
    }

    /// The list and the page each have one id for life, so the view that
    /// holds them is the same view whether they are showing or not — the
    /// reader is expensive to build, and tearing it down was what made the
    /// toggles crawl.
    static let listID = UUID(uuidString: "6C1A0E3F-0000-4000-8000-00000000A115")!
    static let pageID = UUID(uuidString: "6C1A0E3F-0000-4000-8000-00000000BA6E")!
    static var list: ContentPane { ContentPane(id: listID, content: .list) }
    static var page: ContentPane { ContentPane(id: pageID, content: .page) }

    /// What a shelf pane holds, when it holds one.
    var shelfKey: String? {
        if case let .shelf(key) = content { return key }
        return nil
    }
}

/// The window's arrangement as it is kept.
struct WindowArrangement: Codable, Equatable, Sendable {
    var panes: [ContentPane] = [.list, .page]
    var inspectorShown = true
    var inspectorFloats = false
    /// Where the floating inspector stands, from the top left of the panes'
    /// area, and how big it is.
    var floatingFrame: CGRect?
}

/// A pane put away, with where it stood — for «다시 열기», ⌘Z and ⇧⌘T.
struct ClosedPane: Equatable, Identifiable {
    var pane: ContentPane
    var index: Int
    var title: String
    var id: UUID { pane.id }
}

/// The capsule at the foot of the window.
struct PaneNotice: Equatable, Identifiable {
    let id = UUID()
    var text: String
    /// The pane «다시 열기» brings back, when there is one.
    var reopen: UUID?
}

/// What the page shows when something pinned beside it asked for it,
/// rather than what the sidebar is on: a paper pressed in a pinned shelf
/// while the sidebar is on the notes, a note pressed in a pinned list of
/// notes while it is on a shelf. Pressing a row in the sidebar lets go.
enum PageShows: Equatable {
    case paper
    case note
    case project(UUID)
}

/// Where over a pane a shelf or a pane is being dragged.
enum PaneDropZone: Equatable {
    case left, middle, right

    /// The zone a point asks for: the outer 26% either side, and the middle.
    static func at(_ x: CGFloat, width: CGFloat) -> PaneDropZone {
        guard width > 0 else { return .middle }
        let fraction = x / width
        if fraction < 0.26 { return .left }
        if fraction > 0.74 { return .right }
        return .middle
    }
}

struct PaneDropTarget: Equatable {
    var pane: UUID
    var zone: PaneDropZone
    /// Set by a probe, which has no pointer to let go of.
    var held = false
    /// A paper is being dragged, not a sidebar item or a pane: it opens
    /// beside the paper on the page (`AppModel.dock`) rather than in a pane
    /// of its own, so the zones say so.
    var paper = false
}

/// What is being dropped on a pane.
enum PaneDropItem: Equatable {
    /// A sidebar item, by its pane key.
    case shelf(String)
    /// A pane, by its id — moved, not copied.
    case pane(UUID)
    /// A paper — from a list, or by a side-by-side pane's title (`moving`).
    case paper(UUID, moving: UUID?)
}

/// The payloads, the same JSON on both builds (each with its own key format).
struct ShelfTransfer: Codable, Hashable {
    var shelf: String
}

struct PaneTransfer: Codable, Hashable {
    var pane: String
}

extension UTType {
    static let paperTimeShelf = UTType(exportedAs: "com.imtaeheon.PaperTime.shelf")
    static let paperTimePane = UTType(exportedAs: "com.imtaeheon.PaperTime.pane")
}

extension NSItemProvider {
    /// A sidebar item, dragged.
    static func shelf(_ key: String) -> NSItemProvider {
        let provider = NSItemProvider()
        let data = (try? JSONEncoder().encode(ShelfTransfer(shelf: key))) ?? Data()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.paperTimeShelf.identifier, visibility: .ownProcess) { done in
            done(data, nil)
            return nil
        }
        return provider
    }

    /// A pane, dragged by its head.
    static func pane(_ id: UUID) -> NSItemProvider {
        let provider = NSItemProvider()
        let data = (try? JSONEncoder().encode(PaneTransfer(pane: id.uuidString))) ?? Data()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.paperTimePane.identifier, visibility: .ownProcess) { done in
            done(data, nil)
            return nil
        }
        return provider
    }
}

extension LibraryModel.Scope {
    /// The name a sidebar item goes by in a pane and in a drag. Nil for what
    /// cannot be pinned — the search results, the graph.
    @MainActor var paneKey: String? {
        switch self {
        case .searchResults, .graph: nil
        case .notes: "notes"
        case let .knowledge(area): area.map { "knowledge:" + $0 } ?? "knowledge"
        case let .projects(id): id.map { "project:" + $0.uuidString } ?? "projects"
        default: LibraryModel.shelfKey(self)
        }
    }

    /// The sidebar item a pane key names.
    init?(paneKey key: String) {
        func after(_ prefix: String) -> String? { key.hasPrefix(prefix) ? String(key.dropFirst(prefix.count)) : nil }
        switch key {
        case "all": self = .all
        case "open": self = .open
        case "papers": self = .papers
        case "books": self = .books
        case "documents": self = .documents
        case "unread": self = .unread
        case "reading": self = .reading
        case "read": self = .read
        case "favorites": self = .favorites
        case "review": self = .needsReview
        case "week": self = .thisWeek
        case "notes": self = .notes
        case "knowledge": self = .knowledge(nil)
        case "projects": self = .projects(nil)
        default:
            if let path = after("folder:") {
                self = .folder(URL(fileURLWithPath: path, isDirectory: true))
            } else if let area = after("knowledge:") {
                self = .knowledge(area)
            } else if let raw = after("project:"), let id = UUID(uuidString: raw) {
                self = .projects(id)
            } else if let raw = after("collection:"), let id = UUID(uuidString: raw) {
                self = .collection(id)
            } else if let raw = after("tag:"), let id = UUID(uuidString: raw) {
                self = .tag(id)
            } else if let raw = after("plan:"), let id = UUID(uuidString: raw) {
                self = .plan(id)
            } else if let name = after("author:") {
                self = .author(name)
            } else {
                return nil
            }
        }
    }

    /// Whether the shelf is a table of papers (as against notes or projects).
    var holdsPapers: Bool {
        switch self {
        case .notes, .knowledge, .projects, .graph, .searchResults: false
        default: true
        }
    }
}

// MARK: - The model

@MainActor
extension AppModel {
    /// The most panes a window holds.
    static let mostPanes = 4

    /// The panes showing, in their order — in focus, only the page.
    var displayedPanes: [ContentPane] {
        if isFocusMode { return [panes.first { $0.content == .page } ?? .page] }
        return panes
    }

    func paneIndex(_ id: UUID) -> Int? { panes.firstIndex { $0.id == id } }
    func pane(_ id: UUID) -> ContentPane? { panes.first { $0.id == id } }

    // MARK: Adding and taking away

    /// Puts a pane in; says no, at the foot of the window, to a fifth.
    @discardableResult
    func insertPane(_ pane: ContentPane, at index: Int, announce: Bool = true) -> Bool {
        guard panes.count < Self.mostPanes else {
            if announce { tellAboutPanes(L("칸은 네 개까지예요.", "Four panes at most.")) }
            return false
        }
        // The list and the page are one each.
        if pane.content == .list, panes.contains(where: { $0.content == .list }) { return false }
        if pane.content == .page, panes.contains(where: { $0.content == .page }) { return false }
        movingPanes {
            panes.insert(pane, at: min(max(index, 0), panes.count))
        }
        storePanes()
        return true
    }

    /// Closes a pane by its × — not the last one, which stays so the window
    /// is never empty. Says so, offers it back, and remembers it.
    func closePane(_ id: UUID, title: String, undo: UndoManager? = nil) {
        guard panes.count > 1, let index = paneIndex(id) else { return }
        let gone = panes[index]
        movingPanes { _ = panes.remove(at: index) }
        remember(ClosedPane(pane: gone, index: index, title: title))
        // A paper's whole title is a sentence; the capsule names it.
        let name = title.count > 30 ? String(title.prefix(28)).trimmingCharacters(in: .whitespaces) + "…" : title
        tellAboutPanes(L("\(name) 칸을 닫았어요", "Closed \(name)"), reopen: gone.id)
        if let undo {
            undo.registerUndo(withTarget: self) { app in
                MainActor.assumeIsolated { app.reopenClosedPane(gone.id) }
            }
            undo.setActionName(L("칸 닫기", "Close Pane"))
        }
        storePanes()
    }

    private func remember(_ closed: ClosedPane) {
        closedPanes.removeAll { $0.pane.id == closed.pane.id }
        closedPanes.append(closed)
        if closedPanes.count > 8 { closedPanes.removeFirst(closedPanes.count - 8) }
    }

    /// The last pane closed, back where it stood (⇧⌘T, ⌘Z, «다시 열기»).
    func reopenLastClosedPane() {
        guard let last = closedPanes.last else { return }
        reopenClosedPane(last.pane.id)
    }

    func reopenClosedPane(_ id: UUID) {
        guard let index = closedPanes.lastIndex(where: { $0.pane.id == id }) else { return }
        let closed = closedPanes[index]
        // Already back by another way (the toolbar's toggle).
        if paneIndex(closed.pane.id) != nil
            || (closed.pane.content == .list && showsPaperList)
            || (closed.pane.content == .page && showsReader) {
            closedPanes.remove(at: index)
            return
        }
        if isFocusMode { setFocusMode(false) }
        guard insertPane(closed.pane, at: closed.index) else { return }
        closedPanes.remove(at: index)
        if paneNotice?.reopen == id { paneNotice = nil }
    }

    /// A new pane at the end of the row (the «+» column).
    func addPane(_ content: PaneContent) {
        if isFocusMode { setFocusMode(false) }
        switch content {
        case .page:
            if let place = closedPanes.lastIndex(where: { $0.pane.content == .page }) {
                return reopenClosedPane(closedPanes[place].pane.id)
            }
            insertPane(.page, at: panes.count)
        case .list:
            insertPane(.list, at: 0)
        default:
            insertPane(ContentPane(content: content), at: panes.count)
        }
    }

    /// Sets what a pane shows from its ⌄ menu. The list pane goes where the
    /// sidebar goes, so for it a shelf is the sidebar's; any other pane
    /// becomes that shelf, pinned.
    func show(_ content: PaneContent, inPane id: UUID, model: LibraryModel) {
        guard let index = paneIndex(id) else { return }
        if panes[index].content == .list, case let .shelf(key) = content, let scope = LibraryModel.Scope(paneKey: key) {
            withAnimation(Motion.surface) { model.scope = scope }
            pageShows = nil
            return
        }
        var changed = panes[index]
        // The list and the page keep their ids for when they come back; a
        // pane that was one of them becomes a new pane in its place.
        if changed.content == .list || changed.content == .page {
            changed = ContentPane(content: content, width: changed.width)
        } else {
            changed.content = content
        }
        movingPanes { panes[index] = changed }
        storePanes()
    }

    // MARK: Drops

    /// A sidebar item or a pane dropped on a pane: its middle shows it there,
    /// its edges put it beside.
    func drop(_ item: PaneDropItem, on target: UUID, zone: PaneDropZone, model: LibraryModel) {
        guard let targetIndex = paneIndex(target) else { return }
        switch (item, zone) {
        case let (.pane(moving), .middle):
            guard moving != target, let from = paneIndex(moving) else { return }
            movingPanes { panes.swapAt(from, targetIndex) }
            storePanes()
        case let (.pane(moving), _):
            guard moving != target, let from = paneIndex(moving) else { return }
            var row = panes
            let pane = row.remove(at: from)
            guard let at = row.firstIndex(where: { $0.id == target }) else { return }
            row.insert(pane, at: zone == .left ? at : at + 1)
            movingPanes { panes = row }
            storePanes()
        case let (.shelf(key), .middle):
            guard let scope = LibraryModel.Scope(paneKey: key) else { return }
            if panes[targetIndex].content == .list {
                // The same as pressing the row: the sidebar goes there.
                withAnimation(Motion.surface) { model.scope = scope }
                pageShows = nil
            } else {
                show(.shelf(key), inPane: target, model: model)
            }
        case let (.shelf(key), _):
            insertPane(ContentPane(content: .shelf(key)), at: zone == .left ? targetIndex : targetIndex + 1)
        case let (.paper(id, moving), _):
            dropPaper(id, moving: moving, on: targetIndex, zone: zone, model: model)
        }
    }

    /// A paper dropped on a pane (2026-11-18, «논문 자체는 드래그해서 새창으로
    /// 열 수가 없네 … 동일한 논문 두개 띄우는 것도 가능하도록»). Papers stand
    /// side by side on the page — the reader there already holds up to four,
    /// the same paper twice included (`SplitArrangement`) — so a paper put on
    /// another pane opens beside the page's paper, on the side that faces
    /// the pane it was put on. With no page open, the page opens where it
    /// was put. (The page pane's own drops are `DockDropDelegate`'s.)
    func dropPaper(_ id: UUID, moving: UUID?, on targetIndex: Int, zone: PaneDropZone, model: LibraryModel) {
        guard let page = panes.firstIndex(where: { $0.content == .page }) else {
            let at = zone == .left ? targetIndex : targetIndex + 1
            insertPane(.page, at: at)
            model.selectedPaperID = id
            model.keepOpen(id)
            return
        }
        if targetIndex == page {
            switch zone {
            case .left: dock(id, at: .left, in: model, movingPane: moving)
            case .right: dock(id, at: .right, in: model, movingPane: moving)
            case .middle: openOnPage(id, model: model)
            }
            return
        }
        dock(id, at: targetIndex < page ? .left : .right, in: model, movingPane: moving)
    }

    /// A paper put in the middle of the page: shown there, in the pane in
    /// focus when papers stand side by side.
    func openOnPage(_ id: UUID, model: LibraryModel) {
        pageShows = nil
        if var arrangement = split, let focused = focusedPane(in: arrangement, model: model) {
            arrangement.replace(focused.id, with: id)
            movingPanes { split = arrangement }
        }
        model.selectedPaperID = id
        model.keepOpen(id)
    }

    /// A shelf or a pane dropped on the «+» column: at the end of the row.
    func dropAtEnd(_ item: PaneDropItem) {
        switch item {
        case let .paper(id, moving):
            guard let model = library else { return }
            if showsReader {
                dock(id, at: .right, in: model, movingPane: moving)
            } else {
                insertPane(.page, at: panes.count)
                model.selectedPaperID = id
                model.keepOpen(id)
            }
        case let .shelf(key):
            insertPane(ContentPane(content: .shelf(key)), at: panes.count)
        case let .pane(id):
            guard let from = paneIndex(id), from != panes.count - 1 else { return }
            var row = panes
            row.append(row.remove(at: from))
            movingPanes { panes = row }
            storePanes()
        }
    }

    // MARK: The list and the page

    /// The sidebar row pressed: the page lets go of whatever a pinned pane
    /// put on it, and with no list pane open one comes in at the left.
    func sidebarRowPressed() {
        pageShows = nil
        if isFocusMode { return }
        if !showsPaperList {
            if let place = closedPanes.lastIndex(where: { $0.pane.content == .list }) {
                reopenClosedPane(closedPanes[place].pane.id)
            } else {
                insertPane(.list, at: 0)
            }
        }
    }

    /// A paper (or a note, a project) chosen with no page pane open: one comes
    /// in to the right of the pane the press came from, or at the end.
    func ensurePagePane(after paneID: UUID?) {
        guard !showsReader, !isFocusMode else { return }
        let after = paneID.flatMap(paneIndex).map { $0 + 1 } ?? panes.count
        insertPane(.page, at: after)
    }

    /// Shows or hides the list pane — the toolbar's button, ⌘P.
    func toggleListPane() {
        if isFocusMode {
            setFocusMode(false)
            if showsPaperList { return }
        }
        if let index = panes.firstIndex(where: { $0.content == .list }) {
            guard panes.count > 1 else { return }
            let gone = panes[index]
            movingPanes { _ = panes.remove(at: index) }
            remember(ClosedPane(pane: gone, index: index, title: ShortcutAction.paperList.title))
            storePanes()
        } else if let place = closedPanes.lastIndex(where: { $0.pane.content == .list }) {
            reopenClosedPane(closedPanes[place].pane.id)
        } else {
            insertPane(.list, at: 0)
        }
    }

    /// Shows or hides the page pane — the toolbar's button, ⌘\.
    func togglePagePane() {
        if isFocusMode {
            setFocusMode(false)
            return
        }
        if let index = panes.firstIndex(where: { $0.content == .page }) {
            guard panes.count > 1 else { return }
            let gone = panes[index]
            movingPanes { _ = panes.remove(at: index) }
            remember(ClosedPane(pane: gone, index: index, title: ShortcutAction.reader.title))
            storePanes()
        } else if let place = closedPanes.lastIndex(where: { $0.pane.content == .page }) {
            reopenClosedPane(closedPanes[place].pane.id)
        } else {
            let after = panes.firstIndex { $0.content == .list }.map { $0 + 1 } ?? panes.count
            insertPane(.page, at: after)
        }
    }

    /// A list pane lent to hold a paper opened from a note or a project, and
    /// taken back when the paper goes.
    @discardableResult
    func lendListPane() -> Bool {
        guard !showsPaperList, panes.count < Self.mostPanes else { return false }
        let at = panes.firstIndex { $0.content == .page } ?? 0
        movingPanes { panes.insert(.list, at: at) }
        return true
    }

    func returnLentListPane() {
        movingPanes { panes.removeAll { $0.content == .list } }
        if panes.isEmpty { panes = [.page] }
    }

    /// A note opened in a note pane — the one there is, or a new one at the end.
    func openNotePane(_ noteID: String?) {
        if let index = panes.firstIndex(where: { if case .note = $0.content { true } else { false } }) {
            movingPanes { panes[index].content = .note(noteID) }
            storePanes()
        } else {
            addPane(.note(noteID))
        }
    }

    func setPaneWidth(_ id: UUID, _ width: Double) {
        guard let index = paneIndex(id) else { return }
        panes[index].width = width
        storePanes()
    }

    // MARK: The notice

    func tellAboutPanes(_ text: String, reopen: UUID? = nil) {
        let notice = PaneNotice(text: text, reopen: reopen)
        withAnimation(Motion.move) { paneNotice = notice }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, self.paneNotice?.id == notice.id else { return }
            withAnimation(Motion.fade) { self.paneNotice = nil }
        }
    }

    // MARK: The floating inspector

    /// The inspector shown, docked or floating — the menus' two choices.
    /// Choosing the one already showing puts it away.
    func showInspector(floating: Bool) {
        if showsInspector, inspectorFloats == floating {
            movingPanes { showsInspector = false }
            storePanes()
            return
        }
        setInspectorFloats(floating)
    }

    func setInspectorFloats(_ floats: Bool) {
        movingPanes {
            inspectorFloats = floats
            showsInspector = true
        }
        storePanes()
    }

    func setFloatingInspectorFrame(_ frame: CGRect) {
        floatingInspectorFrame = frame
        storePanes()
    }

    // MARK: Keeping it

    /// The arrangement as it is written down.
    var windowArrangement: WindowArrangement {
        WindowArrangement(panes: panes, inspectorShown: showsInspector, inspectorFloats: inspectorFloats,
                          floatingFrame: floatingInspectorFrame)
    }

    /// Writes the arrangement down — never in a probe's run, which shares
    /// the settings of the copy somebody reads with.
    func storePanes() {
        guard Boot.setting("PAPERTIME_LIBRARY") == nil else { return }
        if let data = try? JSONEncoder().encode(windowArrangement) {
            UserDefaults.standard.set(data, forKey: Self.arrangementKey)
        }
    }

    nonisolated static let arrangementKey = "windowPanes"

    /// The arrangement kept, or the first one — and, once, what the old
    /// per-place memory and the «곁 칸» held, moved over and then forgotten.
    nonisolated static func storedWindowArrangement() -> WindowArrangement {
        guard Boot.setting("PAPERTIME_LIBRARY") == nil else { return WindowArrangement() }
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: arrangementKey),
           let kept = try? JSONDecoder().decode(WindowArrangement.self, from: data),
           !kept.panes.isEmpty {
            return kept
        }
        let migrated = migratedArrangement(from: defaults)
        if let data = try? JSONEncoder().encode(migrated) { defaults.set(data, forKey: arrangementKey) }
        defaults.removeObject(forKey: "workspaceArrangements")
        defaults.removeObject(forKey: "companionWidth")
        return migrated
    }

    /// The library's arrangement from the per-place memory, with the
    /// companion it had — or the first a place had — as a pane at the end.
    nonisolated static func migratedArrangement(from defaults: UserDefaults) -> WindowArrangement {
        struct Old: Decodable {
            var list = true
            var page = true
            var inspector = true
            var companion: OldCompanion?
        }
        enum OldCompanion: Decodable {
            case papers, note
            case plan(UUID)
        }
        var arrangement = WindowArrangement()
        guard let data = defaults.data(forKey: "workspaceArrangements"),
              let places = try? JSONDecoder().decode([String: Old].self, from: data) else { return arrangement }
        if let library = places["library"] {
            var panes: [ContentPane] = []
            if library.list { panes.append(.list) }
            if library.page || panes.isEmpty { panes.append(.page) }
            arrangement.panes = panes
            arrangement.inspectorShown = library.inspector
        }
        let companion = ["library", "projects", "literature", "knowledge"].lazy.compactMap { places[$0]?.companion }.first
        let width = defaults.double(forKey: "companionWidth")
        let content: PaneContent? = switch companion {
        case .papers: .shelf("papers")
        case .note: .note(nil)
        case let .plan(id): .shelf("plan:" + id.uuidString)
        case nil: nil
        }
        if let content { arrangement.panes.append(ContentPane(content: content, width: width > 0 ? width : nil)) }
        return arrangement
    }
}

/// What the page pane is showing now.
enum PageShowing: Equatable {
    case paper
    case note
    case project(UUID?)
    case graph
}

#if os(macOS)
@MainActor
extension AppModel {
    /// The page by the sidebar alone: the project, the note, the graph, the
    /// paper.
    func naturalPage(model: LibraryModel) -> PageShowing {
        switch model.scope {
        case let .projects(id): .project(id)
        case .notes, .knowledge: .note
        case .graph: .graph
        default: .paper
        }
    }

    /// The page as it is: what a pinned pane put on it, else the sidebar's.
    func pageShowing(model: LibraryModel) -> PageShowing {
        switch pageShows {
        case .paper?: .paper
        case .note?: .note
        case let .project(id)?: .project(id)
        case nil: naturalPage(model: model)
        }
    }

    /// The page made to show a paper, or a note, or a project — and let go of
    /// when the sidebar's place would show that anyway.
    func showOnPage(_ wanted: PageShows, model: LibraryModel) {
        let natural = naturalPage(model: model)
        let same = switch (wanted, natural) {
        case (.paper, .paper), (.note, .note): true
        case let (.project(id), .project(natural)): natural == id
        default: false
        }
        pageShows = same ? nil : wanted
    }

    /// A pane's name — in its head, in «… 칸을 닫았어요», in the «+» menu.
    func title(of pane: ContentPane, model: LibraryModel) -> String {
        switch pane.content {
        case .list:
            // The list of projects, whichever one is open.
            if case .projects = model.scope { return L("프로젝트", "Projects") }
            return ShelfTitle.of(model.scope, in: model)
        case .page:
            if model.showsBoard { return ShelfTitle.of(model.scope, in: model) }
            switch pageShowing(model: model) {
            case .paper:
                if let split { return L("논문 \(split.panes.count)편 나란히", "\(split.panes.count) Papers Side by Side") }
                return model.selectedPaper?.meta.displayTitle ?? ShortcutAction.reader.title
            case .note:
                return model.notes.openNoteID.flatMap { model.notes.note($0)?.displayTitle } ?? L("노트", "Note")
            case let .project(id):
                let shown = id ?? model.activeProjects.first?.id ?? model.projects.first?.id
                return shown.flatMap { model.project($0)?.name } ?? L("프로젝트", "Projects")
            case .graph:
                return L("그래프", "Graph")
            }
        case let .shelf(key):
            return LibraryModel.Scope(paneKey: key).map { ShelfTitle.of($0, in: model) } ?? L("없는 항목", "Not Found")
        case let .note(id):
            return id.flatMap { model.notes.note($0)?.displayTitle } ?? L("노트", "Note")
        }
    }

    func symbol(of pane: ContentPane, model: LibraryModel) -> String {
        switch pane.content {
        case .list:
            return ShelfTitle.symbol(of: model.scope)
        case .page:
            if model.showsBoard { return ShelfTitle.symbol(of: model.scope) }
            switch pageShowing(model: model) {
            case .paper: return split == nil ? "text.page" : "rectangle.split.2x1"
            case .note: return "note.text"
            case .project: return "flag"
            case .graph: return "point.3.connected.trianglepath.dotted"
            }
        case let .shelf(key):
            return LibraryModel.Scope(paneKey: key).map { ShelfTitle.symbol(of: $0) } ?? "questionmark.folder"
        case .note:
            return "square.and.pencil"
        }
    }
}
#endif
