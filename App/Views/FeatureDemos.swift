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
            case .book: BookDemo(scale: scale)
            case .bookReading: BookReadingDemo(scale: scale)
            case .focus: FocusDemo(scale: scale)
            case .resonance: ResonanceDemo(scale: scale)
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
        VStack(alignment: .leading, spacing: scale.gap) {
            comparison
            HStack(alignment: .top, spacing: scale.gap) {
                page
                list
                    .frame(width: scale.isFull ? 200 : 132)
            }
            .frame(height: scale.isFull ? 230 : 116)
        }
    }

    // MARK: The same line, marked twice

    /// One highlighted line with a formula in it, drawn as every other PDF
    /// app draws it and as this one does.
    ///
    /// The other apps paint the rectangle PDFKit reports, square-cornered and
    /// as tall as the line — and a line carrying a sum with its limits is two
    /// or three times the height of its words, so the box swallows the lines
    /// above and below. Here the ink of the letters is measured and the band
    /// covers just that, rounded at the ends, with the tall glyphs poking
    /// out of it the way they poke out of a stroke drawn by hand.
    private var comparison: some View {
        VStack(alignment: .leading, spacing: scale.isFull ? 6 : 4) {
            HStack(alignment: .top, spacing: scale.gap) {
                sample(ours: false)
                sample(ours: true)
            }
            Text(ReleaseNotes.string(
                "수식이 든 줄: 저쪽은 상자가 줄 높이만큼 자라고 모서리가 각지다. 이쪽은 글자에 딱 맞고 끝이 둥글다 — 사람이 그은 것처럼.",
                "A line with a formula: there, the box grows to the line's height and its corners are square. Here it fits the letters and its ends are round — the way a hand draws it."
            ))
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sample(ours: Bool) -> some View {
        VStack(alignment: .leading, spacing: scale.isFull ? 6 : 4) {
            Text(ours ? "Paper Time" : ReleaseNotes.string("다른 PDF 앱", "Other PDF apps"))
                .font(scale.small.weight(ours ? .semibold : .regular))
                .foregroundStyle(ours ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(ours ? AnyShapeStyle(.tint.opacity(0.14)) : AnyShapeStyle(.quaternary)))
            Paper(scale: scale) {
                VStack(alignment: .leading, spacing: scale.isFull ? 7 : 5) {
                    Rule()
                    markedFormula(ours: ours)
                    Rule(width: scale.isFull ? 120 : 70)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// The line, set the way a page sets it: words, then a sum with its
    /// limits above and below, then words. Marked square and tall on the
    /// left, round and fitted on the right.
    private func markedFormula(ours: Bool) -> some View {
        let size: CGFloat = scale.isFull ? 13 : 10
        return formula(size: size)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 3)
            .background {
                if ours {
                    // The words' ink and a hair of margin, as `LineMetrics` measures it.
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .fill(Color.yellow.opacity(0.32))
                        .frame(height: size * 1.2)
                        .offset(y: size * 0.02)
                } else {
                    Rectangle().fill(Color.yellow.opacity(0.55))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func formula(size: CGFloat) -> Text {
        let body = Font.system(size: size, design: .serif)
        let math = Font.system(size: size, design: .serif).italic()
        let sum = Font.system(size: size * 1.6, design: .serif)
        let limit = Font.system(size: size * 0.6, design: .serif)
        let runs: [Text] = [
            Text(ReleaseNotes.string("총 손실 ", "the total loss ")).font(body),
            Text("∑").font(sum).baselineOffset(-size * 0.2),
            Text("n").font(limit).baselineOffset(size * 0.9),
            Text("i=1").font(limit).baselineOffset(-size * 0.55),
            Text(" ℓ").font(math),
            Text("i").font(limit).baselineOffset(-size * 0.25),
            Text(ReleaseNotes.string("을 최소화한다", " over all tasks")).font(body),
        ]
        return runs.dropFirst().reduce(runs[0]) { $0 + $1 }
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

// MARK: - Layouts

/// The three ways to lay the paper out, switched with their keys.
///
/// Shown as the switch itself: ⌘1, ⌘2, ⌘3 as buttons, and the little window
/// rearranging as each is pressed — a column of pages scrolling, one page on
/// its own, two facing pages you turn with the arrows. What each layout *is*
/// is obvious the moment it is seen next to the other two, and not before.
private struct BookDemo: View {
    let scale: DemoScale
    @Environment(AppModel.self) private var app

    private enum Layout: CaseIterable { case continuous, single, book }
    @State private var layout: Layout = .book
    @State private var leftPage = 4

    var body: some View {
        VStack(alignment: .leading, spacing: scale.gap) {
            ZStack {
                switch layout {
                case .continuous: continuous.transition(.opacity)
                case .single: single.transition(.opacity)
                case .book: book.transition(.opacity)
                }
            }
            .frame(height: scale.isFull ? 190 : 84)
            .frame(maxWidth: .infinity)
            .padding(scale.isFull ? 10 : 6)
            .background(
                // A book is one white field; the scrolling layouts show their
                // pages on the window's ground.
                RoundedRectangle(cornerRadius: scale.corner, style: .continuous)
                    .fill(layout == .book ? AnyShapeStyle(.background) : AnyShapeStyle(.quaternary.opacity(0.35)))
            )
            .clipShape(RoundedRectangle(cornerRadius: scale.corner, style: .continuous))

            HStack(spacing: 6) {
                key(.layoutContinuous, ReleaseNotes.string("연속", "Continuous"), .continuous)
                key(.layoutSinglePage, ReleaseNotes.string("한 장", "Single"), .single)
                key(.layoutBook, ReleaseNotes.string("책", "Book"), .book)
                Spacer(minLength: 0)
                if layout == .book {
                    turn("arrow.left", by: -2, enabled: leftPage > 1)
                    turn("arrow.right", by: 2, enabled: leftPage + 2 < 48)
                    Text(ReleaseNotes.string("\(leftPage)–\(leftPage + 1) / 48", "\(leftPage)–\(leftPage + 1) / 48"))
                        .font(scale.small)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// A key and its name, lit when it is the layout showing.
    private func key(_ action: ShortcutAction, _ name: String, _ target: Layout) -> some View {
        let isOn = layout == target
        return Button {
            withAnimation(.snappy(duration: 0.3)) { layout = target }
        } label: {
            HStack(spacing: 4) {
                Text(app.shortcut(for: action).display).monospaced()
                Text(name)
            }
            .font(scale.small.weight(isOn ? .semibold : .regular))
            .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(isOn ? AnyShapeStyle(.tint.opacity(0.14)) : AnyShapeStyle(.quaternary)))
        }
        .buttonStyle(.plain)
    }

    /// A column of pages, the middle one whole, the ones above and below cut
    /// by the edge — which is what scrolling looks like standing still.
    private var continuous: some View {
        VStack(spacing: scale.isFull ? 8 : 4) {
            page(3).frame(height: scale.isFull ? 60 : 26).clipped()
            page(4)
            page(5).frame(height: scale.isFull ? 60 : 26).clipped()
        }
        .frame(width: scale.isFull ? 150 : 66)
        .offset(y: scale.isFull ? -10 : -5)
    }

    private var single: some View {
        page(4).frame(width: scale.isFull ? 150 : 66)
    }

    /// The spread as the app draws it: cropped to the text, one white field.
    private var book: some View {
        Spread(scale: scale, leftPage: leftPage, trimmed: true, lines: 12)
            .frame(maxWidth: .infinity)
    }

    /// A page of greeked text, its number at the foot, the lines seeded by
    /// the number so turning the page changes what is on it.
    private func page(_ number: Int) -> some View {
        VStack(alignment: .leading, spacing: scale.isFull ? 6 : 3) {
            ForEach(0..<(scale.isFull ? 12 : 6), id: \.self) { line in
                Rule(width: ((number * 7 + line * 13) % 5 == 0) ? 60 : nil)
            }
            Spacer(minLength: 0)
            Text("\(number)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
        }
        .padding(scale.isFull ? 12 : 7)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 3, style: .continuous).fill(.background)
        )
        .id(number)
    }

    private func turn(_ symbol: String, by delta: Int, enabled: Bool) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.25)) { leftPage += delta }
        } label: {
            Image(systemName: symbol)
                .font(scale.small.weight(.medium))
                .frame(width: 26, height: 20)
                .background(Capsule().fill(.quaternary))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}

// MARK: - Focus

/// The window, and the window with everything but the paper gone.
///
/// Drawn as the window rather than as four grey blocks: a sidebar with its
/// rows, a list with its titles, a paper with a heading, an inspector with its
/// fields. Then ⇧⌘F, and the three of them slide away and the paper takes the
/// width — which is the whole of what Focus does, and it only reads as that
/// when what leaves looked like something.
private struct FocusDemo: View {
    let scale: DemoScale
    @Environment(AppModel.self) private var app
    @State private var isFocused = false

    var body: some View {
        VStack(alignment: .leading, spacing: scale.gap) {
            VStack(spacing: 0) {
                // A titlebar, so it is a window.
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle().fill(.quaternary).frame(width: 6, height: 6)
                    }
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)

                HStack(spacing: scale.isFull ? 6 : 3) {
                    if !isFocused {
                        sidebar.transition(.move(edge: .leading).combined(with: .opacity))
                        list.transition(.move(edge: .leading).combined(with: .opacity))
                    }
                    paper
                    if !isFocused {
                        inspector.transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
            .frame(height: scale.isFull ? 170 : 74)
            .background(
                RoundedRectangle(cornerRadius: scale.corner, style: .continuous)
                    .fill(.quaternary.opacity(0.35))
            )
            .clipShape(RoundedRectangle(cornerRadius: scale.corner, style: .continuous))

            HStack(spacing: 8) {
                Button {
                    withAnimation(.snappy(duration: 0.32)) { isFocused.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Text(app.shortcut(for: .focus).display).monospaced()
                        Text(isFocused
                             ? ReleaseNotes.string("돌아오기", "Leave Focus")
                             : ReleaseNotes.string("논문에 집중", "Focus on the Paper"))
                    }
                    .font(scale.small.weight(.medium))
                    .foregroundStyle(isFocused ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(isFocused ? AnyShapeStyle(.tint.opacity(0.14)) : AnyShapeStyle(.quaternary)))
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
                if scale.isFull {
                    Text(isFocused
                         ? ReleaseNotes.string("사이드바·목록·인스펙터가 비켜섰다. 다시 누르면 그대로 돌아온다.", "Sidebar, list and inspector stepped aside. Press again and they come back as they were.")
                         : ReleaseNotes.string("네 패널이 다 보인다. 눌러 보라.", "All four panes. Press it."))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: scale.isFull ? 6 : 3) {
            ForEach(0..<(scale.isFull ? 6 : 3), id: \.self) { row in
                HStack(spacing: 4) {
                    Circle().fill(.quaternary).frame(width: 5, height: 5)
                    Rule(width: row == 0 ? 34 : 26)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(scale.isFull ? 8 : 5)
        .frame(width: scale.isFull ? 62 : 30, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.quaternary.opacity(0.7)))
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: scale.isFull ? 7 : 4) {
            ForEach(0..<(scale.isFull ? 4 : 2), id: \.self) { row in
                VStack(alignment: .leading, spacing: 2) {
                    Rule(width: row == 1 ? 50 : 66)
                    Rule(width: 30).opacity(0.6)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(scale.isFull ? 8 : 5)
        .frame(width: scale.isFull ? 92 : 44, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.quaternary.opacity(0.7)))
    }

    private var paper: some View {
        VStack(alignment: .leading, spacing: scale.isFull ? 6 : 3) {
            Capsule().fill(.secondary.opacity(0.5)).frame(width: scale.isFull ? 90 : 40, height: 3)
            ForEach(0..<(scale.isFull ? 9 : 4), id: \.self) { line in
                Rule(width: line == 4 ? 70 : nil)
            }
            Spacer(minLength: 0)
        }
        .padding(scale.isFull ? 12 : 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.background))
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: scale.isFull ? 7 : 4) {
            ForEach(0..<(scale.isFull ? 5 : 2), id: \.self) { _ in
                HStack { Rule(width: 22); Spacer(minLength: 0); Rule(width: 18).opacity(0.6) }
            }
            Spacer(minLength: 0)
        }
        .padding(scale.isFull ? 8 : 5)
        .frame(width: scale.isFull ? 80 : 40, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.quaternary.opacity(0.7)))
    }
}

// MARK: - Reading a book

/// The spread with what a book gives you: which pages, how far in, and the
/// contents floating in the gutter to jump by section.
/// Two facing pages, drawn the way this app shows them — or the way every
/// other PDF app does.
///
/// Other apps put the PDF's two pages side by side as they come: each paper
/// brings its own margins, a two-sided journal shifts its text toward the
/// spine, the stamp arXiv runs up the margin stays, and PDFKit's spread is
/// wider than the window so it sits wherever the last scroll left it. Here
/// each page is cropped to its text, so the words stand the same distance
/// from the middle on both sides and the gutter is the same width for every
/// paper; there are no page edges to see, just one white field, and the
/// stamp is painted out.
private struct Spread: View {
    let scale: DemoScale
    let leftPage: Int
    /// Cropped to the text, as this app does it; otherwise as the pages come.
    let trimmed: Bool
    var lines: Int = 11

    var body: some View {
        // The gutter as the app makes it: wide enough for the contents to
        // sit in with room to spare, and the same for every paper.
        HStack(spacing: trimmed ? Self.gutter(scale) : (scale.isFull ? 4 : 2)) {
            sheet(leftPage, leading: trimmed ? margin : outer, trailing: trimmed ? margin : inner)
                .overlay(alignment: .leading) { if !trimmed { stamp } }
            sheet(leftPage + 1, leading: trimmed ? margin : inner, trailing: trimmed ? margin : outer)
        }
        .offset(x: trimmed ? 0 : -(scale.isFull ? 18 : 8))
        .animation(.snappy(duration: 0.35), value: trimmed)
    }

    static func gutter(_ scale: DemoScale) -> CGFloat { scale.isFull ? 124 : 66 }

    private var margin: CGFloat { scale.isFull ? 10 : 5 }
    private var outer: CGFloat { scale.isFull ? 34 : 15 }
    private var inner: CGFloat { scale.isFull ? 8 : 4 }

    private func sheet(_ number: Int, leading: CGFloat, trailing: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: scale.isFull ? 6 : 3) {
            ForEach(0..<(scale.isFull ? lines : 5), id: \.self) { line in
                Rule(width: ((number * 7 + line * 13) % 5 == 0) ? 60 : nil)
            }
            Spacer(minLength: 0)
            Text("\(number)").font(.caption2).foregroundStyle(.tertiary).frame(maxWidth: .infinity)
        }
        .padding(.vertical, scale.isFull ? 12 : 7)
        .padding(.leading, leading)
        .padding(.trailing, trailing)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(.background)
                .shadow(color: .black.opacity(trimmed ? 0 : 0.14), radius: 3, y: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .id(number)
    }

    /// The stamp up the margin, as the PDF prints it.
    private var stamp: some View {
        Text("arXiv:2410.24164v1  [cs.RO]  31 Oct 2024")
            .font(.system(size: scale.isFull ? 7 : 4.5, design: .monospaced))
            .foregroundStyle(.secondary.opacity(0.7))
            .fixedSize()
            .rotationEffect(.degrees(-90))
            .frame(width: scale.isFull ? 10 : 6)
            .offset(x: scale.isFull ? 12 : 5)
            .transition(.opacity)
    }
}

private struct BookReadingDemo: View {
    let scale: DemoScale
    @Environment(AppModel.self) private var app
    @State private var leftPage = 3
    @State private var showsContents: Bool
    /// Cropped to the text, as here; or as every other app shows it.
    @State private var trimmed: Bool

    init(scale: DemoScale, trimmed: Bool = true, showsContents: Bool = true) {
        self.scale = scale
        _trimmed = State(initialValue: trimmed)
        _showsContents = State(initialValue: showsContents)
    }

    private let total = 48
    private var sections: [(String, Int)] {
        [
            (ReleaseNotes.string("서론", "Introduction"), 1),
            (ReleaseNotes.string("방법", "Method"), 5),
            (ReleaseNotes.string("실험", "Experiments"), 11),
            (ReleaseNotes.string("결과", "Results"), 19),
            (ReleaseNotes.string("결론", "Conclusion"), 27),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: scale.gap) {
            VStack(spacing: 0) {
                ZStack {
                    Spread(scale: scale, leftPage: leftPage, trimmed: trimmed)
                        .padding(scale.isFull ? 10 : 6)

                    // Only on this side: no other reader floats a contents
                    // list in the gutter, which is the point of the switch.
                    if showsContents && trimmed { contents.transition(.scale(scale: 0.96).combined(with: .opacity)) }
                }
                // Tall enough for the contents to sit inside the spread at
                // the small size too, rather than over the status bar.
                .frame(height: scale.isFull ? 190 : 118)

                // The status bar: both pages of the spread, and how far in.
                HStack(spacing: 8) {
                    Text(ReleaseNotes.string("\(leftPage)–\(leftPage + 1) / \(total)쪽", "Pages \(leftPage)–\(leftPage + 1) of \(total)"))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    ProgressView(value: Double(leftPage + 1), total: Double(total))
                        .progressViewStyle(.linear)
                        .tint(.secondary.opacity(0.6))
                        .frame(width: scale.isFull ? 90 : 50)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, scale.isFull ? 10 : 6)
                .padding(.vertical, 5)
                .background(.background.opacity(0.6))
            }
            .background(
                // One white field when the pages are cropped — the book is
                // the field, not two cards on a ground. A grey ground when
                // they are not, which is what shows their edges.
                RoundedRectangle(cornerRadius: scale.corner, style: .continuous)
                    .fill(trimmed ? AnyShapeStyle(.background) : AnyShapeStyle(.quaternary.opacity(0.35)))
            )
            // No clip on the stage: the contents float over the pages, and a
            // clip was cutting the top and bottom off the floating list.

            HStack(spacing: 6) {
                turn("arrow.left", by: -2, enabled: leftPage > 1)
                turn("arrow.right", by: 2, enabled: leftPage + 2 < total)
                Text("space")
                    .font(scale.small).monospaced()
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.quaternary.opacity(0.6)))
                Spacer(minLength: 0)
                let contentsShowing = showsContents && trimmed
                Button {
                    withAnimation(.snappy(duration: 0.25)) { showsContents.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Text(app.shortcut(for: .floatingList).display).monospaced()
                        Text(ReleaseNotes.string("목차", "Contents"))
                    }
                    .font(scale.small.weight(contentsShowing ? .semibold : .regular))
                    .foregroundStyle(contentsShowing ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(contentsShowing ? AnyShapeStyle(.tint.opacity(0.14)) : AnyShapeStyle(.quaternary)))
                }
                .buttonStyle(.plain)
                // There is no such key in the other readers.
                .disabled(!trimmed)
                .opacity(trimmed ? 1 : 0.4)
            }

            // The same spread as other apps show it, and as this one does.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                mode(ReleaseNotes.string("다른 PDF 앱", "Other PDF apps"), trimmed: false)
                mode("Paper Time", trimmed: true)
                Text(trimmed
                    ? ReleaseNotes.string("글에 맞춰 잘라 좌우 여백이 같고, 두 쪽 사이는 어떤 논문이든 같은 폭. 도장은 지우고, 목차는 그 사이에 뜬다.",
                                          "Cropped to the text: equal margins both sides, a gutter the same width for every paper. The stamp is painted out; the contents float in between.")
                    : ReleaseNotes.string("쪽을 그대로 나란히: 논문마다 여백이 다르고, 두 쪽은 붙거나 벌어지고, 펼침면은 한쪽으로 몰리고, 여백의 도장이 보인다. 사이에 목차를 띄울 자리도 없다.",
                                          "The pages as they come: margins differ by paper, the two pages meet or gape, the spread sits to one side, and the stamp shows. There is no room between them for a contents list, either."))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func mode(_ name: String, trimmed target: Bool) -> some View {
        let isOn = trimmed == target
        return Button {
            withAnimation(.snappy(duration: 0.35)) { trimmed = target }
        } label: {
            Text(name)
                .font(scale.small.weight(isOn ? .semibold : .regular))
                .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(isOn ? AnyShapeStyle(.tint.opacity(0.14)) : AnyShapeStyle(.quaternary)))
        }
        .buttonStyle(.plain)
    }

    /// The contents, narrow and tall in the gutter. A section is one press;
    /// the list stays until it is put away, because reading by sections
    /// means going to several.
    private var contents: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(ReleaseNotes.string("목차", "Contents"))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
            ForEach(sections, id: \.1) { name, first in
                let isHere = leftPage == first - (first - 1) % 2
                Button {
                    withAnimation(.snappy(duration: 0.25)) { leftPage = first - (first - 1) % 2 }
                } label: {
                    HStack {
                        Text(name).font(scale.small).lineLimit(1)
                        Spacer(minLength: 4)
                        Text("\(first)").font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
                    }
                    .foregroundStyle(isHere ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .padding(.horizontal, 6).padding(.vertical, scale.isFull ? 3 : 1)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.accentColor.opacity(isHere ? 0.12 : 0))
                    )
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(scale.isFull ? 8 : 5)
        // Narrower than the gutter by a margin either side, as in the app.
        .frame(width: Spread.gutter(scale) - (scale.isFull ? 16 : 8))
        .background(
            RoundedRectangle(cornerRadius: scale.corner, style: .continuous)
                .fill(.background)
                .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
        )
        .fixedSize(horizontal: false, vertical: true)
    }

    private func turn(_ symbol: String, by delta: Int, enabled: Bool) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.25)) { leftPage += delta }
        } label: {
            Image(systemName: symbol)
                .font(scale.small.weight(.medium))
                .frame(width: 26, height: 20)
                .background(Capsule().fill(.quaternary))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}

// MARK: - Resonance

/// Resonance, learned by doing it: four steps, each a real press.
///
/// A feature nobody has seen before cannot be shown all at once — it has
/// to be done once. So this is the reading surface and the inspector's
/// Notes tab side by side, and a line underneath saying what to do next:
/// turn the page, and the notes that echo it come up; select a sentence, and
/// the ❝ button appears on each; press it, and the passage lands in that
/// note with its address; and under the note, press the link, and two notes
/// that never mentioned each other now do. Every step is the gesture the
/// app itself uses.
private struct ResonanceDemo: View {
    let scale: DemoScale
    /// 0: reading. 1: the echoes are up. 2: a sentence is selected. 3: the
    /// passage is in the note. 4: the link is written.
    @State private var step: Int
    @State private var page = 0
    @State private var openNote: Int?
    @State private var selected = false
    @State private var dropped = false
    @State private var linked = false
    /// The rule that picks the notes, with its numbers, shown on request.
    @State private var showsRule = false

    init(scale: DemoScale, step: Int = 0, showsRule: Bool = false) {
        _showsRule = State(initialValue: showsRule)
        self.scale = scale
        _step = State(initialValue: step)
        _page = State(initialValue: step >= 1 ? 1 : 0)
        _selected = State(initialValue: step == 2)
        _openNote = State(initialValue: step >= 3 ? 0 : nil)
        _dropped = State(initialValue: step >= 3)
        _linked = State(initialValue: step >= 4)
    }

    private struct Echo {
        let title: String
        let source: String
        let shared: [String]
        let body: [String]
    }

    private var sentences: [String] {
        [
            ReleaseNotes.string("우리는 로봇 정책을 위한 사전 학습 데이터셋을 소개한다.", "We introduce a pretraining dataset for robot policies."),
            ReleaseNotes.string("EWC는 옛 과제에 중요한 가중치의 학습을 늦춰 — 시냅스 강화가 기억을 지키듯 — 파국적 망각을 막는다.",
                                "EWC slows learning on the weights important for old tasks — the way synaptic consolidation protects a memory — and so avoids catastrophic forgetting."),
        ]
    }

    private var echoes: [Echo] {
        [
            Echo(title: ReleaseNotes.string("시냅스 강화는 기억을 굳힌다", "Synaptic consolidation hardens a memory"),
                 source: ReleaseNotes.string("Yang 외 2009에서 씀", "Written against Yang et al. 2009"),
                 shared: [ReleaseNotes.string("시냅스 강화", "synaptic consolidation"), ReleaseNotes.string("기억", "memory")],
                 body: [ReleaseNotes.string("새 가시는 며칠 지나면 굳고, 굳은 가시는 지워지지 않는다.", "New spines harden within days; a hardened spine is not erased."),
                        ReleaseNotes.string("기억이 지켜지는 방식은 '쓰지 않기'다.", "A memory is kept by not being written over.")]),
            Echo(title: ReleaseNotes.string("망각은 겹쳐 쓰기다", "Forgetting is overwriting"),
                 source: ReleaseNotes.string("McCloskey 1989에서 씀", "Written against McCloskey 1989"),
                 shared: [ReleaseNotes.string("파국적 망각", "catastrophic forgetting"), ReleaseNotes.string("가중치", "weights")],
                 body: [ReleaseNotes.string("새 과제가 옛 과제의 가중치를 덮어쓴다.", "The new task writes over the old task's weights.")]),
        ]
    }

    private var instructions: [String] {
        [
            ReleaseNotes.string("논문을 읽는 중이에요. →로 장을 넘겨 보세요.", "You are reading. Turn the page with →."),
            ReleaseNotes.string("다른 논문을 읽다 쓴 노트 둘이 올라왔어요 — 이 쪽과 파란 낱말을 나누는 노트예요. 이번엔 쪽의 문장을 눌러 선택해 보세요.",
                                "Two notes came up, written against other papers — they share the blue words with this page. Now click the sentence on the page to select it."),
            ReleaseNotes.string("노트마다 ❝ 단추가 생겼어요. 눌러서 선택한 구절을 그 노트에 떨어뜨리세요.",
                                "Each note grew a ❝ button. Press one to drop the selected passage into that note."),
            ReleaseNotes.string("구절이 주소를 갖고 들어갔어요 — 누르면 이 쪽으로 돌아와요. 아래 'RESONATES WITH'에서 🔗를 눌러 다른 울림을 링크로 만드세요.",
                                "The passage is in, with its address — click it and you are back on this page. Under RESONATES WITH, press the link to make the other echo a link."),
            ReleaseNotes.string("두 논문의 구절이 노트 하나에서 만나고, 두 노트가 서로를 가리켜요. 다른 앱이었다면 그 노트가 있다는 걸 기억해 검색하고, 열어 복사해 붙여야 했을 일이에요.",
                                "Passages from two papers meet in one note, and two notes now point at each other. In another app you would have had to remember the note existed, search for it, open it, and paste."),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: scale.gap) {
            HStack(alignment: .top, spacing: scale.gap) {
                paper
                inspector
                    .frame(width: scale.isFull ? 250 : 168)
            }
            .frame(height: scale.isFull ? 224 : 168)

            guidance
            if showsRule { rule.transition(.opacity.combined(with: .move(edge: .top))) }
        }
        .animation(.snappy(duration: 0.3), value: showsRule)
    }

    /// How the notes are chosen, in numbers — a reading friend who has your
    /// notes by heart, and the arithmetic the friend does.
    private var rule: some View {
        VStack(alignment: .leading, spacing: scale.isFull ? 6 : 4) {
            Text(ReleaseNotes.string("어떻게 고르나", "How the notes are chosen"))
                .font(scale.small.weight(.semibold))
            Text(ReleaseNotes.string(
                "네 노트를 전부 외운 읽기 친구가 있다고 생각하면 된다. 장을 넘기면 친구가 새 쪽의 낱말과 노트 하나하나의 낱말을 나란히 놓고 같은 것을 센다 — 다만 이렇게 센다:",
                "Think of a reading friend who knows your notes by heart. When you turn the page, the friend lays the page's words beside each note's and counts what they share — counting like this:"
            ))
            ForEach(rules, id: \.self) { line in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("·").foregroundStyle(.tertiary)
                    Text(line).fixedSize(horizontal: false, vertical: true)
                }
            }
            Text(ReleaseNotes.string(
                "점수 = Σ 무게 × 짝 보너스 × √min(횟수) ÷ (1 + ln 노트 길이).  겹친 낱말이 둘 이상(짝이면 하나)이고, 점수가 1.0 이상이며 1등의 35% 이상인 노트만, 많아도 넷.",
                "score = Σ weight × pair bonus × √min(count) ÷ (1 + ln note length).  Only notes sharing two words (or one pair), scoring 1.0 or more and at least 35% of the strongest — four at most."
            ))
            .font(scale.small.monospaced())
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .font(scale.small)
        .padding(scale.isFull ? 10 : 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: scale.corner, style: .continuous).fill(.background))
    }

    private var rules: [String] {
        [
            ReleaseNotes.string("흔한 말은 세지 않는다: 기능어와 논문마다 쓰는 말(model, method, results, training, data…) 300개쯤은 겹쳐도 0.",
                                "Common words are not counted: function words and the words every paper uses (model, method, results, training, data…), some 300, count for nothing."),
            ReleaseNotes.string("낱말 하나의 무게 = ln((N+1) ÷ (그 낱말이 나오는 글 수 + 0.5)) + 0.3. N은 노트 수 + 이 논문에서 뽑은 40쪽. 45개 글 중 42개에 나오는 'network'는 0.38, 3개에만 나오는 'consolidation'은 2.88 — 드문 말이 일곱 배.",
                                "A word's weight = ln((N+1) ÷ (texts it appears in + 0.5)) + 0.3, with N = notes + 40 sampled pages of this paper. 'network', in 42 of 45 texts: 0.38. 'consolidation', in 3: 2.88 — seven times as much."),
            ReleaseNotes.string("두 낱말이 붙어서 겹치면('catastrophic forgetting') ×1.3. weights와 weight, pretrained와 pretraining은 같은 말로 본다.",
                                "Two words together ('catastrophic forgetting') count ×1.3. weights and weight, pretrained and pretraining are one word."),
            ReleaseNotes.string("긴 노트는 우연히 더 겹치니 (1 + ln 길이)로 나눈다. 다섯 줄이든 다섯 낱말이든 짧은 노트는 같은 길이로 친다.",
                                "A long note shares more by chance, so its sum is divided by (1 + ln length); anything short is treated as the same short length."),
        ]
    }

    // MARK: The page

    private var paper: some View {
        Paper(scale: scale) {
            VStack(alignment: .leading, spacing: scale.isFull ? 7 : 5) {
                Rule()
                Rule(width: scale.isFull ? 160 : 80)
                sentence
                Rule()
                Rule()
                Rule(width: scale.isFull ? 120 : 60)
                Spacer(minLength: 0)
                Text("\(page + 3)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// The sentence being read. From the second step on it can be selected
    /// with a press, the way a drag selects it on the real page.
    private var sentence: some View {
        Button {
            guard step >= 1 else { return }
            withAnimation(.snappy(duration: 0.25)) {
                selected = true
                if step == 1 { step = 2 }
            }
        } label: {
            Text(sentences[page])
                .font(.system(scale.isFull ? .callout : .caption2, design: .serif))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.accentColor.opacity(selected ? 0.18 : 0))
                )
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .id(page)
        .transition(.opacity)
    }

    // MARK: The inspector

    private var inspector: some View {
        VStack(alignment: .leading, spacing: scale.isFull ? 6 : 4) {
            if let openNote {
                editor(echoes[openNote])
            } else {
                notesTab
            }
        }
        .padding(scale.isFull ? 10 : 7)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: scale.corner, style: .continuous).fill(.background))
        .animation(.snappy(duration: 0.3), value: step)
        .animation(.snappy(duration: 0.3), value: openNote)
    }

    /// The Notes tab: the echoes when there are any, then this paper's own.
    @ViewBuilder
    private var notesTab: some View {
        if step >= 1 {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Label("Resonance", systemImage: "waveform")
                    .font(scale.small.weight(.semibold))
                    .foregroundStyle(.tint)
                if scale.isFull {
                    Text(ReleaseNotes.string("다른 논문에서", "from other papers"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            ForEach(Array(echoes.enumerated()), id: \.offset) { index, echo in
                echoRow(index, echo)
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
        Text(ReleaseNotes.string("이 논문의 노트 0개", "0 notes on this paper"))
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.top, step >= 1 ? 4 : 0)
        Spacer(minLength: 0)
    }

    private func echoRow(_ index: Int, _ echo: Echo) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Button {
                withAnimation(.snappy(duration: 0.3)) { openNote = index }
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(echo.title)
                        .font(scale.small.weight(.medium))
                        .lineLimit(1)
                    Text(echo.source)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(echo.shared.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.tint)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            // The ❝: only once there is a selection to drop, as in the app.
            if selected, !dropped {
                Button {
                    withAnimation(.snappy(duration: 0.3)) {
                        openNote = index
                        dropped = true
                        selected = false
                        if step < 3 { step = 3 }
                    }
                } label: {
                    Image(systemName: "quote.opening")
                        .font(scale.small)
                        .foregroundStyle(.tint)
                        .padding(4)
                        .background(Circle().fill(Color.accentColor.opacity(0.14)))
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.accentColor.opacity(0.07))
        )
    }

    /// The note, open: its title, its lines, the passage once it has landed,
    /// and underneath what it resonates with — with the link to press.
    private func editor(_ echo: Echo) -> some View {
        let other = echoes[openNote == 0 ? 1 : 0]
        return VStack(alignment: .leading, spacing: scale.isFull ? 6 : 4) {
            Button {
                withAnimation(.snappy(duration: 0.3)) { openNote = nil }
            } label: {
                Label("Notes", systemImage: "chevron.left")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            Text(echo.title)
                .font(scale.small.weight(.semibold))
                .lineLimit(1)
            ForEach(echo.body, id: \.self) { line in
                Text(line)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if dropped {
                // The passage as a chip: the shape everything you can go
                // to takes in this app.
                HStack(spacing: 4) {
                    Image(systemName: "quote.opening")
                        .font(.caption2)
                    Text(sentences[page])
                        .lineLimit(1)
                }
                .font(.caption2)
                .foregroundStyle(.tint)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.accentColor.opacity(0.12)))
                .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
            if linked {
                Text("[[\(other.title)]]")
                    .font(.caption2)
                    .foregroundStyle(.tint)
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
            if !linked {
                Text("RESONATES WITH")
                    .font(.system(size: 8, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.tertiary)
                HStack(spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "waveform")
                            .foregroundStyle(.tint)
                        Text(other.title).lineLimit(1)
                    }
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.quaternary.opacity(0.55)))
                    Button {
                        withAnimation(.snappy(duration: 0.3)) {
                            linked = true
                            if step < 4 { step = 4 }
                        }
                    } label: {
                        Image(systemName: "link.badge.plus")
                            .font(.caption2)
                            .foregroundStyle(.tint)
                            .padding(4)
                            .background(Circle().fill(Color.accentColor.opacity(0.14)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: What to do next

    private var guidance: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                // Where you are in the four steps.
                ForEach(0..<4, id: \.self) { index in
                    Text("\(index + 1)")
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(index < step ? Color.accentColor : (index == step ? Color.accentColor.opacity(0.14) : Color.clear)))
                        .overlay(Circle().stroke(index == step ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: 1))
                        .foregroundStyle(index < step ? AnyShapeStyle(.white) : (index == step ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary)))
                }
                if step == 0 {
                    Button {
                        withAnimation(.snappy(duration: 0.3)) {
                            page = 1
                            step = 1
                        }
                    } label: {
                        Image(systemName: "arrow.right")
                            .font(scale.small.weight(.medium))
                            .frame(width: 26, height: 20)
                            .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                            .foregroundStyle(.tint)
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
                Button {
                    withAnimation(.snappy(duration: 0.3)) { showsRule.toggle() }
                } label: {
                    Label(ReleaseNotes.string("어떻게 고르나?", "How are they chosen?"), systemImage: "function")
                        .font(.caption2.weight(showsRule ? .semibold : .regular))
                        .foregroundStyle(showsRule ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.plain)
                if step >= 1 {
                    Button {
                        withAnimation(.snappy(duration: 0.3)) {
                            step = 0; page = 0; openNote = nil; selected = false; dropped = false; linked = false
                        }
                    } label: {
                        Label(ReleaseNotes.string("처음부터", "Start over"), systemImage: "arrow.counterclockwise")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            Text(instructions[min(step, instructions.count - 1)])
                .font(scale.small)
                .foregroundStyle(step == 4 ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
                .id(step)
                .transition(.opacity)
        }
        .animation(.snappy(duration: 0.3), value: step)
    }
}

#if os(macOS)
/// Draws every demo, at both sizes, into PNG files — so they can be looked
/// at without opening a window over whatever the user is doing.
@MainActor
enum DemoRenderer {
    static func render(into directory: String) {
        let model = AppModel()
        let folder = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for demo in ReleaseNotes.Demo.allCases {
            for scale in [DemoScale.compact, .full] {
                let view = FeatureDemoView(demo: demo, scale: scale)
                    .environment(model)
                    .frame(width: scale.isFull ? 560 : 440)
                    .padding(16)
                    .background(Color(nsColor: .windowBackgroundColor))
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiff),
                      let png = bitmap.representation(using: .png, properties: [:])
                else { continue }
                try? png.write(to: folder.appendingPathComponent("\(demo.rawValue)-\(scale.isFull ? "full" : "compact").png"))
            }
        }
        // The states the book demo reaches by a press: as other apps show
        // it, and with the contents floating in the gutter.
        func write(_ name: String, _ view: some View, full: Bool) {
            let renderer = ImageRenderer(content: view
                .environment(model).frame(width: full ? 560 : 440).padding(16).background(Color(nsColor: .windowBackgroundColor)))
            renderer.scale = 2
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
               let png = bitmap.representation(using: .png, properties: [:]) {
                try? png.write(to: folder.appendingPathComponent("\(name).png"))
            }
        }
        write("bookReading-other", BookReadingDemo(scale: .full, trimmed: false, showsContents: false), full: true)
        write("bookReading-contents", BookReadingDemo(scale: .full, trimmed: true, showsContents: true), full: true)
        write("bookReading-contents-compact", BookReadingDemo(scale: .compact, trimmed: true, showsContents: true), full: false)
        // Resonance is learned in steps; each step is a picture.
        for step in 1...4 {
            write("resonance-step\(step)", ResonanceDemo(scale: .full, step: step), full: true)
        }
        write("resonance-step3-compact", ResonanceDemo(scale: .compact, step: 3), full: false)
        write("resonance-rule", ResonanceDemo(scale: .full, step: 4, showsRule: true), full: true)
        exit(0)
    }
}
#endif
