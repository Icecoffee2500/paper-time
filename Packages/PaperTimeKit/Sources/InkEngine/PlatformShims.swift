import CoreGraphics
import Foundation

#if canImport(UIKit)
import UIKit
public typealias PlatformColor = UIColor
public typealias PlatformBezierPath = UIBezierPath
public typealias PlatformFont = UIFont
#else
import AppKit
public typealias PlatformColor = NSColor
public typealias PlatformBezierPath = NSBezierPath
public typealias PlatformFont = NSFont
#endif

extension PlatformBezierPath {
    /// One name for adding a segment on both platforms.
    func appendLine(to point: CGPoint) {
        #if canImport(UIKit)
        addLine(to: point)
        #else
        line(to: point)
        #endif
    }

    static func polyline(_ points: [CGPoint]) -> PlatformBezierPath? {
        guard let first = points.first else { return nil }
        let path = PlatformBezierPath()
        path.move(to: first)
        if points.count == 1 {
            // A dot: a zero-length segment renders as a round cap.
            path.appendLine(to: CGPoint(x: first.x + 0.01, y: first.y))
        } else {
            for point in points.dropFirst() { path.appendLine(to: point) }
        }
        return path
    }
}


extension NSValue {
    /// The point in an `NSValue`, which AppKit and UIKit name differently.
    public var platformPoint: CGPoint {
        #if canImport(UIKit)
        cgPointValue
        #else
        pointValue
        #endif
    }
}

extension CGRect {
    /// Whether every number in the rectangle is one.
    ///
    /// PDFKit's selections can report a `bounds(for:)` of `nan` — seen on a
    /// selection across a table, after the framework's own table analysis had
    /// rewritten the page's lines. `isEmpty` and `isNull` both let such a
    /// rectangle through, because every comparison with `nan` is false; and a
    /// window asked to stand at `nan` throws an Objective-C exception, which
    /// is not a thing a Swift task survives.
    public var isFinite: Bool {
        origin.x.isFinite && origin.y.isFinite && size.width.isFinite && size.height.isFinite
    }
}
