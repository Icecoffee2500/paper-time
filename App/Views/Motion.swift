import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// One set of speeds for the whole app.
///
/// Movement reads as one app's movement only when the same size of change
/// takes the same time everywhere. Written a site at a time it does not: this
/// app had seventeen different durations across eighty-odd places, so a chip
/// lighting up under the pointer and a whole column arriving were timed by
/// whoever wrote them rather than by what they were. Two things that are the
/// same size moved at different speeds, and two things that are different
/// sizes moved at the same one.
///
/// So there is one ladder, the way there is one for corners — and the rung is
/// chosen by *how much of the window changes*, not by how important the change
/// feels:
///
/// | what moves | rung |
/// |---|---|
/// | a control answering the hand: a pin, a star, a hover | `Motion.tap` |
/// | something inside a panel: a lit row travelling, a list refiltering | `Motion.move` |
/// | a whole surface arriving or leaving: a palette, a panel, a pane | `Motion.surface` |
/// | something leaving on its own, unwatched: a flash going out | `Motion.fade` |
///
/// One curve for the first three, because a curve is a voice and the app has
/// one: a spring that settles without wobbling. The last is a plain fade,
/// because nothing is arriving — the eye is being let go of rather than led.
enum Motion {
    /// A control answering the hand. Short enough to read as the press itself.
    static var tap: Animation { curve(0.14) }
    /// Something moving inside a panel.
    static var move: Animation { curve(0.22) }
    /// A whole surface arriving or leaving.
    static var surface: Animation { curve(0.32) }
    /// Something going out on its own, with nobody waiting for it.
    static var fade: Animation { reduced ? .easeOut(duration: 0.2) : .easeOut(duration: 0.4) }

    /// The same rungs for AppKit, which animates by duration rather than by
    /// curve — a floating panel fading in takes a tap's time, not a number
    /// of its own.
    enum Rung { case tap, move, surface }
    static func seconds(_ rung: Rung) -> TimeInterval {
        let duration: TimeInterval
        switch rung {
        case .tap: duration = 0.14
        case .move: duration = 0.22
        case .surface: duration = 0.32
        }
        return reduced ? min(duration, 0.15) : duration
    }

    /// Whether the system has been asked for less movement.
    ///
    /// Read once and kept, because these are asked for on every redraw; the
    /// system says when it changes. Under it the springs become plain eases
    /// and get shorter — the change still happens, so nothing appears out of
    /// nowhere, but nothing travels or overshoots.
    nonisolated(unsafe) private static var reduced = Motion.systemReducesMotion()

    private static func curve(_ duration: TimeInterval) -> Animation {
        reduced ? .easeInOut(duration: min(duration, 0.15)) : .snappy(duration: duration)
    }

    /// Starts listening for the setting. Called once, at launch.
    @MainActor
    static func watch() {
        reduced = systemReducesMotion()
        #if os(macOS)
        // The workspace's own centre, not the default one: this notification
        // is never posted to `NotificationCenter.default`, so an observer
        // added there is an observer that never hears anything.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { reduced = systemReducesMotion() }
        }
        #else
        NotificationCenter.default.addObserver(
            forName: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { reduced = systemReducesMotion() }
        }
        #endif
    }

    private static func systemReducesMotion() -> Bool {
        #if os(macOS)
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #else
        UIAccessibility.isReduceMotionEnabled
        #endif
    }
}
