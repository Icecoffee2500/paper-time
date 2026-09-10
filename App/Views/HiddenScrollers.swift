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
private struct HiddenScrollers: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let probe = ProbeView()
        probe.translatesAutoresizingMaskIntoConstraints = false
        return probe
    }

    func updateNSView(_ view: NSView, context: Context) {
        // Rows come and go as the library changes, and a scroll view made
        // after the last sweep would come with its scroller still on.
        DispatchQueue.main.async { (view as? ProbeView)?.applyToEnclosingScrollView() }
    }

    /// A zero-sized view that reaches for the scroll view it was put inside.
    final class ProbeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyToEnclosingScrollView()
        }

        func applyToEnclosingScrollView() {
            // Walking up finds nothing: the background of a List sits outside
            // the scroll view that List is made of. Sweep the window instead —
            // there are a handful of scroll views in it and every one of them
            // wants the same treatment.
            guard let root = window?.contentView else { return }
            Self.apply(under: root)
        }

        static func apply(under view: NSView) {
            if let scrollView = view as? NSScrollView {
                scrollView.scrollerStyle = .overlay
                scrollView.verticalScrollElasticity = .allowed
                scrollView.autohidesScrollers = true
                // A scroller that draws nothing and measures nothing, rather
                // than `hasVerticalScroller = false`: SwiftUI sets that flag
                // itself on every layout and put the bar straight back. It
                // does not replace the scroller object, so this stays put.
                if !(scrollView.verticalScroller is InvisibleScroller) {
                    scrollView.verticalScroller = InvisibleScroller()
                }
                if !(scrollView.horizontalScroller is InvisibleScroller) {
                    scrollView.horizontalScroller = InvisibleScroller()
                }
            }
            for subview in view.subviews { apply(under: subview) }
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

extension View {
    /// No scrollers in the scroll views this sits among.
    func hiddenScrollers() -> some View {
        background(HiddenScrollers().frame(width: 0, height: 0).allowsHitTesting(false))
    }
}
#else
import SwiftUI

extension View {
    func hiddenScrollers() -> some View { self }
}
#endif
