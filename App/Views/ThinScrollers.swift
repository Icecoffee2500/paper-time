#if os(macOS)
import AppKit
import SwiftUI

/// Makes the scroll view behind a list or a reader use the thin, fading
/// scrollers rather than the permanent grey bars.
///
/// "Show scroll bars: Always" is a system setting, and it turns every scroller
/// in every app into a wide bar that holds its space. That is the right answer
/// for a spreadsheet and the wrong one for a page of text, where it sits in
/// the margin the whole time you are reading. Windows that are about reading
/// ask for the overlay style explicitly.
private struct ThinScrollers: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let probe = ProbeView()
        probe.translatesAutoresizingMaskIntoConstraints = false
        return probe
    }

    func updateNSView(_ view: NSView, context: Context) {
        // Rows come and go as the library changes, and a scroll view made
        // after the last sweep would keep the wide bars.
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
                scrollView.verticalScroller?.controlSize = .small
                scrollView.horizontalScroller?.controlSize = .small
                scrollView.autohidesScrollers = true
            }
            for subview in view.subviews { apply(under: subview) }
        }
    }
}

extension View {
    /// Thin, self-hiding scrollers for the scroll view this sits in.
    func thinScrollers() -> some View {
        background(ThinScrollers().frame(width: 0, height: 0).allowsHitTesting(false))
    }
}
#else
import SwiftUI

extension View {
    func thinScrollers() -> some View { self }
}
#endif
