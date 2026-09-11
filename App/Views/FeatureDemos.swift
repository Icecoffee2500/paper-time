import SwiftUI

/// How much room a demonstration has.
///
/// The same six demos appear twice: folded under a line of the log, where
/// they have to fit in a paragraph's worth of height, and in About, where the
/// point is to let somebody actually try the thing. Rather than two sets of
/// views drifting apart, each demo reads this and grows.
enum DemoScale {
    case compact
    case full

    var isFull: Bool { self == .full }
    var body: Font { isFull ? .callout : .caption }
    var small: Font { isFull ? .caption : .caption2 }
    var pad: CGFloat { isFull ? 14 : 8 }
    var gap: CGFloat { isFull ? 14 : 8 }
    var corner: CGFloat { isFull ? 10 : 6 }
    var stage: CGFloat { isFull ? 250 : 120 }
}

/// A small working model of a feature.
///
/// Not a video. A recording would be a file in the bundle that goes stale the
/// first time the thing it shows is redrawn, and it cannot be poked. These are
/// the real controls, built the same way the app is: press the key in the demo
/// and the panes actually close, click a mark and the inspector actually goes
/// to it. What is missing is the paper — no document is open in here — but the
/// gesture is the true one, which is all a feature list owes anyone.
struct FeatureDemoView: View {
    let demo: ReleaseNotes.Demo
    var scale: DemoScale = .compact

    var body: some View {
        Group {
            switch demo {
            case .annotations: AnnotationDemo(scale: scale)
            case .panes: PaneDemo(scale: scale)
            case .passageLink: PassageDemo(scale: scale)
            case .ultracopy: UltracopyDemo(scale: scale)
            case .slipBox: SlipBoxDemo(scale: scale)
            case .graph: GraphDemo(scale: scale)
            case .search: SearchDemo(scale: scale)
            }
        }
        .padding(scale.pad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: scale.isFull ? Corner.panel : Corner.popover, style: .continuous)
                .fill(.quaternary.opacity(scale.isFull ? 0.2 : 0.25))
        )
    }
}

/// The wrapper the log uses: the same demo, indented under its line.
struct LogDemoView: View {
    let demo: ReleaseNotes.Demo

    var body: some View {
        FeatureDemoView(demo: demo, scale: .compact)
            .padding(.leading, 21)
            .padding(.top, 2)
            .padding(.bottom, 6)
    }
}

/// A sheet of paper, in the demos that need one.
private struct Paper<Content: View>: View {
    let scale: DemoScale
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(scale.isFull ? 10 : 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: scale.corner, style: .continuous).fill(.background)
            )
    }
}

/// A line of body text that is not the point of the demo.
private struct Rule: View {
    var width: CGFloat?

    var body: some View {
        Capsule()
            .fill(.quaternary)
            .frame(width: width, height: 3)
    }
}

// MARK: - Marks, both ways

/// A mark on the page and its row in the inspector, each reaching the other.
///
/// This is the one that is genuinely hard to say in a sentence. The marks list
/// is not a report of what you highlighted, it is a way back into the paper —
/// and the paper is a way into the list. Clicking either end here moves the
/// other, scrolling if it has to, which is exactly what the app does.
private struct AnnotationDemo: View {
    let scale: DemoScale
    @State private var selection: Int?

    private struct Mark: Identifiable {
        let id: Int
        /// Which line of the page it sits on.
        let line: Int
        let text: String
        let tint: Color
        let underlined: Bool
    }

    private var marks: [Mark] {
        [
            Mark(id: 0, line: 1,
                 text: ReleaseNotes.string("경계층에서 초과 감쇠가 생긴다", "excess damping arises in the boundary layer"),
                 tint: .yellow, underlined: false),
            Mark(id: 1, line: 6,
                 text: ReleaseNotes.string("레이놀즈 수에 무관하다", "independent of the Reynolds number"),
                 tint: .blue, underlined: true),
            Mark(id: 2, line: 11,
                 text: ReleaseNotes.string("측정값은 모형보다 40% 크다", "measurements exceed the model by 40%"),
                 tint: .pink, underlined: false),
        ]
    }

