import CoreGraphics
import Foundation
import Testing
@testable import InkEngine

@Suite("Lining a drag up")
struct SketchSnapTests {
    private let a = CGRect(x: 100, y: 100, width: 80, height: 40)

    @Test("A drag that lands near an edge gives up the last few points")
    func edge() {
        // Moving a box to x = 203 when something's left edge is at 200.
        let other = CGRect(x: 200, y: 400, width: 80, height: 40)
        let result = SketchSnap.adjust(box: a, by: CGPoint(x: 103, y: 0), against: [other])
        #expect(result.offset.x == 100)
        #expect(result.guides.contains { $0.axis == .vertical && $0.position == 200 })
    }

    @Test("A middle lines up as an edge does")
    func centres() {
        // Two boxes of the same width, so a left edge on a left edge is also a
        // middle on a middle: already lined up, and it says so rather than
        // nudging anything.
        let other = CGRect(x: 200, y: 400, width: 80, height: 40)
        let result = SketchSnap.adjust(box: a, by: CGPoint(x: 100, y: 0), against: [other])
        #expect(result.offset.x == 100, "already lined up; nothing to give")
        #expect(result.guides.contains { $0.axis == .vertical })

        // And a middle on its own: a narrower box whose centre is where ours
        // would land, with neither edge anywhere near.
        let narrow = CGRect(x: 230, y: 400, width: 20, height: 40)
        let byMiddle = SketchSnap.adjust(box: a, by: CGPoint(x: 97, y: 0), against: [narrow])
        #expect(byMiddle.offset.x == 100, "240 is the middle of both")
        #expect(byMiddle.guides.contains { $0.axis == .vertical && $0.position == 240 })
    }

    @Test("Too far away is left alone")
    func farAway() {
        let other = CGRect(x: 400, y: 400, width: 80, height: 40)
        let result = SketchSnap.adjust(box: a, by: CGPoint(x: 37, y: 11), against: [other])
        #expect(result.offset == CGPoint(x: 37, y: 11))
        #expect(result.guides.isEmpty)
    }

    @Test("Each axis answers for itself")
    func axesAreIndependent() {
        // Near on x, nowhere near on y.
        let other = CGRect(x: 200, y: 900, width: 80, height: 40)
        let result = SketchSnap.adjust(box: a, by: CGPoint(x: 103, y: 50), against: [other])
        #expect(result.offset.x == 100)
        #expect(result.offset.y == 50)
        #expect(result.guides.count == 1)
    }

    @Test("The page is something to line up by")
    func pageEdges() {
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        // The box's middle lands at 302; the page's middle is 306.
        let result = SketchSnap.adjust(box: a, by: CGPoint(x: 162, y: 0), against: [], page: page)
        #expect(result.offset.x == 166)
        #expect(result.guides.contains { $0.axis == .vertical && $0.position == 306 })
    }

    @Test("A guide reaches both boxes")
    func guideSpan() {
        let other = CGRect(x: 200, y: 400, width: 80, height: 40)
        let result = SketchSnap.adjust(box: a, by: CGPoint(x: 103, y: 0), against: [other])
        let guide = try! #require(result.guides.first { $0.axis == .vertical })
        #expect(guide.from == 100)
        #expect(guide.to == 440)
    }

    @Test("Nothing to line up against changes nothing")
    func nothingThere() {
        let result = SketchSnap.adjust(box: a, by: CGPoint(x: 13, y: 7), against: [])
        #expect(result.offset == CGPoint(x: 13, y: 7))
    }
}
