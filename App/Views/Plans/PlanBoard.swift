#if os(macOS)
import AppKit
import LibraryStore
import PaperCore
import SwiftUI

/// A column a board can show beside the title.
enum BoardColumn: String, CaseIterable, Identifiable, Hashable {
    case authors, year, venue, publisher, folder, pages, plan, day, progress, materials, tags, rating, notes, added, opened

    var id: String { rawValue }

    /// The column's name over a table of that kind: a book has «지은이»,
    /// a document «쓴 사람», the way the inspector names them.
    func title(for kind: ShelfKind) -> String {
        guard self == .authors else { return title }
        switch kind {
        case .paper: return title
        case .book: return L("지은이", "Authors")
        case .document: return L("쓴 사람", "Written By")
        }
    }

    var title: String {
        switch self {
        case .authors: L("저자", "Authors")
        case .publisher: L("출판사", "Publisher")
        case .folder: L("폴더", "Folder")
        case .pages: L("쪽", "Pages")
        case .year: L("해", "Year")
        case .venue: L("학회", "Venue")
        case .plan: L("계획", "Plan")
        case .day: L("읽을 날", "Read On")
        case .progress: L("진행", "Progress")
        case .materials: L("자료", "Materials")
        case .tags: L("태그", "Tags")
        case .rating: L("별점", "Rating")
        case .notes: L("노트", "Notes")
        case .added: L("더한 날", "Added")
        case .opened: L("마지막으로 읽은 날", "Last Read")
        }
    }

    var width: CGFloat {
        switch self {
        case .authors: 110
        case .year: 44
        case .venue: 84
        case .publisher: 110
        case .folder: 140
        case .pages: 44
        case .plan: 124
        case .day: 100
        case .progress: 86
        case .materials: 34
        case .tags: 110
        case .rating: 70
        case .notes: 46
        case .added: 76
        case .opened: 96
        }
    }
}

/// What a board is sorted by: the titles (`column == nil`) or a column, and
/// which way.
struct BoardSort: Equatable {
    var column: BoardColumn?
    var ascending: Bool

    /// One paper's value for the sort.
    enum Value {
        case text(String), number(Double)

        /// Text the way Finder orders it: case aside, numbers by value.
        func compare(_ other: Value) -> ComparisonResult {
            switch (self, other) {
            case let (.text(a), .text(b)): a.localizedStandardCompare(b)
            case let (.number(a), .number(b)): a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
            default: .orderedSame
            }
        }
    }
}

/// A column's name over the table, which sorts by it. It answers the
/// pointer — a shade behind it, the hand — because a header that sorts and a
/// header that only names look the same at rest; the one being sorted by is
/// in the accent colour with its arrow.
struct BoardHeaderButton: View {
    let text: String
    let arrow: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(text).lineLimit(1)
                if let arrow { Text(arrow) }
            }
            .foregroundStyle(arrow != nil ? AnyShapeStyle(Color.accentColor)
                             : hovering ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: Corner.control, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.055 : 0))
            )
            // The shade reaches past the name; the name stays where the
            // column's cells start.
            .padding(.horizontal, -5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(Motion.tap, value: hovering)
        .onHover { inside in
            hovering = inside
            (inside ? NSCursor.pointingHand : NSCursor.arrow).set()
        }
        .help(arrow == nil
              ? L("누르면 이 열로 정렬해요", "Click to sort by this column")
              : L("한 번 더 누르면 반대로, 또 누르면 원래 순서로 돌아가요", "Click again to reverse, once more for the original order"))
    }
}

/// How a table's row is laid across the board: a ring, the title, then the
/// columns. When they do not all fit beside a title worth reading, the
/// title is pinned at a fixed width and the columns slide sideways under a
/// window of their own — every column at its own width, lined up, sortable
/// (2026-11-16: folding the authors, year and venue under the title read as
/// clutter — «열로 정렬이 되어있는게 아니다보니까 조금 번잡스럽네»; the user
/// chose this over dropping columns).
struct BoardGeometry: Equatable {
    /// The title's width when pinned; nil when it takes what is left.
    var title: CGFloat?
    /// The room the columns have.
    var viewport: CGFloat
    /// The room they would like.
    var content: CGFloat

    var slides: Bool { title != nil }
    /// How far the columns slide.
    var limit: CGFloat { max(0, content - viewport) }

    /// A title shorter than this is pinned and the columns slide instead.
    static let titleLeast: CGFloat = 150
    static let titleMost: CGFloat = 220

    /// The row is 20 points of padding a side, the ring (22) and its gap, the
    /// title, a gap, and the columns with 10 between them.
    static func of(width: CGFloat, columns: [BoardColumn]) -> BoardGeometry {
        let content = columns.reduce(0) { $0 + $1.width } + 10 * CGFloat(max(0, columns.count - 1))
        let room = width - 82
        if columns.isEmpty || room - content >= titleLeast {
            return BoardGeometry(title: nil, viewport: content, content: content)
        }
        let title = min(max(room * 0.45, titleLeast), titleMost)
        return BoardGeometry(title: title, viewport: max(0, room - title), content: content)
    }
}

/// How far a board's columns have slid — one number for the header and
/// every row, so they move together. Observed, so a slide redraws only the
/// views that read it.
@Observable
final class BoardSlide {
    var x: CGFloat = 0

    init(probeX: CGFloat = 0) { x = probeX }

    /// Moved by a page of the window, the way the header's chevrons move it.
    func page(_ direction: CGFloat, in geometry: BoardGeometry) {
        let to = min(max(x + direction * geometry.viewport * 0.8, 0), geometry.limit)
        withAnimation(Motion.move) { x = to }
    }
}

/// The columns of a row, or of the header, in their window: offset by the
/// slide, faded at an edge with more beyond it, and deaf to the pointer where
/// they cannot be seen.
struct SlidingColumns<Cell: View>: View {
    let columns: [BoardColumn]
    let geometry: BoardGeometry
    let slide: BoardSlide
    @ViewBuilder let cell: (BoardColumn) -> Cell

    var body: some View {
        if geometry.slides {
            let x = min(slide.x, geometry.limit)
            track(x: x)
                .frame(width: geometry.content, alignment: .leading)
                .offset(x: -x)
                .frame(width: geometry.viewport, alignment: .leading)
                .mask {
                    HStack(spacing: 0) {
                        LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                            .frame(width: x > 0.5 ? 16 : 0)
                        Rectangle()
                        LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: x < geometry.limit - 0.5 ? 16 : 0)
                    }
                    // Taller than the row: a count's badge stands proud of its tile.
                    .padding(.vertical, -10)
                }
        } else {
            track(x: 0).frame(width: geometry.content, alignment: .leading)
        }
    }

    private func track(x: CGFloat) -> some View {
        HStack(spacing: 10) {
            ForEach(Array(columns.enumerated()), id: \.element) { index, column in
                let start = columns.prefix(index).reduce(0) { $0 + $1.width + 10 } - x
                let seen = start + column.width > 0 && start < geometry.viewport
                cell(column)
                    .frame(width: column.width, alignment: .leading)
                    .allowsHitTesting(!geometry.slides || seen)
            }
        }
    }
}

/// Which board is in front: a plan, the week, or a shelf — of one kind,
/// since a shelf shows one kind at a time (1.1).
enum BoardKind: Equatable {
    case plan(UUID), week, shelf(ShelfKind)

    /// Where its columns are remembered. A shelf of papers keeps the key it
    /// had before books and documents had tables of their own.
    var key: String {
        switch self {
        case .plan: "plan"
        case .week: "week"
        case .shelf(.paper): "shelf"
        case let .shelf(kind): "shelf." + kind.rawValue
        }
    }

    var isShelf: Bool {
        if case .shelf = self { return true }
        return false
    }

    /// The kind whose names the header uses.
    var shelfKind: ShelfKind {
        if case let .shelf(kind) = self { return kind }
        return .paper
    }

