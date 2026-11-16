#if os(macOS)
import AppKit
import LibraryStore
import PaperCore
import SwiftUI

/// What a menu, a row or a button has asked of the plans, held where it
/// outlives them.
///
/// A context menu is torn down the moment it is clicked, so a sheet it starts
/// has to be presented by something that stays — the window, reading this.
/// The first plan dialogs were alerts raised from inside the menu's own
/// action, and «Make a Plan» on a collection opened and closed in the same
/// moment (2026-11-16). `AttachRequest` is the same answer to the same thing.
@Observable
public final class PlanRequest {
    public var sheet: PlanSheet?
    public var prompt: PlanPrompt?
    public var deleting: UUID?
    /// A sentence for the board to say once it is showing — after a plan was
    /// made with its days, say.
    public var notice: String?
    public init() {}
}

public enum PlanSheet: Identifiable, Equatable {
    /// A new plan: its name, and the papers already chosen.
    case new(name: String, papers: [UUID])
    /// More papers for a plan that is there.
    case add(UUID)

    public var id: String {
        switch self {
        case .new: "new"
        case let .add(id): "add:" + id.uuidString
        }
    }
}

public enum PlanPrompt: Identifiable, Equatable {
    case renamePlan(UUID)
    case newSection(UUID)
    case renameSection(plan: UUID, section: UUID)
    case renameMaterial(paper: UUID, link: UUID)

    public var id: String {
        switch self {
        case let .renamePlan(id): "plan:" + id.uuidString
        case let .newSection(id): "section+:" + id.uuidString
        case let .renameSection(plan, section): "section:" + plan.uuidString + section.uuidString
        case let .renameMaterial(paper, link): "link:" + paper.uuidString + link.uuidString
        }
    }
}

/// The sheets, the prompts and the delete question, hung on the window.
struct PlanPresentations: ViewModifier {
    let model: LibraryModel
    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        let planning = app.planning
        content
            .sheet(item: Binding(get: { planning.sheet }, set: { planning.sheet = $0 })) { sheet in
                switch sheet {
                case let .new(name, papers):
                    NewPlanSheet(model: model, name: name, chosen: papers) { planning.sheet = nil }
                        .environment(app)
                case let .add(id):
                    AddPapersSheet(model: model, planID: id) { planning.sheet = nil }
                        .environment(app)
                }
            }
            .sheet(item: Binding(get: { planning.prompt }, set: { planning.prompt = $0 })) { prompt in
                PlanPromptSheet(model: model, prompt: prompt) { planning.prompt = nil }
            }
            .alert(
                deletingTitle,
                isPresented: Binding(get: { planning.deleting != nil }, set: { if !$0 { planning.deleting = nil } })
            ) {
                Button(L("지우기", "Delete"), role: .destructive) {
                    if let id = planning.deleting { Task { await model.deletePlan(id) } }
                    planning.deleting = nil
                }
                Button(L("취소", "Cancel"), role: .cancel) { planning.deleting = nil }
            } message: {
                Text(L("논문은 그대로 있어요. 계획 파일은 휴지통으로 가요.", "The papers stay. The plan’s file goes to the Trash."))
            }
    }

    private var deletingTitle: String {
        let name = app.planning.deleting.flatMap { model.plan($0)?.name } ?? ""
        return L("‘\(name)’ 계획을 지울까요?", "Delete the plan “\(name)”?")
    }
}

// MARK: - Choosing papers

/// Every paper in the library, to tick: the chosen ones first, in the order
/// they stood when the sheet opened — nothing jumps under the pointer while
/// it is being ticked.
struct PaperPicker: View {
    let model: LibraryModel
    @Binding var chosen: [UUID]
    /// Papers already in the plan: shown ticked, not to be unticked.
    var locked: Set<UUID> = []
    /// Off only for `ImageRenderer`, which draws a scroll view empty.
    var scrolls = true

