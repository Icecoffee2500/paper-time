#if os(macOS)
import LibraryStore
import PaperCore
import SwiftUI
import UniformTypeIdentifiers

/// A project's step, dragged to another column of the board.
struct TodoTransfer: Codable, Transferable, Hashable {
    var project: UUID
    var todo: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .paperTimeTodo)
    }
}

extension UTType {
    static let paperTimeTodo = UTType(exportedAs: "com.imtaeheon.PaperTime.todo")
}

extension Project.Status {
    var label: String {
        switch self {
        case .active: L("진행 중", "Active")
        case .paused: L("멈춤", "Paused")
        case .done: L("끝남", "Done")
        }
    }
}

extension Project.Todo.State {
    var label: String {
        switch self {
        case .todo: L("할 일", "To Do")
        case .doing: L("하는 중", "Doing")
        case .done: L("끝", "Done")
        }
    }

    var tint: Color {
        switch self {
        case .todo: .secondary
        case .doing: .orange
        case .done: .green
        }
    }
}

/// Whether the page is drawn for `ImageRenderer` (`--papertime-project-render`),
/// which draws text fields, segmented pickers and drop targets as yellow
/// placeholders: those stand in as plain text there.
struct ForCameraKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var forCamera: Bool {
        get { self[ForCameraKey.self] }
        set { self[ForCameraKey.self] = newValue }
    }
}

extension View {
    /// A modifier only the live window gets — a drop target, mostly.
    @ViewBuilder
    func unlessCamera<V: View>(_ camera: Bool, _ apply: (Self) -> V) -> some View {
        if camera { self } else { apply(self) }
    }
}

enum ProjectText {
    /// «D-72», «D-day», «D+3» — the way a deadline is counted here.
    static func dday(_ days: Int) -> String {
        if days == 0 { return L("D-day", "Due today") }
        if days > 0 { return L("D-\(days)", "\(days)d left") }
        return L("D+\(-days)", "\(-days)d over")
    }
}

