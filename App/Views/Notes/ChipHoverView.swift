#if os(macOS)
import AppKit

/// The glow over the passage chip the pointer is on.
///
/// Drawn by a view laid over the note's scroll view rather than by the text
/// fragment that paints the chip. TextKit 2 keeps a fragment's rendering and
/// does not draw it again for a hover — `needsDisplay`, invalidating its
/// rendering attributes, invalidating its layout, laying the viewport out
/// again: none of them got the chip repainted while the pointer was on it.
/// This view repaints on every change because it is ours, and sees no mouse:
/// every click goes through it to the text.
final class ChipHoverView: NSView {
    /// The boxes of the hovered chip, one per line, in this view's space.
    var rects: [CGRect] = [] {
        didSet { needsDisplay = true }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard !rects.isEmpty else { return }
        for rect in rects {
            let path = NSBezierPath(roundedRect: rect, xRadius: NoteChip.radius, yRadius: NoteChip.radius)

            // Light, not shade. A hovered chip should be the most legible thing
            // in the note: a faint white lift over the tint, a soft halo of
            // the accent round it, and a thin edge in the accent to say where
            // the pressable thing stops.
            NSGraphicsContext.saveGraphicsState()
            let halo = NSShadow()
            halo.shadowColor = NSColor.controlAccentColor.withAlphaComponent(0.35)
            halo.shadowBlurRadius = 6
            halo.shadowOffset = .zero
            halo.set()
            NSColor.white.withAlphaComponent(0.18).setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()

            // As heavy as the edge a highlight gets on the page, so the two
            // read as the same gesture.
            NSColor.controlAccentColor.withAlphaComponent(0.6).setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }
    }
}
#endif