    @State private var query = ""
    @State private var chosenOnly = false
    @State private var order: [UUID] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                    TextField(L("제목·저자로 찾기", "Search by title or author"), text: $query)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Capsule().fill(Color.primary.opacity(0.05)))
                Button {
                    chosenOnly.toggle()
                } label: {
                    Text(L("고른 것만", "Chosen only"))
                        .font(.system(size: 11.5, weight: chosenOnly ? .semibold : .regular))
                        .foregroundStyle(chosenOnly ? Color.accentColor : .secondary)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(Capsule().fill(chosenOnly ? Color.accentColor.opacity(0.13) : Color.primary.opacity(0.05)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Group {
                if scrolls { ScrollView { rows } } else { rows.frame(maxHeight: .infinity, alignment: .top).clipped() }
            }
            .frame(minHeight: 240, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.03)))
        }
        .onAppear { if order.isEmpty { order = Self.order(model: model, chosen: chosen, locked: locked) } }
    }

    private var rows: some View {
        LazyVStack(spacing: 1) {
            ForEach(scrolls ? shown : Array(shown.prefix(7)), id: \.self) { id in
                if let paper = model.paper(id) { row(paper) }
            }
            if shown.isEmpty {
                Text(query.isEmpty ? L("고른 논문이 없어요", "Nothing chosen yet") : L("맞는 논문이 없어요", "No paper matches"))
                    .font(.system(size: 12.5))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 40)
            }
        }
        .padding(4)
    }

    /// The chosen first, in the order they were chosen, then what is already
    /// in the plan, then the rest by title — fixed when the sheet opens.
    static func order(model: LibraryModel, chosen: [UUID], locked: Set<UUID>) -> [UUID] {
        let all = model.papers.filter { $0.meta.parentID == nil }
            .sorted { $0.meta.displayTitle.localizedCaseInsensitiveCompare($1.meta.displayTitle) == .orderedAscending }
            .map(\.id)
        let first = Set(chosen).union(locked)
        return chosen.filter { all.contains($0) } + all.filter { locked.contains($0) && !chosen.contains($0) }
            + all.filter { !first.contains($0) }
    }

    private var shown: [UUID] {
        var ids = order
        if chosenOnly { ids = ids.filter { chosen.contains($0) || locked.contains($0) } }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return ids }
        let folded = TextNormalization.foldedTitle(text)
        return ids.filter { id in model.paper(id).map { LibraryModel.matches(folded: folded, paper: $0) } ?? false }
    }

    private func row(_ paper: LoadedPaper) -> some View {
        let isLocked = locked.contains(paper.id)
        let isOn = isLocked || chosen.contains(paper.id)
        return Button {
            guard !isLocked else { return }
            if let index = chosen.firstIndex(of: paper.id) { chosen.remove(at: index) } else { chosen.append(paper.id) }
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle().strokeBorder(isOn ? Color.clear : Color.secondary.opacity(0.5), lineWidth: 1.5)
                    if isOn {
                        Circle().fill(isLocked ? Color.secondary.opacity(0.45) : Color.accentColor)
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                    }
                }
                .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(paper.meta.displayTitle).font(.system(size: 13)).lineLimit(1)
                    let line = byline(paper)
                    if !line.isEmpty {
                        Text(line).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if isLocked {
                    Text(L("이미 있어요", "Already in")).font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: Corner.row, style: .continuous)
                .fill(isOn && !isLocked ? Color.accentColor.opacity(0.08) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func byline(_ paper: LoadedPaper) -> String {
        let first = paper.meta.csl.author.first?.family ?? paper.meta.csl.author.first?.displayName ?? ""
        let more = paper.meta.csl.author.count > 1 ? L(" 외", " et al.") : ""
        let year = paper.meta.csl.year.map(String.init) ?? ""
        return [first.isEmpty ? "" : first + more, year].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// The weekdays, how many a day and from when — Spread Out's controls, used
/// by its popover and by the New Plan sheet.
struct SpreadControls: View {
    @Binding var weekdays: Set<Int>
    @Binding var perDay: Int
    @Binding var nextWeek: Bool
    let preview: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            row(L("요일", "Days")) {
                HStack(spacing: 3) {
                    ForEach([0, 1, 2, 3, 4, 5, 6], id: \.self) { day in
                        let on = weekdays.contains(day)
                        Button {
                            if on { weekdays.remove(day) } else { weekdays.insert(day) }
                        } label: {
                            Text(L(PlanText.koWeekdays[day], String(PlanText.enWeekdays[day].prefix(2))))
                                .font(.system(size: 11.5, weight: on ? .semibold : .regular))
                                .foregroundStyle(on ? Color.white : .secondary)
                                .frame(width: 25, height: 25)
                                .background(Circle().fill(on ? Color.accentColor : Color.primary.opacity(0.06)))
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            row(L("하루에", "Per day")) {
                HStack(spacing: 8) {
                    stepper("−", enabled: perDay > 1) { perDay -= 1 }
                    Text(PlanText.papers(perDay)).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                        .frame(minWidth: 48)
                    stepper("+", enabled: perDay < 3) { perDay += 1 }
                }
            }
            row(L("시작", "Start")) {
                ShelfSwitchButtons(
                    choices: [(false, L("오늘부터", "Today")), (true, L("다음 주부터", "Next Week"))],
                    selection: $nextWeek
                )
            }
            Text(preview)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.07)))
        }
    }

    private func row(_ name: String, @ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 8) {
            Text(name).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
            content()
        }
    }

    private func stepper(_ mark: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(mark).font(.system(size: 14))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.primary.opacity(0.06)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }

    static func preview(count: Int, days: [PlanDay], weekdays: Set<Int>) -> String {
        if weekdays.isEmpty { return L("요일을 하나 이상 골라주세요.", "Choose at least one day.") }
        guard let first = days.first, let last = days.last else {
            return count == 0 ? L("고른 논문이 없어요.", "No papers chosen yet.") : L("안 읽은 논문이 없어요.", "Every paper here is read.")
        }
        return L("\(days.count)편 · \(PlanText.span(first, last))", "\(PlanText.papers(days.count)) · \(PlanText.span(first, last))")
    }
}

/// Two or three words in a capsule, one of them lit — a segmented control
/// drawn here so it says its words (the system's draws only icons when given
/// both) and so `ImageRenderer` can draw it.
struct ShelfSwitchButtons<Value: Hashable>: View {
    let choices: [(Value, String)]
    @Binding var selection: Value
    var symbols: [String] = []
    var compact = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(choices.enumerated()), id: \.offset) { index, choice in
                let on = selection == choice.0
                Button {
                    withAnimation(Motion.tap) { selection = choice.0 }
                } label: {
                    HStack(spacing: 5) {
                        if index < symbols.count { Image(systemName: symbols[index]).font(.system(size: compact ? 10.5 : 11.5)) }
                        Text(choice.1).lineLimit(1)
                    }
                    .font(.system(size: compact ? 11.5 : 12.5, weight: on ? .semibold : .regular))
                    .foregroundStyle(on ? Color.primary : .secondary)
                    .padding(.horizontal, compact ? 8 : 11)
                    .frame(height: compact ? 22 : 24)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(on ? Color(nsColor: .controlBackgroundColor) : .clear)
                            .shadow(color: .black.opacity(on ? 0.1 : 0), radius: 1, y: 0.5)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
        .fixedSize()
    }
}

// MARK: - New Plan

/// A plan made in one place: what it is called, which papers, and — if
/// wanted — the days to read them on.
struct NewPlanSheet: View {
    let model: LibraryModel
    @Environment(AppModel.self) private var app
    let close: () -> Void

    @State private var name: String
    @State private var chosen: [UUID]
    @State private var givesDays = false
    @State private var weekdays: Set<Int> = SpreadPicker.stored().weekdays
    @State private var perDay: Int = SpreadPicker.stored().perDay
    @State private var nextWeek: Bool = SpreadPicker.stored().nextWeek
    @FocusState private var nameFocused: Bool

    /// For `ImageRenderer` (`PlanProbe`): the list without its scroll view.
    var rendering = false

    init(model: LibraryModel, name: String, chosen: [UUID], givesDays: Bool = false, rendering: Bool = false,
         close: @escaping () -> Void) {
        self.model = model
        self.close = close
        self.rendering = rendering
        _name = State(initialValue: name)
        _chosen = State(initialValue: chosen)
        _givesDays = State(initialValue: givesDays)
    }

    private var start: PlanDay { nextWeek ? model.today.monday.adding(days: 7) : model.today }
    private var days: [PlanDay] {
        let unread = chosen.compactMap(model.paper).filter { $0.state.readingStatus != .read }
        return PlanSpread.days(count: unread.count, weekdays: weekdays, perDay: perDay, from: start)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L("새 계획", "New Plan")).font(.system(size: 17, weight: .semibold))
                Text(L("읽을 논문을 모으고, 원하면 날짜까지 한 번에 정해요.", "Gather the papers to read and, if you like, give them days in one go."))
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
            part(1, L("이름", "Name")) {
                TextField(L("예: Offline RL 정주행", "e.g. Offline RL, in Order"), text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
            }
            part(2, L("논문", "Papers"), detail: L("\(chosen.count)편 골랐어요", "\(chosen.count) chosen")) {
                PaperPicker(model: model, chosen: $chosen, scrolls: !rendering)
            }
            part(3, L("날짜", "Days"), detail: L("나중에 해도 돼요", "Optional")) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(L("날짜도 지금 정하기", "Give them days now"), isOn: $givesDays.animation(Motion.move))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    if givesDays {
                        SpreadControls(
                            weekdays: $weekdays, perDay: $perDay, nextWeek: $nextWeek,
                            preview: SpreadControls.preview(count: chosen.count, days: days, weekdays: weekdays)
                        )
                    }
                }
            }
            HStack {
                Spacer()
                Button(L("취소", "Cancel"), action: close).keyboardShortcut(.cancelAction)
                Button(L("계획 만들기", "Create Plan")) { Task { await create() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 540, height: givesDays ? 760 : 640)
        .onAppear { nameFocused = name.isEmpty }
    }

    private func part(_ number: Int, _ title: String, detail: String? = nil, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("\(number)")
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.accentColor.opacity(0.13)))
                Text(title).font(.system(size: 13, weight: .semibold))
                if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(.tertiary) }
            }
            content()
        }
    }

    private func create() async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let id = await model.createPlan(named: trimmed, papers: chosen) else { return }
        if givesDays {
            let assignments = model.spread(id, weekdays: weekdays, perDay: perDay, from: start)
            await model.setDays(Dictionary(assignments.map { ($0.0, Optional($0.1)) }, uniquingKeysWith: { a, _ in a }))
            if !assignments.isEmpty {
                app.planning.notice = L("\(assignments.count)편에 날짜를 정했어요.", "Gave \(PlanText.papers(assignments.count)) a day.")
            }
            SpreadPicker.remember(weekdays: weekdays, perDay: perDay, nextWeek: nextWeek)
        }
        model.setShelfView(.table, for: .plan(id))
        withAnimation(Motion.surface) { model.scope = .plan(id) }
        close()
    }
}

