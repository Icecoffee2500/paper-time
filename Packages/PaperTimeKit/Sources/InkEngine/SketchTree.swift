import CoreGraphics
import Foundation

/// How a frame arranges its children: Figma's auto layout, cut to what a
/// reader annotating a paper needs — a row or a column, a gap between the
/// children, a padding inside the edge, and which side the shorter children
/// line up on.
public struct SketchLayout: Codable, Hashable, Sendable {
    public enum Direction: String, Codable, Sendable, CaseIterable {
        case vertical, horizontal
    }

    /// Where children shorter than the row (or narrower than the column)
    /// sit across it: at its start, its middle, or its end.
    public enum Align: String, Codable, Sendable, CaseIterable {
        case start, center, end
    }

    public var direction: Direction
    public var gap: CGFloat
    public var padding: CGFloat
    public var align: Align
    /// Whether the frame takes its size from its children — what Figma
    /// calls hugging. Off once the frame has been resized by hand: the
    /// children are then packed from its top-left corner and the rest of the
    /// frame is empty.
    public var hugs: Bool

    public init(
        direction: Direction = .vertical, gap: CGFloat = 8, padding: CGFloat = 8,
        align: Align = .start, hugs: Bool = true
    ) {
        self.direction = direction
        self.gap = gap
        self.padding = padding
        self.align = align
        self.hugs = hugs
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        direction = try c.decodeIfPresent(Direction.self, forKey: .direction) ?? .vertical
        gap = try c.decodeIfPresent(CGFloat.self, forKey: .gap) ?? 8
        padding = try c.decodeIfPresent(CGFloat.self, forKey: .padding) ?? 8
        align = try c.decodeIfPresent(Align.self, forKey: .align) ?? .start
        hugs = try c.decodeIfPresent(Bool.self, forKey: .hugs) ?? true
    }
}

/// A page's elements read as a tree.
///
/// The array stays flat — the file is a flat list, and every renderer and
/// every PDF copy walks it as one — and the tree is read off the `parent`
/// fields when something needs it: what a click selects, what a drag takes
/// along, where a frame's children go.
public struct SketchTree {
    public let elements: [SketchElement]
    private let position: [UUID: Int]
    private let childIDs: [UUID: [UUID]]
    /// The elements with no parent, in the order they lie.
    public let roots: [UUID]

    public init(_ elements: [SketchElement]) {
        self.elements = elements
        var position: [UUID: Int] = [:]
        for (i, element) in elements.enumerated() { position[element.id] = i }
        var children: [UUID: [UUID]] = [:]
        var roots: [UUID] = []
        for element in elements {
            // A parent that is not on the page — hidden mid-drag, or lost —
            // makes its children roots for now.
            if let parent = element.parent, position[parent] != nil, parent != element.id {
                children[parent, default: []].append(element.id)
            } else {
                roots.append(element.id)
            }
        }
        self.position = position
        self.childIDs = children
        self.roots = roots
    }

    public subscript(id: UUID) -> SketchElement? {
        position[id].map { elements[$0] }
    }

    public func children(of id: UUID) -> [SketchElement] {
        (childIDs[id] ?? []).compactMap { self[$0] }
    }

    public func hasChildren(_ id: UUID) -> Bool { !(childIDs[id] ?? []).isEmpty }

    /// Everything inside a container, at any depth, parents before children.
    public func descendants(of id: UUID) -> [SketchElement] {
        var out: [SketchElement] = []
        func walk(_ id: UUID) {
            for child in children(of: id) {
                out.append(child)
                walk(child.id)
            }
        }
        walk(id)
        return out
    }

    public func descendantIDs(of id: UUID) -> Set<UUID> {
        Set(descendants(of: id).map(\.id))
    }

    /// The chain above an element, nearest first.
    public func ancestors(of id: UUID) -> [SketchElement] {
        var out: [SketchElement] = []
        var current = self[id]?.parent
        var seen: Set<UUID> = [id]
        while let next = current, !seen.contains(next), let element = self[next] {
            out.append(element)
            seen.insert(next)
            current = element.parent
        }
        return out
    }

    public func isDescendant(_ id: UUID, of container: UUID) -> Bool {
        ancestors(of: id).contains { $0.id == container }
    }

    /// The element at the top of an element's chain.
    public func root(of id: UUID) -> SketchElement? {
        ancestors(of: id).last ?? self[id]
    }

    /// What a click on an element selects.
    ///
    /// Figma's rule: a group is picked up whole — the outermost group round
    /// the thing clicked — while a frame lets the click through to its
    /// children, because a frame is a place and a group is a thing. A group
    /// that has been entered (double-clicked) lets the click through to the
    /// child inside it, one level down.
    public func selectable(for id: UUID, within entered: UUID? = nil) -> UUID {
        var chosen = id
        for ancestor in ancestors(of: id) {
            if ancestor.id == entered { break }
            if ancestor.kind == .group { chosen = ancestor.id }
        }
        return chosen
    }

