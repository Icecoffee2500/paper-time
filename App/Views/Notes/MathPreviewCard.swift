#if os(macOS)
import AppKit
import PaperCore
import SwiftUI

/// The formula being typed, set as it will read, in a small card under the
/// line.
///
/// A note shows the caret's line as it is written — that is what makes it
/// editable — so while a formula is being typed it is a string of backslashes
/// and braces, and whether it says what was meant is only found out on
/// leaving the line. This card shows the set formula the whole time: the same
/// typesetter, at the note's own size, a keystroke behind the fingers. It is
/// a card like the one that offers note links — a floating panel that never
/// takes the keyboard, so Tab still goes to the next placeholder and every
/// letter still lands in the note.
///
/// A formula half typed does not set — `\frac{a}{` is nothing yet — and a
/// card that flashed an error at every second keystroke would be worse than
/// none. So the last formula that did set stays, dimmed, until the next one
/// does; and before anything has set, the words are shown as they are.
@MainActor
final class MathPreviewCard {
    /// What the card shows.
    enum Face: Equatable {
        /// The formula, set.
        case set(NSImage)
        /// The last formula that set, kept while the current one does not.
        case stale(NSImage)
        /// Nothing has set yet: the LaTeX itself, in a quieter colour.
        case raw(String)
    }

    private var panel: NSPanel?
    private var hosting: NSHostingView<ContentView>?
    private var lastGood: NSImage?
    private(set) var face: Face?
    /// The LaTeX the card was last asked to show.
    private(set) var latex: String?

    var isShowing: Bool { panel?.isVisible == true }
    /// Where the card is, on screen, while it shows.
    var frame: NSRect? { isShowing ? panel?.frame : nil }

    /// Shows `span` set, under the line at `line` (screen coordinates) with
    /// its left edge at `startX`, kept inside `bounds` — the editor's visible
    /// rectangle, on screen. Above the line when there is no room below it.
    func show(_ span: NoteMath.Span, startX: CGFloat, line: NSRect, bounds: NSRect, in view: NSView) {
        guard let window = view.window else { return hide() }
        latex = span.latex
        let room = min(480, max(120, bounds.width - 24))
        let size = NoteTypography.mathSize(forBody: NoteTypography.baseSize) * (span.display ? 1.12 : 1)
        if let made = MathTypesetter.image(
            latex: span.latex, display: span.display, pointSize: size,
            color: .labelColor, maxWidth: room - 24
        ) {
            lastGood = made.image
            face = .set(made.image)
        } else if let lastGood {
            face = .stale(lastGood)
        } else {
            face = .raw(span.latex)
        }

        let panel = self.panel ?? makePanel()
        self.panel = panel
        guard let hosting, let face else { return }
        hosting.rootView = ContentView(face: face, room: room, drawsOwnGlass: !Self.hasSystemGlass)
        let fitted = hosting.fittingSize
        let cardSize = NSSize(width: min(max(fitted.width, 44), room), height: max(fitted.height, 28))
        panel.setContentSize(cardSize)
        hosting.frame = NSRect(origin: .zero, size: cardSize)

        var origin = NSPoint(x: startX, y: line.minY - cardSize.height - 4)
        if origin.y < bounds.minY {
            origin.y = line.maxY + 4
        }
        origin.x = min(max(origin.x, bounds.minX), max(bounds.minX, bounds.maxX - cardSize.width))
        panel.setFrameOrigin(origin)

        if !panel.isVisible {
            panel.alphaValue = 0
            window.addChildWindow(panel, ordered: .above)
            panel.orderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Motion.seconds(.tap)
                panel.animator().alphaValue = 1
            }
        }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        face = nil
        latex = nil
    }

    /// One line for a probe: whether the card shows, where, and what.
    var report: String {
        guard let panel, panel.isVisible, let face else { return "math preview: hidden" }
        let kind: String
        switch face {
        case .set: kind = "set"
        case .stale: kind = "stale"
        case .raw(let text): kind = "raw \(text.debugDescription)"
        }
        let frame = panel.frame
        return "math preview: visible \(kind) at \(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))×\(Int(frame.height)) for \(latex?.debugDescription ?? "nil")"
    }

    /// The card's pixels, for a probe that photographs the editor: a child
    /// window is not in the editor's own picture.
    func picture() -> NSImage? {
        guard let view = panel?.contentView, isShowing,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(bitmap)
        return image
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = true
        // Never in the way: a click through it goes to the note.
        panel.ignoresMouseEvents = true
        let hosting = NSHostingView(rootView: ContentView(face: .raw(""), room: 120, drawsOwnGlass: !Self.hasSystemGlass))
        hosting.autoresizingMask = [.width, .height]
        self.hosting = hosting
        // The glass is the system's where the system has it. Drawn by hand
        // — a white body, a shadow, a hairline round the rim — it read as a
        // bar of soap: opaque in the middle and doubled at the corners where
        // the stroke, the shadow and the fill each rounded off on their own.
        // `NSGlassEffectView` bends what is behind the card instead of
        // painting over it, and draws the rim as light caught on a curve.
        // Sonoma has no such view and keeps the hand-made surface.
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = Corner.popover
            glass.contentView = hosting
            panel.contentView = glass
        } else {
            panel.contentView = hosting
        }
        return panel
    }

    /// Whether the system draws the glass (macOS 26), or the card does.
    static var hasSystemGlass: Bool {
        if #available(macOS 26, *) { return true } else { return false }
    }

    struct ContentView: View {
        var face: Face
        var room: CGFloat
        /// Sonoma: the surface is assembled here. macOS 26: the panel's glass
        /// view is the surface, and this is only what lies on it.
        var drawsOwnGlass: Bool

        var body: some View {
            Group {
                switch face {
                case .set(let image):
                    Image(nsImage: image)
                case .stale(let image):
                    Image(nsImage: image).opacity(0.45)
                case .raw(let text):
                    Text(text)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: room)
            .fixedSize(horizontal: true, vertical: true)
            .background {
                if drawsOwnGlass {
                    Color.clear
                        .liquidGlass(.floating, in: RoundedRectangle(cornerRadius: Corner.popover, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: Corner.popover, style: .continuous)
                                .strokeBorder(.separator, lineWidth: 0.5)
                        }
                }
            }
            .animation(Motion.tap, value: face)
        }
    }
}
#endif
