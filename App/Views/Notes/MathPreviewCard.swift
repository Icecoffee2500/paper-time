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
    /// Where the glass got its ground: "window" (the window server),
    /// "view" (the text view's own drawing) or "none".
    private(set) var groundSource = "none"
    /// How long the last slab took to render, in milliseconds.
    private(set) var renderMilliseconds = 0.0
    /// The slab last rendered, kept under the face while the next one is
    /// computed — the render is a few hundred thousand pixels and runs off
    /// the main thread, so a keystroke never waits for it.
    private var lastSlab: NSImage?
    /// Counts `show` calls, so a slab rendered for an earlier one is dropped.
    private var generation = 0

    /// A child window outlives its owner: the parent window keeps it. So
    /// the card takes its panel down with it — which is how a card was
    /// left standing over the notes list after the note was closed.
    deinit {
        guard let panel else { return }
        MainActor.assumeIsolated {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
    }

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
        // The formula's ink, resolved under the note's own appearance: a
        // dynamic colour drawn into a bitmap outside a drawing pass comes
        // out as the light appearance's, and dark notes got black formulas.
        var ink = NSColor.labelColor
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            ink = NSColor(cgColor: NSColor.labelColor.cgColor) ?? .labelColor
        }
        if let made = MathTypesetter.image(
            latex: span.latex, display: span.display, pointSize: size,
            color: ink, maxWidth: room - 24
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

        // What lies under and around the card, for the glass to bend: a
        // picture of the note there. Taken from the view, not the screen,
        // so no permission is asked and a probe's photograph has it too.
        let screenRect = NSRect(origin: origin, size: cardSize)
        let local = view.convert(window.convertFromScreen(screenRect), from: nil)
        let dark = view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        panel.appearance = view.effectiveAppearance
        let ground = Self.ground(under: local, of: view)
        groundSource = ground?.source ?? "none"
        // The last slab stays under the face while the new one is computed,
        // when it is the same size; a card that changed size shows the
        // plain backing for the few milliseconds until the slab lands.
        let held = lastSlab.flatMap { $0.size == cardSize ? $0 : nil }
        hosting.rootView = ContentView(face: face, room: room, ground: held)
        generation += 1
        let mark = generation
        if let ground {
            nonisolated(unsafe) let picture = ground.image
            let scale = window.backingScaleFactor
            Task.detached(priority: .userInitiated) { [weak self] in
                let started = Date()
                nonisolated(unsafe) let slab = GlassSlab.render(
                    ground: picture, size: cardSize, cornerRadius: Corner.popover, dark: dark, scale: scale
                )
                let took = Date().timeIntervalSince(started) * 1000
                await MainActor.run {
                    guard let self, self.generation == mark, let hosting = self.hosting, let face = self.face else { return }
                    self.renderMilliseconds = took
                    self.lastSlab = slab
                    hosting.rootView = ContentView(face: face, room: room, ground: slab)
                }
            }
        }

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
        return "math preview: visible \(kind) at \(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))×\(Int(frame.height)) ground \(groundSource) slab \(lastSlab == nil ? "pending" : String(format: "%.0f ms", renderMilliseconds)) for \(latex?.debugDescription ?? "nil")"
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

    /// A picture of `rect` (window coordinates) of `window`, as the window
    /// server has it — or nil when the window is off screen.
    private static func windowPixels(of window: NSWindow, at rect: NSRect) -> NSImage? {
        let onScreen = window.convertToScreen(rect)
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(onScreen) }) else { return nil }
        // Quartz counts from the top of the main display; AppKit from the bottom.
        let mainHeight = NSScreen.screens.first.map(\.frame.maxY) ?? screen.frame.maxY
        let quartz = CGRect(
            x: onScreen.minX, y: mainHeight - onScreen.maxY,
            width: onScreen.width, height: onScreen.height
        )
        guard let cg = CGWindowListCreateImage(
            quartz, .optionIncludingWindow, CGWindowID(window.windowNumber), [.bestResolution, .boundsIgnoreFraming]
        ), cg.width > 2, cg.height > 2 else { return nil }
        return NSImage(cgImage: cg, size: rect.size)
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
    private static func ground(under card: NSRect, of view: NSView) -> (image: NSImage, source: String)? {
        let inside = card.intersection(view.bounds)
        guard !inside.isNull, inside.width > 1, inside.height > 1 else { return nil }
        // With the margin the lens reaches into.
        let rect = card.insetBy(dx: -GlassSlab.margin, dy: -GlassSlab.margin)
        // First choice: the window's own pixels, from the window server —
        // the note's pane, the ground the pane lies on, and the words, as
        // they are on screen. Only this window is asked for, which needs
        // no permission: the screen-recording gate is on other apps'
        // windows. A window off every display has no pixels there, so the
        // probe's window falls through to the view's own drawing.
        if let window = view.window, let taken = Self.windowPixels(of: window, at: view.convert(rect, to: nil)) {
            return (taken, "window")
        }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        view.cacheDisplay(in: rect, to: rep)
        let taken = NSImage(size: rect.size)
        taken.addRepresentation(rep)
        // A text view that leaves its background to the window is clear
        // where there is no ink, and a clear ground diffuses to grey. The
        // paper under the words is the window's.
        let paper = (view as? NSTextView).flatMap { $0.drawsBackground ? $0.backgroundColor : nil }
            ?? view.window?.backgroundColor ?? .textBackgroundColor
        // Painted into pixels here, on the main thread: an image made of a
        // drawing handler runs that handler wherever it is first drawn, and
        // the slab is rendered on another thread — the handler's actor check
        // trapped there.
        let scale = view.window?.backingScaleFactor ?? 2
        let wide = max(Int(rect.width * scale), 1), high = max(Int(rect.height * scale), 1)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: wide, pixelsHigh: high, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        bitmap.size = rect.size
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.current = context
        let bounds = NSRect(origin: .zero, size: rect.size)
        // Under the view's own appearance: the paper is a dynamic colour,
        // and filled outside a drawing pass it comes out as the light one —
        // a dark note's card was rendered over white.
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            paper.setFill()
            bounds.fill()
            taken.draw(in: bounds)
        }
        context.flushGraphics()
        let image = NSImage(size: rect.size)
        image.addRepresentation(bitmap)
        return (image, "view")
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
                GlassSlab(picture: ground, cornerRadius: Corner.popover)
            }
            .animation(Motion.tap, value: face)
        }
    }
}
#endif