    /// Which columns stay when the column is narrow, most wanted first.
    /// Progress gives way before the materials: the ring at the head of
    /// every row already fills with it.
    static let priority: [BoardColumn] = [.day, .plan, .materials, .progress, .year, .authors, .venue,
                                          .publisher, .folder, .pages, .tags, .rating, .notes, .added, .opened]

    /// The columns each table starts with (2026-11-18, the user's ask: each
    /// kind its own columns). A paper is placed by who, when and where; a
    /// book by who, when and who published it — and how far through it you
    /// are, since a book is read over weeks; a document has no authors or
    /// venue worth a column, and is found by the folder it was put in, its
    /// length and when it arrived — the week's slides are the newest.
    var defaults: [BoardColumn] {
        switch self {
        case .plan: [.authors, .year, .venue, .day, .progress, .materials]
        case .week: [.plan, .day, .materials]
        case .shelf(.paper): [.authors, .year, .venue, .day, .plan, .materials]
        case .shelf(.book): [.authors, .year, .publisher, .day, .plan, .progress]
        case .shelf(.document): [.folder, .pages, .day, .plan, .added]
        }
    }
}

/// A heading's facts.
struct BoardGroup {
    var title: String
    var detail: String?
    /// The section the heading stands for, in a plan grouped by section.
    var section: UUID?
    var isSection = false
    /// «밀린 것»: the heading that offers to bring them to today.
    var behind = false
}

struct BoardToast: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var undo: (@MainActor () -> Void)?

    static func == (a: BoardToast, b: BoardToast) -> Bool { a.id == b.id }
}

/// The table and the calendar: sidebar | board | inspector, where the list
/// and the page were.
struct PlanBoard: View {
    @Bindable var model: LibraryModel
    /// Rows in a stack rather than a table, for `ImageRenderer`, which cannot
    /// draw an `NSTableView` (`PlanProbe`).
    var staticRows = false
    /// The shelf this board shows, when it is not the one in front — a shelf
    /// or a plan pinned in a pane of its own (`Workspace`).
    var shownScope: LibraryModel.Scope? = nil
    /// What opening a paper does here, when it is not the list's own —
    /// a pinned pane opens it on the page.
    var onOpen: ((UUID) -> Void)? = nil
    private var scope: LibraryModel.Scope { shownScope ?? model.scope }
    /// Pinned: the shelf is not the one the sidebar is on, so its papers are
    /// its own rather than the list's (`LibraryModel.pinnedShelf`).
    private var pinned: Bool { shownScope != nil && shownScope != model.scope }
    /// The kind a pinned shelf that holds several shows — its own chips.
    @State private var pinnedKind: ShelfKind?
    private var pinnedShelf: (papers: [LoadedPaper], kind: ShelfKind, kinds: [(kind: ShelfKind, count: Int)]) {
        model.pinnedShelf(scope, kind: pinnedKind)
    }
    /// The papers the board stands on: the list's, or the pinned shelf's.
    private var shelfPapers: [LoadedPaper] { pinned ? pinnedShelf.papers : model.visiblePapers }
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    @Environment(\.colorScheme) private var colorScheme

    enum Grouping: String { case section, week, status }

    @State private var grouping: Grouping = Grouping(rawValue: Boot.setting("PAPERTIME_PLAN_GROUP") ?? "") ?? .section
    /// How each board is sorted, if it is: the shelves share one, each plan
    /// and the week have their own — a plan sorted by year is not every
    /// shelf sorted by year.
    @State private var sorts: [String: BoardSort] = [:]
    /// How far the columns have slid, when the table is too narrow for them.
    @State private var slide = BoardSlide(probeX: PlanBoard.probeSlide)
    @State private var hidden: [String: [String]] = PlanBoard.storedColumns()
    @State private var toast: BoardToast?
    @State private var showsSpread = false
    @State private var calendarStart: PlanDay?
    @State private var addText = ""
    @State private var adding = false
    /// Plans whose «when will you read them?» strip was put away this session.
    @State private var quietStrips: Set<UUID> = []
    /// How wide the board is — it decides which columns fit.
    @State private var width: CGFloat = 900
    /// Whether a shelf's table shows «Read On» and «Plan» — off until asked
    /// for: on a shelf that is not a plan they are two columns of «Set Date»
    /// and «—» (2026-11-16, the user's ask).
    @State private var showsPlanColumns = PlanBoard.storedPlanColumns()

    private var kind: BoardKind {
        switch scope {
        case let .plan(id): .plan(id)
        case .thisWeek: .week
        default: .shelf(pinned ? pinnedShelf.kind : model.tableKind)
        }
    }

