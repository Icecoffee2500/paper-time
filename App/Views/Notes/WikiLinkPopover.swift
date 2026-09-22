#if os(macOS)
import AppKit
import SwiftUI

/// The list of notes offered while typing inside `[[ ]]`.
///
/// A panel of our own rather than the text system's completion list: that one
/// is a menu from another decade, and what belongs here is what a Mac shows
/// when it suggests something — a small floating card, the current row picked
/// out in the accent colour, arrow keys and Return to choose, Escape to leave.
@MainActor
final class WikiLinkPopover {
    struct Match: Identifiable, Hashable {
        var id: String
        var title: String
        var subtitle: String
    }

    private var panel: NSPanel?
    private var matches: [Match] = []
    private var selection = 0
    private var onChoose: ((Match) -> Void)?

    var isShowing: Bool { panel?.isVisible == true }
    var selected: Match? { matches.indices.contains(selection) ? matches[selection] : nil }

    /// Puts the card under the caret, or above it when there is no room below.
    func show(
        matches: [Match], below caret: NSRect, in view: NSView,
        onChoose: @escaping (Match) -> Void
    ) {
        guard !matches.isEmpty, let window = view.window else { return hide() }
        self.matches = matches
        self.onChoose = onChoose
        if selection >= matches.count { selection = 0 }

        let panel = self.panel ?? makePanel()
        self.panel = panel
        (panel.contentView as? NSHostingView<ContentView>)?.rootView = content
        let size = NSSize(width: 320, height: min(CGFloat(matches.count) * 44 + 12, 232))
        panel.setContentSize(size)

        let onScreen = window.convertToScreen(view.convert(caret, to: nil))
        var origin = NSPoint(x: onScreen.minX, y: onScreen.minY - size.height - 6)
        if let screen = window.screen, origin.y < screen.visibleFrame.minY + 20 {
            origin.y = onScreen.maxY + 6
        }
        panel.setFrameOrigin(origin)
        if !panel.isVisible { window.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    func hide() {
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        selection = 0
    }

    /// Moves the pick. Returns false when there is nothing showing, so the key
    /// press can go on to do what it normally does.
    @discardableResult
    func move(by step: Int) -> Bool {
        guard isShowing, !matches.isEmpty else { return false }
        selection = (selection + step + matches.count) % matches.count
        (panel?.contentView as? NSHostingView<ContentView>)?.rootView = content
        return true
    }

    @discardableResult
    func chooseSelected() -> Bool {
        guard isShowing, let match = selected else { return false }
        hide()
        onChoose?(match)
        return true
    }

    // MARK: - The card

    private var content: ContentView {
        ContentView(matches: matches, selection: selection) { [weak self] match in
            self?.hide()
            self?.onChoose?(match)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = true
        panel.contentView = NSHostingView(rootView: content)
        return panel
    }

    struct ContentView: View {
        var matches: [Match]
        var selection: Int
        var choose: (Match) -> Void

        var body: some View {
            ScrollViewReader { scroller in
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(Array(matches.enumerated()), id: \.element.id) { index, match in
                            row(match, isSelected: index == selection)
                                .id(match.id)
                        }
                    }
                    .padding(5)
                }
                .scrollIndicators(.never)
                .onChange(of: selection) { _, index in
                    guard matches.indices.contains(index) else { return }
                    withAnimation(Motion.tap) {
                        scroller.scrollTo(matches[index].id)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .liquidGlass(.floating, in: RoundedRectangle(cornerRadius: Corner.popover,
                                                               style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Corner.popover, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 0.5)
            }
        }

        private func row(_ match: Match, isSelected: Bool) -> some View {
            HStack(spacing: 8) {
                Image(systemName: "note.text")
                    .font(.caption)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                VStack(alignment: .leading, spacing: 1) {
                    Text(match.title)
                        .font(.callout)
                        .lineLimit(1)
                    Text(match.subtitle)
                        .font(.caption)
                        .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.8))
                                                    : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Corner.row, style: .continuous)
                    .fill(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear))
            }
            .contentShape(.rect)
            .onTapGesture { choose(match) }
        }
    }
}
#endif