    private var lineCount: Int { 14 }

    var body: some View {
        HStack(alignment: .top, spacing: scale.gap) {
            page
            list
                .frame(width: scale.isFull ? 200 : 132)
        }
        .frame(height: scale.isFull ? 230 : 116)
    }

    /// The paper. Marks are the only thing set in type; everything else is
    /// greeked, because the words are not what is being shown.
    private var page: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: scale.isFull ? 7 : 5) {
                    ForEach(0..<lineCount, id: \.self) { line in
                        if let mark = marks.first(where: { $0.line == line }) {
                            markOnPage(mark).id("page-\(mark.id)")
                        } else {
                            Rule(width: greekedWidth(line))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, scale.isFull ? 4 : 2)
                        }
                    }
                }
                .padding(scale.isFull ? 10 : 8)
            }
            .scrollIndicators(.never)
            .background(
                RoundedRectangle(cornerRadius: scale.corner, style: .continuous).fill(.background)
            )
            .onChange(of: selection) { _, now in
                guard let now else { return }
                withAnimation(.snappy(duration: 0.35)) { proxy.scrollTo("page-\(now)", anchor: .center) }
            }
        }
    }

    private func markOnPage(_ mark: Mark) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.3)) { selection = mark.id }
        } label: {
            Text(mark.text)
                .font(scale.body)
                .lineLimit(scale.isFull ? 2 : 1)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        // As pale as the marks on the real page now are.
                        .fill(mark.underlined ? .clear : mark.tint.opacity(0.28))
                )
                .overlay(alignment: .bottom) {
                    if mark.underlined {
                        Rectangle().fill(mark.tint).frame(height: 2)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .stroke(Color.accentColor, lineWidth: selection == mark.id ? 1.5 : 0)
                        .padding(-1.5)
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    /// The inspector's Marks tab.
    private var list: some View {
        VStack(alignment: .leading, spacing: scale.isFull ? 6 : 4) {
            Text(ReleaseNotes.string("표시", "Marks"))
                .font(scale.small.weight(.semibold))
                .foregroundStyle(.secondary)

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(marks) { mark in
                            row(mark).id("row-\(mark.id)")
                        }
                    }
                }
                .scrollIndicators(.never)
                .onChange(of: selection) { _, now in
                    guard let now else { return }
                    withAnimation(.snappy(duration: 0.35)) { proxy.scrollTo("row-\(now)", anchor: .center) }
                }
            }
        }
    }

    private func row(_ mark: Mark) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.3)) { selection = mark.id }
        } label: {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: mark.underlined ? "underline" : "highlighter")
                    .font(scale.small)
                    .foregroundStyle(mark.tint)
                Text(mark.text)
                    .font(scale.small)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: Corner.row, style: .continuous)
                    .fill(selection == mark.id ? AnyShapeStyle(.tint.opacity(0.16)) : AnyShapeStyle(.clear))
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    /// Varied line lengths, so the greeked text reads as prose rather than a
    /// bar chart. Fixed, not random: a demo that reshuffles on every redraw
    /// is a demo that flickers.
    private func greekedWidth(_ line: Int) -> CGFloat? {
        let pattern: [CGFloat?] = [nil, nil, nil, 120, nil, nil, nil, 90, nil, nil, nil, nil, 140, nil]
        return pattern[line % pattern.count]
    }
}

// MARK: - Four panes

/// The window, small, with its four keys under it.
private struct PaneDemo: View {
    let scale: DemoScale
    @Environment(AppModel.self) private var app
    @State private var shown: Set<ShortcutAction> = [.sidebar, .paperList, .reader, .inspector]

