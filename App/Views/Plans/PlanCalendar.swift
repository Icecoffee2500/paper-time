#if os(macOS)
import AppKit
import LibraryStore
import PaperCore
import SwiftUI

/// A plan on five weeks of days: drag a paper to another day, or out of the
/// calendar into «No Date». Other plans' papers on the same day are drawn
/// faintly, so a crowded day shows before it is a crowded day.
struct PlanCalendar: View {
    let model: LibraryModel
    let planID: UUID
    @Binding var start: PlanDay?
    /// Off only for `ImageRenderer`, which draws a scroll view empty.
    var scrolls = true
    let select: (UUID) -> Void
    let open: (UUID) -> Void
    let move: (UUID, PlanDay?) -> Void

    @State private var target: String?

    /// Last week's Monday, unless the arrows moved it.
    private var first: PlanDay { start ?? model.today.monday.adding(days: -7) }

    var body: some View {
        let plan = model.plan(planID)
        let mine = (plan?.readingOrder ?? []).compactMap(model.paper)
        let undated = mine.filter { $0.schedule == nil }
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                navigation
                if scrolls { ScrollView(.vertical) { grid(mine) } } else { grid(mine) }
            }
            tray(undated)
                .frame(width: 168)
                .padding(.top, 34)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var navigation: some View {
        HStack(spacing: 6) {
            Text(PlanText.span(first, first.adding(days: 34)))
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            Button { start = first.adding(days: -28) } label: { Image(systemName: "chevron.left") }
                .help(L("앞의 네 주", "Four weeks back"))
            Button(L("오늘", "Today")) { start = nil }
                .disabled(start == nil)
            Button { start = first.adding(days: 28) } label: { Image(systemName: "chevron.right") }
                .help(L("뒤의 네 주", "Four weeks on"))
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 4)
    }

    private func grid(_ mine: [LoadedPaper]) -> some View {
        let byDay = Dictionary(grouping: mine.filter { $0.schedule != nil }) { $0.schedule! }
        let others = Dictionary(grouping: model.papers.filter { paper in
            paper.schedule != nil && !mine.contains(where: { $0.id == paper.id })
                && !model.plans(containing: paper.id).isEmpty
        }) { $0.schedule! }
        return GeometryReader { proxy in
            let gap: CGFloat = 4
            let unit = (proxy.size.width - gap * 6) / (5 + 2 * 0.62)
            let widths = (0..<7).map { $0 < 5 ? unit : unit * 0.62 }
            VStack(alignment: .leading, spacing: gap) {
                HStack(spacing: gap) {
                    ForEach(0..<7, id: \.self) { index in
                        Text(L(PlanText.koWeekdays[index], PlanText.enWeekdays[index]))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 7)
                            .frame(width: widths[index], alignment: .leading)
                    }
                }
                ForEach(0..<5, id: \.self) { week in
                    HStack(alignment: .top, spacing: gap) {
                        ForEach(0..<7, id: \.self) { index in
                            let day = first.adding(days: week * 7 + index)
                            cell(day, papers: byDay[day] ?? [], others: others[day] ?? [], first: week == 0 && index == 0)
                                .frame(width: widths[index])
                        }
                    }
                }
            }
        }
        .frame(minHeight: 5 * 96 + 24)
    }

    private func cell(_ day: PlanDay, papers: [LoadedPaper], others: [LoadedPaper], first: Bool) -> some View {
        let today = model.today
        let isToday = day == today
        let label = first || day.day == 1 ? PlanText.long(day) : "\(day.day)"
        return VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 11, weight: isToday ? .bold : .regular))
                .monospacedDigit()
                .foregroundStyle(isToday ? Color.white : Color.secondary.opacity(0.8))
                .padding(.horizontal, isToday ? 7 : 4)
                .frame(height: 18)
                .background(Capsule().fill(isToday ? Color.accentColor : .clear))
            ForEach(papers) { paper in pill(paper) }
            ForEach(others) { paper in ghost(paper) }
        }
        .padding(5)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(ground(day))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: target == day.text ? 2 : 0)
        )
        .modifier(Drop(enabled: scrolls, key: day.text, target: $target) { id in
            if model.paper(id)?.schedule != day { move(id, day) }
            return true
        })
    }

    /// A drop target, left off for `ImageRenderer`, which draws one as a
    /// placeholder.
    private struct Drop: ViewModifier {
        let enabled: Bool
        let key: String
        @Binding var target: String?
        let accept: (UUID) -> Bool

        func body(content: Content) -> some View {
            if enabled {
                content.dropDestination(for: PaperTransfer.self) { items, _ in
                    target = nil
                    guard let id = items.first?.id else { return false }
                    return accept(id)
                } isTargeted: { on in
                    if on { target = key } else if target == key { target = nil }
                }
            } else {
                content
            }
        }
    }

    private func ground(_ day: PlanDay) -> Color {
        if target == day.text { return Color.accentColor.opacity(0.14) }
        if day.monday == model.today.monday { return Color.accentColor.opacity(0.06) }
        if day < model.today { return Color.primary.opacity(0.02) }
        return Color.primary.opacity(0.04)
    }

    private func pill(_ paper: LoadedPaper) -> some View {
        let behind = model.isBehind(paper)
        let selected = model.selection.contains(paper.id)
        return HStack(alignment: .top, spacing: 4) {
            StatusRing(status: paper.state.readingStatus, progress: model.progress(of: paper), size: 13)
                .padding(.top, 1)
            Text(paper.meta.displayTitle)
                .font(.system(size: 11))
                .foregroundStyle(paper.state.readingStatus == .read ? .secondary : .primary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(behind ? Color.orange.opacity(0.16) : Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: selected ? 2 : 0)
        )
        .contentShape(Rectangle())
        .onTapGesture { select(paper.id) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { open(paper.id) })
        .modifier(Drag(enabled: scrolls, paper: paper))
        .help(paper.meta.displayTitle)
    }

    private struct Drag: ViewModifier {
        let enabled: Bool
        let paper: LoadedPaper

        func body(content: Content) -> some View {
            if enabled {
                content.draggable(PaperTransfer(id: paper.id, title: paper.meta.displayTitle)) {
                    Text(paper.meta.displayTitle).font(.system(size: 11)).padding(6)
                        .background(RoundedRectangle(cornerRadius: 7).fill(.background))
                }
            } else {
                content
            }
        }
    }

    private func ghost(_ paper: LoadedPaper) -> some View {
        Text(paper.meta.displayTitle)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .lineLimit(2)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            )
            .help((model.plans(containing: paper.id).first.map { $0.name + " · " } ?? "") + paper.meta.displayTitle)
    }

    private func tray(_ undated: [LoadedPaper]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("날짜 없음 · \(undated.count)", "No Date · \(undated.count)"))
                .font(.system(size: 12, weight: .semibold))
            Text(L("달력으로 끌면 그날로 정해요. 여기로 끌면 날짜를 지워요.",
                   "Drag to the calendar to give it a day. Drag here to clear the day."))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            if scrolls {
                ScrollView(.vertical) { VStack(spacing: 6) { ForEach(undated) { pill($0) } } }
            } else {
                VStack(spacing: 6) { ForEach(undated) { pill($0) } }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(target == "tray" ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: target == "tray" ? 2 : 0)
        )
        .modifier(Drop(enabled: scrolls, key: "tray", target: $target) { id in
            guard model.paper(id)?.schedule != nil else { return false }
            move(id, nil)
            return true
        })
    }
}