    /// Everything an element covers, its descendants included.
    ///
    /// A frame is its own box whatever lies in it; a group is the box round
    /// its children; anything else is what it is on its own.
    public func bounds(of id: UUID) -> CGRect {
        guard let element = self[id] else { return .null }
        switch element.kind {
        case .group:
            let inner = children(of: id).map { bounds(of: $0.id) }.filter { !$0.isNull }
            return inner.isEmpty ? element.rect : CGRect.union(of: inner)
        case .frame:
            return element.rect
        case .line, .arrow:
            return element.bounds
        default:
            return element.rect
        }
    }

    /// The box round several elements.
    public func bounds(of ids: some Sequence<UUID>) -> CGRect {
        CGRect.union(of: ids.map { bounds(of: $0) }.filter { !$0.isNull })
    }

    /// The ids among these that are not inside another of them — what a
    /// selection is really of, once its descendants are taken out.
    public func outermost(_ ids: Set<UUID>) -> Set<UUID> {
        ids.filter { id in !ancestors(of: id).contains { ids.contains($0.id) } }
    }

    /// These ids and everything inside them.
    public func expanded(_ ids: Set<UUID>) -> Set<UUID> {
        var out = ids
        for id in ids { out.formUnion(descendantIDs(of: id)) }
        return out
    }

    // MARK: - Keeping the list honest

    /// The same elements, put in the order a tree wants — every element
    /// after its parent, each container's children in their own order —
    /// with every frame's layout applied and every group's own box drawn
    /// round its children. Every change to a page passes through this.
    public static func normalized(_ elements: [SketchElement]) -> [SketchElement] {
        var tree = SketchTree(elements)
        var ordered: [SketchElement] = []
        func emit(_ id: UUID) {
            guard var element = tree[id] else { return }
            if let parent = element.parent, tree[parent] == nil { element.parent = nil }
            ordered.append(element)
            for child in tree.children(of: id) { emit(child.id) }
        }
        for root in tree.roots { emit(root) }
        tree = SketchTree(ordered)
        var result = ordered
        // Innermost first: an outer frame's layout measures its inner frame
        // after that one has taken its own size.
        func settle(_ id: UUID) {
            for child in tree.children(of: id) { settle(child.id) }
            guard let element = tree[id], element.isContainer else { return }
            if element.kind == .frame, let layout = element.layout {
                result = arrange(frameID: id, layout: layout, in: result)
                tree = SketchTree(result)
            } else if element.kind == .group, tree.hasChildren(id) {
                let box = tree.bounds(of: id)
                if let i = result.firstIndex(where: { $0.id == id }), !box.isNull, result[i].rect != box {
                    result[i].rect = box
                    tree = SketchTree(result)
                }
            }
        }
        for root in tree.roots { settle(root) }
        return result
    }

    /// Moves a frame's children into their row or column, and — when the
    /// frame hugs — fits the frame round them, keeping its top-left corner
    /// where it is.
    static func arrange(frameID: UUID, layout: SketchLayout, in elements: [SketchElement]) -> [SketchElement] {
        let tree = SketchTree(elements)
        guard let frame = tree[frameID] else { return elements }
        let children = tree.children(of: frameID)
        guard !children.isEmpty else { return elements }
        var result = elements
        let boxes = children.map { tree.bounds(of: $0.id) }
        let pad = layout.padding
        let gapTotal = layout.gap * CGFloat(children.count - 1)
        let content: CGSize
        switch layout.direction {
        case .vertical:
            content = CGSize(width: boxes.map(\.width).max() ?? 0, height: boxes.map(\.height).reduce(0, +) + gapTotal)
        case .horizontal:
            content = CGSize(width: boxes.map(\.width).reduce(0, +) + gapTotal, height: boxes.map(\.height).max() ?? 0)
        }
        var outer = frame.rect
        if layout.hugs {
            outer = CGRect(
                x: outer.minX, y: outer.maxY - content.height - pad * 2,
                width: content.width + pad * 2, height: content.height + pad * 2
            )
            if let i = result.firstIndex(where: { $0.id == frameID }) { result[i].rect = outer }
        }
        let inner = outer.insetBy(dx: pad, dy: pad)
        var cursor: CGFloat = layout.direction == .vertical ? inner.maxY : inner.minX
        for (child, box) in zip(children, boxes) {
            let target: CGPoint
            switch layout.direction {
            case .vertical:
                let x: CGFloat
                switch layout.align {
                case .start: x = inner.minX
                case .center: x = inner.midX - box.width / 2
                case .end: x = inner.maxX - box.width
                }
                target = CGPoint(x: x, y: cursor - box.height)
                cursor -= box.height + layout.gap
            case .horizontal:
                let y: CGFloat
                switch layout.align {
                case .start: y = inner.maxY - box.height
                case .center: y = inner.midY - box.height / 2
                case .end: y = inner.minY
                }
                target = CGPoint(x: cursor, y: y)
                cursor += box.width + layout.gap
            }
            let delta = CGPoint(x: target.x - box.minX, y: target.y - box.minY)
            guard abs(delta.x) > 0.001 || abs(delta.y) > 0.001 else { continue }
            let moving = tree.descendantIDs(of: child.id).union([child.id])
            for i in result.indices where moving.contains(result[i].id) {
                result[i] = result[i].translated(by: delta)
            }
        }
        return result
    }
}