/// A project's progress, as the ring the papers wear.
struct ProjectRing: View {
    let progress: Double
    var size: CGFloat = 22
    var tint: Color = .accentColor

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.1), lineWidth: size > 30 ? 5 : 3)
            Circle()
                .trim(from: 0, to: max(0.001, progress))
                .stroke(tint, style: StrokeStyle(lineWidth: size > 30 ? 5 : 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if size > 30 {
                Text("\(Int((progress * 100).rounded()))%")
                    .font(.system(size: size * 0.24, weight: .bold))
                    .monospacedDigit()
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - The list

/// Every project, by status: the ones under way first, the finished ones
/// folded away.
struct ProjectList: View {
    let model: LibraryModel
    /// Pinned in a pane of its own (`Workspace`): a project pressed here goes
    /// on the page rather than taking the sidebar with it.
    var pinnedPick: ((UUID?) -> Void)? = nil
    /// The project the page shows, for a pinned list.
    var pinnedSelection: UUID? = nil
    @State private var asking = false
    @State private var showsDone = false

    private var selection: Binding<UUID?> {
        if let pinnedPick {
            return Binding(get: { pinnedSelection }, set: { pinnedPick($0) })
        }
        return Binding(
            get: { if case let .projects(id) = model.scope { id } else { nil } },
            set: { model.scope = .projects($0) }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            ShelfHeader(symbol: "flag", title: L("프로젝트", "Projects"),
                        subtitle: L("진행 중 \(model.projects.filter { $0.status == .active }.count)개",
                                    "\(model.projects.filter { $0.status == .active }.count) active")) {
                Button { asking = true } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help(L("새 프로젝트", "New Project"))
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 10)

            if model.projects.isEmpty {
                VStack(spacing: 12) {
                    Spacer(minLength: 20)
                    Image(systemName: "flag").font(.system(size: 28, weight: .light)).foregroundStyle(.tertiary)
                    Text(L("아직 프로젝트가 없어요", "No Projects Yet")).font(.system(size: 15, weight: .semibold))
                    Text(L("마감을 정하고, 이정표를 놓고, 할 일을 옮기며 끝까지 가요.",
                           "Set a deadline, place the milestones, and move the steps along to the end."))
                        .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .frame(maxWidth: 300)
                    Button(L("새 프로젝트…", "New Project…")) { asking = true }
                        .buttonStyle(SoftButtonStyle(prominent: true))
                    Spacer(minLength: 40)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 20)
            } else {
                List(selection: selection) {
                    ForEach([Project.Status.active, .paused], id: \.self) { status in
                        let rows = model.projects.filter { $0.status == status }
                        if !rows.isEmpty {
                            Section(status.label) {
                                ForEach(rows) { project in
                                    ProjectRow(project: project, today: model.today).tag(Optional(project.id))
                                        .contextMenu { menu(project) }
                                }
                            }
                        }
                    }
                    let done = model.projects.filter { $0.status == .done }
                    if !done.isEmpty {
                        Section(isExpanded: $showsDone) {
                            ForEach(done) { project in
                                ProjectRow(project: project, today: model.today).tag(Optional(project.id))
                                    .contextMenu { menu(project) }
                            }
                        } header: {
                            Text(L("끝남 \(done.count)개", "Done (\(done.count))"))
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .hiddenScrollers()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheet(isPresented: $asking) {
            ProjectNameSheet { name in
                Task {
                    guard let id = await model.createProject(named: name) else { return }
                    if let pinnedPick { pinnedPick(id) } else { model.scope = .projects(id) }
                }
            }
        }
    }

    @ViewBuilder
    private func menu(_ project: Project) -> some View {
        Picker(L("상태", "Status"), selection: Binding(
            get: { project.status },
            set: { status in Task { await model.editProject(project.id) { $0.status = status } } }
        )) {
            ForEach(Project.Status.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        Divider()
        Button(L("프로젝트 지우기", "Delete Project"), role: .destructive) {
            Task { await model.deleteProject(project.id) }
        }
    }
}

private struct ProjectRow: View {
    let project: Project
    let today: PlanDay

    var body: some View {
        HStack(spacing: 10) {
            ProjectRing(progress: project.progress, size: 20, tint: project.status == .done ? .green : .accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                if !project.goal.isEmpty {
                    Text(project.goal).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if let days = project.daysLeft(today: today), project.status != .done {
                Text(ProjectText.dday(days))
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(days < 0 ? Color.orange : days <= 14 ? Color.accentColor : .secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

/// A new project's name.
struct ProjectNameSheet: View {
    let onDone: (String) -> Void
    @State private var name = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField(L("프로젝트 이름", "Project Name"), text: $name).onSubmit(done)
            }
            .formStyle(.grouped)
            .navigationTitle(L("새 프로젝트", "New Project"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("취소", "Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("만들기", "Create"), action: done)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .frame(minWidth: 340, minHeight: 150)
    }

    private func done() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onDone(trimmed)
        dismiss()
    }
}

// MARK: - The page

/// One project, planned backwards from its deadline: the head (how far, how
/// long left), the milestones on a track, the steps as a board or along a
/// timeline, and what it draws on.
struct ProjectPage: View {
    let model: LibraryModel
    let openPaper: (UUID) -> Void
    /// Laid out without its scroll view, for `ImageRenderer`, which draws a
    /// scroll view empty (`--papertime-project-render`).
    var scrolls = true
    /// The view to draw, for a render — the settings are not touched.
    var forcedView: String? = nil
    /// The project shown when it is not the sidebar's — pinned in a pane, or
    /// put on the page from a pinned list (`Workspace`).
    var pinnedID: UUID? = nil
    @Environment(AppModel.self) private var app
    @Environment(\.forCamera) private var camera
    @AppStorage("projectView") private var viewRaw = "board"
    @State private var quickAdd = ""
    @State private var asking = false

    private var projectID: UUID? {
        if let pinnedID { return pinnedID }
        if case let .projects(id) = model.scope { return id ?? model.activeProjects.first?.id ?? model.projects.first?.id }
        return nil
    }

    var body: some View {
        if let id = projectID, let project = model.project(id) {
            if scrolls {
                ScrollView { page(project) }.hiddenScrollers()
            } else {
                page(project)
            }
        } else {
            empty
        }
    }

    private func page(_ project: Project) -> some View {
                VStack(alignment: .leading, spacing: 16) {
                    ProjectHead(model: model, project: project)
                    MilestoneTrack(model: model, project: project)
                    HStack(spacing: 10) {
                        if camera {
                            Text((forcedView ?? viewRaw) == "timeline" ? L("타임라인", "Timeline") : L("보드", "Board"))
                                .font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 12)
                                .frame(height: 24)
                                .background(Capsule().fill(Color.primary.opacity(0.07)))
                        } else {
                            Picker("", selection: $viewRaw) {
                                Text(L("보드", "Board")).tag("board")
                                Text(L("타임라인", "Timeline")).tag("timeline")
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .fixedSize()
                        }
                        addField(project)
                    }
                    if (forcedView ?? viewRaw) == "timeline" {
                        ProjectTimeline(model: model, project: project)
                    } else {
                        ProjectBoard(model: model, project: project, openPaper: openPaper)
                    }
                    ProjectMaterials(model: model, project: project, openPaper: openPaper)
                }
                .padding(20)
    }

    private var empty: some View {
            VStack(spacing: 12) {
                Image(systemName: "flag").font(.system(size: 30, weight: .light)).foregroundStyle(.tertiary)
                Text(L("프로젝트를 고르거나 새로 만들어요", "Choose a project, or make one")).font(.system(size: 15, weight: .semibold))
                Button(L("새 프로젝트…", "New Project…")) { asking = true }
                    .buttonStyle(SoftButtonStyle(prominent: true))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .sheet(isPresented: $asking) {
                ProjectNameSheet { name in
                    Task { if let made = await model.createProject(named: name) { model.scope = .projects(made) } }
                }
            }
    }

    /// One line in, one step out — with a day read off its end, the way the
    /// plans' date field reads «금요일», «12/3», «+1주».
    private func addField(_ project: Project) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.accentColor)
            if camera {
                Text(L("할 일 더하기 — «금요일», «12/3», «+1주»처럼 날짜도 적어요", "Add a step — a date like Fri, 12/3 or +1w at the end works"))
                    .font(.system(size: 13)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField(L("할 일 더하기 — «금요일», «12/3», «+1주»처럼 날짜도 적어요", "Add a step — a date like Fri, 12/3 or +1w at the end works"),
                          text: $quickAdd)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .onSubmit { add(to: project) }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: Corner.control, style: .continuous).fill(Color.accentColor.opacity(0.07)))
    }

    private func add(to project: Project) {
        let text = quickAdd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let parsed = ProjectPage.splitDay(text, today: model.today)
        quickAdd = ""
        let todo = Project.Todo(title: parsed.title, due: parsed.day)
        Task { await model.editProject(project.id) { $0.todos.append(todo) } }
    }

    /// The step's title and the day at its end, when the end reads as one.
    static func splitDay(_ text: String, today: PlanDay) -> (title: String, day: PlanDay?) {
        let words = text.split(separator: " ").map(String.init)
        for take in [2, 1] where words.count > take {
            let tail = words.suffix(take).joined(separator: " ")
            if let day = PlanDayParser.read(tail, today: today) {
                return (words.dropLast(take).joined(separator: " "), day)
            }
        }
        return (text, nil)
    }
}

/// The head: how far, what for, how long left — and what state it is in.
private struct ProjectHead: View {
    let model: LibraryModel
    let project: Project
    @State private var name = ""
    @State private var goal = ""
    @State private var pickingDeadline = false
    @FocusState private var field: Field?
    @Environment(\.forCamera) private var camera

    enum Field { case name, goal }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ProjectRing(progress: project.progress, size: 50, tint: project.status == .done ? .green : .accentColor)
            VStack(alignment: .leading, spacing: 3) {
                if camera {
                    Text(project.name).font(.system(size: 20, weight: .semibold))
                    Text(project.goal.isEmpty ? L("목표 한 줄 — 무엇을 끝내면 끝인가요?", "The goal in a line — what does done look like?") : project.goal)
                        .font(.system(size: 13))
                        .foregroundStyle(project.goal.isEmpty ? .tertiary : .secondary)
                } else {
                    TextField(L("프로젝트 이름", "Project name"), text: $name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 20, weight: .semibold))
                        .focused($field, equals: .name)
                        .onSubmit(commit)
                    TextField(L("목표 한 줄 — 무엇을 끝내면 끝인가요?", "The goal in a line — what does done look like?"), text: $goal)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .focused($field, equals: .goal)
                        .onSubmit(commit)
                }
            }
            // Clicking away keeps what was typed, the way a note does.
            .onChange(of: field) { old, _ in if old != nil { commit() } }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Button { pickingDeadline = true } label: {
                    if let days = project.daysLeft(today: model.today) {
                        Text(ProjectText.dday(days))
                            .font(.system(size: 22, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(days < 0 ? Color.orange : Color.primary)
                    } else {
                        Text(L("마감 정하기", "Set Deadline")).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.accentColor)
                    }
                }
                .buttonStyle(.plain)
                .popover(isPresented: $pickingDeadline, arrowEdge: .bottom) {
                    DayPicker(today: model.today, current: project.deadline) { day in
                        pickingDeadline = false
                        Task { await model.editProject(project.id) { $0.deadline = day } }
                    }
                }
                HStack(spacing: 6) {
                    if let deadline = project.deadline {
                        Text(L("마감 \(PlanText.long(deadline))", "Due \(PlanText.long(deadline))"))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Menu {
                        Picker(L("상태", "Status"), selection: Binding(
                            get: { project.status },
                            set: { status in Task { await model.editProject(project.id) { $0.status = status } } }
                        )) {
                            ForEach(Project.Status.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                    } label: {
                        Text(project.status.label)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(project.status == .active ? Color.accentColor : .secondary)
                            .padding(.horizontal, 8)
                            .frame(height: 20)
                            .background(Capsule().fill((project.status == .active ? Color.accentColor : .gray).opacity(0.13)))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
        }
        .onAppear(perform: load)
        .onChange(of: project.id) { load() }
        .onChange(of: project.name) { if field != .name, name != project.name { name = project.name } }
        .onChange(of: project.goal) { if field != .goal, goal != project.goal { goal = project.goal } }
    }

    private func load() {
        name = project.name
        goal = project.goal
    }

    private func commit() {
        let newName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let newGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty else { name = project.name; return }
        guard newName != project.name || newGoal != project.goal else { return }
        Task { await model.editProject(project.id) { $0.name = newName; $0.goal = newGoal } }
    }
}

/// The days a project spans on screen: from when it began (or today) to its
/// deadline (or eight weeks on), widened to hold every milestone.
private struct ProjectSpan {
    let start: PlanDay
    let end: PlanDay

    init(_ project: Project, today: PlanDay) {
        var first = min(PlanDay.today(now: project.createdAt), today)
        var last = project.deadline ?? today.adding(days: 56)
        for milestone in project.milestones {
            first = min(first, milestone.day)
            last = max(last, milestone.day)
        }
        for todo in project.todos {
            if let day = todo.start { first = min(first, day) }
            if let day = todo.due { last = max(last, day) }
        }
        if first.days(until: last) < 14 { last = first.adding(days: 14) }
        start = first
        end = last
    }

    var days: Int { max(1, start.days(until: end)) }

    func x(_ day: PlanDay, width: CGFloat) -> CGFloat {
        CGFloat(start.days(until: day)) / CGFloat(days) * width
    }

    func day(atX x: CGFloat, width: CGFloat) -> PlanDay {
        let offset = Int((x / max(1, width) * CGFloat(days)).rounded())
        return start.adding(days: min(max(offset, 0), days))
    }
}

/// The milestones on a track from the start to the deadline, today marked.
/// A milestone is dragged to another day; pressed, it is renamed, marked
/// reached, or taken away.
private struct MilestoneTrack: View {
    let model: LibraryModel
    let project: Project
    @State private var dragging: (id: UUID, day: PlanDay)?
    @State private var editing: UUID?

    var body: some View {
        let span = ProjectSpan(project, today: model.today)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("이정표", "Milestones")).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    let day = model.today.adding(days: max(1, model.today.days(until: span.end) / 2))
                    let milestone = Project.Milestone(title: L("새 이정표", "New milestone"), day: day)
                    Task { await model.editProject(project.id) { $0.milestones.append(milestone) } }
                    editing = milestone.id
                } label: {
                    Label(L("이정표", "Milestone"), systemImage: "plus").font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
            GeometryReader { proxy in
                let width = max(1, proxy.size.width - 28)
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04))
                    Capsule().fill(Color.primary.opacity(0.08)).frame(width: width, height: 2).offset(x: 14, y: 29)
                    Capsule().fill(Color.accentColor)
                        .frame(width: max(0, min(width, span.x(model.today, width: width))), height: 2)
                        .offset(x: 14, y: 29)
                    // Today.
                    Rectangle().fill(Color.accentColor.opacity(0.5)).frame(width: 2, height: 40)
                        .offset(x: 14 + span.x(model.today, width: width) - 1, y: 8)
                    Text(L("오늘", "Today")).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Color.accentColor)
                        .offset(x: 14 + span.x(model.today, width: width) + 4, y: 4)
                    if let deadline = project.deadline {
                        diamond(color: .orange, filled: true)
                            .offset(x: 14 + span.x(deadline, width: width) - 7, y: 22)
                        Text(L("마감", "Due")).font(.system(size: 10.5)).foregroundStyle(.secondary)
                            .fixedSize()
                            .offset(x: 14 + span.x(deadline, width: width) - 10, y: 40)
                    }
                    ForEach(project.milestones) { milestone in
                        let day = dragging?.id == milestone.id ? dragging!.day : milestone.day
                        let x = 14 + span.x(day, width: width)
                        VStack(spacing: 3) {
                            diamond(color: .accentColor, filled: milestone.done)
                            Text(milestone.title).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                        }
                        .offset(x: x - 7, y: 22)
                        .gesture(
                            DragGesture(minimumDistance: 2)
                                .onChanged { value in
                                    dragging = (milestone.id, span.day(atX: x - 14 + value.translation.width, width: width))
                                }
                                .onEnded { _ in
                                    guard let moved = dragging else { return }
                                    dragging = nil
                                    Task { await model.editProject(project.id) { project in
                                        if let index = project.milestones.firstIndex(where: { $0.id == moved.id }) {
                                            project.milestones[index].day = moved.day
                                        }
                                    } }
                                }
                        )
                        .onTapGesture { editing = milestone.id }
                        .popover(isPresented: Binding(get: { editing == milestone.id }, set: { if !$0 { editing = nil } })) {
                            MilestoneEditor(model: model, projectID: project.id, milestone: milestone)
                        }
                        .help(L("\(milestone.title) · \(PlanText.long(milestone.day)) — 끌어서 날짜를 바꿔요", "\(milestone.title) · \(PlanText.long(milestone.day)) — drag to change its day"))
                    }
                }
            }
            .frame(height: 64)
        }
    }

    private func diamond(color: Color, filled: Bool) -> some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(filled ? color : Color(nsColor: .windowBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(color, lineWidth: 2))
            .frame(width: 13, height: 13)
            .rotationEffect(.degrees(45))
            .frame(width: 14, height: 14)
    }
}

private struct MilestoneEditor: View {
    let model: LibraryModel
    let projectID: UUID
    let milestone: Project.Milestone
    @State private var title = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(L("이정표 이름", "Milestone name"), text: $title)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            Toggle(L("다다랐어요", "Reached"), isOn: Binding(
                get: { milestone.done },
                set: { done in edit { $0.done = done } }
            ))
            Text(L("날짜: \(PlanText.long(milestone.day)) — 트랙에서 끌어 바꿔요", "\(PlanText.long(milestone.day)) — drag it on the track to change"))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(L("지우기", "Delete"), role: .destructive) {
                    let id = milestone.id
                    Task { await model.editProject(projectID) { $0.milestones.removeAll { $0.id == id } } }
                }
                Spacer()
                Button(L("저장", "Save"), action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 260)
        .onAppear { title = milestone.title }
    }

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        edit { $0.title = trimmed }
    }

    private func edit(_ change: @escaping @Sendable (inout Project.Milestone) -> Void) {
        let id = milestone.id
        Task { await model.editProject(projectID) { project in
            if let index = project.milestones.firstIndex(where: { $0.id == id }) { change(&project.milestones[index]) }
        } }
    }
}

// MARK: - The board

/// The steps in three columns. A card is dragged to another column; a paper
/// dropped on a card is that step's.
private struct ProjectBoard: View {
    let model: LibraryModel
    let project: Project
    let openPaper: (UUID) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(Project.Todo.State.allCases, id: \.self) { state in
                BoardColumnView(model: model, project: project, state: state, openPaper: openPaper)
            }
        }
    }
}

private struct BoardColumnView: View {
    let model: LibraryModel
    let project: Project
    let state: Project.Todo.State
    let openPaper: (UUID) -> Void
    @State private var targeted = false
    @Environment(\.forCamera) private var camera

    var body: some View {
        let todos = project.todos(in: state)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(state.tint).frame(width: 7, height: 7)
                Text(state.label).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Text("\(todos.count)").font(.system(size: 11.5)).monospacedDigit().foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 4)
            ForEach(todos) { todo in
                TodoCard(model: model, project: project, todo: todo, openPaper: openPaper)
                    .draggable(TodoTransfer(project: project.id, todo: todo.id))
            }
            if todos.isEmpty {
                Text(L("여기로 끌어와요", "Drag here"))
                    .font(.system(size: 11.5)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: Corner.popover, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Corner.popover, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(targeted ? 0.6 : 0), lineWidth: 2)
        )
        .unlessCamera(camera) {
            $0.dropDestination(for: TodoTransfer.self) { items, _ in
                guard let item = items.first, item.project == project.id else { return false }
                let target = state
                Task { await model.editProject(project.id) { $0.move(item.todo, to: target) } }
                return true
            } isTargeted: { targeted = $0 }
        }
    }
}

private struct TodoCard: View {
    let model: LibraryModel
    let project: Project
    let todo: Project.Todo
    let openPaper: (UUID) -> Void
    @State private var editing = false
    @State private var targeted = false
    @Environment(\.forCamera) private var camera

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(todo.title)
                .font(.system(size: 13, weight: .medium))
                .strikethrough(todo.state == .done, color: .secondary)
                .foregroundStyle(todo.state == .done ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
            let chips = chipRow
            if !chips.isEmpty {
                FlowChips(items: chips)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.accentColor.opacity(targeted ? 0.7 : 0), lineWidth: 2))
        .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
        .contentShape(Rectangle())
        .onTapGesture { editing = true }
        .popover(isPresented: $editing, arrowEdge: .trailing) {
            TodoEditor(model: model, projectID: project.id, todo: todo, openPaper: openPaper)
        }
        .unlessCamera(camera) {
            $0.dropDestination(for: PaperTransfer.self) { items, _ in
                let ids = items.flatMap { model.draggedPapers(startingAt: $0.id) }
                guard !ids.isEmpty else { return false }
                Task { await model.addToProject(project.id, papers: ids, todo: todo.id) }
                return true
            } isTargeted: { targeted = $0 }
        }
        .contextMenu {
            ForEach(Project.Todo.State.allCases, id: \.self) { state in
                Button(state.label) {
                    let id = todo.id
                    Task { await model.editProject(project.id) { $0.move(id, to: state) } }
                }
                .disabled(todo.state == state)
            }
            Divider()
            Button(L("지우기", "Delete"), role: .destructive) {
                let id = todo.id
                Task { await model.editProject(project.id) { $0.todos.removeAll { $0.id == id } } }
            }
        }
    }

    private var chipRow: [FlowChips.Item] {
        var items: [FlowChips.Item] = []
        if let due = todo.due {
            let late = todo.state != .done && due < model.today
            items.append(.init(text: PlanText.short(due), symbol: "calendar", tint: late ? .orange : .secondary))
        }
        for id in todo.papers.prefix(2) {
            if let paper = model.paper(id) {
                items.append(.init(text: paper.meta.displayAuthors.isEmpty ? paper.meta.displayTitle : paper.meta.displayAuthors,
                                   symbol: "text.document", tint: .accentColor))
            }
        }
        if todo.papers.count > 2 { items.append(.init(text: "+\(todo.papers.count - 2)", symbol: nil, tint: .accentColor)) }
        if !todo.notes.isEmpty { items.append(.init(text: "\(todo.notes.count)", symbol: "note.text", tint: .green)) }
        return items
    }
}

/// Small chips, in rows as wide as they are given.
struct FlowChips: View {
    struct Item: Hashable {
        let text: String
        let symbol: String?
        let tint: Color
    }
    let items: [Item]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items, id: \.self) { item in
                HStack(spacing: 3) {
                    if let symbol = item.symbol { Image(systemName: symbol).font(.system(size: 9)) }
                    Text(item.text).lineLimit(1)
                }
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(item.tint)
                .padding(.horizontal, 6)
                .frame(height: 18)
                .background(Capsule().fill(item.tint.opacity(0.12)))
            }
        }
    }
}

private struct TodoEditor: View {
    let model: LibraryModel
    let projectID: UUID
    let todo: Project.Todo
    let openPaper: (UUID) -> Void
    @State private var title = ""
    @State private var memo = ""
    @State private var picking: Which?

    enum Which: String, Identifiable { case start, due; var id: String { rawValue } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(L("할 일", "Step"), text: $title)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 14, weight: .medium))
                .onSubmit(save)
            Picker(L("상태", "State"), selection: Binding(
                get: { todo.state },
                set: { state in
                    let id = todo.id
                    Task { await model.editProject(projectID) { $0.move(id, to: state) } }
                }
            )) {
                ForEach(Project.Todo.State.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            HStack(spacing: 8) {
                dayButton(L("시작", "Start"), todo.start, .start)
                dayButton(L("마감", "Due"), todo.due, .due)
            }
            Text(L("메모", "Memo")).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $memo)
                .font(.system(size: 12.5))
                .frame(height: 70)
                .scrollContentBackground(.hidden)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            if !todo.papers.isEmpty {
                Text(L("논문", "Papers")).font(.caption).foregroundStyle(.secondary)
                ForEach(todo.papers, id: \.self) { id in
                    if let paper = model.paper(id) {
                        HStack {
                            Button(paper.meta.displayTitle) { openPaper(id) }
                                .buttonStyle(.plain)
                                .lineLimit(1)
                                .font(.system(size: 12))
                            Spacer()
                            Button {
                                let todoID = todo.id
                                Task { await model.editProject(projectID) { project in
                                    if let index = project.todos.firstIndex(where: { $0.id == todoID }) {
                                        project.todos[index].papers.removeAll { $0 == id }
                                    }
                                } }
                            } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Text(L("논문을 카드 위로 끌어다 놓으면 이 할 일에 붙어요.", "Drop a paper on the card to attach it to this step."))
                    .font(.caption).foregroundStyle(.tertiary)
            }
            HStack {
                Spacer()
                Button(L("저장", "Save"), action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 300)
        .onAppear {
            title = todo.title
            memo = todo.memo
        }
        .popover(item: $picking) { which in
            DayPicker(today: model.today, current: which == .start ? todo.start : todo.due) { day in
                picking = nil
                let id = todo.id
                Task { await model.editProject(projectID) { project in
                    if let index = project.todos.firstIndex(where: { $0.id == id }) {
                        if which == .start { project.todos[index].start = day } else { project.todos[index].due = day }
                    }
                } }
            }
        }
    }

    private func dayButton(_ label: String, _ day: PlanDay?, _ which: Which) -> some View {
        Button { picking = which } label: {
            HStack(spacing: 4) {
                Text(label).foregroundStyle(.secondary)
                Text(day.map(PlanText.short) ?? L("정하기", "Set"))
            }
            .font(.system(size: 12))
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
        }
        .buttonStyle(.plain)
    }

    private func save() {
        let newTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newTitle.isEmpty else { return }
        let newMemo = memo
        let id = todo.id
        Task { await model.editProject(projectID) { project in
            if let index = project.todos.firstIndex(where: { $0.id == id }) {
                project.todos[index].title = newTitle
                project.todos[index].memo = newMemo
            }
        } }
    }
}

// MARK: - The timeline

/// The steps along the project's days, each a bar from its start to its due
/// day. A bar is dragged to move both.
private struct ProjectTimeline: View {
    let model: LibraryModel
    let project: Project
    @State private var dragging: (id: UUID, shift: Int)?
    /// A bar's end being pulled: only its due day moves.
    @State private var stretching: (id: UUID, shift: Int)?

    var body: some View {
        let span = ProjectSpan(project, today: model.today)
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                let width = max(1, proxy.size.width - 150)
                ZStack(alignment: .topLeading) {
                    // Weeks.
                    ForEach(Array(stride(from: 0, through: span.days, by: 7)), id: \.self) { offset in
                        let x = 150 + CGFloat(offset) / CGFloat(span.days) * width
                        Rectangle().fill(Color.primary.opacity(0.05)).frame(width: 1)
                            .offset(x: x)
                        Text(PlanText.short(span.start.adding(days: offset)))
                            .font(.system(size: 9.5)).foregroundStyle(.tertiary).fixedSize()
                            .offset(x: x + 3, y: 0)
                    }
                    // The milestones, faintly through the rows, and the deadline.
                    ForEach(project.milestones) { milestone in
                        let x = 150 + span.x(milestone.day, width: width)
                        Rectangle().fill(Color.accentColor.opacity(0.18)).frame(width: 1)
                            .offset(x: x)
                        Image(systemName: milestone.done ? "diamond.fill" : "diamond")
                            .font(.system(size: 8, weight: .bold)).foregroundStyle(Color.accentColor)
                            .offset(x: x - 4, y: 12)
                            .help(milestone.title)
                    }
                    if let deadline = project.deadline {
                        Rectangle().fill(Color.orange.opacity(0.7)).frame(width: 2)
                            .offset(x: 150 + span.x(deadline, width: width))
                    }
                    Rectangle().fill(Color.accentColor.opacity(0.5)).frame(width: 2)
                        .offset(x: 150 + span.x(model.today, width: width))
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(project.todos) { todo in
                            row(todo, span: span, width: width)
                        }
                        if project.todos.isEmpty {
                            Text(L("할 일을 더하면 여기 날짜를 따라 놓여요", "Steps you add are laid out here by their days"))
                                .font(.system(size: 12)).foregroundStyle(.tertiary).padding(.leading, 150)
                        }
                    }
                    .padding(.top, 26)
                }
            }
            .frame(height: CGFloat(max(1, project.todos.count)) * 30 + 38)
        }
    }

    private func row(_ todo: Project.Todo, span: ProjectSpan, width: CGFloat) -> some View {
        let shift = dragging?.id == todo.id ? dragging!.shift : 0
        let stretch = stretching?.id == todo.id ? stretching!.shift : 0
        let due = todo.due ?? todo.start?.adding(days: 7) ?? model.today.adding(days: 7)
        let start = todo.start ?? due.adding(days: -7)
        let from = span.x(start.adding(days: shift), width: width)
        let to = max(from, span.x(due.adding(days: shift + stretch), width: width))
        return HStack(spacing: 0) {
            Text(todo.title).font(.system(size: 12)).lineLimit(1).frame(width: 140, alignment: .leading)
            Spacer().frame(width: 10)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.03)).frame(width: width, height: 24)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(todo.state.tint.opacity(todo.state == .todo ? 0.15 : 0.22))
                    .overlay(alignment: .leading) {
                        Text(PlanText.short(due.adding(days: shift + stretch))).font(.system(size: 9.5)).foregroundStyle(.secondary)
                            .padding(.leading, 6).lineLimit(1)
                    }
                    .overlay(alignment: .trailing) {
                        // The end, to pull the due day by.
                        Rectangle().fill(Color.clear).frame(width: 8)
                            .contentShape(Rectangle())
                            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                            .gesture(
                                DragGesture(minimumDistance: 1)
                                    .onChanged { value in
                                        stretching = (todo.id, Int((value.translation.width / width * CGFloat(span.days)).rounded()))
                                    }
                                    .onEnded { _ in
                                        guard let pulled = stretching, pulled.shift != 0 else { stretching = nil; return }
                                        stretching = nil
                                        let id = todo.id, startDay = start
                                        let dueDay = max(start, due.adding(days: pulled.shift))
                                        Task { await model.editProject(project.id) { project in
                                            if let index = project.todos.firstIndex(where: { $0.id == id }) {
                                                project.todos[index].start = startDay
                                                project.todos[index].due = dueDay
                                            }
                                        } }
                                    }
                            )
                    }
                    .frame(width: max(14, to - from), height: 20)
                    .offset(x: from)
                    .gesture(
                        DragGesture(minimumDistance: 2)
                            .onChanged { value in
                                dragging = (todo.id, Int((value.translation.width / width * CGFloat(span.days)).rounded()))
                            }
                            .onEnded { _ in
                                guard let moved = dragging, moved.shift != 0 else { dragging = nil; return }
                                dragging = nil
                                let id = todo.id, startDay = start, dueDay = due
                                Task { await model.editProject(project.id) { project in
                                    if let index = project.todos.firstIndex(where: { $0.id == id }) {
                                        project.todos[index].start = startDay.adding(days: moved.shift)
                                        project.todos[index].due = dueDay.adding(days: moved.shift)
                                    }
                                } }
                            }
                    )
                    .help(L("끌어서 날짜를 옮기고, 끝을 끌어 마감을 바꿔요", "Drag to move its days; drag its end to change when it is due"))
            }
        }
        .frame(height: 24)
    }
}

// MARK: - What it draws on

/// The papers, notes and plans a project draws on — dropped here, from a
/// pane of papers beside it.
private struct ProjectMaterials: View {
    let model: LibraryModel
    let project: Project
    let openPaper: (UUID) -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.forCamera) private var camera
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("자료", "Materials")).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    if model.plans.isEmpty { Text(L("계획이 없어요", "No Plans")) }
                    ForEach(model.plans) { plan in
                        Button(plan.name) {
                            let id = plan.id
                            Task { await model.editProject(project.id) { if !$0.plans.contains(id) { $0.plans.append(id) } } }
                        }
                        .disabled(project.plans.contains(plan.id))
                    }
                } label: {
                    Label(L("계획 붙이기", "Attach Plan"), systemImage: "plus").font(.system(size: 11.5, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                if !app.panes.contains(where: { $0.content == .shelf("papers") }) {
                    Button {
                        app.addPane(.shelf("papers"))
                    } label: {
                        Label(L("논문 칸 열기", "Open Papers Pane"), systemImage: "rectangle.split.3x1").font(.system(size: 11.5, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .help(L("옆에 논문 칸을 열어 여기로 끌어와요", "Open the papers beside this, to drag them in"))
                }
            }
            if project.papers.isEmpty && project.notes.isEmpty && project.plans.isEmpty {
                Text(L("논문과 노트를 여기로 끌어다 놓아요. 옆에 논문 칸을 열고 끌어오면 돼요.",
                       "Drop papers and notes here — open a Papers pane beside this one and drag them in."))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.accentColor)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Corner.popover, style: .continuous).fill(Color.accentColor.opacity(0.07)))
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(project.plans, id: \.self) { id in
                        if let plan = model.plan(id) {
                            materialRow(symbol: "point.topleft.down.to.point.bottomright.curvepath", tint: .indigo, title: plan.name,
                                        detail: L("읽기 계획", "Reading plan")) {
                                model.scope = .plan(id)
                            } remove: {
                                Task { await model.editProject(project.id) { $0.plans.removeAll { $0 == id } } }
                            }
                        }
                    }
                    ForEach(project.papers, id: \.self) { id in
                        if let paper = model.paper(id) {
                            materialRow(symbol: paper.meta.shelfKind.symbolName, tint: paper.meta.shelfKind.tint, title: paper.meta.displayTitle,
                                        detail: [paper.meta.displayAuthors, paper.meta.csl.year.map(String.init)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")) {
                                openPaper(id)
                            } remove: {
                                Task { await model.editProject(project.id) { $0.papers.removeAll { $0 == id } } }
                            }
                        }
                    }
                    ForEach(project.notes, id: \.self) { id in
                        if let note = model.notes.note(id) {
                            materialRow(symbol: "note.text", tint: .green, title: note.displayTitle,
                                        detail: note.paperID != nil ? L("문헌 노트", "Literature note") : KnowledgeArea.title(note.area)) {
                                app.openNotePane(id)
                            } remove: {
                                Task { await model.editProject(project.id) { $0.notes.removeAll { $0 == id } } }
                            }
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: Corner.popover, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(targeted ? 0.6 : 0), lineWidth: 2)
        )
        // One target for both kinds: two `dropDestination`s on one view
        // leave only the outer one listening.
        .unlessCamera(camera) {
            $0.onDrop(of: [.paperTimePaper, .paperTimeNote], isTargeted: $targeted) { providers in
                accept(providers)
            }
        }
    }

    private func accept(_ providers: [NSItemProvider]) -> Bool {
        let projectID = project.id
        let model = model
        var taken = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.paperTimePaper.identifier) {
                taken = true
                _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.paperTimePaper.identifier) { data, _ in
                    guard let data, let item = try? JSONDecoder().decode(PaperTransfer.self, from: data) else { return }
                    Task { @MainActor in
                        let ids = model.draggedPapers(startingAt: item.id)
                        if !ids.isEmpty { await model.addToProject(projectID, papers: ids) }
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.paperTimeNote.identifier) {
                taken = true
                _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.paperTimeNote.identifier) { data, _ in
                    guard let data, let item = try? JSONDecoder().decode(NoteTransfer.self, from: data) else { return }
                    Task { @MainActor in await model.editProject(projectID) { $0.add(notes: [item.id]) } }
                }
            }
        }
        return taken
    }

    private func materialRow(symbol: String, tint: Color, title: String, detail: String, open: @escaping () -> Void, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(tint.opacity(0.12)))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                if !detail.isEmpty { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: open)
        .contextMenu {
            Button(L("열기", "Open"), action: open)
            Button(L("프로젝트에서 빼기", "Remove from Project"), role: .destructive, action: remove)
        }
    }
}
#endif

#if os(macOS)
extension AppModel {
    /// `--papertime-project-render=<folder>` (see `AppModel`).
    @MainActor
    func renderProject(to folder: String, model: LibraryModel) {
        let directory = URL(fileURLWithPath: folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for view in ["board", "timeline"] {
            for dark in [false, true] {
                let page = ProjectPage(model: model, openPaper: { _ in }, scrolls: false, forcedView: view)
                    .frame(width: 860)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(self)
                    .environment(\.forCamera, true)
                    .environment(\.colorScheme, dark ? .dark : .light)
                let renderer = ImageRenderer(content: page)
                renderer.scale = 2
                guard let image = renderer.cgImage,
                      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { continue }
                let url = directory.appending(path: "project-\(view)\(dark ? "-dark" : "").png")
                try? png.write(to: url)
                FileHandle.standardError.write(Data("project render: wrote \(url.path) \(image.width)×\(image.height)\n".utf8))
            }
        }
    }
}
#endif
