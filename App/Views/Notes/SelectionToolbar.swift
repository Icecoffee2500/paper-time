#if os(macOS)
import AppKit
import InkEngine
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
        /// A highlight's colour dot rather than a letter: the colour's name.
        var color: MarkupColor?
        var id: String { mark }
        var width: CGFloat { color == nil ? 28 : 22 }
    }

    /// Bold, italic, code, math — and the five highlighter colours as dots,
    /// the way Apple Notes offers them. The first dot is `==` with no name.
    static let marks: [Mark] = [
        Mark(mark: "**", label: "B", help: L("굵게", "Bold")),
        Mark(mark: "*", label: "I", help: L("기울임", "Italic")),
        Mark(mark: "`", label: "<>", help: L("코드", "Code")),
        Mark(mark: "$", label: "$", help: L("수식", "Math")),
    ] + MarkupColor.allCases.map { color in
        Mark(mark: color == .yellow ? "==" : "=={\(color.rawValue)}", label: color.rawValue,
             help: L("하이라이트", "Highlight") + " · " + color.displayName, color: color)
    }

    private static var barWidth: CGFloat { marks.reduce(10 + 9) { $0 + $1.width + 1 } }

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
        let size = NSSize(width: Self.barWidth, height: 32)
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
            contentRect: NSRect(x: 0, y: 0, width: 150, height: 32),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        // The glass casts its own shadow; the panel's would double it.
        panel.hasShadow = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = true
        panel.contentView = NSHostingView(rootView: bar)
        return panel
    }

    struct Bar: View {
        var choose: (String) -> Void

        var body: some View {
            HStack(spacing: 1) {
                ForEach(SelectionToolbar.marks) { mark in
                    if mark.mark == "==" { divider }
                    Button { choose(mark.mark) } label: { face(of: mark) }
                        .buttonStyle(BarButtonStyle(width: mark.width))
                        .help(mark.help)
                }
            }
            .padding(.horizontal, 5)
            .frame(height: 32)
            // One capsule of glass, as the bar over a selection on the page
            // is: a hairline where it ends, not an outline.
            .liquidGlass(.floating)
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)
            }
        }

        private var divider: some View {
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(width: 1, height: 16)
                .padding(.horizontal, 4)
        }

        /// A letter for bold and italic, the system's symbols for code and
        /// math, and for a highlight the colour its words will be, as a dot.
        @ViewBuilder
        private func face(of mark: Mark) -> some View {
            if let color = mark.color {
                let ink = HighlightTone.ink(color)
                Circle()
                    .fill(Color(red: ink.red, green: ink.green, blue: ink.blue))
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
                    .frame(width: 14, height: 14)
            } else {
                switch mark.mark {
                case "**": Text("B").font(.system(size: 13, weight: .bold))
                case "*": Text("I").font(.system(size: 13, design: .serif).italic())
                case "`": Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: 11, weight: .medium))
                default: Image(systemName: "function").font(.system(size: 12, weight: .medium))
                }
            }
        }
    }

    /// A bar button: nothing until the pointer is over it, then a soft
    /// capsule — and a dot grows a little instead.
    private struct BarButtonStyle: ButtonStyle {
        let width: CGFloat
        @State private var hovering = false

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .foregroundStyle(.primary)
                .frame(width: width, height: 24)
                .contentShape(.rect)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(hovering || configuration.isPressed ? 0.09 : 0))
                )
                .scaleEffect(configuration.isPressed ? 0.94 : 1)
                .onHover { hovering = $0 }
                .animation(Motion.tap, value: hovering)
        }
    }
}
#endif
