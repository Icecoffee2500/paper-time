import SwiftUI

#if os(macOS)
import AppKit
#endif

/// What this app is, shown rather than described.
///
/// The log gives each feature a sentence and a demonstration the size of a
/// paragraph, because a log is read by somebody checking whether a particular
/// thing moved. This page is read by somebody deciding whether any of it is
/// for them, and for that a sentence is nearly useless: "a passage keeps its
/// address" means nothing until you have sent one and clicked it back. So the
/// demonstrations here are full size and come first, with the prose above them
/// as a caption rather than the other way round.
struct AboutView: View {
    @Environment(AppModel.self) private var app
    @State private var showsReleaseNotes = false
    @State private var showsFeatureLog = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                FeatureShowcase(header: { AboutHeader() })
                together
                footer
            }
            .padding(.horizontal, 26)
            .padding(.top, 26)
            .padding(.bottom, 34)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .sheet(isPresented: $showsReleaseNotes) {
            WhatsNewView(marksAsSeen: false)
        }
        .sheet(isPresented: $showsFeatureLog) {
            VStack(spacing: 0) {
                FeatureLogView()
                Button(ReleaseNotes.string("완료", "Done")) { showsFeatureLog = false }
                    .keyboardShortcut(.defaultAction)
                    .padding(.bottom, 16)
            }
        }
    }

    /// Who asked for what is in this version.
    ///
    /// Baked in at release time rather than fetched, because the app asks no
    /// server for anything and a wall that needed a network call would mostly
    /// be an empty one. Somebody who reported a bug opens this page and finds
    /// their own name inside the app they use — which is the whole reward, and
    /// the right one.
    @ViewBuilder
    private var together: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider().opacity(0.5)

            Text(L("함께 만들고 있어요", "Built together"))
                .font(.headline)

            if Contributors.all.isEmpty {
                Text(L(
                    "아직 아무도 한마디를 보내지 않았어요. \(app.shortcut(for: .feedback).display)를 누르면 화면이 이미 찍힌 채로 창이 열려요.",
                    "Nobody has sent anything yet. Press \(app.shortcut(for: .feedback).display) and the sheet opens with the screenshot already taken."
                ))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(L(
                    "\(Contributors.all.count)명이 \(Contributors.total)가지를 알려줬고, 그 덕분에 고쳐진 것들이 이 버전에 들어 있어요.",
                    "\(Contributors.all.count) people sent \(Contributors.total) reports. What they found is in this version."
                ))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                FlowingNames(people: Contributors.all)
            }

            Button(L("한마디 보내기…", "Send Feedback…")) { app.askForFeedback() }
                .padding(.top, 2)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider().opacity(0.5)

            HStack(spacing: 10) {
                Button(ReleaseNotes.string("환영 화면 다시 보기…", "What's New…")) {
                    showsReleaseNotes = true
                }
                Button(ReleaseNotes.string("모든 기능과 단축키…", "All Features and Keys…")) {
                    showsFeatureLog = true
                }
            }

            Text(ReleaseNotes.string(
                "논문은 이 앱 안이 아니라 직접 고른 폴더에 평범한 파일로 있어요. 노트도 Markdown 파일이고요. 앱을 지워도 읽던 것은 그대로 남아요.",
                "Papers are ordinary files in the folder you chose, not inside this app; notes are Markdown. Delete the app and what you were reading is still there."
            ))
            .font(.footnote)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The feature list, demonstrations and all.
///
/// One view, used twice: on the first run as the welcome, and afterwards in
/// Settings under About. They had drifted — the welcome was a column of
/// sentences while About had the working demos — which meant the introduction
/// was the weaker of the two, and it is the one most people will only see
/// once. Whatever is worth showing somebody on day one is worth leaving where
/// they can find it again, in the same form.
struct FeatureShowcase<Header: View>: View {
    @ViewBuilder var header: Header
    /// Which one is showing. One at a time, because a page of twenty things
    /// is a page nobody reads: the reader is being shown, not indexed.
    @State private var page = 0

