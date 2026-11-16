import LibraryStore
import PaperCore
import SwiftUI

/// The words a reading plan is told in: days, weeks, spans.
///
/// Written out rather than asked of `DateFormatter`, because the board says
/// «금 11.20» and «Fri Nov 20» whatever region the Mac is set to, and the
/// Portable build says exactly the same.
enum PlanText {
    static let koWeekdays = ["월", "화", "수", "목", "금", "토", "일"]
    static let enWeekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    static let enWeekdaysLong = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
    static let enMonths = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    static let enMonthsLong = ["January", "February", "March", "April", "May", "June", "July", "August",
                               "September", "October", "November", "December"]

    /// «금» / «Fri».
    static func weekday(_ day: PlanDay) -> String {
        L(koWeekdays[day.weekday], enWeekdays[day.weekday])
    }

    /// «금요일» / «Friday».
    static func weekdayLong(_ day: PlanDay) -> String {
        L(koWeekdays[day.weekday] + "요일", enWeekdaysLong[day.weekday])
    }

    /// «11.20» / «Nov 20».
    static func short(_ day: PlanDay) -> String {
        L("\(day.month).\(day.day)", "\(enMonths[day.month - 1]) \(day.day)")
    }

    /// «11월 20일» / «Nov 20».
    static func long(_ day: PlanDay) -> String {
        L("\(day.month)월 \(day.day)일", "\(enMonths[day.month - 1]) \(day.day)")
    }

    /// «11월 20일 금요일» / «Friday, Nov 20».
    static func full(_ day: PlanDay) -> String {
        L("\(day.month)월 \(day.day)일 \(koWeekdays[day.weekday])요일", "\(enWeekdaysLong[day.weekday]), \(enMonths[day.month - 1]) \(day.day)")
    }

    /// «11월 9일 – 11월 27일».
    static func span(_ first: PlanDay, _ last: PlanDay) -> String {
        first == last ? long(first) : "\(long(first)) – \(long(last))"
    }

    enum ChipStyle { case none, plain, today, behind }

    /// What a day says in a cell: «정하기», «오늘», «내일», «금 11.20», or
    /// «11.12 · 밀림» for a day gone by with the paper still unread.
    static func chip(_ day: PlanDay?, behind: Bool, today: PlanDay) -> (text: String, style: ChipStyle) {
        guard let day else { return (L("정하기", "Set Date"), .none) }
        if behind { return (L("\(short(day)) · 밀림", "\(short(day)) · Overdue"), .behind) }
        switch day.days(since: today) {
        case 0: return (L("오늘", "Today"), .today)
        case 1: return (L("내일", "Tomorrow"), .plain)
        default: return ("\(weekday(day)) \(short(day))", .plain)
        }
    }

    /// The week a Monday starts, by name when it is near.
    static func week(_ monday: PlanDay, today: PlanDay) -> String {
        let range = "\(short(monday))–\(short(monday.adding(days: 6)))"
        switch monday.days(since: today.monday) / 7 {
        case 0: return L("이번 주 · \(range)", "This week · \(range)")
        case 1: return L("다음 주 · \(range)", "Next week · \(range)")
        case -1: return L("지난주 · \(range)", "Last week · \(range)")
        default: return range
        }
    }

    /// A day's heading in «This Week»: «오늘 · 11월 16일 월요일».
    static func heading(_ day: PlanDay, today: PlanDay) -> String {
        switch day.days(since: today) {
        case 0: return L("오늘 · \(full(day))", "Today · \(full(day))")
        case 1: return L("내일 · \(full(day))", "Tomorrow · \(full(day))")
        default: return L("\(koWeekdays[day.weekday])요일 · \(long(day))", full(day))
        }
    }

    static func papers(_ count: Int) -> String { L("\(count)편", count == 1 ? "1 paper" : "\(count) papers") }
}

extension MaterialKind {
    var name: String {
        switch self {
        case .paper: L("논문", "Paper")
        case .slides: L("슬라이드", "Slides")
        case .code: L("코드", "Code")
        case .notebook: L("노트북", "Notebook")
        case .video: L("영상", "Video")
        case .data: L("데이터", "Data")
        case .post: L("글", "Article")
        case .file: L("파일", "File")
        case .supplement: L("보충 자료", "Supplement")
        }
    }

    var symbol: String {
        switch self {
        case .paper: "doc.text"
        case .slides: "rectangle.on.rectangle"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .notebook: "book.closed"
        case .video: "play.rectangle"
        case .data: "cylinder"
        case .post: "text.alignleft"
        case .file: "doc"
        case .supplement: "paperclip"
        }
    }

    var tint: Color {
        switch self {
        case .paper: .blue
        case .slides: .orange
        case .code: .gray
        case .notebook: .yellow
        case .video: .pink
        case .data: .teal
        case .post: .green
        case .file: .indigo
        case .supplement: .purple
        }
    }

    /// «코드(으)로 알아챘어요» needs the right particle.
    var detected: String {
        switch self {
        case .paper: L("논문으로 알아챘어요", "Looks like a paper")
        case .slides: L("슬라이드로 알아챘어요", "Looks like slides")
        case .code: L("코드로 알아챘어요", "Looks like code")
        case .notebook: L("노트북으로 알아챘어요", "Looks like a notebook")
        case .video: L("영상으로 알아챘어요", "Looks like a video")
        case .data: L("데이터로 알아챘어요", "Looks like data")
        case .post: L("글로 알아챘어요", "Looks like an article")
        case .file: L("파일로 알아챘어요", "Looks like a file")
        case .supplement: L("보충 자료로 알아챘어요", "Looks like a supplement")
        }
    }

