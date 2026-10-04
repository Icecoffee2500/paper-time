#if os(macOS)
import AppKit
import SwiftUI

/// The small bar that appears over a selection in a note — bold, italic,
/// code, math — the way Notion's does. Each button does what the key does
/// (⌘B, ⌘I, ⌘E, ⌘⇧M): wraps the words in their Markdown, or takes it off.
///
/// A non-activating panel of our own, as `WikiLinkPopover` is: it floats over
/// the editor without taking the keyboard, and goes with the selection.
@MainActor
final class SelectionToolbar {
    struct Mark: Identifiable {
        var mark: String
        var label: String
        var help: String
        var id: String { mark }
    }

    static let marks: [Mark] = [
        Mark(mark: "**", label: "B", help: L("굵게", "Bold")),
        Mark(mark: "*", label: "I", help: L("기울임", "Italic")),
        Mark(mark: "`", label: "<>", help: L("코드", "Code")),
        Mark(mark: "$", label: "$", help: L("수식", "Math")),
    ]

    private var panel: NSPanel?
    private var onMark: ((String) -> Void)?

    var isShowing: Bool { panel?.isVisible == true }
    /// The labels, in order — for the probe.
    var buttons: [String] { Self.marks.map(\.label) }

    /// Puts the bar over the first line of the selection (`selection` is in
    /// screen coordinates), or under it when there is no room above.
    func show(over selection: NSRect, in view: NSView, onMark: @escaping (String) -> Void) {
        guard let window = view.window else { return hide() }
        self.onMark = onMark
        let panel = self.panel ?? makePanel()
        self.panel = panel
        (panel.contentView as? NSHostingView<Bar>)?.rootView = bar
        let size = NSSize(width: CGFloat(Self.marks.count) * 34 + 10, height: 36)
        panel.setContentSize(size)
        var origin = NSPoint(x: selection.midX - size.width / 2, y: selection.maxY + 6)
        if let screen = window.screen {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
            if origin.y + size.height > visible.maxY - 8 { origin.y = selection.minY - size.height - 6 }
        }
        panel.setFrameOrigin(origin)
        if !panel.isVisible { window.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    func hide() {
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private var bar: Bar {
        Bar { [weak self] mark in self?.onMark?(mark) }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 150, height: 36),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = true
        panel.contentView = NSHostingView(rootView: bar)
        return panel
    }

    struct Bar: View {
        var choose: (String) -> Void

        var body: some View {
            HStack(spacing: 2) {
                ForEach(SelectionToolbar.marks) { mark in
                    Button { choose(mark.mark) } label: {
                        Text(mark.label)
                            .font(font(for: mark.mark))
                            .frame(width: 32, height: 26)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help(mark.help)
                }
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 5)
            .liquidGlass(.floating, in: RoundedRectangle(cornerRadius: Corner.popover, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Corner.popover, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 0.5)
            }
        }

        private func font(for mark: String) -> Font {
            switch mark {
            case "**": .system(size: 13, weight: .bold)
            case "*": .system(size: 13).italic()
            default: .system(size: 12, design: .monospaced)
            }
        }
    }
}
#endif