    private let panes: [(ShortcutAction, Double)] = [
        (.sidebar, 0.16), (.paperList, 0.24), (.reader, 0.38), (.inspector, 0.22),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: scale.gap) {
            GeometryReader { geometry in
                HStack(spacing: scale.isFull ? 6 : 4) {
                    ForEach(panes, id: \.0) { pane, share in
                        if shown.contains(pane) {
                            RoundedRectangle(cornerRadius: scale.corner - 2, style: .continuous)
                                .fill(pane == .reader ? AnyShapeStyle(.background) : AnyShapeStyle(.quaternary))
                                .frame(width: max(10, geometry.size.width * share))
                                .overlay { if pane == .reader { paperLines } }
                                .transition(.scale(scale: 0.9, anchor: .center).combined(with: .opacity))
                        }
                    }
                    // The rest stay their own width as one closes, rather
                    // than stretching over the gap: the window reveals what
                    // was behind, it does not rebalance.
                    Spacer(minLength: 0)
                }
            }
            .frame(height: scale.isFull ? 150 : 66)

            HStack(spacing: 6) {
                ForEach(panes, id: \.0) { pane, _ in
                    let isShown = shown.contains(pane)
                    Button {
                        withAnimation(.snappy(duration: 0.28)) {
                            if isShown { shown.remove(pane) } else { shown.insert(pane) }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(app.shortcut(for: pane).display).monospaced()
                            Text(pane.title)
                        }
                        .font(scale.small)
                        .foregroundStyle(isShown ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(isShown ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var paperLines: some View {
        VStack(spacing: scale.isFull ? 6 : 3) {
            ForEach(0..<(scale.isFull ? 8 : 4), id: \.self) { _ in
                Capsule().fill(.quaternary).frame(height: 2)
            }
        }
        .padding(scale.isFull ? 12 : 6)
    }
}

// MARK: - Passage links

/// A sentence on a page, and what ⌘L does with it.
private struct PassageDemo: View {
    let scale: DemoScale
    @Environment(AppModel.self) private var app
    @State private var sent = false

    private var sentence: String {
        ReleaseNotes.string(
            "관측된 초과 감쇠는 경계층에서 비롯된다.",
            "The observed excess damping originates in the boundary layer."
        )
    }

    var body: some View {
        HStack(alignment: .top, spacing: scale.gap) {
            Paper(scale: scale) {
                VStack(alignment: .leading, spacing: scale.isFull ? 7 : 4) {
                    Rule(width: 90)
                    Text(sentence)
                        .font(scale.body)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(Color.accentColor.opacity(sent ? 0 : 0.22))
                        )
                    Rule()
                    Rule(width: 120)
                }
            }

            Button {
                withAnimation(.snappy(duration: 0.35)) { sent.toggle() }
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: sent ? "arrow.uturn.backward" : "arrow.right")
                    Text(sent ? ReleaseNotes.string("되돌리기", "Undo")
                              : app.shortcut(for: .linkToNote).display)
                        .monospaced()
                }
                .font(scale.small)
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.top, scale.isFull ? 26 : 18)

            Paper(scale: scale) {
                VStack(alignment: .leading, spacing: scale.isFull ? 7 : 5) {
                    Text(ReleaseNotes.string("감쇠 메모", "Damping"))
                        .font(scale.body.weight(.semibold))
                    if sent {
                        Text(sentence)
                            .font(scale.body)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                                    .fill(Color.accentColor.opacity(0.14))
                            )
                            .overlay(alignment: .bottomTrailing) {
                                // Inside the chip, not hanging off it: at this
                                // size an overhang reads as the chip being cut
                                // by the edge of the note.
                                Image(systemName: "arrow.up.left.circle.fill")
                                    .font(.system(size: scale.isFull ? 11 : 9))
                                    .foregroundStyle(.tint)
                                    .padding(1)
                            }
                            .transition(.scale(scale: 0.85).combined(with: .opacity))
                        if scale.isFull {
                            Text(ReleaseNotes.string("↖︎ 를 누르면 그 자리로 돌아간다.", "The ↖︎ goes back to the page it came from."))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    } else {
                        Rule(width: 70)
                    }
                }
            }
        }
    }
}

// MARK: - Ultracopy

/// The same passage copied twice: once the ordinary way, once with Ultracopy.
///
/// Said as a comparison, because on its own the good result looks merely
/// normal. Nobody knows what "the mathematics comes out as LaTeX" is worth
/// until they have seen what ⌘C does to the same line — a formula spilled
/// into a row of loose letters and digits that has to be retyped from the
/// page. Both keys are here to press, and the two results sit next to each
/// other until one of them is obviously the one you wanted.
private struct UltracopyDemo: View {
    let scale: DemoScale
    @Environment(AppModel.self) private var app
    @State private var plainCopied = false
    @State private var ultraCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: scale.gap) {
            passage

            if scale.isFull {
                HStack(alignment: .top, spacing: scale.gap) {
                    plain
                    ultra
                }
            } else {
                plain
                ultra
            }

            if plainCopied && ultraCopied {
                Text(ReleaseNotes.string(
                    "왼쪽은 손으로 다시 쳐야 하고, 오른쪽은 원고에 그대로 붙는다.",
                    "The left has to be retyped; the right pastes into a manuscript as it is."
                ))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .transition(.opacity)
            }
        }
    }

    /// The line on the page, set the way the page sets it.
    private var passage: some View {
        Paper(scale: scale) {
            VStack(alignment: .leading, spacing: scale.isFull ? 6 : 4) {
                Rule(width: 110)
                formula
                    .font(scale.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.accentColor.opacity(0.18))
                    )
                Rule(width: 150)
            }
        }
    }

