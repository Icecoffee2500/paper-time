import CoreGraphics
import Foundation

#if canImport(UIKit)
import UIKit
public typealias PlatformColor = UIColor
public typealias PlatformBezierPath = UIBezierPath
#else
import AppKit
public typealias PlatformColor = NSColor
public typealias PlatformBezierPath = NSBezierPath
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
