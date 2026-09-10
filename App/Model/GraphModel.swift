import Foundation
import LibraryStore
import Observation
import PaperCore
import SwiftUI

/// The library as a graph: what is connected to what, and why.
///
/// A shelf of papers is a list until you can see it. What makes a graph worth
/// looking at is the reason two papers are joined, so there are four kinds of
/// line and each one says something different:
///
/// - **Cites** — one paper names the other in its own text. The literature's
///   own connection, found by reading the PDFs.
/// - **Note** — something you wrote about one paper links to something you
///   wrote about the other. Your thinking, which is the point of the box.
/// - **Author** — a person is on both.
/// - **Filed together** — you put them in the same collection or gave them the
///   same tag; the connection you already made by hand.
///
/// The first two are why this is worth building: they are the dots that only
/// get connected if something goes looking for them.
@MainActor
@Observable
public final class GraphModel {
    public typealias EdgeKind = PaperLink
    public typealias Edge = PaperConnection

    public struct Node: Hashable, Sendable, Identifiable {
        public var id: UUID
        public var title: String
        public var year: Int?
        public var degree: Int
        public var position: CGPoint
    }

    // MARK: - State

    public private(set) var nodes: [Node] = []
    public private(set) var edges: [Edge] = []
    public private(set) var isBuilding = false
    /// Set when the library changes under it: a paper added, a note written.
    /// The graph is rebuilt the next time it is looked at, and straight away
    /// if it is already on screen.
    public private(set) var isStale = true
    public private(set) var progress: (done: Int, total: Int)?

    /// Which kinds of line are drawn. Turning one off is how you ask a
    /// question: "what does my own writing connect that the papers do not?"
    public var shownKinds: Set<EdgeKind> = Set(EdgeKind.allCases)
    public var selection: UUID?
    /// Only the selected paper and what it touches.
    public var focusesOnSelection = false

    @ObservationIgnored private var citations: [UUID: Set<UUID>] = [:]
    @ObservationIgnored private var index: CitationIndex?
    @ObservationIgnored private var neighbourCache: [UUID: Set<UUID>] = [:]

    public init() {}

    // MARK: - Building

    /// Works out the connections, reading the PDFs the first time only.
    /// Rebuilds only if something changed since the last time.
    public func buildIfNeeded(from model: LibraryModel) async {
        guard isStale || nodes.isEmpty else { return }
        await build(from: model)
    }

    public func markStale() {
        isStale = true
    }

    public func build(from model: LibraryModel) async {
        guard !isBuilding else { return }
        isBuilding = true
        isStale = false
        defer { isBuilding = false; progress = nil }

        let papers = model.papers.filter { $0.meta.parentID == nil }
        let index = self.index ?? CitationIndex(store: model.store)
        self.index = index

        citations = await index.citations(among: papers) { [weak self] done, total in
            self?.progress = done < total ? (done, total) : nil
        }

        let edges = PaperGraphBuilder.connections(
            papers: papers,
            citations: citations,
            collections: model.collections,
            notes: model.notes.notes
        )
        let degrees = PaperGraphBuilder.degrees(of: edges)
        let placed = await Self.layout(
            papers: papers.map { ($0.id, $0.meta.csl.fullTitle ?? "Untitled", $0.meta.csl.year) },
            edges: edges,
            degrees: degrees
        )
        self.edges = edges
        self.nodes = placed
        var neighbours: [UUID: Set<UUID>] = [:]
        for edge in edges {
            neighbours[edge.a, default: []].insert(edge.b)
            neighbours[edge.b, default: []].insert(edge.a)
        }
        self.neighbourCache = neighbours
    }

    // MARK: - Reading

    public func node(_ id: UUID) -> Node? { nodes.first { $0.id == id } }

    public var visibleEdges: [Edge] {
        edges.filter { !$0.kinds.isDisjoint(with: shownKinds) }
    }