    /// The formula as type, one run at a time. Built as a list and folded,
    /// because a dozen `Text`s joined with `+` in one expression is more than
    /// the type-checker will sit through.
    private var formula: Text {
        let body = Font.system(scale.isFull ? .body : .caption, design: .serif)
        let sub = Font.system(size: scale.isFull ? 9 : 7, design: .serif)
        func main(_ string: String) -> Text { Text(string).font(body).italic() }
        func low(_ string: String) -> Text { Text(string).font(sub).baselineOffset(-3) }
        let runs: [Text] = [
            Text(ReleaseNotes.string("각 단계에서 롤아웃 손실 ", "At each step we minimise the rollout loss ")),
            main("ℒ"), low("rollout"), main("(ϕ) := ‖P"), low("ϕ"), main("(a"), low("1:T"),
            main(", s"), low("1"), main(", z"), low("1"), main(") − z"), low("T+1"), main("‖"), low("1"),
            Text(ReleaseNotes.string("을 최소화한다.", " over the horizon.")),
        ]
        return runs.dropFirst().reduce(runs[0]) { $0 + $1 }
    }

    private var plain: some View {
        result(
            key: "⌘C",
            name: ReleaseNotes.string("그냥 복사", "Plain copy"),
            tint: .secondary,
            shown: plainCopied,
            reveal: { plainCopied = true }
        ) {
            // What PDFKit hands back: every glyph, in reading order, with the
            // structure that made it a formula gone.
            Text(ReleaseNotes.string(
                "각 단계에서 롤아웃 손실 Lrollout(ϕ) := ∥Pϕ(a1:T , s1, z1) − zT +1∥1을 최소화한다.",
                "At each step we minimise the rollout loss Lrollout(ϕ) := ∥Pϕ(a1:T , s1, z1) − zT +1∥1 over the horizon."
            ))
            .foregroundStyle(.secondary)
        }
    }

