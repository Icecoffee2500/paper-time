import SwiftUI

#if os(macOS)
import AppKit
#endif

private struct WindowToolbarBandKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// How tall the band at the top of the window is — the strip the titlebar
    /// and the toolbar cover. Nought on iOS, which has neither.
    ///
    /// A material toolbar background makes the window use a full-size content
    /// view. SwiftUI then lays parts of the window out from the very top of it
    /// and reports a top safe area of zero — which is what a list wants, since
    /// AppKit hands scroll views the content inset that keeps them clear. But
    /// anything pinned to the top edge of one of those parts is laid out
    /// *behind* the toolbar, under the material, where it cannot be seen.
    ///
    /// Two things were: the find bar, which made ⌘F look like it did nothing
    /// at all, and the inspector's Details / Marks / Note picker, which looked
    /// like it had been taken away. Both were drawn, both were 52 points too
    /// high.
    ///
    /// This is only half of what a site needs. Which parts of the window start
    /// under the toolbar and which start below it is not uniform — measured,
    /// the sidebar's own header sits at y=52 while the reader and the
    /// inspector both start at y=0 — so a view that wants to clear the toolbar
    /// has to subtract where *it* begins:
    ///
    /// ```swift
    /// .padding(.top, max(0, toolbarBand - containerTop))
    /// ```
    ///
    /// with `containerTop` measured on the thing it sits at the top of, never
    /// on itself. Measuring the padded view would be measuring our own answer.
    var windowToolbarBand: CGFloat {
        get { self[WindowToolbarBandKey.self] }
        set { self[WindowToolbarBandKey.self] = newValue }
    }
}

#if os(macOS)
extension View {
    /// Asks AppKit how tall the window's chrome is and publishes it as
    /// `\.windowToolbarBand`. Belongs once, on the root of a window's content.
    func measuringWindowToolbarBand() -> some View {
        modifier(WindowToolbarBandMeasure())
    }
}

private struct WindowToolbarBandMeasure: ViewModifier {
    @State private var band: CGFloat = 0
    /// The window's own height, purely as something that changes when the
    /// window's geometry does. A size, not a position, so nothing we go on to
    /// move can feed back into it.
    @State private var height: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            .background {
                WindowToolbarBandReader(revision: height) { band = $0 }
            }
            .environment(\.windowToolbarBand, band)
    }
}

/// Reports how much of the top of the window the titlebar and toolbar cover.
///
/// AppKit holds the number and nothing in SwiftUI does: `contentLayoutRect` is
/// the part of the content view they leave alone.
private struct WindowToolbarBandReader: NSViewRepresentable {
    /// Changes when the window's geometry does, so the band gets measured
    /// again: resizing and entering full screen both change it.
    var revision: CGFloat
    var onChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.onChange = onChange
        return probe
    }

    func updateNSView(_ probe: Probe, context: Context) {
        // Deliberately does not measure. Reporting from here means writing
        // SwiftUI state in the middle of a SwiftUI update, and the write that
        // carried the real band — the one taken once the toolbar existed —
        // was quietly lost that way, leaving every reader of it on the
        // titlebar-only 32. The window's own notifications are the safe place
        // to do it from.
        probe.onChange = onChange
    }

    /// A view of no size whose only purpose is to have a window to ask.
    final class Probe: NSView {
        var onChange: ((CGFloat) -> Void)?
        private var reported: CGFloat?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let center = NotificationCenter.default
            center.removeObserver(self)
            if let window {
                // Landing in the window is too early to ask. The toolbar is
                // usually not installed yet, and the band measured without it
                // is the titlebar alone — about twenty points short, which put
                // the find bar and the inspector's picker half under the
                // toolbar instead of entirely under it. `didUpdate` is AppKit
                // saying the window has finished an update pass, which is the
                // first moment the toolbar is reliably there, and every later
                // one: a toolbar hidden or a window resized comes through here
                // too.
                for name in [NSWindow.didUpdateNotification, NSWindow.didResizeNotification] {
                    center.addObserver(
                        self, selector: #selector(windowDidChange),
                        name: name, object: window
                    )
                }
            }
            report()
        }

        @objc private func windowDidChange() { report() }

        func report() {
            guard let window, let content = window.contentView else { return }
            // The content view's own top inset: 32 with just a titlebar, 52
            // once the toolbar is installed. `contentLayoutRect` agrees to the
            // point, and this says what it means.
            let band = content.safeAreaInsets.top
            // Reporting the same number back would only spin the view update
            // that asked for it.
            guard band != reported else { return }
            reported = band
            onChange?(band)
        }
    }
}
#endif
