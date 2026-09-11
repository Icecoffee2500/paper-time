import PaperCore
import SwiftUI

/// The library, drawn.
///
/// Papers are dots, sized by how connected they are; the lines are why they are
/// connected. Dragging moves the sheet, a pinch or scroll zooms, clicking a dot
/// picks a paper and dims everything it does not touch, and a double click
/// opens it.
struct PaperGraphView: View {
    let model: LibraryModel
    let graph: GraphModel

    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    /// What the current drag took hold of, decided when it started.
    @State private var dragging: Dragging?
    @State private var gestureZoom: CGFloat = 1
    @State private var gesturePan: CGSize = .zero
    @State private var hovered: UUID?

    var body: some View {
        GeometryReader { geometry in
            let transform = Transform(
                size: geometry.size,
                zoom: zoom * gestureZoom,
                pan: CGSize(
                    width: pan.width + gesturePan.width,
                    height: pan.height + gesturePan.height
                ),
                bounds: bounds
            )

            Canvas { context, size in
                draw(in: &context, size: size, transform: transform)
            }
            // No background of its own: the canvas was an opaque white
            // rectangle sitting inside a glass panel, the same way the lists
            // were. `contentShape` is what makes it catch the gestures, so
            // nothing is lost by taking the fill away.
            .contentShape(.rect)
            .gesture(dragGesture(transform: transform))
            .simultaneousGesture(magnifyGesture)
            .onTapGesture(count: 2) { point in
                if let id = paper(at: point, transform: transform) { open(id) }
            }
            .onTapGesture { point in
                let id = paper(at: point, transform: transform)
                graph.selection = id
                if id == nil { graph.focusesOnSelection = false }
                graph.reheat(0.3)
            }
            .onContinuousHover { phase in
                switch phase {
                case let .active(point): hovered = paper(at: point, transform: transform)
                case .ended: hovered = nil
                }
            }
            .overlay(alignment: .topTrailing) { controls }
            .overlay(alignment: .bottom) { caption }
            .overlay { emptyState }
        }
        .task { await graph.buildIfNeeded(from: model) }
        // The forces keep running under it. Sleeping longer once it has come
        // to rest means an idle graph costs nothing, and anything the reader
        // does puts motion back in and wakes this up again.
        .task {
            while !Task.isCancelled {
                graph.step()
                try? await Task.sleep(for: .milliseconds(graph.isSettling ? 16 : 120))
            }
        }
        // Papers arriving, or notes linking to each other, change the shape of
        // the thing being looked at.
        .onChange(of: model.papers.count) { _, _ in
            Task { await graph.build(from: model) }
        }
        .onChange(of: model.notes.notes.count) { _, _ in
            Task { await graph.build(from: model) }
        }
    }

    // MARK: - Drawing

    private func draw(in context: inout GraphicsContext, size: CGSize, transform: Transform) {
        let selected = graph.selection
        let highlighted = selected.map { graph.neighbours(of: $0) } ?? []
        let focus = hovered ?? selected

        for edge in graph.visibleEdges {
            guard let a = graph.node(edge.a), let b = graph.node(edge.b) else { continue }
            guard graph.isVisible(edge.a), graph.isVisible(edge.b) else { continue }
            let touchesFocus = focus == nil || edge.a == focus || edge.b == focus
            var path = Path()
            path.move(to: transform.point(a.position))
            path.addLine(to: transform.point(b.position))
            let kind = edge.kinds.min { $0.weight > $1.weight } ?? .filed
            context.stroke(
                path,
                with: .color(color(for: kind).opacity(touchesFocus ? 0.75 : 0.16)),
                lineWidth: touchesFocus ? 1.6 : 1
            )
        }

        for node in graph.nodes {
            guard graph.isVisible(node.id) else { continue }
            let point = transform.point(node.position)
            let radius = radius(for: node) * min(max(transform.zoom, 0.6), 1.8)
            let isFocus = node.id == focus
            let isNear = selected != nil && highlighted.contains(node.id)
            let dim = focus != nil && !isFocus && !isNear

            let circle = Path(ellipseIn: CGRect(
                x: point.x - radius, y: point.y - radius,
                width: radius * 2, height: radius * 2
            ))
            // A halo first, in the colour of the surface, so the dot sits on
            // the lines rather than in them. Without it a node in a dense
            // patch is a smudge where several edges cross.
            context.fill(
                Path(ellipseIn: CGRect(
                    x: point.x - radius - 2, y: point.y - radius - 2,
                    width: (radius + 2) * 2, height: (radius + 2) * 2
                )),
                with: .color(Color(nsColor: .textBackgroundColor).opacity(dim ? 0.35 : 0.9))
            )
            context.fill(
                circle,
                with: .color(isFocus ? Color.accentColor
                             : Color.primary.opacity(dim ? 0.16 : 0.42))
            )
            if isFocus || isNear {
                context.stroke(
                    circle,
                    with: .color(Color.accentColor.opacity(isFocus ? 0.9 : 0.45)),
                    lineWidth: isFocus ? 2.5 : 1.5
                )
            }

            // Names appear when there is room for them. Everything a hub
            // touches, labelled at once, is a pile of text rather than a
            // graph, so the neighbours wait until the view is zoomed in.
            let showsLabel = isFocus || (transform.zoom > 1.3 && (node.degree > 0 || isNear))
            guard showsLabel else { continue }
            let text = Text(Self.shortened(node.title))
                .font(.system(size: 10, weight: isFocus ? .semibold : .regular))
                .foregroundStyle(dim ? .tertiary : .primary)
            context.draw(
                context.resolve(text),
                at: CGPoint(x: point.x, y: point.y + radius + 9),
                anchor: .top
            )
        }
    }

