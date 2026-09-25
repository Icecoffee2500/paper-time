import Foundation
import PDFKit
#if canImport(UIKit)
import UIKit
typealias PlatformColor = UIColor
typealias PlatformBezierPath = UIBezierPath
#else
import AppKit
typealias PlatformColor = NSColor
typealias PlatformBezierPath = NSBezierPath
#endif

/// What an annotation says, digested — to notice one that was changed where
/// it stood rather than taken off the page and put back.
///
/// The writer tells what an edit did by comparing the page's annotations
/// before and after it, and an annotation that is the same object before and
/// after looks untouched. Most edits the app makes remove and add, but one
/// that sets a colour or a key on an annotation already in the file would
/// otherwise be dropped without a word: the save would report "unchanged"
/// and the file would keep the old colour. So every annotation is digested
/// before the edit and again after it, and one whose digest moved is written
/// again.
///
/// A digest rather than a description: every annotation of the paper is
/// read twice on every save, and on a page of four hundred strokes spelling
/// each of them out as text was a quarter of the save. The two digests are
/// only ever compared within one save, so the seed Swift gives `Hasher` for
/// each run does not matter; nothing that differs between two looks at the
/// same unchanged annotation — an address, an order — goes into it.
enum AnnotationFingerprint {
    static func of(_ annotation: PDFAnnotation) -> Int {
        var h = Hasher()
        h.combine(annotation.type ?? "?")
        combine(annotation.bounds, into: &h)
        h.combine(unordered(annotation.annotationKeyValues, depth: 0))
        // What PDFKit keeps for an ink annotation's strokes and a line's
        // ends, which it holds apart from the dictionary.
        if annotation.type == "Ink" {
            for path in annotation.paths ?? [] {
                combine(path.bounds, into: &h)
                h.combine(elementCount(path))
            }
        }
        if annotation.type == "Line" {
            combine(annotation.startPoint, into: &h)
            combine(annotation.endPoint, into: &h)
            h.combine(annotation.startLineStyle.rawValue)
            h.combine(annotation.endLineStyle.rawValue)
        }
        h.combine(annotation.shouldDisplay)
        h.combine(annotation.shouldPrint)
        return h.finalize()
    }

    /// A dictionary's pairs, in whatever order they come: summed, so the
    /// order does not count.
    private static func unordered(_ dict: [AnyHashable: Any], depth: Int) -> Int {
        var sum = 0
        for (key, value) in dict {
            var h = Hasher()
            h.combine(key)
            h.combine(digest(value, depth: depth + 1))
            sum &+= h.finalize()
        }
        return sum
    }

    private static func digest(_ value: Any, depth: Int) -> Int {
        guard depth < 8 else { return 0 }
        var h = Hasher()
        switch value {
        case let s as String: h.combine(0); h.combine(s)
        case let n as NSNumber: h.combine(1); h.combine(n.doubleValue)
        case let d as Date: h.combine(2); h.combine(d.timeIntervalSinceReferenceDate)
        case let c as PlatformColor: h.combine(3); colour(c, into: &h)
        case let v as NSValue: h.combine(4); h.combine(v.description)
        case let b as PDFBorder:
            h.combine(5)
            h.combine(b.lineWidth)
            h.combine(b.style.rawValue)
            for n in (b.dashPattern as? [NSNumber]) ?? [] { h.combine(n.doubleValue) }
        case let a as PDFActionURL: h.combine(6); h.combine(a.url?.absoluteString)
        case let a as PDFActionGoTo: h.combine(7); combine(a.destination.point, into: &h)
        case let a as PDFActionNamed: h.combine(8); h.combine(a.name.rawValue)
        case let a as PDFAction: h.combine(9); h.combine(a.type)
        case let d as PDFDestination: h.combine(10); combine(d.point, into: &h)
        case let a as PDFAnnotation: h.combine(11); h.combine(a.type)
        case let list as [Any]:
            h.combine(12)
            for item in list { h.combine(digest(item, depth: depth + 1)) }
        case let dict as [AnyHashable: Any]: h.combine(13); h.combine(unordered(dict, depth: depth + 1))
        default: h.combine(14); h.combine("\(type(of: value))")
        }
        return h.finalize()
    }

    private static func colour(_ c: PlatformColor, into h: inout Hasher) {
        #if canImport(UIKit)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if c.getRed(&r, green: &g, blue: &b, alpha: &a) {
            for x in [r, g, b, a] { h.combine(x) }
        } else {
            h.combine(c.description)
        }
        #else
        let cg = c.cgColor
        h.combine(cg.colorSpace?.name as String?)
        for x in cg.components ?? [] { h.combine(x) }
        #endif
    }

    private static func combine(_ r: CGRect, into h: inout Hasher) {
        for x in [r.minX, r.minY, r.width, r.height] { h.combine(x) }
    }

    private static func combine(_ p: CGPoint, into h: inout Hasher) {
        h.combine(p.x)
        h.combine(p.y)
    }

    private static func elementCount(_ path: PlatformBezierPath) -> Int {
        #if canImport(UIKit)
        var count = 0
        path.cgPath.applyWithBlock { _ in count += 1 }
        return count
        #else
        return path.elementCount
        #endif
    }
}
