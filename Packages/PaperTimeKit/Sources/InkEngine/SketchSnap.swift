import CoreGraphics
import Foundation

/// What a box being dragged should line up with.
///
/// Figma's behaviour, and the reason it is worth having: a page of cards laid
/// out by eye is a page of cards that are all nearly aligned, and nearly is
/// what makes a page look unmade. The drag gives up the last few points to the
/// nearest edge or centre, and says which line it found so the reader can see
/// why it moved.
///
/// Pure geometry, on purpose — no view, no page, no PDFKit — so it is tested
/// without a window, the way `SketchTree` is.
public enum SketchSnap {
    /// A line the drag lined up with, in page coordinates.
    public struct Guide: Equatable, Sendable {
        public enum Axis: Sendable { case vertical, horizontal }
        public let axis: Axis
        /// Where the line is: an x for a vertical guide, a y for a horizontal.
        public let position: CGFloat
        /// How far the line reaches — enough to touch both the box that moved
        /// and the one it lined up with, which is what makes it readable.
        public let from: CGFloat
        public let to: CGFloat

        public init(axis: Axis, position: CGFloat, from: CGFloat, to: CGFloat) {
            self.axis = axis
            self.position = position
            self.from = min(from, to)
            self.to = max(from, to)
        }
    }

    public struct Result: Equatable, Sendable {
        public let offset: CGPoint
        public let guides: [Guide]
    }

    /// The three places a box can line up by, on each axis: its two edges and
    /// its middle. Six numbers, compared against the same six of everything
    /// else on the page.
    private static func marks(_ box: CGRect) -> (x: [CGFloat], y: [CGFloat]) {
        ([box.minX, box.midX, box.maxX], [box.minY, box.midY, box.maxY])
    }

    /// Corrects a drag so it lines up, when something is close enough.
    ///
    /// `tolerance` is in page points and should be the same few points on
    /// screen at any zoom — the caller divides by the zoom, as the rest of this
    /// view does for hit-testing.
    public static func adjust(
        box: CGRect,
        by offset: CGPoint,
        against others: [CGRect],
        page: CGRect? = nil,
        tolerance: CGFloat = 6
    ) -> Result {
        guard tolerance > 0 else { return Result(offset: offset, guides: []) }
        let moved = box.offsetBy(dx: offset.dx_, dy: offset.dy_)
        var candidates = others
        // The page's own edges and middle, because a card centred on the page
        // is a thing people line up by and nothing else on the page says where
        // that is.
        if let page { candidates.append(page) }

        let mine = marks(moved)
        var bestX: (distance: CGFloat, shift: CGFloat, guide: Guide)?
        var bestY: (distance: CGFloat, shift: CGFloat, guide: Guide)?

        for other in candidates {
            let theirs = marks(other)
            for mineX in mine.x {
                for theirX in theirs.x {
                    let distance = abs(theirX - mineX)
                    guard distance <= tolerance, distance < (bestX?.distance ?? .infinity) else { continue }
                    bestX = (distance, theirX - mineX, Guide(
                        axis: .vertical, position: theirX,
                        from: min(moved.minY, other.minY), to: max(moved.maxY, other.maxY)
                    ))
                }
            }
            for mineY in mine.y {
                for theirY in theirs.y {
                    let distance = abs(theirY - mineY)
                    guard distance <= tolerance, distance < (bestY?.distance ?? .infinity) else { continue }
                    bestY = (distance, theirY - mineY, Guide(
                        axis: .horizontal, position: theirY,
                        from: min(moved.minX, other.minX), to: max(moved.maxX, other.maxX)
                    ))
                }
            }
        }

        var guides: [Guide] = []
        if let bestX { guides.append(bestX.guide) }
        if let bestY { guides.append(bestY.guide) }
        return Result(
            offset: CGPoint(x: offset.dx_ + (bestX?.shift ?? 0), y: offset.dy_ + (bestY?.shift ?? 0)),
            guides: guides
        )
    }
}

private extension CGPoint {
    // `CGPoint` is what the drag carries its offset in; naming the two fields
    // for what they are keeps the arithmetic above readable.
    var dx_: CGFloat { x }
    var dy_: CGFloat { y }
}
