#if os(macOS)
import AppKit
import SwiftUI

extension View {
    /// Opens this view's window in the middle of the screen the app is on,
    /// every time it opens.
    ///
    /// AppKit remembers where a window was left and puts it back there, which
    /// is right for a document and wrong for Settings. Settings is somewhere
    /// you go for a moment and leave again, and a window that comes back onto
    /// a monitor the app is no longer on has to be hunted for. Moving it is
    /// still allowed — it simply does not carry that over to the next time it
    /// is asked for.
    func centeredOnOpen() -> some View {
        background(CenteredWindow().frame(width: 0, height: 0).allowsHitTesting(false))
    }
}

private struct CenteredWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Centerer() }
    func updateNSView(_ view: NSView, context: Context) {}

    final class Centerer: NSView {
        /// Set while the window is away, so coming back centres it and
        /// clicking on it does not.
        private var isDue = true

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let center = NotificationCenter.default
            center.removeObserver(self)
            guard let window else { return }

            // Stops AppKit writing the frame out on close, and stops it
            // reading one back in on open. Without this the saved frame is
            // restored after we have centred, and the centring is a frame the
            // user never sees.
            window.setFrameAutosaveName("")

            for (name, selector) in [
                (NSWindow.willCloseNotification, #selector(windowWillClose)),
                (NSWindow.didBecomeKeyNotification, #selector(windowDidBecomeKey)),
            ] {
                center.addObserver(self, selector: selector, name: name, object: window)
            }
            recentreIfDue()
        }

        @objc private func windowWillClose() { isDue = true }
        @objc private func windowDidBecomeKey() { recentreIfDue() }

        deinit { NotificationCenter.default.removeObserver(self) }

        private func recentreIfDue() {
            // A probe's picture of Settings is taken in a window the probe put
            // outside every display, and centring it would bring it onto the
            // screen of whoever is at the machine.
            guard !Boot.isSet("PAPERTIME_SETTINGS") else { return }
            guard isDue, let window else { return }
            isDue = false
            // Next tick: SwiftUI is still sizing the window on the pass that
            // shows it, and a frame set against a size that is about to
            // change is a window centred on the wrong dimensions.
            DispatchQueue.main.async { [weak window] in
                guard let window else { return }
                Self.centre(window)
            }
        }

        /// Puts the window in the middle of the screen the app is being used
        /// on — the library window's screen, not the last one this window sat
        /// on and not whichever screen macOS calls main.
        static func centre(_ window: NSWindow) {
            let host = NSApp.windows.first {
                $0 !== window && $0.isVisible && $0.canBecomeMain && $0.screen != nil
            }
            guard let screen = host?.screen ?? window.screen ?? NSScreen.main else { return }

            let room = screen.visibleFrame
            var frame = window.frame
            frame.origin.x = room.midX - frame.width / 2
            // Not the true middle. A window placed on the centre line reads as
            // low, because the eye takes the top edge for where a thing is;
            // AppKit's own `center()` lifts it by a third of the room left
            // over, and this is the same lift.
            frame.origin.y = room.minY + (room.height - frame.height) * 2 / 3
            window.setFrame(frame, display: true)
        }
    }
}
#endif