    /// The papers a paper is joined to, by the kinds of line now drawn.
    public func neighbours(of id: UUID) -> Set<UUID> {
        var result: Set<UUID> = []
        for edge in visibleEdges where edge.a == id || edge.b == id {
            result.insert(edge.a == id ? edge.b : edge.a)
        }
        return result
    }

    /// The best-connected papers, which is where a graph is worth entering.
    public func mostConnected(limit: Int = 12) -> [Node] {
        nodes.filter { $0.degree > 0 }.sorted { $0.degree > $1.degree }.prefix(limit).map(\.self)
    }

    public func isVisible(_ id: UUID) -> Bool {
        guard focusesOnSelection, let selection else { return true }
        return id == selection || neighbours(of: selection).contains(id)
    }

    // MARK: - Layout

    /// Spring layout, off the main actor: connected papers pull together,
    /// everything pushes apart, and the whole thing cools until it settles.
    ///
    /// Papers with no connection at all sit in a ring around the outside
    /// rather than being flung wherever the repulsion sends them: they are not
    /// part of the shape, but they are part of the library, and a graph that
    /// hides them would be telling a comfortable lie.
    nonisolated static func layout(
        papers: [(id: UUID, title: String, year: Int?)],
        edges: [Edge],
        degrees: [UUID: Int]
    ) async -> [Node] {
        await Task.detached(priority: .userInitiated) {
            guard !papers.isEmpty else { return [] }
            let connected = papers.filter { (degrees[$0.id] ?? 0) > 0 }
            let lonely = papers.filter { (degrees[$0.id] ?? 0) == 0 }
            var positions: [UUID: CGPoint] = [:]

            if !connected.isEmpty {
                let count = connected.count
                // How far apart two papers want to be. Raised from 1,400:
                // at the old spacing a library of this size settled into one
                // dense ball where a dot was a smudge where several edges
                // crossed, and the picture said nothing except "these are all
                // related", which is not a finding.
                let ideal = sqrt(2_100 * 2_100 / Double(count))
                for (index, paper) in connected.enumerated() {
                    let angle = Double(index) / Double(count) * 2 * .pi
                    let radius = ideal * (1.2 + Double((index * 37) % 100) / 220)
                    positions[paper.id] = CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
                }

                var temperature = ideal * 1.2
                let iterations = count > 120 ? 220 : 400
                let ids = connected.map(\.id)
                let inside = Set(ids)
                let springs = edges.filter { inside.contains($0.a) && inside.contains($0.b) }

                for _ in 0..<iterations {
                    var forces: [UUID: CGVector] = [:]
                    for (offset, first) in ids.enumerated() {
                        for second in ids.dropFirst(offset + 1) {
                            let a = positions[first]!, b = positions[second]!
                            var dx = a.x - b.x, dy = a.y - b.y
                            var distance = sqrt(dx * dx + dy * dy)
                            if distance < 0.01 {
                                dx = Double((first.hashValue % 17) + 1) * 0.1
                                dy = Double((second.hashValue % 13) + 1) * 0.1
                                distance = sqrt(dx * dx + dy * dy)
                            }
                            let push = ideal * ideal / distance
                            let fx = dx / distance * push, fy = dy / distance * push
                            forces[first, default: .zero].dx += fx
                            forces[first, default: .zero].dy += fy
                            forces[second, default: .zero].dx -= fx
                            forces[second, default: .zero].dy -= fy
                        }
                    }
                    for edge in springs {
                        guard let a = positions[edge.a], let b = positions[edge.b] else { continue }
                        let dx = a.x - b.x, dy = a.y - b.y
                        let distance = max(sqrt(dx * dx + dy * dy), 0.01)
                        let pull = distance * distance / ideal * min(edge.weight, 1.5)
                        let fx = dx / distance * pull, fy = dy / distance * pull
                        forces[edge.a, default: .zero].dx -= fx
                        forces[edge.a, default: .zero].dy -= fy
                        forces[edge.b, default: .zero].dx += fx
                        forces[edge.b, default: .zero].dy += fy
                    }
                    for id in ids {
                        var point = positions[id]!
                        // A pull to the middle, so a paper joined to the rest
                        // by one thread does not drift off the sheet.
                        let distance = max(sqrt(point.x * point.x + point.y * point.y), 0.01)
                        let gravity = distance / ideal * 0.9
                        forces[id, default: .zero].dx -= point.x / distance * gravity
                        forces[id, default: .zero].dy -= point.y / distance * gravity

                        let force = forces[id] ?? .zero
                        let magnitude = max(sqrt(force.dx * force.dx + force.dy * force.dy), 0.01)
                        let step = min(magnitude, temperature)
                        point.x += force.dx / magnitude * step
                        point.y += force.dy / magnitude * step
                        positions[id] = point
                    }
                    temperature = max(temperature * 0.97, ideal * 0.01)
                }

                // Then simply push apart anything still touching. A force
                // layout balances attraction against repulsion and is
                // perfectly happy to leave two dots on top of each other; the
                // eye is not. This settles quickly because by now almost
                // nothing needs moving.
                let minimum = ideal * 0.5
                for _ in 0..<60 {
                    var moved = false
                    for (offset, first) in ids.enumerated() {
                        for second in ids.dropFirst(offset + 1) {
                            let a = positions[first]!, b = positions[second]!
                            let dx = a.x - b.x, dy = a.y - b.y
                            let distance = sqrt(dx * dx + dy * dy)
                            guard distance < minimum else { continue }
                            let safe = max(distance, 0.01)
                            let shove = (minimum - safe) / 2
                            let ux = dx / safe * shove, uy = dy / safe * shove
                            positions[first] = CGPoint(x: a.x + ux, y: a.y + uy)
                            positions[second] = CGPoint(x: b.x - ux, y: b.y - uy)
                            moved = true
                        }
                    }
                    if !moved { break }
                }
            }

            // The papers nothing has been connected to yet, on a shelf under
            // the rest.
            //
            // They used to sit in a ring around everything, and a ring was
            // wrong twice over. It says these papers surround the shape and
            // belong to it, when the point is that they do not; and a circle
            // of radius R makes the drawing 2R square, so the part worth
            // looking at was fitted into a quarter of the view while six
            // unconnected dots held the corners. A row underneath says
            // "also in the library, not yet part of this" — and it costs the
            // picture almost nothing.
            if !lonely.isEmpty {
                let ideal = sqrt(2_100 * 2_100 / Double(max(connected.count, 1)))
                let extent = positions.values.reduce(
                    into: (minX: 0.0, maxX: 0.0, maxY: 0.0)
                ) { box, point in
                    box.minX = min(box.minX, point.x)
                    box.maxX = max(box.maxX, point.x)
                    box.maxY = max(box.maxY, point.y)
                }
                let width = max(extent.maxX - extent.minX, ideal * 4)
                let gap = ideal * 0.5
                let perRow = max(Int(width / gap), 1)
                let top = extent.maxY + ideal * 1.1

                for (index, paper) in lonely.enumerated() {
                    let row = index / perRow
                    let column = index % perRow
                    // Each row is centred on the cluster rather than left
                    // aligned to it, so a short last row does not hang off.
                    let inRow = min(lonely.count - row * perRow, perRow)
                    let rowWidth = Double(inRow - 1) * gap
                    let centre = (extent.minX + extent.maxX) / 2
                    positions[paper.id] = CGPoint(
                        x: centre - rowWidth / 2 + Double(column) * gap,
                        y: top + Double(row) * gap
                    )
                }
            }

            return papers.map { paper in
                Node(
                    id: paper.id,
                    title: paper.title,
                    year: paper.year,
                    degree: degrees[paper.id] ?? 0,
                    position: positions[paper.id] ?? .zero
                )
            }
        }.value
    }
}
