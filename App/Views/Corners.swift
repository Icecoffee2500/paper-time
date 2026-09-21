import SwiftUI

/// One corner curve for the whole app.
///
/// A rounded corner reads as "the same roundness" only when its radius grows
/// with the box it is on: the same 8 points that look right on a list row look
/// pinched on a floating panel. So there is one ladder, and everything on it —
/// a chip, a button, a row, a popover, a panel — is a rung rather than a
/// number someone typed.
///
/// The rungs:
///
/// | what | shape |
/// |---|---|
/// | a control: chip, button, bar of controls | capsule — half its own height |
/// | a row inside a list | `Corner.row` |
/// | a small floating surface | `Corner.popover` |
/// | a large floating surface | `Corner.panel` |
///
/// Anything one line tall is a capsule, which is where the ladder starts: the
/// filter chips in the marks list are exactly that, and everything else is
/// measured against them.
enum Corner {
    /// Selection and highlight behind a row of a list.
    static let row: CGFloat = 8
    /// A small surface floating over the page: an editor, a menu-sized panel.
    static let popover: CGFloat = 14
    /// A large surface: the search palette, the floating library.
    static let panel: CGFloat = 22

    /// A capsule's radius for a box of this height — what a control uses when
    /// its corner has to be drawn rather than clipped to a `Capsule`.
    static func capsule(height: CGFloat) -> CGFloat { height / 2 }

    /// Where a box is big enough that a true capsule would look like a pill
    /// rather than a panel, the radius stops growing here.
    static func surface(height: CGFloat) -> CGFloat { min(height / 2, panel) }

    /// A bar of controls floating over the page: the pencil's tool rack.
    static let bar: CGFloat = 12
    /// A control sitting inside a rounded surface — a chip in a bar, the
    /// selected tool in the rack.
    static let control: CGFloat = 8

    /// The radius of a shape nested inside another rounded shape, so the two
    /// curves are concentric: the same radius on both makes the inner one
    /// look sharper than the outer, because a curve that starts closer to
    /// the corner reads as a tighter corner. The rule is the one every
    /// design tool's "nested corners" follows — outer radius less the gap
    /// between the edges, and never below a hairline's worth.
    static func inner(_ outer: CGFloat, inset: CGFloat) -> CGFloat { max(outer - inset, 2) }
}

extension View {
    /// A control that reads as one pill: chips, prominent buttons, bars.
    func pillShaped() -> some View {
        buttonBorderShape(.capsule)
    }
}