    private var ultra: some View {
        result(
            key: app.shortcut(for: .ultracopy).display,
            name: "Ultracopy",
            tint: .accentColor,
            shown: ultraCopied,
            reveal: { ultraCopied = true }
        ) {
            (Text(ReleaseNotes.string("각 단계에서 롤아웃 손실 ", "At each step we minimise the rollout loss "))
             + Text(verbatim: "$\\mathcal{L}_{\\mathrm{rollout}}(\\phi) := \\|P_\\phi(a_{1:T}, s_1, z_1) - z_{T+1}\\|_1$")
                .foregroundStyle(.tint)
             + Text(ReleaseNotes.string("을 최소화한다.", " over the horizon.")))
        }
    }

    /// One of the two results: a key to press, and what comes out.
    private func result(
        key: String, name: String, tint: Color, shown: Bool,
        reveal: @escaping () -> Void, @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: scale.isFull ? 8 : 5) {
            HStack(spacing: 6) {
                Text(key)
                    .font(scale.small.weight(.medium))
                    .monospaced()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: Corner.row - 2, style: .continuous)
                            .fill(tint.opacity(tint == .accentColor ? 0.14 : 0.1))
                    )
                    .foregroundStyle(tint)
                Text(name)
                    .font(scale.small.weight(tint == .accentColor ? .semibold : .regular))
                    .foregroundStyle(tint == .accentColor ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                Spacer(minLength: 0)
            }