    /// A title cut to what fits under a dot.
    private static func shortened(_ title: String) -> String {
        title.count <= 42 ? title : String(title.prefix(40)) + "…"
    }

    private func radius(for node: GraphModel.Node) -> CGFloat {
        3 + min(CGFloat(node.degree), 24).squareRoot() * 1.7
    }

    private func color(for kind: GraphModel.EdgeKind) -> Color {
        switch kind {
        case .cites: .accentColor
        case .note: .green
        case .author: .orange
        case .filed: .secondary
        }
    }

    // MARK: - Chrome

    /// The legend, which is also the filter.
    ///
    /// One panel rather than four pills stacked in a corner. They were four
    /// separate floating things that happened to be near each other, and they
    /// read as clutter over the drawing; grouped, they read as a legend, which
    /// is what they are — and it is clearer that a line in it can be switched
    /// off, which is the whole use of the thing.
    private var controls: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("SHOWING")
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)

            ForEach(GraphModel.EdgeKind.allCases, id: \.self) { kind in
                let isOn = graph.shownKinds.contains(kind)
                Button {
                    if isOn { graph.shownKinds.remove(kind) } else { graph.shownKinds.insert(kind) }
                } label: {
                    HStack(spacing: 8) {
                        Capsule()
                            .fill(isOn ? color(for: kind) : Color.secondary.opacity(0.35))
                            .frame(width: 16, height: 3)
                        Text(kind.label)
                            .font(.caption)
                        Spacer(minLength: 8)
                        Image(systemName: isOn ? "checkmark" : "")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 10)
                    }
                    .foregroundStyle(isOn ? .primary : .tertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .frame(width: 172)
        .liquidGlass(.floating, in: RoundedRectangle(cornerRadius: Corner.popover, style: .continuous))
        .padding(12)
    }

    @ViewBuilder
    private var caption: some View {
        if let id = hovered ?? graph.selection, let node = graph.node(id) {
            VStack(spacing: 2) {
                Text(node.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(summary(for: id, node: node))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: 420)
            .liquidGlass(.floating, in: Capsule(style: .continuous))
            .padding(.bottom, 16)
        }
    }

    private func summary(for id: UUID, node: GraphModel.Node) -> String {
        var parts: [String] = []
        if let year = node.year { parts.append(String(year)) }
        let links = graph.visibleEdges.filter { $0.a == id || $0.b == id }
        parts.append(links.count == 1 ? "1 connection" : "\(links.count) connections")
        let kinds = Set(links.flatMap(\.kinds)).sorted { $0.label < $1.label }
        if !kinds.isEmpty {
            parts.append(kinds.map(\.label).joined(separator: " · "))
        }
        return parts.joined(separator: "  ·  ")
    }

    @ViewBuilder
    private var emptyState: some View {
        if graph.isBuilding, graph.nodes.isEmpty {
            VStack(spacing: 10) {
                ProgressView()
                if let progress = graph.progress {
                    Text("Reading papers for references… \(progress.done) of \(progress.total)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Working out the connections…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .background(.regularMaterial, in: RoundedRectangle(
                cornerRadius: Corner.popover, style: .continuous
            ))
        } else if graph.nodes.isEmpty {
            ContentUnavailableView {
                Label("Nothing to Connect Yet", systemImage: "point.3.connected.trianglepath.dotted")
            } description: {
                Text("Add a few papers, and the graph will show what they have in common.")
            }
        }
    }

    // MARK: - Gestures

    /// One gesture for both: take hold of a paper, or take hold of the sheet.
    ///
    /// Which one it is depends on where it started, decided once at the
    /// beginning and kept for the rest of the drag — a graph where the thing
    /// you are pulling changes halfway through is unusable.
    private func dragGesture(transform: Transform) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if dragging == nil {
                    dragging = paper(at: value.startLocation, transform: transform)
                        .map { Dragging.paper($0) } ?? .sheet
                    if case let .paper(id) = dragging {
                        graph.beginHolding(id, at: transform.position(value.startLocation))
                    }
                }
                switch dragging {
                case let .paper(id):
                    _ = id
                    graph.hold(at: transform.position(value.location))
                case .sheet, .none:
                    gesturePan = value.translation
                }
            }
            .onEnded { value in
                switch dragging {
                case .paper:
                    graph.endHolding()
                case .sheet, .none:
                    pan.width += value.translation.width
                    pan.height += value.translation.height
                    gesturePan = .zero
                }
                dragging = nil
            }
    }

    private enum Dragging {
        case paper(UUID)
        case sheet
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { gesturePan = $0.translation }
            .onEnded { value in
                pan.width += value.translation.width
                pan.height += value.translation.height
                gesturePan = .zero
            }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { gestureZoom = $0.magnification }
            .onEnded { value in
                zoom = min(max(zoom * value.magnification, 0.35), 4)
                gestureZoom = 1
            }
    }

    private func open(_ id: UUID) {
        model.scope = .all
        model.selectedPaperID = id
    }

    private func paper(at point: CGPoint, transform: Transform) -> UUID? {
        var best: (id: UUID, distance: CGFloat)?
        for node in graph.nodes where graph.isVisible(node.id) {
            let centre = transform.point(node.position)
            let distance = hypot(centre.x - point.x, centre.y - point.y)
            let reach = max(radius(for: node) * transform.zoom, 10) + 6
            guard distance <= reach else { continue }
            if best == nil || distance < best!.distance { best = (node.id, distance) }
        }
        return best?.id
    }

    private var bounds: CGRect {
        // Only what is being shown. With focus on, the view was still being
        // fitted to every paper in the library, so the dozen left after the
        // filter sat in a corner at the scale of the whole thing — the filter
        // worked and looked as though it had not.
        let shown = graph.nodes.filter { graph.isVisible($0.id) }
        guard let first = shown.first?.position else { return CGRect(x: -1, y: -1, width: 2, height: 2) }
        var rect = CGRect(origin: first, size: .zero)
        for node in shown {
            rect = rect.union(CGRect(origin: node.position, size: .zero))
        }
        // A margin in proportion to the drawing, not 60 units of graph space:
        // that was a fixed number in a coordinate system whose scale depends
        // on how many papers there are, so on a large library it came to a few
        // screen points and the outermost dots were clipped by the edge.
        let margin = max(rect.width, rect.height) * 0.06
        return rect.insetBy(dx: -margin, dy: -margin)
    }

    /// Graph space to screen space: fit the whole thing, then zoom and pan.
    private struct Transform {
        let scale: CGFloat
        let offset: CGSize
        let zoom: CGFloat
        let centre: CGPoint
        let origin: CGPoint

        init(size: CGSize, zoom: CGFloat, pan: CGSize, bounds: CGRect) {
            let fit = min(
                size.width / max(bounds.width, 1),
                size.height / max(bounds.height, 1)
            )
            self.scale = fit * zoom
            self.zoom = zoom
            self.offset = pan
            self.centre = CGPoint(x: bounds.midX, y: bounds.midY)
            self.origin = CGPoint(x: size.width / 2, y: size.height / 2)
        }

        /// Screen back to graph, for putting a dragged paper where the
        /// pointer is.
        func position(_ point: CGPoint) -> CGPoint {
            CGPoint(
                x: centre.x + (point.x - origin.x - offset.width) / scale,
                y: centre.y + (point.y - origin.y - offset.height) / scale
            )
        }

        func point(_ position: CGPoint) -> CGPoint {
            CGPoint(
                x: origin.x + (position.x - centre.x) * scale + offset.width,
                y: origin.y + (position.y - centre.y) * scale + offset.height
            )
        }
    }
}
