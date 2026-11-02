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
        (panel.contentView as? SelectionBarView)?.hosting.rootView = bar
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
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The window's own shadow, which follows the capsule: the panel is
        // exactly the bar's size, so a shadow drawn inside it was cut off.
        panel.hasShadow = true
        panel.hidesOnDeactivate = true
        // The glass is AppKit's, not SwiftUI's. A SwiftUI material in a
        // hosting view inside a borderless panel is an `NSVisualEffectView`
        // the hosting view puts behind the content, rectangular, and the
        // capsule the body was filled in never clipped it — grey square
        // corners stood out behind the rounded bar. The page's bar
        // (`MarkupBarView`) is a visual effect view with its own corner, and
        // this is the same construction: one capsule of glass, buttons in it.
        panel.contentView = SelectionBarView(rootView: bar)
        return panel
    }

    /// For the probe: the content view's class, the corner it keeps, and the
    /// visual effect views inside — there must be exactly the one.
    static func describePanel() -> String {
        let bar = SelectionBarView(rootView: Bar(choose: { _ in }))
        bar.frame = NSRect(x: 0, y: 0, width: barWidth, height: 32)
        bar.layoutSubtreeIfNeeded()
        var effects = 0
        func walk(_ view: NSView) {
            if view is NSVisualEffectView { effects += 1 }
            view.subviews.forEach(walk)
        }
        walk(bar)
        return String(format: "content %@ corner %.1f masks %@ effect views %d width %.0f",
                      String(describing: type(of: bar)), bar.layer?.cornerRadius ?? -1,
                      bar.layer?.masksToBounds == true ? "yes" : "no", effects, barWidth)
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
            // The glass is the panel's (`SelectionBarView`): the buttons
            // here sit on it with nothing of their own behind them.
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
                // The highlighter's own colour, bright — Apple's — not the
                // deep ink its words become.
                let ink = HighlightTone.swatch(color)
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

    /// The capsule of glass the bar is — the page's `MarkupBarView`, with
    /// SwiftUI buttons inside instead of AppKit ones: popover material
    /// blurring what is behind the window, a corner of half the height,
    /// and a hairline where the glass ends. The hosting view draws no
    /// background of its own.
    final class SelectionBarView: NSVisualEffectView {
        let hosting: NSHostingView<Bar>

        init(rootView: Bar) {
            hosting = NSHostingView(rootView: rootView)
            super.init(frame: .zero)
            material = .popover
            blendingMode = .behindWindow
            state = .active
            wantsLayer = true
            layer?.cornerCurve = .continuous
            layer?.masksToBounds = true
            layer?.borderWidth = 0.5
            layer?.borderColor = NSColor.black.withAlphaComponent(0.08).cgColor
            hosting.translatesAutoresizingMaskIntoConstraints = false
            addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
                hosting.topAnchor.constraint(equalTo: topAnchor),
                hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        required init?(coder: NSCoder) { nil }

        override func layout() {
            super.layout()
            layer?.cornerRadius = Corner.capsule(height: bounds.height)
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