    private var view: LibraryModel.ShelfView { model.shelfView(for: scope) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if case let .plan(id) = kind, view == .calendar {
                PlanCalendar(
                    model: model, planID: id, start: $calendarStart, scrolls: !staticRows,
                    select: { model.selection = [$0] },
                    open: open,
                    move: { id, day in
                        let text = day.map { L("\(PlanText.full($0))로 옮겼어요.", "Moved to \(PlanText.full($0)).") }
                            ?? L("날짜를 지웠어요.", "Day cleared.")
                        changeDays([id: day], say: text)
                    }
                )
            } else if case let .plan(id) = kind, model.plan(id)?.entries.isEmpty == true {
                emptyPlan(id)
            } else {
                if case let .plan(id) = kind {
                    if needsDays(id), !quietStrips.contains(id) { daysStrip(id) }
                    viewbar
                }
                if kind.isShelf {
                    notices
                    kindBar
                }
                columnHeader
                if kind.isShelf, data.entries.isEmpty {
                    let empty = PaperListView.emptyShelf(for: scope)
                    ContentUnavailableView(empty.title, systemImage: empty.symbol, description: Text(empty.note))
                        .frame(maxHeight: .infinity)
                } else if kind == .week, data.entries.isEmpty {
                    Text(L("이번 주에 읽을 논문이 없어요", "Nothing to read this week."))
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                    Spacer()
                } else if staticRows {
                    let rows = data.entries
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, entry in
                            row(entry, selected: { if case let .paper(id) = entry { model.selection.contains(id) } else { false } }())
                                .frame(height: { switch entry {
                                case .paper: BoardTable.paperHeight
                                case .group: BoardTable.groupHeight
                                case .add: BoardTable.addHeight
                                } }())
                        }
                    }
                } else {
                BoardTable(
                    entries: data.entries,
                    revision: model.searchRevision,
                    slide: slide,
                    slideLimit: geometry.limit,
                    selection: $model.selection,
                    row: { entry, selected in row(entry, selected: selected) },
                    reorders: reorders,
                    drop: drop,
                    open: open,
                    model: model,
                    reveal: model.revealRequest
                )
                // The scroller floats over the rows rather than taking a lane
                // of its own, as the list's did: with «Show scroll bars:
                // Always» the lane narrowed the rows and not the column
                // titles over them, and every title stood 15 points right of
                // its column.
                .hiddenScrollers()
                }
            }
        }
        // Measured against the width it is given, not the width it would
        // like: the columns are laid out from this number, and a board
        // measured at its own wish kept itself at 512 points in a 300-point
        // column — the wide layout asked for the width that made it wide
        // (2026-11-16, `--papertime-plan-window` caught it).
        // Leading: in a pane narrower than the board will go, the start of
        // every row is what stays in sight.
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onGeometryChange(for: CGFloat.self) { ($0.size.width / 8).rounded(.down) * 8 } action: { width = $0 }
        // Another shelf, or other columns: the slide starts again at the
        // first column.
        .onChange(of: scope) { slide.x = 0 }
        .onChange(of: columns) { slide.x = 0 }
        .overlay(alignment: .bottom) { toastView }
        // What the New Plan sheet did, said here once the plan is showing.
        .onChange(of: app.planning.notice, initial: true) { _, notice in
            guard let notice else { return }
            app.planning.notice = nil
            show(notice)
        }
        .animation(Motion.move, value: toast)
        // Midnight, or a Mac woken the next morning: the board's «today»
        // moves with the clock.
        .onReceive(NotificationCenter.default.publisher(for: NSWorkspace.didWakeNotification)) { _ in refreshToday() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshToday() }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in refreshToday() }
    }

    private func refreshToday() {
        let now = PlanDay.today()
        if now != model.today { model.today = now }
    }

    // MARK: Header

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            ShelfHeader(symbol: ShelfTitle.symbol(of: scope), tint: ShelfTitle.tint(of: scope),
                        title: title, subtitle: subtitle) {
                topControls
            }
            if case let .plan(id) = kind, let plan = model.plan(id) {
                // The plan's own buttons on a row of their own, so a column
                // the width of a list still has room for them; words when
                // they fit, the symbols alone when they do not.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { planActions(id, words: true); Spacer(minLength: 12); if !plan.entries.isEmpty { stats(plan) } }
                    VStack(alignment: .leading, spacing: 8) { planActions(id, words: true); if !plan.entries.isEmpty { stats(plan) } }
                    VStack(alignment: .leading, spacing: 8) { planActions(id, words: false); if !plan.entries.isEmpty { stats(plan) } }
                }
                .popover(isPresented: $showsSpread, arrowEdge: .bottom) {
                    SpreadPicker(model: model, planID: id) { assignments in
                        showsSpread = false
                        let days = Dictionary(assignments.map { ($0.0, Optional($0.1)) }, uniquingKeysWith: { a, _ in a })
                        changeDays(days, say: L("\(days.count)편에 날짜를 정했어요.", "Gave \(PlanText.papers(days.count)) a day."))
                    }
                }
                if !plan.entries.isEmpty {
                    PlanPath(model: model, plan: plan, scrolls: !staticRows)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 6)
    }

    /// What sits at the end of the head: a plan's table and calendar; a
    /// shelf's «Read On · Plan» columns, shown on asking.
    @ViewBuilder
    private var topControls: some View {
        switch kind {
        case .plan:
            // Smaller in a narrow pane, and gone in a very narrow one, so the
            // plan's name — and the pane's ⌄ and × — keep their room.
            if width >= 340 {
                ShelfViewSwitch(view: Binding(get: { view }, set: { model.setShelfView($0, for: scope) }),
                                choices: [.table, .calendar], compact: width < 440)
            }
        case .week:
            if Legacy.paperList {
                ShelfViewSwitch(view: Binding(get: { view }, set: { model.setShelfView($0, for: scope) }),
                                choices: [.list, .table])
            }
        case .shelf:
            HStack(spacing: 8) {
                // In a narrow pane the shelf's name comes first: the words
                // go, then the button (a pane's ⌄ and × share the head now).
                if width >= 320 {
                Button {
                    withAnimation(Motion.move) { showsPlanColumns.toggle() }
                    PlanBoard.storePlanColumns(showsPlanColumns)
                } label: {
                    Label(L("읽을 날·계획", "Read On · Plan"), systemImage: "calendar")
                        .labelStyle(PlanColumnsLabelStyle(words: width >= 440))
                        .font(.system(size: 12, weight: showsPlanColumns ? .semibold : .regular))
                        .foregroundStyle(showsPlanColumns ? Color.accentColor : .secondary)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(Capsule().fill(showsPlanColumns ? Color.accentColor.opacity(0.13) : Color.primary.opacity(0.05)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(L("읽을 날과 계획 열을 보이거나 숨겨요", "Show or hide the Read On and Plan columns"))
                }
                if Legacy.paperList {
                    ShelfViewSwitch(view: Binding(get: { view }, set: { model.setShelfView($0, for: scope) }),
                                    choices: [.list, .table])
                }
            }
        }
    }

    static func storedPlanColumns() -> Bool {
        guard Boot.setting("PAPERTIME_LIBRARY") == nil else { return Boot.isSet("PAPERTIME_PLAN_COLUMNS") }
        return UserDefaults.standard.bool(forKey: "boardShowsPlanColumns")
    }

    static func storePlanColumns(_ on: Bool) {
        guard Boot.setting("PAPERTIME_LIBRARY") == nil else { return }
        UserDefaults.standard.set(on, forKey: "boardShowsPlanColumns")
    }

    /// What the old list said about the folder, said over the table: records
    /// that have not arrived, PDFs still to add, and the ones that would not.
    @ViewBuilder
    private var notices: some View {
        let failures = model.loadFailures.count
        if failures > 0 || model.isAdopting || !model.looseDocuments.isEmpty || !model.adoptFailures.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if failures > 0 {
                    Button { Task { await model.pullFromCloud() } } label: {
                        Label(L("기록 \(failures)개가 아직 안 왔어요", "\(failures) record\(failures == 1 ? "" : "s") \(failures == 1 ? "hasn't" : "haven't") arrived"),
                              systemImage: "icloud.slash")
                    }
                    .buttonStyle(.plain)
                }
                if model.isAdopting {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(L("PDF \(model.adoptingCount)개 더하는 중…", "Adding \(model.adoptingCount) PDFs…")).foregroundStyle(.secondary)
                    }
                } else if !model.looseDocuments.isEmpty {
                    Button { Task { await model.adoptLooseDocuments() } } label: {
                        Label(L("이 폴더에 남은 PDF \(model.looseDocuments.count)개 더하기", "Add \(model.looseDocuments.count) more PDFs from this folder"),
                              systemImage: "tray.and.arrow.down")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
                if !model.adoptFailures.isEmpty {
                    Label(L("PDF \(model.adoptFailures.count)개는 더하지 못했어요", "\(model.adoptFailures.count) PDF\(model.adoptFailures.count == 1 ? "" : "s") couldn't be added"),
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Corner.popover, style: .continuous).fill(Color.accentColor.opacity(0.06)))
            .padding(.horizontal, 16)
            .padding(.top, 4)
        }
    }

    private var title: String {
        switch scope {
        case let .plan(id): model.plan(id)?.name ?? L("계획", "Plan")
        case .thisWeek: L("이번 주", "This Week")
        default: ShelfTitle.of(scope, in: model)
        }
    }

    private var subtitle: String {
        switch kind {
        case let .plan(id):
            guard let plan = model.plan(id) else { return "" }
            let papers = plan.readingOrder.compactMap(model.paper)
            let read = papers.filter { $0.state.readingStatus == .read }.count
            if papers.isEmpty { return L("아직 논문이 없어요", "No papers yet") }
            let days = papers.compactMap(\.schedule).sorted()
            let span = days.first.map { PlanText.span($0, days.last!) } ?? L("날짜를 아직 안 정했어요", "No dates yet")
            return L("\(span) · \(papers.count)편 중 \(read)편 읽음", "\(span) · \(read) of \(papers.count) read")
        case .week:
            let monday = model.today.monday
            let papers = shelfPapers
            let plans = Set(papers.flatMap { model.plans(containing: $0.id).map(\.id) }).count
            let span = PlanText.span(monday, monday.adding(days: 6))
            return L("\(span) · 계획 \(plans)개에서 \(papers.count)편", "\(span) · \(PlanText.papers(papers.count)) from \(plans == 1 ? "1 plan" : "\(plans) plans")")
        case let .shelf(shelfKind):
            let count = shelfPapers.count
            return L("\(shelfKind.counted(count)) · 열 머리를 누르면 정렬돼요", "\(shelfKind.counted(count)) · Click a column to sort")
        }
    }

    /// A plan's three buttons — with their words, or as symbols when the
    /// column is too narrow for the words.
    @ViewBuilder
    private func planActions(_ id: UUID, words: Bool) -> some View {
        let papers = (model.plan(id)?.readingOrder ?? []).compactMap(model.paper)
        let pushable = !model.pushedAWeek(id).isEmpty
        HStack(spacing: 8) {
            Button {
                app.planning.sheet = .add(id)
            } label: {
                Label(L("논문 더하기…", "Add Papers…"), systemImage: "plus")
            }
            .help(L("논문 더하기", "Add Papers"))
            if !papers.isEmpty {
                Button {
                    showsSpread.toggle()
                } label: {
                    Label(L("고르게 나누기…", "Spread Out…"), systemImage: "calendar.badge.plus")
                }
                .help(L("고르게 나누기", "Spread Out"))
            }
            // Only once there is a day to push.
            if pushable {
                Button {
                    let pushed = model.pushedAWeek(id)
                    changeDays(pushed, say: L("남은 \(pushed.count)편을 한 주 뒤로 옮겼어요.", "Moved \(PlanText.papers(pushed.count)) a week later."))
                } label: {
                    Label(L("한 주 미루기", "Push a Week"), systemImage: "arrow.right")
                }
                .help(L("한 주 미루기", "Push a Week"))
            }
        }
        .buttonStyle(SoftButtonStyle())
        .labelStyle(PlanActionLabel(words: words))
        .fixedSize()
    }

    private func stats(_ plan: ReadingPlan) -> some View {
        let papers = plan.readingOrder.compactMap(model.paper)
        let week = papers.filter { $0.schedule?.monday == model.today.monday }.count
        let behind = papers.filter(model.isBehind).count
        let none = papers.filter { $0.schedule == nil }.count
        return HStack(spacing: 6) {
            StatCapsule(text: L("이번 주 \(week)편", "This week \(week)"), color: .blue)
            if behind > 0 { StatCapsule(text: L("밀린 것 \(behind)편", "Overdue \(behind)"), color: .orange) }
            if none > 0 {
                // Where the undated ones wait: the calendar's tray.
                Button {
                    model.setShelfView(.calendar, for: scope)
                } label: {
                    StatCapsule(text: L("날짜 없음 \(none)편", "No date \(none)"), color: .gray)
                }
                .buttonStyle(.plain)
                .help(L("달력에서 날짜를 정해요", "Give them days on the calendar"))
            }
        }
    }

    // MARK: What to do next

    /// A plan's papers, none with a day yet.
    private func needsDays(_ id: UUID) -> Bool {
        let papers = (model.plan(id)?.readingOrder ?? []).compactMap(model.paper)
        return !papers.isEmpty && papers.allSatisfy { $0.schedule == nil }
    }

    /// The next step, said where the work is: until a plan has a day, the
    /// board asks when, and offers the two ways to answer.
    private func daysStrip(_ id: UUID) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 18))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("언제 읽을지 정해 볼까요?", "When will you read them?"))
                    .font(.system(size: 13, weight: .semibold))
                Text(L("요일만 고르면 차례대로 날짜를 정해요.", "Pick the weekdays and each paper gets a day, in order."))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(L("고르게 나누기…", "Spread Out…")) { showsSpread = true }
                .buttonStyle(SoftButtonStyle(prominent: true))
            Button(L("달력에서 정하기", "Use the Calendar")) { model.setShelfView(.calendar, for: scope) }
                .buttonStyle(SoftButtonStyle())
            Button {
                withAnimation(Motion.move) { _ = quietStrips.insert(id) }
            } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .help(L("닫기", "Close"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: Corner.popover, style: .continuous).fill(Color.accentColor.opacity(0.07)))
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .transition(.opacity)
    }

    /// A plan with nothing in it says what goes in, and how.
    private func emptyPlan(_ id: UUID) -> some View {
        VStack(spacing: 12) {
            Spacer(minLength: 20)
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text(L("이 계획에 읽을 논문을 모아요", "Gather the papers for this plan"))
                .font(.system(size: 15, weight: .semibold))
            Text(L("라이브러리에서 고르거나, arXiv 주소·DOI를 붙여넣거나, 목록에서 끌어와요.",
                   "Pick them from your library, paste an arXiv link or a DOI, or drag them in from the list."))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button(L("논문 고르기…", "Choose Papers…")) { app.planning.sheet = .add(id) }
                .buttonStyle(SoftButtonStyle(prominent: true))
                .padding(.top, 4)
            addRow.frame(maxWidth: 520)
            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 20)
    }

    // MARK: The kinds on a shelf

    /// A shelf that holds more than one kind — a semester's folder, «안
    /// 읽음» — shows one at a time, each under its own columns: these chips
    /// say which, and how many of each there are. The choice follows the
    /// kind shelf picked last.
    @ViewBuilder
    private var kindBar: some View {
        let kinds = pinned ? pinnedShelf.kinds : model.kindsOnShelf
        if kinds.count > 1 {
            HStack(spacing: 4) {
                ForEach(kinds, id: \.kind) { entry in
                    kindChip(entry.kind, count: entry.count)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 6)
        }
    }

    private func kindChip(_ shelfKind: ShelfKind, count: Int) -> some View {
        let on = kind.shelfKind == shelfKind
        return Button {
            withAnimation(Motion.tap) {
                if pinned { pinnedKind = shelfKind } else { model.shownKind = shelfKind }
            }
        } label: {
            HStack(spacing: 5) {
                Text(shelfKind.label)
                Text("\(count)")
                    .monospacedDigit()
                    .opacity(0.7)
            }
            .font(.system(size: 11.5, weight: on ? .semibold : .regular))
            .foregroundStyle(on ? Color.accentColor : .secondary)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(Capsule().fill(on ? Color.accentColor.opacity(0.13) : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pressable(cornerRadius: 11)
        .help(L("\(shelfKind.counted(count)) 보기", "Show \(shelfKind.counted(count))"))
    }

    // MARK: The bar over a plan's table

    private var viewbar: some View {
        // A narrow table keeps the chips and the sort on one line: the
        // «Group By» word goes, and «Add Section» keeps only its plus.
        let narrow = width < 420
        return HStack(spacing: 8) {
            if !narrow {
                Text(L("묶기", "Group By")).font(.system(size: 11.5)).foregroundStyle(.tertiary)
            }
            HStack(spacing: 4) {
                chip(L("섹션", "Section"), .section)
                chip(L("주", "Week"), .week)
                chip(L("상태", "Status"), .status)
            }
            // A sorted plan says so where its order is chosen, with the way
            // back to the reading order: the arrow in a header is easy to
            // miss, and the plan's order is the plan.
            if let sort {
                Button {
                    withAnimation(Motion.move) { sorts[sortKey] = nil }
                } label: {
                    HStack(spacing: 5) {
                        Text(L("\(sort.column?.title ?? "제목") 순 \(sort.ascending ? "↑" : "↓")",
                               "By \(sort.column?.title ?? "Title") \(sort.ascending ? "↑" : "↓")"))
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 9)
                    .frame(height: 22)
                    .background(Capsule().fill(Color.accentColor.opacity(0.13)))
                    .contentShape(Capsule())
                    .fixedSize()
                }
                .buttonStyle(.plain)
                .help(L("계획 순서로 돌아가요", "Back to the plan's order"))
                .transition(.opacity)
            }
            Spacer()
            if case let .plan(id) = kind {
                Button {
                    app.planning.prompt = .newSection(id)
                } label: {
                    if narrow {
                        Image(systemName: "plus").font(.system(size: 11.5, weight: .medium))
                    } else {
                        Label(L("섹션 더하기", "Add Section"), systemImage: "plus")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(L("섹션 더하기", "Add Section"))
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
    }

    private func chip(_ text: String, _ value: Grouping) -> some View {
        Button {
            withAnimation(Motion.tap) { grouping = value }
        } label: {
            Text(text)
                .font(.system(size: 11.5, weight: grouping == value ? .semibold : .regular))
                .foregroundStyle(grouping == value ? Color.accentColor : .secondary)
                .padding(.horizontal, 9)
                .frame(height: 22)
                .background(Capsule().fill(grouping == value ? Color.accentColor.opacity(0.13) : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Sorting

    private var sortKey: String {
        switch kind {
        case let .plan(id): "plan:" + id.uuidString
        case .week: "week"
        case .shelf: kind.key
        }
    }

    /// What this board is sorted by, if anything.
    private var sort: BoardSort? { sorts[sortKey] ?? PlanBoard.probeSort }

    /// A header pressed: by it, then the other way, then the board's own
    /// order again — a plan's reading order, which a sort must not lose.
    private func cycleSort(_ column: BoardColumn?) {
        let next: BoardSort?
        if let sort, sort.column == column {
            next = sort.ascending ? BoardSort(column: column, ascending: false) : nil
        } else {
            next = BoardSort(column: column, ascending: true)
        }
        withAnimation(Motion.move) { sorts[sortKey] = next }
    }

    private static func sortable(_ column: BoardColumn?) -> Bool { column != .materials && column != .tags }

    /// `--papertime-plan-sort=year` (a leading `-` for descending, `title`
    /// for the titles): a probe's board drawn sorted.
    /// `--papertime-plan-slide=<points>`: a probe's board drawn with its
    /// columns slid that far.
    static let probeSlide: CGFloat = {
        guard Boot.setting("PAPERTIME_LIBRARY") != nil else { return 0 }
        return CGFloat(Double(Boot.setting("PAPERTIME_PLAN_SLIDE") ?? "") ?? 0)
    }()

    static let probeSort: BoardSort? = {
        guard Boot.setting("PAPERTIME_LIBRARY") != nil, var raw = Boot.setting("PAPERTIME_PLAN_SORT") else { return nil }
        let ascending = !raw.hasPrefix("-")
        if !ascending { raw.removeFirst() }
        if raw == "title" { return BoardSort(column: nil, ascending: ascending) }
        return BoardColumn(rawValue: raw).map { BoardSort(column: $0, ascending: ascending) }
    }()

    /// The papers in the order the board is sorted by, those with nothing
    /// to sort by last whichever way it goes — a paper with no year is not
    /// the oldest one — and ties in the order they came.
    private func sorted(_ papers: [LoadedPaper]) -> [LoadedPaper] {
        guard let sort else { return papers }
        let keyed = papers.enumerated().map { (index: $0.offset, paper: $0.element, value: sortValue($0.element, sort.column)) }
        return keyed.sorted { x, y in
            switch (x.value, y.value) {
            case let (a?, b?):
                let order = a.compare(b)
                if order == .orderedSame { return x.index < y.index }
                return sort.ascending ? order == .orderedAscending : order == .orderedDescending
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return x.index < y.index
            }
        }.map(\.paper)
    }

    private func sortValue(_ paper: LoadedPaper, _ column: BoardColumn?) -> BoardSort.Value? {
        switch column {
        case nil: .text(paper.meta.displayTitle)
        case .authors: paper.meta.csl.author.first?.sortingSurname.map { .text($0) }
        case .year: paper.meta.csl.year.map { .number(Double($0)) }
        case .venue: BoardRow.venue(paper).map { .text($0) }
        case .publisher: paper.meta.csl.publisher.flatMap { $0.isEmpty ? nil : .text($0) }
        case .folder: .text(model.folderLabel(for: paper.documentURL.deletingLastPathComponent()))
        case .pages: paper.meta.file.pageCount > 0 ? .number(Double(paper.meta.file.pageCount)) : nil
        case .plan: model.plans(containing: paper.id).first.map { .text($0.name) }
        case .day: paper.schedule.map { .number(Double($0.ordinal)) }
        case .progress: .number(Double(model.progress(of: paper)))
        case .rating: paper.state.rating.map { .number(Double($0)) }
        case .notes: .number(Double(model.notes.notes(forPaper: paper.id).count))
        case .added: .number(paper.meta.addedAt.timeIntervalSinceReferenceDate)
        case .opened: paper.state.lastOpenedAt.map { .number($0.timeIntervalSinceReferenceDate) }
        default: nil
        }
    }

    // MARK: Columns

    /// The columns asked for, in their order.
    private var wantedColumns: [BoardColumn] {
        let off = Set(hidden[kind.key] ?? [])
        var base = kind.defaults
        if kind.isShelf, !showsPlanColumns { base.removeAll { $0 == .day || $0 == .plan } }
        let shown = base.filter { !off.contains($0.rawValue) }
        let extra = BoardColumn.allCases.filter { !kind.defaults.contains($0) && off.contains("+" + $0.rawValue) }
        return shown + extra
    }

    /// The ones that fit beside a title of at least 180 points, the most
    /// wanted kept first — in a column the width of a list, the table loses
    /// its venue before it loses its days.
    private var columns: [BoardColumn] { wantedColumns }

    /// Where the title ends and the columns' window begins.
    private var geometry: BoardGeometry { BoardGeometry.of(width: width, columns: columns) }

    private func isShown(_ column: BoardColumn) -> Bool { wantedColumns.contains(column) }

    private func toggle(_ column: BoardColumn) {
        var list = hidden[kind.key] ?? []
        let key = kind.defaults.contains(column) ? column.rawValue : "+" + column.rawValue
        if let index = list.firstIndex(of: key) { list.remove(at: index) } else { list.append(key) }
        hidden[kind.key] = list
        PlanBoard.storeColumns(hidden)
    }

    static func storedColumns() -> [String: [String]] {
        guard Boot.setting("PAPERTIME_LIBRARY") == nil else { return [:] }
        return UserDefaults.standard.dictionary(forKey: "boardColumns") as? [String: [String]] ?? [:]
    }

    static func storeColumns(_ value: [String: [String]]) {
        guard Boot.setting("PAPERTIME_LIBRARY") == nil else { return }
        UserDefaults.standard.set(value, forKey: "boardColumns")
    }

    private var columnHeader: some View {
        HStack(spacing: 10) {
            let geometry = geometry
            Color.clear.frame(width: 22, height: 1)
            headerLabel(L("제목", "Title"), column: nil)
                .frame(width: geometry.title, alignment: .leading)
                .frame(maxWidth: geometry.title == nil ? .infinity : nil, alignment: .leading)
                .zIndex(1)
            SlidingColumns(columns: columns, geometry: geometry, slide: slide) { column in
                headerLabel(column.title(for: kind.shelfKind), column: column)
            }
            .overlay(alignment: .leading) {
                if geometry.slides, min(slide.x, geometry.limit) > 0.5 {
                    // In the empty end of the title's header, not over a name.
                    slideButton("chevron.left") { slide.page(-1, in: geometry) }
                        .offset(x: -16)
                }
            }
            .overlay(alignment: .trailing) {
                if geometry.slides, min(slide.x, geometry.limit) < geometry.limit - 0.5 {
                    // In the row's margin, past the last column it shows.
                    slideButton("chevron.right") { slide.page(1, in: geometry) }
                        .offset(x: 14)
                }
            }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.tertiary)
        .frame(height: 28)
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .contentShape(Rectangle())
        .contextMenu {
            Text(L("보일 열", "Columns"))
            ForEach(BoardColumn.allCases) { column in
                Toggle(column.title(for: kind.shelfKind), isOn: Binding(get: { isShown(column) }, set: { _ in toggle(column) }))
            }
            Divider()
            Button(L("기본으로 되돌리기", "Restore Defaults")) {
                hidden[kind.key] = nil
                PlanBoard.storeColumns(hidden)
            }
        }
        .help(L("열 머리를 오른쪽 클릭하면 보일 열을 고를 수 있어요", "Right-click a column to choose what shows"))
    }

    /// A chevron at an edge of the columns' window that has more beyond it —
    /// the way to the other columns for a mouse with no sideways wheel. A
    /// trackpad swipe or ⇧ and the wheel slide them as well.
    private func slideButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .background(Circle().fill(.background))
                .background(Circle().fill(Color.primary.opacity(0.07)).padding(-0.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .pressable(cornerRadius: 9)
        .help(L("다른 열 보기 — 트랙패드로 옆으로 밀어도 돼요", "More columns — or swipe sideways on the trackpad"))
    }

    @ViewBuilder
    private func headerLabel(_ text: String, column: BoardColumn?) -> some View {
        if PlanBoard.sortable(column) {
            let current = sort?.column == column && sort != nil
            BoardHeaderButton(text: text, arrow: current ? (sort?.ascending == true ? "↑" : "↓") : nil) {
                cycleSort(column)
            }
        } else {
            Text(text).lineLimit(1)
        }
    }

    // MARK: Rows

    private var reorders: Bool {
        // Dragging into an order means nothing while the rows stand in
        // another one.
        if case .plan = kind { return grouping == .section && sort == nil }
        return false
    }

    private var data: (entries: [BoardEntry], groups: [String: BoardGroup]) {
        switch kind {
        case let .plan(id): planRows(id)
        case .week: weekRows()
        case .shelf: (sortedShelf().map { .paper($0.id) }, [:])
        }
    }

    private func planRows(_ id: UUID) -> ([BoardEntry], [String: BoardGroup]) {
        guard let plan = model.plan(id) else { return ([], [:]) }
        var entries: [BoardEntry] = []
        var groups: [String: BoardGroup] = [:]
        func add(_ key: String, _ group: BoardGroup, _ papers: [LoadedPaper]) {
            groups[key] = group
            entries.append(.group(key))
            entries += papers.map { .paper($0.id) }
        }
        func readCount(_ papers: [LoadedPaper]) -> String {
            let read = papers.filter { $0.state.readingStatus == .read }.count
            return L("\(read)/\(papers.count) 읽음", "\(read)/\(papers.count) read")
        }
        let all = plan.readingOrder.compactMap(model.paper)
        switch grouping {
        case .section:
            for group in plan.groups {
                let papers = sorted(group.papers.compactMap(model.paper))
                if group.section == nil, plan.sections.isEmpty {
                    entries += papers.map { .paper($0.id) }
                    continue
                }
                let key = "section:" + (group.section?.id.uuidString ?? "none")
                add(key, BoardGroup(title: group.section?.name ?? L("섹션 없음", "No Section"),
                                    detail: readCount(papers), section: group.section?.id, isSection: group.section != nil), papers)
            }
        case .week:
            let weeks = Dictionary(grouping: all) { $0.schedule?.monday }
            for monday in weeks.keys.compactMap({ $0 }).sorted() {
                let papers = sorted(weeks[monday]!.sorted { ($0.schedule ?? monday) < ($1.schedule ?? monday) })
                add("week:" + monday.text, BoardGroup(title: PlanText.week(monday, today: model.today), detail: readCount(papers)), papers)
            }
            if let none = weeks[nil], !none.isEmpty {
                add("week:none", BoardGroup(title: L("날짜 없음", "No Date"), detail: readCount(none)), sorted(none))
            }
        case .status:
            for status in [PaperState.ReadingStatus.reading, .unread, .read] {
                let papers = sorted(all.filter { $0.state.readingStatus == status })
                if !papers.isEmpty { add("status:" + status.rawValue, BoardGroup(title: status.label, detail: readCount(papers)), papers) }
            }
        }
        entries.append(.add)
        return (entries, groups)
    }

    private func weekRows() -> ([BoardEntry], [String: BoardGroup]) {
        var entries: [BoardEntry] = []
        var groups: [String: BoardGroup] = [:]
        let papers = shelfPapers
        let behind = papers.filter(model.isBehind)
        if !behind.isEmpty {
            groups["behind"] = BoardGroup(title: L("밀린 것", "Overdue"), detail: PlanText.papers(behind.count), behind: true)
            entries.append(.group("behind"))
            entries += sorted(behind).map { .paper($0.id) }
        }
        let rest = papers.filter { !model.isBehind($0) }
        let days = Dictionary(grouping: rest) { $0.schedule ?? model.today }
        for day in days.keys.sorted() {
            groups["day:" + day.text] = BoardGroup(title: PlanText.heading(day, today: model.today))
            entries.append(.group("day:" + day.text))
            entries += sorted(days[day]!).map { .paper($0.id) }
        }
        return (entries, groups)
    }

    private func sortedShelf() -> [LoadedPaper] { sorted(shelfPapers) }

    private func row(_ entry: BoardEntry, selected: Bool) -> AnyView {
        switch entry {
        case let .paper(id):
            guard let paper = model.paper(id) else { return AnyView(EmptyView()) }
            return AnyView(
                BoardRow(
                    paper: paper, model: model, columns: columns, geometry: geometry, slide: slide, selected: selected,
                    cycle: {
                        model.selection = [id]
                        Task { await model.setReadingStatus(paper.state.readingStatus.next, for: id) }
                    },
                    pickDay: { pickDay(for: id) },
                    menu: { AnyView(rowMenu(paper)) }
                )
                .environment(app)
            )
        case let .group(key):
            let group = data.groups[key] ?? BoardGroup(title: "")
            return AnyView(groupRow(group))
        case .add:
            return AnyView(addRow)
        }
    }

    private func groupRow(_ group: BoardGroup) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(group.title).font(.system(size: 12, weight: .semibold))
            if let detail = group.detail {
                Text(detail).font(.system(size: 11.5)).monospacedDigit().foregroundStyle(.tertiary)
            }
            Spacer()
            if group.behind {
                Button(L("오늘로 옮기기", "Move to Today")) {
                    let days = model.behindToToday()
                    changeDays(days, say: L("\(days.count)편을 오늘로 옮겼어요.", "Moved \(PlanText.papers(days.count)) to today."))
                }
                .buttonStyle(SoftButtonStyle())
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 4)
        .contentShape(Rectangle())
        .contextMenu {
            if group.isSection, let section = group.section, case let .plan(planID) = kind {
                Button(L("섹션 이름 바꾸기…", "Rename Section…")) { app.planning.prompt = .renameSection(plan: planID, section: section) }
                Button(L("위로", "Move Up")) { editPlan(planID, name: L("섹션 옮기기", "Move Section")) { $0.moveSection(section, by: -1) } }
                Button(L("아래로", "Move Down")) { editPlan(planID, name: L("섹션 옮기기", "Move Section")) { $0.moveSection(section, by: 1) } }
                Divider()
                Button(L("섹션 지우기", "Delete Section"), role: .destructive) {
                    editPlan(planID, name: L("섹션 지우기", "Delete Section")) { $0.removeSection(section) }
                }
            }
        }
    }

    @ViewBuilder
    private func rowMenu(_ paper: LoadedPaper) -> some View {
        // Everything the list's rows offered: open beside, keep open, reading
        // state, star, tags, attach, the key, Finder, the Trash.
        PaperMenu(paper: paper, model: model)
        if case let .plan(planID) = kind, let plan = model.plan(planID) {
            Divider()
            if !plan.sections.isEmpty {
                Menu(L("섹션", "Section")) {
                    Button(L("섹션 없음", "No Section")) {
                        editPlan(planID, name: L("섹션 옮기기", "Move to Section")) { $0.move([paper.id], toEndOf: nil) }
                    }
                    ForEach(plan.sections) { section in
                        Button(section.name) {
                            editPlan(planID, name: L("섹션 옮기기", "Move to Section")) { $0.move([paper.id], toEndOf: section.id) }
                        }
                    }
                }
            }
            Divider()
            Button(L("계획에서 빼기", "Remove from Plan")) {
                let ids = model.selection.contains(paper.id) ? model.selection : [paper.id]
                editPlan(planID, name: L("계획에서 빼기", "Remove from Plan")) { $0.remove(ids) }
            }
        }
        if paper.schedule != nil {
            Button(L("날짜 지우기", "Clear Date")) { changeDays([paper.id: nil], say: L("날짜를 지웠어요.", "Day cleared.")) }
        }
    }

    private var addRow: some View {
        HStack(spacing: 10) {
            Image(systemName: adding ? "hourglass" : "plus")
                .font(.system(size: 12, weight: .semibold))
            TextField(L("arXiv 주소나 DOI를 붙여넣어 논문을 더해요", "Paste an arXiv link or a DOI to add a paper"), text: $addText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .onSubmit { Task { await addAddresses() } }
                .disabled(adding)
            Text(L("목록에서 끌어와도 돼요", "Or drag one in from the list"))
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.07)))
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    // MARK: Doing

    private func open(_ id: UUID) {
        if let onOpen { return onOpen(id) }
        model.openFromBoard(id)
        if !app.showsReader { app.ensurePagePane(after: ContentPane.listID) }
    }

    private func pickDay(for id: UUID) {
        model.selection = [id]
        DayPopover.show(model: model, paperID: id) { day in
            changeDays([id: day], say: nil)
        }
    }

    /// Gives days, says so, and makes it one undo — from the toast and from
    /// ⌘Z alike.
    private func changeDays(_ days: [UUID: PlanDay?], say text: String?) {
        guard !days.isEmpty else { return }
        Task { @MainActor in
            let before = await model.setDays(days)
            let undo: @MainActor () -> Void = { Task { await model.setDays(before) } }
            registerUndo(L("날짜 바꾸기", "Change Day"), undo)
            if let text { show(text, undo: undo) }
        }
    }

    private func editPlan(_ id: UUID, name: String, _ change: @escaping @Sendable (inout ReadingPlan) -> Void) {
        guard let before = model.plan(id) else { return }
        Task { @MainActor in
            await model.editPlan(id, change)
            registerUndo(name) {
                Task {
                    await model.editPlan(id) {
                        $0.entries = before.entries
                        $0.sections = before.sections
                    }
                }
            }
        }
    }

    private func registerUndo(_ name: String, _ undo: @escaping @MainActor () -> Void) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: model) { _ in MainActor.assumeIsolated { undo() } }
        undoManager.setActionName(name)
    }

    private func show(_ text: String, undo: (@MainActor () -> Void)? = nil) {
        let made = BoardToast(text: text, undo: undo)
        toast = made
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(undo == nil ? 3.2 : 7))
            if toast?.id == made.id { toast = nil }
        }
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast {
            HStack(spacing: 10) {
                Text(toast.text).font(.system(size: 13))
                if let undo = toast.undo {
                    Button(L("되돌리기", "Undo")) {
                        undo()
                        self.toast = nil
                        show(L("되돌렸어요.", "Undone."))
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(Capsule().fill(Color.white.opacity(0.18)))
                }
            }
            .foregroundStyle(colorScheme == .dark ? Color.black : .white)
            .padding(.leading, 16)
            .padding(.trailing, toast.undo == nil ? 16 : 8)
            .frame(minHeight: 36)
            .background(Capsule().fill(colorScheme == .dark ? Color(white: 0.92) : Color(white: 0.17)))
            .shadow(color: .black.opacity(0.2), radius: 14, y: 6)
            .padding(.bottom, 18)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func drop(_ ids: [UUID], at row: Int) -> Bool {
        guard case let .plan(planID) = kind, let plan = model.plan(planID) else { return false }
        let entries = data.entries
        let groups = data.groups
        var target: UUID?
        var section: UUID?
        if row < entries.count, case let .paper(id) = entries[row] {
            target = id
        } else {
            var index = row - 1
            while index >= 0 {
                if case let .group(key) = entries[index] { section = groups[key]?.section; break }
                if case let .paper(id) = entries[index] { section = plan.section(of: id)?.id; break }
                index -= 1
            }
        }
        let order = plan.readingOrder
        let moving = ids.sorted { (order.firstIndex(of: $0) ?? Int.max) < (order.firstIndex(of: $1) ?? Int.max) }
        let fresh = moving.filter { !plan.contains($0) }
        let before = target, into = section
        editPlan(planID, name: L("차례 바꾸기", "Reorder")) { plan in
            plan.add(fresh, to: into)
            if let before { plan.move(moving, before: before) } else { plan.move(moving, toEndOf: into) }
        }
        return true
    }

    /// The foot of a plan: addresses, one per line. A paper the library has
    /// joins the plan; one it does not is fetched first, the way «Add Paper by
    /// Address…» fetches it.
    private func addAddresses() async {
        guard case let .plan(planID) = kind else { return }
        let lines = addText.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty else { return }
        adding = true
        defer { adding = false }
        var ids: [UUID] = []
        var failed = 0
        for line in lines {
            guard let address = PaperAddress.read(line) else { failed += 1; continue }
            if let have = existing(address) { ids.append(have); continue }
            switch await model.addPaper(byAddress: line, keepFile: !app.settings.keepsPDFsInMemory) {
            case let .added(paper), let .already(paper): ids.append(paper.id)
            case .failed: failed += 1
            }
        }
        if !ids.isEmpty {
            let added = ids
            editPlan(planID, name: L("논문 더하기", "Add Papers")) { $0.add(added) }
            addText = ""
        }
        if failed > 0 {
            show(L("주소 \(failed)개는 더하지 못했어요.", failed == 1 ? "One address couldn't be added." : "\(failed) addresses couldn't be added."))
        } else if !ids.isEmpty {
            show(L("논문 \(ids.count)편을 더했어요.", "Added \(PlanText.papers(ids.count))."))
        }
    }

    private func existing(_ address: PaperAddress) -> UUID? {
        switch address {
        case let .arxiv(id):
            let base = Identifiers(arxiv: id).arxivBaseID ?? id
            return model.papers.first { $0.meta.identifiers.arxivBaseID?.lowercased() == base.lowercased() }?.id
        case let .doi(doi):
            return model.papers.first { $0.meta.identifiers.doi?.lowercased() == doi.lowercased() }?.id
        case .web:
            return nil
        }
    }
}

/// A plan button's label: icon and words, or the icon alone.
struct PlanActionLabel: LabelStyle {
    let words: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
            if words { configuration.title }
        }
    }
}

/// One paper on a board, drawn like the demo's grid row.
struct BoardRow: View {
    let paper: LoadedPaper
    let model: LibraryModel
    let columns: [BoardColumn]
    var geometry = BoardGeometry(title: nil, viewport: 0, content: 0)
    var slide = BoardSlide()
    let selected: Bool
    let cycle: () -> Void
    let pickDay: () -> Void
    let menu: () -> AnyView
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            // The ring and the title stay where they are while the columns
            // slide; above them, so a column slid under the title is not
            // what a click on the title finds.
            HStack(spacing: 10) {
                Button(action: cycle) {
                    StatusRing(status: paper.state.readingStatus, progress: model.progress(of: paper))
                        .frame(width: 22, height: 22)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(L("누르면 읽기 상태가 바뀌어요", "Click to change the reading state"))
                Text(paper.meta.displayTitle)
                    .font(.system(size: 13, weight: paper.state.readingStatus == .read ? .regular : .medium))
                    .foregroundStyle(paper.state.readingStatus == .read ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: geometry.title, alignment: .leading)
                    .frame(maxWidth: geometry.title == nil ? .infinity : nil, alignment: .leading)
                    .help(paper.meta.displayTitle)
            }
            .contentShape(Rectangle())
            .zIndex(1)
            SlidingColumns(columns: columns, geometry: geometry, slide: slide) { column in
                // Held open even when the cell has nothing to draw: a cell
                // that drew nothing (no materials) took its frame with it, and
                // every column after it slid over (2026-11-16).
                HStack(spacing: 0) {
                    cell(column)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: BoardTable.paperHeight - 2)
        .background(
            RoundedRectangle(cornerRadius: Corner.row, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.14) : hovering ? Color.primary.opacity(0.045) : .clear)
        )
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu { menu() }
    }

    @ViewBuilder
    private func cell(_ column: BoardColumn) -> some View {
        switch column {
        case .authors:
            Text(authors).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
        case .year:
            Text(paper.meta.csl.year.map(String.init) ?? "—").font(.system(size: 12)).monospacedDigit()
                .foregroundStyle(.secondary).lineLimit(1)
        case .venue:
            Text(BoardRow.venue(paper) ?? "—")
                .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                .help(paper.meta.csl.containerTitle ?? "")
        case .publisher:
            Text(paper.meta.csl.publisher.flatMap { $0.isEmpty ? nil : $0 } ?? "—")
                .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                .help(paper.meta.csl.publisher ?? "")
        case .folder:
            // The folder it sits in by name; the way down from the library
            // in the tooltip.
            let folder = paper.documentURL.deletingLastPathComponent()
            Text(folder.lastPathComponent)
                .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                .help(model.folderLabel(for: folder))
        case .pages:
            Text(paper.meta.file.pageCount > 0 ? "\(paper.meta.file.pageCount)" : "—")
                .font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
        case .plan:
            if let plan = model.plans(containing: paper.id).first {
                TagCapsule(name: plan.name, color: .indigo)
            } else {
                Text("—").foregroundStyle(.tertiary)
            }
        case .day:
            let chip = PlanText.chip(paper.schedule, behind: model.isBehind(paper), today: model.today)
            Button(action: pickDay) { DayChipLabel(text: chip.text, style: chip.style) }
                .buttonStyle(.plain)
                .padding(.leading, chip.style == .today || chip.style == .behind ? 0 : -8)
                .help(L("읽을 날 정하기", "Set the day to read it"))
        case .progress:
            ProgressCell(fraction: model.progress(of: paper), page: paper.state.lastPageIndex > 0 ? paper.state.lastPageIndex + 1 : 0,
                         pages: paper.meta.file.pageCount, isRead: paper.state.readingStatus == .read)
        case .materials:
            MaterialChips(paper: paper, model: model)
        case .tags:
            HStack(spacing: 4) {
                ForEach(paper.meta.tagIDs.prefix(2), id: \.self) { id in
                    if let tag = model.tag(for: id) { TagCapsule(name: tag.name, color: tag.color.swiftUIColor) }
                }
            }
        case .rating:
            Text(paper.state.rating.map { String(repeating: "★", count: $0) } ?? "—")
                .font(.system(size: 11)).foregroundStyle(paper.state.rating == nil ? .tertiary : .secondary)
        case .notes:
            let count = model.notes.notes(forPaper: paper.id).count
            Text(count == 0 ? "—" : "\(count)").font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
        case .added:
            Text(PlanText.short(PlanDay.today(now: paper.meta.addedAt))).font(.system(size: 12)).foregroundStyle(.secondary)
        case .opened:
            Text(paper.state.lastOpenedAt.map { PlanText.short(PlanDay.today(now: $0)) } ?? "—")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private var authors: String {
        let first = paper.meta.csl.author.first?.family ?? paper.meta.csl.author.first?.displayName ?? ""
        let more = paper.meta.csl.author.count > 1 ? L(" 외", " et al.") : ""
        return first.isEmpty ? "—" : first + more
    }

    /// The venue as a table says it: NeurIPS, not the proceedings' title.
    static func venue(_ paper: LoadedPaper) -> String? {
        VenueName.short(full: paper.meta.csl.containerTitle, short: paper.meta.csl.containerTitleShort)
    }
}

/// A paper's materials as small tiles: its own address first.
struct MaterialChips: View {
    let paper: LoadedPaper
    let model: LibraryModel

    var body: some View {
        let kinds = (model.paperLink(of: paper) != nil ? [MaterialKind.paper] : [])
            + Array(repeating: MaterialKind.supplement, count: model.attachmentCount(of: paper.id))
            + paper.links.map(\.kind)
        // One tile, the width of the column; more than one, and a count in
        // its corner (2026-11-16: the column only as wide as the button).
        if let first = kinds.first {
            KindTile(kind: first)
                .overlay(alignment: .topTrailing) {
                    if kinds.count > 1 {
                        Text("\(kinds.count)")
                            .font(.system(size: 9, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 3.5)
                            .frame(minWidth: 14, minHeight: 14)
                            .background(Capsule().fill(Color.accentColor))
                            .offset(x: 5, y: -5)
                    }
                }
                .help(kinds.map(\.name).joined(separator: " · "))
        }
    }
}

/// The plan's path: a ring per paper, in order, cut by section.
struct PlanPath: View {
    let model: LibraryModel
    let plan: ReadingPlan
    var scrolls = true

    var body: some View {
        if scrolls {
            ScrollView(.horizontal, showsIndicators: false) { path }
                .fixedSize(horizontal: false, vertical: true)
        } else {
            path
        }
    }

    private var path: some View {
            HStack(alignment: .top, spacing: 20) {
                ForEach(Array(plan.groups.enumerated()), id: \.offset) { _, group in
                    let papers = group.papers.compactMap(model.paper)
                    if !papers.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 8) {
                                ForEach(papers) { paper in
                                    Button {
                                        model.selection = [paper.id]
                                    } label: {
                                        StatusRing(status: paper.state.readingStatus, progress: model.progress(of: paper), size: 16)
                                            .padding(1)
                                            .background(Circle().fill(.background))
                                            .overlay(Circle().strokeBorder(Color.accentColor.opacity(model.selection.contains(paper.id) ? 0.55 : 0), lineWidth: 2.5).padding(-2))
                                    }
                                    .buttonStyle(.plain)
                                    .help(paper.meta.displayTitle)
                                }
                            }
                            .background(alignment: .center) {
                                Rectangle().fill(Color.primary.opacity(0.15)).frame(height: 1.5).padding(.horizontal, 8)
                            }
                            if let name = group.section?.name {
                                Text(name).font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 2)
    }
}

/// The «읽을 날·계획» button's label: its words and its symbol, or the
/// symbol alone where the head is narrow.
private struct PlanColumnsLabelStyle: LabelStyle {
    let words: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon
            if words { configuration.title }
        }
    }
}

/// What a shelf is called, for a board's header.
enum ShelfTitle {
    /// The symbol the sidebar gives the shelf.
    @MainActor static func symbol(of scope: LibraryModel.Scope) -> String {
        switch scope {
        case .all: "tray.full"
        case .papers: "text.document"
        case .books: "book"
        case .documents: "doc"
        case .folder: "folder"
        case .open: "rectangle.on.rectangle"
        case .notes: "text.quote"
        case let .knowledge(area): area.map { $0.isEmpty ? "tray" : "folder" } ?? "lightbulb"
        case .projects: "flag"
        case .graph: "point.3.connected.trianglepath.dotted"
        case .searchResults: "magnifyingglass"
        case .unread: "circle"
        case .reading: "circle.lefthalf.filled"
        case .read: "checkmark.circle"
        case .favorites: "star"
        case .needsReview: "exclamationmark.triangle"
        case .collection: "folder"
        case .tag: "tag"
        case .author: "person"
        case .plan: "point.topleft.down.to.point.bottomright.curvepath"
        case .thisWeek: "calendar"
        }
    }

    /// The colour the sidebar lights the shelf in.
    static func tint(of scope: LibraryModel.Scope) -> Color {
        switch scope {
        case .reading: .orange
        case .read: .green
        case .favorites: .yellow
        case .needsReview: .red
        default: .accentColor
        }
    }

    @MainActor static func of(_ scope: LibraryModel.Scope, in model: LibraryModel) -> String {
        switch scope {
        case .all: L("모두", "All")
        case .papers: L("논문", "Papers")
        case .books: L("책", "Books")
        case .documents: L("문서", "Documents")
        case let .folder(root): root.lastPathComponent
        case .open: L("열린 문서", "Open Documents")
        case .notes: L("문헌 노트", "Literature Notes")
        case let .knowledge(area): KnowledgeArea.title(area)
        case let .projects(id): id.flatMap { model.project($0)?.name } ?? L("프로젝트", "Projects")
        case .graph: L("그래프", "Graph")
        case .searchResults: L("찾은 것", "Search Results")
        case .unread: L("안 읽음", "Unread")
        case .reading: L("읽는 중", "Reading")
        case .read: L("읽음", "Read")
        case .favorites: L("즐겨찾기", "Favorites")
        case .needsReview: L("살펴볼 것", "Needs Review")
        case let .collection(id): model.collections.collections.first { $0.id == id }?.name ?? L("컬렉션", "Collection")
        case let .tag(id): model.manifest.tags.first { $0.id == id }?.name ?? L("태그", "Tag")
        case let .author(key): model.authorRanking.first { $0.key == key }?.name ?? L("저자", "Author")
        case let .plan(id): model.plan(id)?.name ?? L("계획", "Plan")
        case .thisWeek: L("이번 주", "This Week")
        }
    }
}

#endif
