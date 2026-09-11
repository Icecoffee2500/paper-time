import SwiftUI

/// A small working model of a feature, drawn under its line in the log.
///
/// Not a video. A recording would be a file in the bundle that goes stale the
/// first time the thing it shows is redrawn, and it cannot be poked. These are
/// the real controls at a tenth of the size: press the key in the demo and the
/// panes actually close, send the passage and it actually lands in the note.
/// What you cannot do here is the thing itself — no paper is open — but the
/// shape of the gesture is honest, which is all a changelog owes anyone.
struct LogDemoView: View {
    let demo: ReleaseNotes.Demo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch demo {
            case .panes: PaneDemo()
            case .passageLink: PassageDemo()
            case .ultracopy: UltracopyDemo()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Corner.popover, style: .continuous)
                .fill(.quaternary.opacity(0.25))
        )
        .padding(.leading, 21)
        .padding(.top, 2)
        .padding(.bottom, 6)
    }
}

// MARK: - Four panes

/// The window, at a tenth of the size, with its four keys under it.
private struct PaneDemo: View {
    @Environment(AppModel.self) private var app
    @State private var shown: Set<ShortcutAction> = [.sidebar, .paperList, .reader, .inspector]

    private let panes: [(ShortcutAction, Double)] = [
        (.sidebar, 0.16), (.paperList, 0.24), (.reader, 0.38), (.inspector, 0.22),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geometry in
                HStack(spacing: 4) {
                    ForEach(panes, id: \.0) { pane, share in
                        if shown.contains(pane) {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(pane == .reader ? AnyShapeStyle(.background) : AnyShapeStyle(.quaternary))
                                .frame(width: max(10, geometry.size.width * share))
                                .overlay {
                                    if pane == .reader {
                                        VStack(spacing: 3) {
                                            ForEach(0..<4, id: \.self) { _ in
                                                Capsule().fill(.quaternary)
                                                    .frame(height: 2)
                                            }
                                        }
                                        .padding(6)
                                    }
                                }
                                .transition(.scale(scale: 0.9, anchor: .center).combined(with: .opacity))
                        }
                    }
                    // Keeps the remaining panes to the left as one closes,
                    // rather than letting them stretch across the gap: the
                    // window reveals what is behind, it does not rebalance.
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 66)

            HStack(spacing: 6) {
                ForEach(panes, id: \.0) { pane, _ in
                    Button {
                        withAnimation(.snappy(duration: 0.28)) {
                            if shown.contains(pane) { shown.remove(pane) } else { shown.insert(pane) }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(app.shortcut(for: pane).display)
                                .monospaced()
                            Text(pane.title)
                        }
                        .font(.caption2)
                        .foregroundStyle(shown.contains(pane) ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(shown.contains(pane) ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Passage links

/// A sentence on a page, and what ⌘L does with it.
private struct PassageDemo: View {
    @Environment(AppModel.self) private var app
    @State private var sent = false

    private var sentence: String {
        ReleaseNotes.string(
            "관측된 초과 감쇠는 경계층에서 비롯된다.",
            "The observed excess damping originates in the boundary layer."
        )
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // The page.
            VStack(alignment: .leading, spacing: 4) {
                Capsule().fill(.quaternary).frame(width: 90, height: 3)
                Text(sentence)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.accentColor.opacity(sent ? 0 : 0.22))
                    )
                Capsule().fill(.quaternary).frame(height: 3)
                Capsule().fill(.quaternary).frame(width: 120, height: 3)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.background)
            )

            Button {
                withAnimation(.snappy(duration: 0.35)) { sent.toggle() }
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: sent ? "arrow.uturn.backward" : "arrow.right")
                    Text(sent ? ReleaseNotes.string("되돌리기", "Undo")
                              : app.shortcut(for: .linkToNote).display)
                        .monospaced()
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.top, 18)

            // The note.
            VStack(alignment: .leading, spacing: 5) {
                Text(ReleaseNotes.string("감쇠 메모", "Damping"))
                    .font(.caption.weight(.semibold))
                if sent {
                    Text(sentence)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                                .fill(Color.accentColor.opacity(0.14))
                        )
                        .overlay(alignment: .bottomTrailing) {
                            // Inside the chip, not hanging off it: at this
                            // size an overhang reads as the chip being cut by
                            // the edge of the note.
                            Image(systemName: "arrow.up.left.circle.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.tint)
                                .padding(1)
                        }
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                } else {
                    Capsule().fill(.quaternary).frame(width: 70, height: 3)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.background)
            )
        }
    }
}

// MARK: - Ultracopy

/// The same paragraph as it is read and as it is pasted.
private struct UltracopyDemo: View {
    @Environment(AppModel.self) private var app
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if copied {
                    Text(ReleaseNotes.string(
                        "감쇠율은 벽 근처에서 $\\gamma \\sim \\nu k^{2}$에\n비례한다.",
                        "The damping rate scales as $\\gamma \\sim \\nu k^{2}$\nnear the wall."
                    ))
                        .monospaced()
                        .transition(.opacity)
                } else {
                    (Text(ReleaseNotes.string("감쇠율은 벽 근처에서 ", "The damping rate scales as "))
                     + Text("γ ~ νk²").italic()
                     + Text(ReleaseNotes.string("에 비례한다.", " near the wall.")))
                        .transition(.opacity)
                }
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.background)
            )

            HStack(spacing: 8) {
                Text(copied ? ReleaseNotes.string("클립보드", "On the clipboard")
                            : ReleaseNotes.string("논문 위", "On the page"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    withAnimation(.snappy(duration: 0.25)) { copied.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Text(app.shortcut(for: .ultracopy).display).monospaced()
                        Text(copied ? ReleaseNotes.string("되돌리기", "Back")
                                    : ReleaseNotes.string("복사", "Copy"))
                    }
                    .font(.caption2)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(.quaternary))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
