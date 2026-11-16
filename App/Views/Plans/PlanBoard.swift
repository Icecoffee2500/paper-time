#if os(macOS)
import AppKit
import LibraryStore
import PaperCore
import SwiftUI

/// A column a board can show beside the title.
enum BoardColumn: String, CaseIterable, Identifiable, Hashable {
    case authors, venue, plan, day, progress, materials, tags, rating, notes, added, opened

    var id: String { rawValue }

    var title: String {
        switch self {
        case .authors: L("저자 · 해", "Author · Year")
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
        case .authors: 116
        case .venue: 90
        case .plan: 124
        case .day: 100
        case .progress: 86
        case .materials: 124
        case .tags: 110
        case .rating: 70
        case .notes: 46
        case .added: 76
        case .opened: 96
        }
    }
}

/// Which board is in front.
enum BoardKind: Equatable {
    case plan(UUID), week, shelf

    var key: String {
        switch self {
        case .plan: "plan"
        case .week: "week"
        case .shelf: "shelf"
        }
    }

    /// The columns the demo shows, in its order.
    var defaults: [BoardColumn] {
        switch self {
        case .plan: [.day, .progress, .materials, .tags]
        case .week: [.plan, .day, .materials]
        case .shelf: [.authors, .day, .plan, .materials]
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
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    @Environment(\.colorScheme) private var colorScheme

    enum Grouping: String { case section, week, status }

    @State private var grouping: Grouping = Grouping(rawValue: Boot.setting("PAPERTIME_PLAN_GROUP") ?? "") ?? .section
    @State private var sortColumn: BoardColumn?
    @State private var sortByTitle = false
    @State private var ascending = true
    @State private var hidden: [String: [String]] = PlanBoard.storedColumns()
    @State private var toast: BoardToast?
    @State private var showsSpread = false
    @State private var calendarStart: PlanDay?
    @State private var addText = ""
    @State private var adding = false

    private var kind: BoardKind {
        switch model.scope {
        case let .plan(id): .plan(id)
        case .thisWeek: .week
        default: .shelf
        }
    }

    private var view: LibraryModel.ShelfView { model.shelfView(for: model.scope) }

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
            } else {
                if case .plan = kind { viewbar }
                columnHeader
                if kind == .week, data.entries.isEmpty {
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
                    selection: $model.selection,
                    row: { entry, selected in row(entry, selected: selected) },
                    reorders: reorders,
                    drop: drop,
                    open: open
                )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .bottom) { toastView }
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
            HStack(alignment: .center, spacing: 12) {
                tile
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 19, weight: .semibold)).lineLimit(1)
                    Text(subtitle).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                .layoutPriority(1)
                Spacer(minLength: 8)
                actions
            }
            if case let .plan(id) = kind, let plan = model.plan(id) {
                stats(plan)
                PlanPath(model: model, plan: plan, scrolls: !staticRows)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 6)
    }

    private var tile: some View {
        Image(systemName: tileSymbol)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(Color.accentColor)
            .frame(width: 36, height: 36)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.accentColor.opacity(0.13)))
    }

    private var tileSymbol: String {
        switch kind {
        case .plan: "point.topleft.down.to.point.bottomright.curvepath"
        case .week: "calendar"
        case .shelf: "tray.full"
        }
    }

    private var title: String {
        switch model.scope {
        case let .plan(id): model.plan(id)?.name ?? L("계획", "Plan")
        case .thisWeek: L("이번 주", "This Week")
        default: ShelfTitle.of(model.scope, in: model)
        }
    }

    private var subtitle: String {
        switch kind {
        case let .plan(id):
            guard let plan = model.plan(id) else { return "" }
            let papers = plan.readingOrder.compactMap(model.paper)
            let read = papers.filter { $0.state.readingStatus == .read }.count
            let days = papers.compactMap(\.schedule).sorted()
            let span = days.first.map { PlanText.span($0, days.last!) } ?? L("날짜를 아직 안 정했어요", "No dates yet")
            return L("\(span) · \(papers.count)편 중 \(read)편 읽음", "\(span) · \(read) of \(papers.count) read")
        case .week:
            let monday = model.today.monday
            let papers = model.visiblePapers
            let plans = Set(papers.flatMap { model.plans(containing: $0.id).map(\.id) }).count
            let span = PlanText.span(monday, monday.adding(days: 6))
            return L("\(span) · 계획 \(plans)개에서 \(papers.count)편", "\(span) · \(PlanText.papers(papers.count)) from \(plans == 1 ? "1 plan" : "\(plans) plans")")
        case .shelf:
            let count = model.visiblePapers.count
            return L("논문 \(count)편 · 열 머리를 누르면 정렬돼요", "\(PlanText.papers(count)) · Click a column to sort")
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 8) {
            if case let .plan(id) = kind {
                Button {
                    showsSpread.toggle()
                } label: {
                    Label(L("고르게 나누기…", "Spread Out…"), systemImage: "calendar.badge.plus")
                }
                .buttonStyle(SoftButtonStyle())
                .popover(isPresented: $showsSpread, arrowEdge: .bottom) {
                    SpreadPicker(model: model, planID: id) { assignments in
                        showsSpread = false
                        let days = Dictionary(assignments.map { ($0.0, Optional($0.1)) }, uniquingKeysWith: { a, _ in a })
                        changeDays(days, say: L("\(days.count)편에 날짜를 정했어요.", "Gave \(PlanText.papers(days.count)) a day."))
                    }
                }
                Button {
                    let pushed = model.pushedAWeek(id)
                    guard !pushed.isEmpty else {
                        show(L("날짜를 정한 논문이 없어요.", "No paper here has a day yet."))
                        return
                    }
                    changeDays(pushed, say: L("남은 \(pushed.count)편을 한 주 뒤로 옮겼어요.", "Moved \(PlanText.papers(pushed.count)) a week later."))
                } label: {
                    Label(L("한 주 미루기", "Push a Week"), systemImage: "arrow.right")
                }
                .buttonStyle(SoftButtonStyle())
            }
            ShelfViewSwitch(
                view: Binding(get: { view }, set: { model.setShelfView($0, for: model.scope) }),
                choices: { if case .plan = kind { [.table, .calendar] } else { [.list, .table] } }()
            )
        }
        .labelStyle(.titleAndIcon)
    }

    private func stats(_ plan: ReadingPlan) -> some View {
        let papers = plan.readingOrder.compactMap(model.paper)
        let week = papers.filter { $0.schedule?.monday == model.today.monday }.count
        let behind = papers.filter(model.isBehind).count
        let none = papers.filter { $0.schedule == nil }.count
        return HStack(spacing: 6) {
            StatCapsule(text: L("이번 주 \(week)편", "This week \(week)"), color: .blue)
            if behind > 0 { StatCapsule(text: L("밀린 것 \(behind)편", "Overdue \(behind)"), color: .orange) }
            if none > 0 { StatCapsule(text: L("날짜 없음 \(none)편", "No date \(none)"), color: .gray) }
        }
    }

    // MARK: The bar over a plan's table

    private var viewbar: some View {
        HStack(spacing: 8) {
            Text(L("묶기", "Group By")).font(.system(size: 11.5)).foregroundStyle(.tertiary)
            HStack(spacing: 4) {
                chip(L("섹션", "Section"), .section)
                chip(L("주", "Week"), .week)
                chip(L("상태", "Status"), .status)
            }
            Spacer()
            if case let .plan(id) = kind {
                Button {
                    Task { await addSection(to: id) }
                } label: {
                    Label(L("섹션 더하기", "Add Section"), systemImage: "plus")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
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

    // MARK: Columns

    private var columns: [BoardColumn] {
        let off = Set(hidden[kind.key] ?? [])
        let shown = kind.defaults.filter { !off.contains($0.rawValue) }
        let extra = BoardColumn.allCases.filter { !kind.defaults.contains($0) && off.contains("+" + $0.rawValue) }
        return shown + extra
    }

    private func isShown(_ column: BoardColumn) -> Bool { columns.contains(column) }

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
            Color.clear.frame(width: 22, height: 1)
            headerLabel(L("제목", "Title"), column: nil)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(columns) { column in
                headerLabel(column.title, column: column)
                    .frame(width: column.width, alignment: .leading)
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
                Toggle(column.title, isOn: Binding(get: { isShown(column) }, set: { _ in toggle(column) }))
            }
            Divider()
            Button(L("기본으로 되돌리기", "Restore Defaults")) {
                hidden[kind.key] = nil
                PlanBoard.storeColumns(hidden)
            }
        }
        .help(L("열 머리를 오른쪽 클릭하면 보일 열을 고를 수 있어요", "Right-click a column to choose what shows"))
    }

    @ViewBuilder
    private func headerLabel(_ text: String, column: BoardColumn?) -> some View {
        if kind == .shelf, column != .materials, column != .tags {
            let current = column == nil ? sortByTitle : (sortColumn == column && !sortByTitle)
            Button {
                if current {
                    ascending.toggle()
                } else {
                    ascending = true
                    sortByTitle = column == nil
                    sortColumn = column
                }
            } label: {
                HStack(spacing: 3) {
                    Text(text).lineLimit(1)
                    if current { Text(ascending ? "↑" : "↓") }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            Text(text).lineLimit(1)
        }
    }

    // MARK: Rows

    private var reorders: Bool {
        if case .plan = kind { return grouping == .section }
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
                let papers = group.papers.compactMap(model.paper)
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
                let papers = weeks[monday]!.sorted { ($0.schedule ?? monday) < ($1.schedule ?? monday) }
                add("week:" + monday.text, BoardGroup(title: PlanText.week(monday, today: model.today), detail: readCount(papers)), papers)
            }
            if let none = weeks[nil], !none.isEmpty {
                add("week:none", BoardGroup(title: L("날짜 없음", "No Date"), detail: readCount(none)), none)
            }
        case .status:
            for status in [PaperState.ReadingStatus.reading, .unread, .read] {
                let papers = all.filter { $0.state.readingStatus == status }
                if !papers.isEmpty { add("status:" + status.rawValue, BoardGroup(title: status.label, detail: readCount(papers)), papers) }
            }
        }
        entries.append(.add)
        return (entries, groups)
    }

    private func weekRows() -> ([BoardEntry], [String: BoardGroup]) {
        var entries: [BoardEntry] = []
        var groups: [String: BoardGroup] = [:]
        let papers = model.visiblePapers
        let behind = papers.filter(model.isBehind)
        if !behind.isEmpty {
            groups["behind"] = BoardGroup(title: L("밀린 것", "Overdue"), detail: PlanText.papers(behind.count), behind: true)
            entries.append(.group("behind"))
            entries += behind.map { .paper($0.id) }
        }
        let rest = papers.filter { !model.isBehind($0) }
        let days = Dictionary(grouping: rest) { $0.schedule ?? model.today }
        for day in days.keys.sorted() {
            groups["day:" + day.text] = BoardGroup(title: PlanText.heading(day, today: model.today))
            entries.append(.group("day:" + day.text))
            entries += days[day]!.map { .paper($0.id) }
        }
        return (entries, groups)
    }

    private func sortedShelf() -> [LoadedPaper] {
        let papers = model.visiblePapers
        guard sortByTitle || sortColumn != nil else { return papers }
        func less(_ a: LoadedPaper, _ b: LoadedPaper) -> Bool {
            if sortByTitle { return a.meta.displayTitle.localizedCaseInsensitiveCompare(b.meta.displayTitle) == .orderedAscending }
            switch sortColumn {
            case .authors:
                let x = a.meta.csl.author.first?.sortingSurname ?? "zzz", y = b.meta.csl.author.first?.sortingSurname ?? "zzz"
                if x != y { return x.localizedCaseInsensitiveCompare(y) == .orderedAscending }
                return (a.meta.csl.year ?? 0) < (b.meta.csl.year ?? 0)
            case .venue: return (a.meta.csl.containerTitle ?? "~").localizedCaseInsensitiveCompare(b.meta.csl.containerTitle ?? "~") == .orderedAscending
            case .plan: return (model.plans(containing: a.id).first?.name ?? "~") < (model.plans(containing: b.id).first?.name ?? "~")
            case .day: return (a.schedule?.ordinal ?? Int.max) < (b.schedule?.ordinal ?? Int.max)
            case .progress: return model.progress(of: a) < model.progress(of: b)
            case .rating: return (a.state.rating ?? 0) < (b.state.rating ?? 0)
            case .notes: return model.notes.notes(forPaper: a.id).count < model.notes.notes(forPaper: b.id).count
            case .added: return a.meta.addedAt < b.meta.addedAt
            case .opened: return (a.state.lastOpenedAt ?? .distantPast) < (b.state.lastOpenedAt ?? .distantPast)
            default: return false
            }
        }
        let sorted = papers.sorted(by: less)
        return ascending ? sorted : sorted.reversed()
    }

    private func row(_ entry: BoardEntry, selected: Bool) -> AnyView {
        switch entry {
        case let .paper(id):
            guard let paper = model.paper(id) else { return AnyView(EmptyView()) }
            return AnyView(
                BoardRow(
                    paper: paper, model: model, columns: columns, selected: selected,
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
                Button(L("섹션 이름 바꾸기…", "Rename Section…")) { Task { await renameSection(section, in: planID) } }
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
        Button(L("열기", "Open")) { open(paper.id) }
        if case let .plan(planID) = kind, let plan = model.plan(planID) {
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
        } else if !model.plans.isEmpty {
            Menu(L("계획에 넣기", "Add to Plan")) {
                ForEach(model.plans) { plan in
                    Button(plan.name) {
                        let ids = Array(model.selection.contains(paper.id) ? model.selection : [paper.id])
                        Task { await model.addToPlan(plan.id, papers: ids) }
                    }
                }
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
        model.openFromBoard(id)
        if !app.showsReader { app.toggleReader() }
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

    private func addSection(to planID: UUID) async {
        guard let name = await Ask.text(
            title: L("새 섹션", "New Section"),
            message: L("계열이나 주제의 이름을 적어요.", "Name a line of work or a topic."),
            placeholder: L("예: 값을 낮춰 잡기", "e.g. Conservative Estimates")
        ) else { return }
        editPlan(planID, name: L("섹션 더하기", "Add Section")) { $0.addSection(named: name) }
    }

    private func renameSection(_ section: UUID, in planID: UUID) async {
        let current = model.plan(planID)?.sections.first { $0.id == section }?.name ?? ""
        guard let name = await Ask.text(title: L("섹션 이름 바꾸기", "Rename Section"), message: nil, placeholder: "", initial: current) else { return }
        editPlan(planID, name: L("섹션 이름 바꾸기", "Rename Section")) { $0.renameSection(section, to: name) }
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

/// One paper on a board, drawn like the demo's grid row.
struct BoardRow: View {
    let paper: LoadedPaper
    let model: LibraryModel
    let columns: [BoardColumn]
    let selected: Bool
    let cycle: () -> Void
    let pickDay: () -> Void
    let menu: () -> AnyView
    @State private var hovering = false

    var body: some View {
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
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(paper.meta.displayTitle)
            ForEach(columns) { column in
                cell(column).frame(width: column.width, alignment: .leading)
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
        case .venue:
            Text(paper.meta.csl.containerTitleShort ?? paper.meta.csl.containerTitle ?? "—")
                .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
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
        let year = paper.meta.csl.year.map { " · \($0)" } ?? ""
        return first.isEmpty ? (paper.meta.csl.year.map(String.init) ?? "—") : first + more + year
    }
}

/// A paper's materials as small tiles: its own address first.
struct MaterialChips: View {
    let paper: LoadedPaper
    let model: LibraryModel

    var body: some View {
        let kinds = (model.paperLink(of: paper) != nil ? [MaterialKind.paper] : []) + paper.links.map(\.kind)
        // Four fit; past four, three and a count of the rest.
        let shown = kinds.count > 4 ? 3 : kinds.count
        HStack(spacing: 4) {
            ForEach(Array(kinds.prefix(shown).enumerated()), id: \.offset) { _, kind in
                KindTile(kind: kind).help(kind.name)
            }
            if kinds.count > shown {
                Text("+\(kinds.count - shown)").font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(.tertiary).fixedSize()
            }
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

/// What a shelf is called, for a board's header.
enum ShelfTitle {
    @MainActor static func of(_ scope: LibraryModel.Scope, in model: LibraryModel) -> String {
        switch scope {
        case .all: L("모두", "All")
        case .papers: L("논문", "Papers")
        case .documents: L("문서", "Documents")
        case let .folder(root): root.lastPathComponent
        case .open: L("열린 문서", "Open Documents")
        case .notes: L("노트", "Notes")
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

/// A name asked for in a small window of its own — an alert with a field,
/// the way Finder asks for a folder's name.
@MainActor
enum Ask {
    static func text(title: String, message: String?, placeholder: String, initial: String = "",
                     confirm: String = L("확인", "OK")) async -> String? {
        let alert = NSAlert()
        alert.messageText = title
        if let message { alert.informativeText = message }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = placeholder
        field.stringValue = initial
        alert.accessoryView = field
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: L("취소", "Cancel"))
        alert.window.initialFirstResponder = field
        let answer: NSApplication.ModalResponse
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            answer = await alert.beginSheetModal(for: window)
        } else {
            answer = alert.runModal()
        }
        guard answer == .alertFirstButtonReturn else { return nil }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static func confirm(title: String, message: String, action: String) async -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: L("취소", "Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
        }
        return alert.runModal() == .alertFirstButtonReturn
    }
}
#endif