    private var features: [ReleaseNotes.Highlight] { ReleaseNotes.highlights }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            HStack(spacing: 6) {
                turner(back: true)
                card
                turner(back: false)
            }
            dots
        }
        // The arrow keys turn the page, because they are what a hand reaches
        // for once it has seen that there is a next one. Focusable so the keys
        // arrive, but without the ring: a ring is drawn round the thing a key
        // will type into, and there is nothing here to type into — it put a
        // blue box round the whole sheet.
        .focusable()
        .focusEffectDisabled()
        .onMoveCommand { direction in
            switch direction {
            case .left: turn(-1)
            case .right: turn(1)
            default: break
            }
        }
    }

    private var current: ReleaseNotes.Highlight? {
        features.indices.contains(page) ? features[page] : features.first
    }

    /// One feature, the way the system shows one: the thing itself, large,
    /// with its name and a sentence underneath — not a row with a picture
    /// beside it.
    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let highlight = current {
                ZStack {
                    // The stage keeps its height across pages, so turning one
                    // does not move the words underneath.
                    Color.clear
                    if let demo = highlight.demo {
                        FeatureDemoView(demo: demo, scale: .full)
                    } else {
                        Image(systemName: highlight.symbol)
                            .font(.system(size: 64, weight: .light))
                            .foregroundStyle(.tint)
                    }
                }
                // One height for every page, the tallest demonstration's, so
                // that turning a page does not move the words underneath it.
                .frame(height: 330)
                .frame(maxWidth: .infinity)

                // Every page's words are laid out here, all but one of them
                // invisible, so the block is exactly as tall as the longest
                // of them. A number in its place (it was 116) is a guess that
                // goes stale the first time somebody writes a longer sentence
                // — and what it did then was let the words run off the bottom
                // of a sheet with a fixed height, under the dots.
                ZStack(alignment: .topLeading) {
                    ForEach(features) { other in
                        words(for: other)
                            .hidden()
                            .accessibilityHidden(true)
                    }
                    words(for: highlight)
                        // The page is replaced rather than redrawn: a new
                        // thing arriving from the side it came from.
                        .id(highlight.id)
                        .transition(.opacity)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.top, 20)
            }
        }
        .padding(26)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: Corner.panel, style: .continuous))
        .animation(Motion.surface, value: page)
    }

    /// What one page says: the kind of change, its name, and the sentence.
    private func words(for highlight: ReleaseNotes.Highlight) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: highlight.tier.symbol)
                    .font(.caption2)
                Text(highlight.tier.name.value.uppercased())
                    .font(.caption2.weight(.semibold))
                    .tracking(0.7)
            }
            .foregroundStyle(.tint)

            HStack(spacing: 9) {
                Text(highlight.title.value)
                    .font(.system(size: 17, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                if let action = highlight.action {
                    KeyCap(action: action)
                }
            }

            Text(highlight.detail.value)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The way to the next one, and the one before.
    ///
    /// Outside the card rather than on it: the card is the thing being shown,
    /// and a control drawn on top of it would be part of what is shown.
    private func turner(back: Bool) -> some View {
        PageTurner(
            back: back,
            disabled: back ? page == 0 : page >= features.count - 1,
            turn: { turn(back ? -1 : 1) }
        )
    }

    /// Where you are in the set, and a way to jump.
    private var dots: some View {
        HStack(spacing: 7) {
            ForEach(features.indices, id: \.self) { index in
                Button {
                    withAnimation(Motion.surface) { page = index }
                } label: {
                    Circle()
                        .fill(index == page ? AnyShapeStyle(.primary) : AnyShapeStyle(.quaternary))
                        .frame(width: 7, height: 7)
                        .contentShape(.rect.inset(by: -4))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(ReleaseNotes.string("\(index + 1)번째", "Item \(index + 1)"))
            }
        }
        .animation(Motion.tap, value: page)
        .frame(maxWidth: .infinity)
    }

    private func turn(_ by: Int) {
        let next = page + by
        guard features.indices.contains(next) else { return }
        withAnimation(Motion.surface) { page = next }
    }
}

/// A chevron that answers the pointer.
///
/// Two plain grey arrows either side of a card say nothing about being
/// pressable — the first reading is that they are decoration, or a hint that
/// there is more, which is exactly what somebody said when they first saw
/// this sheet. So the pointer gets an answer, and it is the app's own answer:
/// `pressable` is what every row that goes somewhere already uses, which
/// means the same faint lift (`Color.primary` at 0.055) and the same hand for
/// a cursor. A ground of its own was tried here first and came out as a grey
/// block behind the arrow — a control drawn beside a card must not be heavier
/// than the card.
private struct PageTurner: View {
    let back: Bool
    let disabled: Bool
    let turn: () -> Void

    private var name: String {
        back ? ReleaseNotes.string("이전", "Previous") : ReleaseNotes.string("다음", "Next")
    }

    @ViewBuilder
    var body: some View {
        let chevron = Button(action: turn) {
            Image(systemName: back ? "chevron.left" : "chevron.right")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 46)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)

        // The last page's arrow is not pressable, so it does not answer the
        // pointer and does not put a hand under it either.
        if disabled {
            chevron.disabled(true).opacity(0.25)
        } else {
            chevron.pressable(cornerRadius: Corner.control)
        }
    }
}

/// Who this is, over the list of what it does.
private struct AboutHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 12) {
                Image(systemName: "books.vertical.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Paper Time")
                        .font(.system(size: 24, weight: .bold))
                    Text(ReleaseNotes.string(
                        "버전 \(ReleaseNotes.version) · 베타",
                        "Version \(ReleaseNotes.version) · Beta"
                    ))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }

            Text(ReleaseNotes.string(
                "논문을 읽고, 표시하고, 그 표시를 생각으로 바꾸기 위한 앱이에요. 아래의 것들은 설명이 아니라 눌러볼 수 있는 것들이에요 — 논문만 없을 뿐, 손에 닿는 건 앱의 것 그대로예요.",
                "An app for reading papers, marking them, and turning those marks into thinking. What follows is not a description: each one works. Only the paper is missing."
            ))
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)
        }
    }

}


/// The names, wrapped like words rather than listed like rows: a wall, not a
/// table. Somebody who sent two things is shown as having sent two.
private struct FlowingNames: View {
    let people: [Contributor]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(people) { person in
                Text(person.reports > 1 ? "\(person.name) ×\(person.reports)" : person.name)
                    .font(.caption)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(.quaternary.opacity(0.5), in: Capsule())
            }
        }
    }
}

/// A row that wraps. `Layout` rather than a grid because the names are all
/// different widths and a grid would leave holes.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: proposal.width ?? x, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
