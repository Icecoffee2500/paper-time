import CoreGraphics
import Foundation
@testable import InkEngine
import Testing

/// The tree read off a flat list: what a click selects, what a group is
/// the size of, where a frame's layout puts its children — and that a file
/// written before any of this existed comes back byte for byte.
struct SketchTreeTests {
    static func box(_ rect: CGRect, parent: UUID? = nil) -> SketchElement {
        SketchElement(
            kind: .rectangle,
            points: [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY)],
            parent: parent
        )
    }

    @Test func anOldElementIsWrittenWithoutTheNewKeys() throws {
        let element = SketchElement(kind: .rectangle, points: [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 10)])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(element), as: UTF8.self)
        for key in ["parent", "name", "clips", "layout", "textSizing", "strokeHidden", "cornerRadius", "fontSize", "textAlign"] {
            #expect(!json.contains("\"\(key)\""), "\(key) should be absent when unset")
        }
        let back = try JSONDecoder().decode(SketchElement.self, from: Data(json.utf8))
        #expect(back == element)
        #expect(back.sizing == .autoHeight)
    }

    @Test func theNewKeysRoundTrip() throws {
        var frame = SketchElement(kind: .frame, points: [.zero, CGPoint(x: 100, y: 100)], name: "Frame 1", clips: true, layout: SketchLayout(direction: .horizontal, gap: 4))
        frame.style.strokeHidden = true
        frame.style.cornerRadius = 6
        var text = SketchElement(kind: .text, points: [.zero, CGPoint(x: 40, y: 10)], text: "hi", parent: frame.id, textSizing: .autoWidth)
        text.style.fontSize = 14
        text.style.textAlign = .center
        let data = try JSONEncoder().encode([frame, text])
        let back = try JSONDecoder().decode([SketchElement].self, from: data)
        #expect(back == [frame, text])
        #expect(back[1].parent == frame.id)
        #expect(back[0].layout?.direction == .horizontal)
    }

    @Test func aClickInsideAGroupSelectsTheGroup() {
        var group = SketchElement(kind: .group, points: [.zero, .zero])
        let a = Self.box(CGRect(x: 0, y: 0, width: 10, height: 10), parent: group.id)
        let b = Self.box(CGRect(x: 20, y: 0, width: 10, height: 10), parent: group.id)
        group.points = [.zero, .zero]
        let tree = SketchTree([group, a, b])
        #expect(tree.selectable(for: a.id) == group.id)
        #expect(tree.selectable(for: a.id, within: group.id) == a.id)
        #expect(tree.bounds(of: group.id) == CGRect(x: 0, y: 0, width: 30, height: 10))
        #expect(tree.outermost([group.id, a.id]) == [group.id])
        #expect(tree.expanded([group.id]) == [group.id, a.id, b.id])
    }

    @Test func aFrameLetsTheClickThroughToItsChild() {
        let frame = SketchElement(kind: .frame, points: [.zero, CGPoint(x: 100, y: 100)])
        let a = Self.box(CGRect(x: 10, y: 10, width: 10, height: 10), parent: frame.id)
        let tree = SketchTree([frame, a])
        #expect(tree.selectable(for: a.id) == a.id)
        #expect(tree.root(of: a.id)?.id == frame.id)
    }

    @Test func normalizedPutsChildrenAfterTheirParentAndSizesGroups() {
        var group = SketchElement(kind: .group, points: [.zero, .zero])
        let a = Self.box(CGRect(x: 0, y: 0, width: 10, height: 10), parent: group.id)
        let loose = Self.box(CGRect(x: 50, y: 50, width: 5, height: 5))
        group.points = [.zero, .zero]
        // The child listed before its parent, and a loose box between them.
        let out = SketchTree.normalized([a, loose, group])
        #expect(out.map(\.id) == [loose.id, group.id, a.id])
        #expect(out[1].rect == CGRect(x: 0, y: 0, width: 10, height: 10))
    }

    @Test func aVerticalLayoutStacksChildrenFromTheTopAndHugsThem() {
        var frame = SketchElement(kind: .frame, points: [CGPoint(x: 0, y: 0), CGPoint(x: 300, y: 300)])
        frame.layout = SketchLayout(direction: .vertical, gap: 10, padding: 5)
        let a = Self.box(CGRect(x: 70, y: 20, width: 40, height: 20), parent: frame.id)
        let b = Self.box(CGRect(x: 120, y: 200, width: 60, height: 30), parent: frame.id)
        let out = SketchTree.normalized([frame, a, b])
        let tree = SketchTree(out)
        let placedFrame = tree[frame.id]!
        // Top-left corner stays; the frame hugs: width 60 + 10, height 20 + 30 + 10 + 10.
        #expect(placedFrame.rect.minX == 0)
        #expect(placedFrame.rect.maxY == 300)
        #expect(abs(placedFrame.rect.width - 70) < 0.001)
        #expect(abs(placedFrame.rect.height - 70) < 0.001)
        let first = tree[a.id]!, second = tree[b.id]!
        #expect(first.rect.minX == 5 && abs(first.rect.maxY - 295) < 0.001)
        #expect(abs(second.rect.maxY - (295 - 20 - 10)) < 0.001)
    }

    @Test func aHorizontalLayoutMovesGrandchildrenWithTheirGroup() {
        var frame = SketchElement(kind: .frame, points: [.zero, CGPoint(x: 400, y: 100)])
        frame.layout = SketchLayout(direction: .horizontal, gap: 0, padding: 0, hugs: false)
        var group = SketchElement(kind: .group, points: [.zero, .zero], parent: frame.id)
        let inner = Self.box(CGRect(x: 200, y: 50, width: 10, height: 10), parent: group.id)
        group.points = [.zero, .zero]
        let out = SketchTree.normalized([frame, group, inner])
        let tree = SketchTree(out)
        // Packed from the frame's top-left: the group's only child is now at x 0, top 100.
        #expect(tree[inner.id]!.rect.minX == 0)
        #expect(abs(tree[inner.id]!.rect.maxY - 100) < 0.001)
        // Not hugging: the frame keeps its size.
        #expect(tree[frame.id]!.rect.width == 400)
    }

    @Test func aFittedTextCardGrowsSidewaysOrDownwards() {
        var card = SketchElement(kind: .text, points: [CGPoint(x: 0, y: 100), CGPoint(x: 24, y: 99)], text: "a fairly long line of words", textSizing: .autoWidth)
        card.rect = SketchTypesetter.fittedRect(for: card)
        #expect(card.rect.width > 60)
        #expect(card.rect.maxY == 100)
        card.textSizing = .autoHeight
        card.rect = CGRect(x: 0, y: 100, width: 50, height: 0)
        card.rect = SketchTypesetter.fittedRect(for: card)
        #expect(card.rect.width == 50)
        #expect(card.rect.height > 20)
    }

    @Test func hexReadsAndWrites() {
        let blue = SketchColor(hex: "1F5FFA", alpha: 0.5)
        #expect(blue?.hex == "1F5FFA")
        #expect(blue?.alpha == 0.5)
        #expect(SketchColor(hex: "#f00")?.hex == "FF0000")
        #expect(SketchColor(hex: "nope") == nil)
    }
}