    var added: String {
        switch self {
        case .paper: L("논문으로 붙였어요.", "Added as a paper.")
        case .slides: L("슬라이드로 붙였어요.", "Added as slides.")
        case .code: L("코드로 붙였어요.", "Added as code.")
        case .notebook: L("노트북으로 붙였어요.", "Added as a notebook.")
        case .video: L("영상으로 붙였어요.", "Added as a video.")
        case .data: L("데이터로 붙였어요.", "Added as data.")
        case .post: L("글로 붙였어요.", "Added as an article.")
        case .file: L("파일로 붙였어요.", "Added as a file.")
        case .supplement: L("보충 자료로 붙였어요.", "Added as a supplement.")
        }
    }
}

/// The reading state as a ring: empty, filling in orange as the pages go,
/// and a green disc with a check when it is read.
struct StatusRing: View {
    let status: PaperState.ReadingStatus
    var progress: Double = 0
    var size: CGFloat = 16

    var body: some View {
        ZStack {
            switch status {
            case .read:
                Circle().fill(Color.green).padding(size / 16)
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(.white)
            case .reading:
                Circle().stroke(Color.orange.opacity(0.24), lineWidth: size / 8).padding(size / 8)
                Circle()
                    .trim(from: 0, to: max(0.12, min(0.92, progress)))
                    .stroke(Color.orange, style: StrokeStyle(lineWidth: size / 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(size / 8)
            case .unread:
                Circle().strokeBorder(Color.secondary.opacity(0.55), lineWidth: 1.5).padding(size / 8)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(status.label)
    }
}

extension PaperState.ReadingStatus {
    var label: String {
        switch self {
        case .unread: L("안 읽음", "Unread")
        case .reading: L("읽는 중", "Reading")
        case .read: L("읽음", "Read")
        }
    }

    /// The next state round the ring: unread, reading, read, unread.
    var next: PaperState.ReadingStatus {
        switch self {
        case .unread: .reading
        case .reading: .read
        case .read: .unread
        }
    }
}

/// A day, in a capsule that says how near it is.
struct DayChipLabel: View {
    let text: String
    let style: PlanText.ChipStyle

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: style == .today || style == .behind ? .semibold : .regular))
            .monospacedDigit()
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(background))
    }

    private var foreground: Color {
        switch style {
        case .none: Color.secondary.opacity(0.7)
        case .plain: .secondary
        case .today: .accentColor
        case .behind: Color.orange.mixed(with: .primary, by: 0.35)
        }
    }

    private var background: Color {
        switch style {
        case .today: Color.accentColor.opacity(0.14)
        case .behind: Color.orange.opacity(0.15)
        default: .clear
        }
    }
}

/// A material's kind as a small tinted tile.
struct KindTile: View {
    let kind: MaterialKind
    var width: CGFloat = 24
    var height: CGFloat = 22

    var body: some View {
        Image(systemName: kind.symbol)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(kind.tint.mixed(with: .primary, by: 0.3))
            .frame(width: width, height: height)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(kind.tint.opacity(0.15)))
    }
}

/// How far through, as a bar and a number.
struct ProgressCell: View {
    let fraction: Double
    let page: Int
    let pages: Int
    let isRead: Bool

    var body: some View {
        HStack(spacing: 7) {
            Capsule()
                .fill(Color.primary.opacity(0.08))
                .frame(width: 34, height: 4)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(isRead ? Color.green : .orange)
                        .frame(width: 34 * max(0, min(1, fraction)), height: 4)
                }
            Text(text)
                .font(.system(size: 11.5))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    private var text: String {
        if page > 0, !isRead, pages > 0 { return "\(page)/\(pages)" }
        return pages > 0 ? L("\(pages)쪽", "\(pages) pp.") : "—"
    }
}

/// A tag, as the list draws one.
struct TagCapsule: View {
    let name: String
    let color: Color

    var body: some View {
        Text(name)
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
            .foregroundStyle(color.mixed(with: .primary, by: 0.4))
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Capsule().fill(color.opacity(0.13)))
    }
}

/// A count in a soft capsule of its own colour: «이번 주 3편».
struct StatCapsule: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(color.mixed(with: .primary, by: 0.38))
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(Capsule().fill(color.opacity(0.13)))
    }
}

/// How much of a plan is read, as a small ring for the sidebar.
struct PlanDonut: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.15), lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(0, min(1, fraction)))
                .stroke(Color.green, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 11, height: 11)
    }
}

/// A rounded button with a soft ground, the plan header's buttons.
struct SoftButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: prominent ? .semibold : .medium))
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(
                Capsule().fill(prominent ? Color.accentColor : Color.primary.opacity(configuration.isPressed ? 0.11 : 0.06))
            )
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Capsule())
    }
}

/// The switch between list, table and calendar — in words, so the calendar
/// is something you can see is there. The system's segmented picker drew only
/// the icons, and the calendar went unfound (2026-11-16).
struct ShelfViewSwitch: View {
    @Binding var view: LibraryModel.ShelfView
    let choices: [LibraryModel.ShelfView]
    var compact = false

    var body: some View {
        ShelfSwitchButtons(
            choices: choices.map { ($0, $0.label) },
            selection: $view,
            symbols: choices.map(\.symbol),
            compact: compact
        )
        .accessibilityLabel(L("보기", "View"))
    }
}

/// The head every left column wears — the table of any shelf, a plan, the
/// week, the slip-box: a tinted tile, the name, one line about it, and the
/// column's own controls at the end. One shape, so moving between shelves
/// reads as moving within one place (2026-11-16, the user's ask).
struct ShelfHeader<Trailing: View>: View {
    let symbol: String
    var tint: Color = .accentColor
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(tint.opacity(0.13)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 19, weight: .semibold)).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            trailing()
        }
    }
}