// MARK: - Add Papers

struct AddPapersSheet: View {
    let model: LibraryModel
    let planID: UUID
    let close: () -> Void
    @State private var chosen: [UUID] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L("논문 더하기", "Add Papers")).font(.system(size: 17, weight: .semibold))
                Text(model.plan(planID)?.name ?? "").font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
            PaperPicker(model: model, chosen: $chosen, locked: Set(model.plan(planID)?.readingOrder ?? []))
            HStack {
                Spacer()
                Button(L("취소", "Cancel"), action: close).keyboardShortcut(.cancelAction)
                Button(chosen.isEmpty ? L("더하기", "Add") : L("\(chosen.count)편 더하기", "Add \(chosen.count)")) {
                    let ids = chosen
                    Task {
                        await model.addToPlan(planID, papers: ids)
                        close()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(chosen.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 540, height: 560)
    }
}

// MARK: - A name

/// One field and two buttons: a plan's name, a section's, a material's.
struct PlanPromptSheet: View {
    let model: LibraryModel
    let prompt: PlanPrompt
    let close: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 15, weight: .semibold))
            if let message { Text(message).font(.system(size: 12.5)).foregroundStyle(.secondary) }
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(save)
            HStack {
                Spacer()
                Button(L("취소", "Cancel"), action: close).keyboardShortcut(.cancelAction)
                Button(L("확인", "OK"), action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !allowsEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear {
            text = initial
            focused = true
        }
    }

    private var title: String {
        switch prompt {
        case .renamePlan: L("계획 이름 바꾸기", "Rename Plan")
        case .newSection: L("새 섹션", "New Section")
        case .renameSection: L("섹션 이름 바꾸기", "Rename Section")
        case .renameMaterial: L("자료 이름 바꾸기", "Rename Material")
        }
    }

    private var message: String? {
        switch prompt {
        case .newSection: L("계열이나 주제의 이름을 적어요.", "Name a line of work or a topic.")
        case .renameMaterial: L("비워 두면 주소에서 딴 이름으로 돌아가요.", "Leave it empty to go back to the name from the address.")
        default: nil
        }
    }

    private var placeholder: String {
        switch prompt {
        case .newSection: L("예: 값을 낮춰 잡기", "e.g. Conservative Estimates")
        case let .renameMaterial(paper, link): model.paper(paper)?.links.first { $0.id == link }?.displayTitle ?? ""
        default: ""
        }
    }

    private var allowsEmpty: Bool {
        if case .renameMaterial = prompt { return true }
        return false
    }

    private var initial: String {
        switch prompt {
        case let .renamePlan(id): model.plan(id)?.name ?? ""
        case .newSection: ""
        case let .renameSection(plan, section): model.plan(plan)?.sections.first { $0.id == section }?.name ?? ""
        case let .renameMaterial(paper, link): model.paper(paper)?.links.first { $0.id == link }?.title ?? ""
        }
    }

    private func save() {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty || allowsEmpty else { return }
        let prompt = prompt
        Task {
            switch prompt {
            case let .renamePlan(id): await model.renamePlan(id, to: value)
            case let .newSection(id): await model.editPlan(id) { $0.addSection(named: value) }
            case let .renameSection(plan, section): await model.editPlan(plan) { $0.renameSection(section, to: value) }
            case let .renameMaterial(paper, link): await model.renameLink(link, of: paper, to: value)
            }
        }
        close()
    }
}
#endif
