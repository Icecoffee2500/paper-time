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
        hosting.rootView = ContentView(face: face, room: room, ground: nil)
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

        // What lies under the card, for the glass to show: a picture of
        // the note there, diffused. Taken from the view, not the screen, so
        // no permission is asked and a probe's photograph has it too.
        let screenRect = NSRect(origin: origin, size: cardSize)
        let local = view.convert(window.convertFromScreen(screenRect), from: nil)
        hosting.rootView = ContentView(face: face, room: room, ground: Self.ground(under: local, of: view))

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
        panel.hasShadow = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = true
        // Never in the way: a click through it goes to the note.
        panel.ignoresMouseEvents = true
        let hosting = NSHostingView(rootView: ContentView(face: .raw(""), room: 120, ground: nil))
        hosting.autoresizingMask = [.width, .height]
        self.hosting = hosting
        // The glass is `GlassSlab`, not the system's `NSGlassEffectView`:
        // that one is set for a window's chrome, and over a white page it
        // read as a white card with a rim. The slab is built from the
        // material's parts — the diffused ground, a thin body, a darkened
        // rim, a specular line — and shows the note through itself.
        panel.contentView = hosting
        // The slab casts its own shadow; a second one from the window
        // doubled the edge.
        panel.hasShadow = false
        return panel
    }

    /// A picture of `rect` of `view` (the view's coordinates), diffused as
    /// the glass shows it. Nil when the card lies wholly outside the view.
    private static func ground(under rect: NSRect, of view: NSView) -> NSImage? {
        let inside = rect.intersection(view.bounds)
        guard !inside.isNull, inside.width > 1, inside.height > 1 else { return nil }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        view.cacheDisplay(in: rect, to: rep)
        let taken = NSImage(size: rect.size)
        taken.addRepresentation(rep)
        // A text view that leaves its background to the window is clear
        // where there is no ink, and a clear ground diffuses to grey. The
        // paper under the words is the window's.
        let paper = (view as? NSTextView).flatMap { $0.drawsBackground ? $0.backgroundColor : nil }
            ?? view.window?.backgroundColor ?? .textBackgroundColor
        let image = NSImage(size: rect.size, flipped: false) { bounds in
            paper.setFill()
            bounds.fill()
            taken.draw(in: bounds)
            return true
        }
        return GlassSlab<RoundedRectangle>.diffuse(image)
    }

    struct ContentView: View {
        var face: Face
        var room: CGFloat
        /// What lies under the card, diffused — the ground the glass shows.
        var ground: NSImage?

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
                GlassSlab(ground: ground, shape: RoundedRectangle(cornerRadius: Corner.popover, style: .continuous))
            }
            .animation(Motion.tap, value: face)
        }
    }
}
#endif
