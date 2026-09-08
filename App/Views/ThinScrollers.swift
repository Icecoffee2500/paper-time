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
        (view as? ProbeView)?.applyToEnclosingScrollView()
    }

    /// A zero-sized view that reaches for the scroll view it was put inside.
    final class ProbeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyToEnclosingScrollView()
        }

        func applyToEnclosingScrollView() {
            var ancestor = superview
            while let view = ancestor {
                if let scrollView = view as? NSScrollView {
                    scrollView.scrollerStyle = .overlay
                    scrollView.verticalScroller?.controlSize = .small
                    scrollView.horizontalScroller?.controlSize = .small
                    return
                }
                ancestor = view.superview
            }
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