// MARK: - Picking a day

/// The day a paper is read on: typed («금요일», «12/3», «+1주»), picked from
/// four quick ones, or from five weeks of days.
struct DayPicker: View {
    let today: PlanDay
    let current: PlanDay?
    let pick: (PlanDay?) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    private var read: PlanDay? { PlanDayParser.read(text, today: today) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField(L("금요일, 12/3, +1주처럼 적어요", "Type Friday, 12/3 or +1w"), text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Capsule().fill(Color.primary.opacity(0.05)))
                .focused($focused)
                .onSubmit { if let read { pick(read) } }
            Text(preview)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(read == nil ? Color.secondary : Color.accentColor)
                .frame(height: 20)
                .padding(.horizontal, 4)
                .padding(.top, 2)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)], spacing: 4) {
                quick(L("오늘", "Today"), today)
                quick(L("내일", "Tomorrow"), today.adding(days: 1))
                quick(L("이번 금요일", "This Friday"), today.adding(days: (4 - today.weekday + 7) % 7))
                quick(L("다음 주 월요일", "Next Monday"), today.monday.adding(days: 7))
            }
            .padding(.vertical, 8)
            HStack(spacing: 2) {
                ForEach(0..<7, id: \.self) { index in
                    Text(L(PlanText.koWeekdays[index], PlanText.enWeekdays[index]))
                        .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.bottom, 2)
            VStack(spacing: 2) {
                ForEach(0..<5, id: \.self) { week in
                    HStack(spacing: 2) {
                        ForEach(0..<7, id: \.self) { index in
                            let day = today.monday.adding(days: week * 7 + index)
                            Button { pick(day) } label: {
                                Text("\(day.day)")
                                    .font(.system(size: 12, weight: day == current ? .semibold : day == today ? .bold : .regular))
                                    .monospacedDigit()
                                    .foregroundStyle(day == current ? Color.white : day == today ? Color.accentColor : Color.primary)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 26)
                                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(day == current ? Color.accentColor : .clear))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(PlanText.full(day))
                        }
                    }
                }
            }
            if current != nil {
                Button { pick(nil) } label: {
                    Text(L("날짜 지우기", "Clear Date"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
            }
        }
        .padding(12)
        .frame(width: 284)
        .onAppear { focused = true }
    }

    private var preview: String {
        if let read { return L("→ \(PlanText.full(read)) · Enter", "→ \(PlanText.full(read)) · Return") }
        return text.trimmingCharacters(in: .whitespaces).isEmpty ? " " : L("아직 못 읽었어요", "Not a day yet")
    }

    private func quick(_ name: String, _ day: PlanDay) -> some View {
        Button { pick(day) } label: {
            HStack(spacing: 4) {
                Text(name).font(.system(size: 11.5)).lineLimit(1).fixedSize()
                Spacer(minLength: 2)
                Text("\(PlanText.weekday(day)) \(PlanText.short(day))")
                    .font(.system(size: 10)).monospacedDigit().foregroundStyle(.tertiary).lineLimit(1).fixedSize()
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The day picker as a popover from wherever the pointer is: the chips that
/// open it live in table rows, whose views come and go as the table scrolls,
/// so the popover is pinned to the window rather than to the chip.
@MainActor
enum DayPopover {
    private static var current: NSPopover?

    static func show(model: LibraryModel, paperID: UUID, pick: @escaping (PlanDay?) -> Void) {
        current?.close()
        guard let event = NSApp.currentEvent, let window = event.window ?? NSApp.keyWindow,
              let content = window.contentView else { return }
        let point = content.convert(event.locationInWindow, from: nil)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: DayPicker(
            today: model.today, current: model.paper(paperID)?.schedule
        ) { day in
            popover.close()
            pick(day)
        })
        popover.show(relativeTo: NSRect(x: point.x - 6, y: point.y - 8, width: 12, height: 16), of: content, preferredEdge: .minY)
        current = popover
    }
}

/// «Spread Out»: the weekdays to read on and how many a day, previewed
/// before anything changes.
struct SpreadPicker: View {
    let model: LibraryModel
    let planID: UUID
    let apply: ([(UUID, PlanDay)]) -> Void

    @State private var weekdays: Set<Int> = SpreadPicker.stored().weekdays
    @State private var perDay: Int = SpreadPicker.stored().perDay
    @State private var nextWeek: Bool = SpreadPicker.stored().nextWeek

    private var start: PlanDay { nextWeek ? model.today.monday.adding(days: 7) : model.today }
    private var assignments: [(UUID, PlanDay)] { model.spread(planID, weekdays: weekdays, perDay: perDay, from: start) }

    var body: some View {
        let made = assignments
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("고르게 나누기", "Spread Out")).font(.system(size: 13, weight: .semibold))
                Text(L("아직 안 읽은 논문에 차례대로 날짜를 정해요.", "Gives each unread paper a day, in order."))
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            row(L("요일", "Days")) {
                HStack(spacing: 3) {
                    ForEach([0, 1, 2, 3, 4, 5, 6], id: \.self) { day in
                        let on = weekdays.contains(day)
                        Button {
                            if on { weekdays.remove(day) } else { weekdays.insert(day) }
                            remember()
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
                Stepper(value: Binding(get: { perDay }, set: { perDay = $0; remember() }), in: 1...3) {
                    Text(PlanText.papers(perDay)).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                }
            }
            row(L("시작", "Start")) {
                Picker("", selection: Binding(get: { nextWeek }, set: { nextWeek = $0; remember() })) {
                    Text(L("오늘부터", "Today")).tag(false)
                    Text(L("다음 주부터", "Next Week")).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
            Text(preview(made))
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.07)))
            HStack {
                Spacer()
                Button(L("날짜 정하기", "Set Days")) { apply(made) }
                    .buttonStyle(SoftButtonStyle(prominent: true))
                    .disabled(made.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .frame(width: 268)
    }

    private func row(_ name: String, @ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 8) {
            Text(name).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
            content()
        }
    }

    private func preview(_ made: [(UUID, PlanDay)]) -> String {
        if weekdays.isEmpty { return L("요일을 하나 이상 골라주세요.", "Choose at least one day.") }
        guard let first = made.first?.1, let last = made.last?.1 else {
            return L("안 읽은 논문이 없어요.", "Every paper here is read.")
        }
        return L("\(made.count)편 · \(PlanText.span(first, last))", "\(PlanText.papers(made.count)) · \(PlanText.span(first, last))")
    }

    private struct Choice { var weekdays: Set<Int>; var perDay: Int; var nextWeek: Bool }

    private static func stored() -> Choice {
        let defaults = UserDefaults.standard
        guard Boot.setting("PAPERTIME_LIBRARY") == nil, let days = defaults.array(forKey: "spreadWeekdays") as? [Int] else {
            return Choice(weekdays: [0, 2, 4], perDay: 1, nextWeek: false)
        }
        return Choice(weekdays: Set(days), perDay: max(1, min(3, defaults.integer(forKey: "spreadPerDay"))),
                      nextWeek: defaults.bool(forKey: "spreadNextWeek"))
    }

    private func remember() {
        guard Boot.setting("PAPERTIME_LIBRARY") == nil else { return }
        let defaults = UserDefaults.standard
        defaults.set(weekdays.sorted(), forKey: "spreadWeekdays")
        defaults.set(perDay, forKey: "spreadPerDay")
        defaults.set(nextWeek, forKey: "spreadNextWeek")
    }
}
#endif
