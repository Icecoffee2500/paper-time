#if os(macOS)
import AppKit
import SwiftUI

/// Takes the scrollers out of the scroll views behind the lists and the
/// reader.
///
/// "Show scroll bars: Always" is a system setting, and it turns every scroller
/// in every app into a wide grey bar that holds its space. That is the right
/// answer for a spreadsheet and the wrong one for a page of text, where it
/// sits in the margin the whole time you are reading — and on a glass panel it
/// is a grey slab laid across the one surface meant to be see-through.
///
/// This half only asks for the overlay style, which is what stops the scroller
/// holding a lane of its own. Hiding it is `.scrollIndicators(.hidden)`, set
/// once at the root of the window: turning `hasVerticalScroller` off from out
/// here worked for a moment and then SwiftUI put it back on its next layout,
/// which is a fight not worth having with a framework over its own views.
private struct ScrollerSweep: NSViewRepresentable {
    /// Whether the scrollers should be slim rather than gone.
    ///
    /// Gone is right for the reader, where the page itself says where you are.
    /// A settings page has no such landmark, so it keeps a scroller — just not
    /// the wide grey lane the system draws when "Show scroll bars: Always" is
    /// on.
    let thin: Bool

    func makeNSView(context: Context) -> NSView {
        let probe = ProbeView()
        probe.thin = thin
        probe.translatesAutoresizingMaskIntoConstraints = false
        return probe
    }

    func updateNSView(_ view: NSView, context: Context) {
        // Rows come and go as the library changes, and a scroll view made
        // after the last sweep would come with its scroller still on. Once a
        // turn of the run loop, though, however many probes ask: the sweep
        // walks every view in the window, and there is a probe in every list
        // — so a resize, which updates all of them on every frame, was
        // walking the whole window a dozen times a frame.
        guard let probe = view as? ProbeView else { return }
        probe.thin = thin
        probe.scheduleSweep()
    }

    /// A zero-sized view that reaches for the scroll view it was put inside.
    final class ProbeView: NSView {
        var thin = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyToEnclosingScrollView()
        }

        /// Asks for a sweep, and gets one — with everybody else who asked
        /// before the run loop came round again.
        func scheduleSweep() {
            guard !Self.sweepPending else { return }
            Self.sweepPending = true
            DispatchQueue.main.async { [weak self] in
                Self.sweepPending = false
                self?.applyToEnclosingScrollView()
            }
        }

        @MainActor private static var sweepPending = false

        func applyToEnclosingScrollView() {
            // Walking up finds nothing: the background of a List sits outside
            // the scroll view that List is made of. Sweep the window instead —
            // there are a handful of scroll views in it and every one of them
            // wants the same treatment.
            guard let root = window?.contentView else { return }
            Self.apply(under: root, thin: thin)
        }

        static func apply(under view: NSView, thin: Bool) {
            if let scrollView = view as? NSScrollView {
                scrollView.scrollerStyle = .overlay
                scrollView.verticalScrollElasticity = .allowed
                scrollView.autohidesScrollers = true
                // A scroller of our own, rather than `hasVerticalScroller =
                // false`: SwiftUI sets that flag itself on every layout and
                // put the bar straight back. It does not replace the scroller
                // object, so this stays put.
                let wanted: NSScroller.Type = thin ? ThinScroller.self : InvisibleScroller.self
                if !(type(of: scrollView.verticalScroller ?? NSScroller()) == wanted) {
                    scrollView.verticalScroller = wanted.init()
                }
                if !(type(of: scrollView.horizontalScroller ?? NSScroller()) == wanted) {
                    scrollView.horizontalScroller = wanted.init()
                }
            }
            for subview in view.subviews { apply(under: subview, thin: thin) }
        }
    }
}

/// A scroller with nothing drawn in it and no width to draw it in.
///
/// Scrolling is unaffected — the wheel, the trackpad and the keyboard all go
/// through the scroll view, not through this.
private final class InvisibleScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override class func scrollerWidth(
        for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style
    ) -> CGFloat { 0 }

    override func draw(_ dirtyRect: NSRect) {}
    override func drawKnob() {}
    override func drawKnobSlot(in slotRect: NSRect, highlight: Bool) {}
}

/// A scroller drawn as a thin capsule, with no slot behind it.
///
/// The system's own is 15pt wide with a grey trough; this is a knob and
/// nothing else, closer to the overlay scroller that appears when the setting
/// is left on "Automatically".
private final class ThinScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override class func scrollerWidth(
        for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style
    ) -> CGFloat { 9 }

    override func draw(_ dirtyRect: NSRect) { drawKnob() }
    override func drawKnobSlot(in slotRect: NSRect, highlight: Bool) {}

    override func drawKnob() {
        let rect = rect(for: .knob).insetBy(dx: 2.5, dy: 2)
        guard rect.width > 0, rect.height > 0 else { return }
        NSColor.secondaryLabelColor.withAlphaComponent(0.45).setFill()
        NSBezierPath(
            roundedRect: rect, xRadius: rect.width / 2, yRadius: rect.width / 2
        ).fill()
    }
}

extension View {
    /// No scrollers in the scroll views this sits among.
    func hiddenScrollers() -> some View {
        background(ScrollerSweep(thin: false).frame(width: 0, height: 0).allowsHitTesting(false))
    }

    /// Slim ones instead, for a window that still needs to say where you are.
    func thinScrollers() -> some View {
        background(ScrollerSweep(thin: true).frame(width: 0, height: 0).allowsHitTesting(false))
    }
}
#else
import SwiftUI

extension View {
    func hiddenScrollers() -> some View { self }
    func thinScrollers() -> some View { self }
}
#endif
