import CoreGraphics
import PencilKit

/// How wide PencilKit draws a pen stroke, and the point size that draws a
/// given width.
///
/// A `PKStrokePoint`'s size is not the width of the line it draws. PencilKit
/// draws a pen point of size `s` as a line `2s − 4` points wide, and nothing
/// at all below a size of 2 — measured on this Mac and in the iPad simulator
/// alike, at every picture scale and every force: 3 draws 2, 4 draws 4, 10
/// draws 16. The monoline pen follows the same rule; the marker does not
/// (it draws a little over half its size, and is left as it is).
///
/// The Mac's pen wrote the width it wanted straight into the size, so its
/// thinnest pen (1.5 pt) drew nothing once the stroke landed, the middle one
/// (3 pt) drew 2, and the PDF copy said 3 while the page showed 2. A stroke
/// made here now asks for the size that draws its width, and the width that
/// goes into the file — and comes back out of it — is the width drawn.
public enum PenWidth {
    /// The point size that PencilKit draws `width` points wide.
    public static func size(drawing width: CGFloat) -> CGFloat {
        (max(width, 0) + 4) / 2
    }

    /// The width PencilKit draws a point of `size`.
    public static func drawn(bySize size: CGFloat) -> CGFloat {
        max(0, 2 * size - 4)
    }

    /// The inks whose points follow the rule.
    public static func applies(to ink: PKInk.InkType) -> Bool {
        ink == .pen || ink == .monoline
    }
}