            ZStack(alignment: .topLeading) {
                if shown {
                    content()
                        .font(scale.small.monospaced())
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                } else {
                    Button {
                        withAnimation(.snappy(duration: 0.3)) { reveal() }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "doc.on.clipboard")
                            Text(ReleaseNotes.string("\(key) 눌러 보기", "Press \(key)"))
                        }
                        .font(scale.small)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(.quaternary))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: scale.isFull ? 84 : 44, alignment: .topLeading)
            .padding(scale.isFull ? 10 : 8)
            .background(
                RoundedRectangle(cornerRadius: scale.corner, style: .continuous)
                    .fill(.background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: scale.corner, style: .continuous)
                    .stroke(tint == .accentColor && shown ? Color.accentColor.opacity(0.35) : .clear, lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Slip-box

/// Two notes, a link between them, and the way back.
private struct SlipBoxDemo: View {
    let scale: DemoScale
    @State private var open = 0

    private var titles: [String] {
        [ReleaseNotes.string("감쇠 메모", "Damping"), ReleaseNotes.string("경계층", "Boundary layer")]
    }

    var body: some View {
        Paper(scale: scale) {
            VStack(alignment: .leading, spacing: scale.isFull ? 10 : 6) {
                HStack(spacing: 6) {
                    if open != 0 {
                        Button {
                            withAnimation(.snappy(duration: 0.25)) { open = 0 }
                        } label: {
                            Image(systemName: "chevron.left").font(scale.small)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                    Text(titles[open])
                        .font(scale.body.weight(.semibold))
                    Spacer()
                    Text("\(titles[open]).md")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if open == 0 { first } else { second }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: scale.isFull ? 140 : 96, alignment: .top)
        }
    }

    private var first: some View {
        VStack(alignment: .leading, spacing: scale.isFull ? 8 : 5) {
            HStack(spacing: 0) {
                Text(ReleaseNotes.string("초과 감쇠는 ", "The excess damping comes from the "))
                Button {
                    withAnimation(.snappy(duration: 0.25)) { open = 1 }
                } label: {
                    Text(titles[1])
                        .foregroundStyle(.tint)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.accentColor.opacity(0.12))
                        )
                }
                .buttonStyle(.plain)
                Text(ReleaseNotes.string("에서 온다.", "."))
            }
            .font(scale.body)

            Rule()
            Rule(width: 110)

            Text(ReleaseNotes.string("링크를 눌러 보라.", "Click the link."))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var second: some View {
        VStack(alignment: .leading, spacing: scale.isFull ? 8 : 5) {
            Text(ReleaseNotes.string("벽 근처에서 속도 기울기가 커진다.", "The velocity gradient steepens near the wall."))
                .font(scale.body)
                .fixedSize(horizontal: false, vertical: true)
            Rule(width: 140)

            Divider().opacity(0.4)

            Text(ReleaseNotes.string("나를 가리키는 노트", "Linked mentions"))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Button {
                withAnimation(.snappy(duration: 0.25)) { open = 0 }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.turn.up.left").font(.caption2)
                    Text(titles[0]).font(scale.small)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: Corner.row, style: .continuous).fill(.quaternary.opacity(0.5))
                )
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - The graph

/// The library drawn four ways at once, and the legend that takes one away.
private struct GraphDemo: View {
    let scale: DemoScale
    @State private var hidden: Set<Kind> = []
    @State private var focus: Int?

    enum Kind: String, CaseIterable, Identifiable {
        case citation, note, author, collection
        var id: String { rawValue }

        var tint: Color {
            switch self {
            case .citation: .blue
            case .note: .purple
            case .author: .teal
            case .collection: .orange
            }
        }

        var label: String {
            switch self {
            case .citation: ReleaseNotes.string("인용", "Citation")
            case .note: ReleaseNotes.string("내 노트", "My notes")
            case .author: ReleaseNotes.string("공저자", "Author")
            case .collection: ReleaseNotes.string("컬렉션", "Collection")
            }
        }
    }

    /// Seven papers, placed by hand in unit space. The app's own graph finds
    /// these positions by simulation; a demo that had to settle first would
    /// spend its first second looking broken.
    private let nodes: [CGPoint] = [
        CGPoint(x: 0.18, y: 0.30), CGPoint(x: 0.42, y: 0.14), CGPoint(x: 0.50, y: 0.52),
        CGPoint(x: 0.26, y: 0.76), CGPoint(x: 0.72, y: 0.30), CGPoint(x: 0.84, y: 0.66),
        CGPoint(x: 0.58, y: 0.86),
    ]

    /// Who the seven are. Invented, but recognisable — the point is that a
    /// dot with a name under it reads as a paper and a bare dot reads as a
    /// diagram.
    private let names = ["Attention", "ViT", "V-JEPA 2", "DINOv2", "OpenVLA", "π0", "Octo"]

    private let edges: [(Int, Int, Kind)] = [
        (0, 1, .citation), (1, 2, .citation), (2, 4, .citation),
        (0, 2, .note), (2, 6, .note),
        (1, 4, .author), (4, 5, .author),
        (2, 3, .collection), (3, 6, .collection), (5, 6, .collection),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: scale.gap) {
            TimelineView(.animation) { timeline in
                let time = timeline.date.timeIntervalSinceReferenceDate
                GeometryReader { geometry in
                    let size = geometry.size
                    ZStack {
                        ForEach(Array(edges.enumerated()), id: \.offset) { index, edge in
                            let (a, b, kind) = edge
                            if !hidden.contains(kind) {
                                Path { path in
                                    path.move(to: place(a, in: size, at: time))
                                    path.addLine(to: place(b, in: size, at: time))
                                }
                                .stroke(kind.tint.opacity(dim(a, b) ? 0.06 : 0.5), lineWidth: 1.2)
                                .id(index)
                            }
                        }
                        ForEach(nodes.indices, id: \.self) { index in
                            let point = place(index, in: size, at: time)
                            Circle()
                                .fill(.tint)
                                .opacity(focus == nil || related(index) ? 1 : 0.15)
                                .frame(width: dot, height: dot)
                                .overlay(
                                    Circle().stroke(Color.accentColor, lineWidth: focus == index ? 2 : 0)
                                        .padding(-3)
                                )
                                .position(point)
                                .onTapGesture {
                                    withAnimation(.snappy(duration: 0.25)) {
                                        focus = focus == index ? nil : index
                                    }
                                }
                            if scale.isFull {
                                Text(names[index])
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .opacity(focus == nil || related(index) ? 1 : 0.2)
                                    .position(CGPoint(x: point.x, y: point.y + dot + 6))
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                }
            }
            .frame(height: scale.isFull ? 200 : 92)
            .background(
                RoundedRectangle(cornerRadius: scale.corner, style: .continuous).fill(.background)
            )

            HStack(spacing: 6) {
                ForEach(Kind.allCases) { kind in
                    let on = !hidden.contains(kind)
                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            if on { hidden.insert(kind) } else { hidden.remove(kind) }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Circle().fill(kind.tint).frame(width: 6, height: 6).opacity(on ? 1 : 0.3)
                            Text(kind.label)
                        }
                        .font(scale.small)
                        .foregroundStyle(on ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(on ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear)))
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
                if scale.isFull {
                    Text(focus == nil
                         ? ReleaseNotes.string("논문을 눌러 집중", "Click a paper to focus")
                         : ReleaseNotes.string("다시 눌러 해제", "Click it again to release"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var dot: CGFloat { scale.isFull ? 13 : 8 }

    /// Where a paper is right now. The drift is small and slow and never
    /// stops, which is the difference between a diagram of a graph and a
    /// graph — the app's own keeps moving for the same reason.
    private func place(_ index: Int, in size: CGSize, at time: TimeInterval) -> CGPoint {
        let node = nodes[index]
        let phase = Double(index) * 1.7
        let amplitude = scale.isFull ? 5.0 : 2.5
        return CGPoint(
            x: node.x * size.width + sin(time * 0.5 + phase) * amplitude,
            y: node.y * size.height + cos(time * 0.4 + phase * 1.3) * amplitude
        )
    }

    /// Whether a paper survives the focus.
    private func related(_ index: Int) -> Bool {
        guard let focus else { return true }
        if index == focus { return true }
        return edges.contains { a, b, kind in
            !hidden.contains(kind) && ((a == focus && b == index) || (b == focus && a == index))
        }
    }

    private func dim(_ a: Int, _ b: Int) -> Bool {
        guard let focus else { return false }
        return a != focus && b != focus
    }
}

// MARK: - Search everything

/// ⌘K, at its own size.
///
/// Built to look like the palette itself rather than like a picture of it —
/// the same card, the same capitalised group captions, the same 44-point rows
/// with a symbol, a title and a line under it — because the thing worth
/// showing is that papers, notes, authors, collections, tags and commands all
/// come back from the same field. The corpus is invented; the filtering is
/// real, so typing in here behaves the way typing in there does.
private struct SearchDemo: View {
    let scale: DemoScale
    @Environment(AppModel.self) private var app
    @State private var query = "vision"
    @State private var highlighted = 0

    private struct Row: Identifiable {
        let id = UUID()
        let group: String
        let symbol: String
        let title: String
        let subtitle: String
    }

    private var corpus: [Row] {
        [
            Row(group: ReleaseNotes.string("논문", "Papers"), symbol: "doc.text",
                title: "OpenVLA: An Open-Source Vision-Language-Action Model",
                subtitle: "Kim, Pertsch, Karamcheti · 2024"),
            Row(group: ReleaseNotes.string("논문", "Papers"), symbol: "doc.text",
                title: "V-JEPA 2: Self-Supervised Video Models",
                subtitle: "Assran, Bardes, LeCun · 2025"),
            Row(group: ReleaseNotes.string("논문", "Papers"), symbol: "doc.text",
                title: "Attention Is All You Need",
                subtitle: "Vaswani, Shazeer, Parmar · 2017"),
            Row(group: ReleaseNotes.string("노트", "Notes"), symbol: "note.text",
                title: ReleaseNotes.string("행동 표현은 어디서 오는가", "Where action representations come from"),
                subtitle: ReleaseNotes.string("OpenVLA를 읽다가", "while reading OpenVLA")),
            Row(group: ReleaseNotes.string("저자", "Authors"), symbol: "person",
                title: "Sergey Levine",
                subtitle: ReleaseNotes.string("논문 3편", "3 papers")),
            Row(group: ReleaseNotes.string("컬렉션", "Collections"), symbol: "folder",
                title: "Vision Language Action",
                subtitle: ReleaseNotes.string("논문 4편", "4 papers")),
            Row(group: ReleaseNotes.string("태그", "Tags"), symbol: "number",
                title: "#robotics",
                subtitle: ReleaseNotes.string("논문 6편 · 노트 2개", "6 papers · 2 notes")),
            Row(group: ReleaseNotes.string("명령", "Actions"), symbol: "square.and.arrow.down",
                title: ReleaseNotes.string("논문 추가…", "Add Papers…"),
                subtitle: app.shortcut(for: .addPapers).display),
        ]
    }

    private var matches: [Row] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return corpus }
        return corpus.filter {
            $0.title.lowercased().contains(needle) || $0.subtitle.lowercased().contains(needle)
        }
    }

    /// The matches in their groups, in the palette's own order, each row
    /// carrying its place in the flat list so one highlight runs through all
    /// of them.
    private var grouped: [(name: String, rows: [(offset: Int, row: Row)])] {
        var order: [String] = []
        var byGroup: [String: [(Int, Row)]] = [:]
        for (offset, row) in matches.enumerated() {
            if byGroup[row.group] == nil { order.append(row.group) }
            byGroup[row.group, default: []].append((offset, row))
        }
        return order.map { (name: $0, rows: byGroup[$0]!.map { (offset: $0.0, row: $0.1) }) }
    }

    var body: some View {
        VStack(spacing: 0) {
            field
            if !matches.isEmpty {
                Divider()
                results
            }
        }
        .background(
            RoundedRectangle(cornerRadius: scale.isFull ? Corner.panel : Corner.popover, style: .continuous)
                .fill(.background)
        )
        .clipShape(
            RoundedRectangle(cornerRadius: scale.isFull ? Corner.panel : Corner.popover, style: .continuous)
        )
        .shadow(color: .black.opacity(0.12), radius: scale.isFull ? 14 : 6, y: scale.isFull ? 5 : 2)
        .onChange(of: query) { _, _ in highlighted = 0 }
    }

    private var field: some View {
        HStack(spacing: scale.isFull ? 12 : 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: scale.isFull ? 20 : 13))
                .foregroundStyle(.secondary)
            TextField(ReleaseNotes.string("Paper Time 검색", "Paper Time Search"), text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: scale.isFull ? 20 : 13))
            Text(app.shortcut(for: .searchEverything).display)
                .font(scale.small)
                .monospaced()
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, scale.isFull ? 16 : 10)
        .padding(.vertical, scale.isFull ? 12 : 7)
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(grouped, id: \.name) { group in
                Text(group.name.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, scale.isFull ? 16 : 10)
                    .padding(.top, scale.isFull ? 10 : 7)
                    .padding(.bottom, 3)

                ForEach(group.rows, id: \.offset) { entry in
                    row(entry.row, isHighlighted: entry.offset == highlighted)
                        .onHover { if $0 { highlighted = entry.offset } }
                        .onTapGesture { highlighted = entry.offset }
                }
            }
        }
        .padding(.bottom, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ row: Row, isHighlighted: Bool) -> some View {
        HStack(spacing: scale.isFull ? 11 : 8) {
            Image(systemName: row.symbol)
                .font(.system(size: scale.isFull ? 14 : 11))
                .frame(width: scale.isFull ? 20 : 15)
                .foregroundStyle(isHighlighted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            VStack(alignment: .leading, spacing: 0) {
                Text(row.title)
                    .font(scale.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(row.subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, scale.isFull ? 10 : 7)
        .frame(height: scale.isFull ? 38 : 28)
        .background(
            RoundedRectangle(cornerRadius: Corner.row, style: .continuous)
                .fill(isHighlighted ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(.clear))
        )
        .padding(.horizontal, scale.isFull ? 6 : 4)
        .contentShape(.rect)
    }
}
