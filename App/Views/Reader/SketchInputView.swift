#if os(macOS)
import AppKit
import InkEngine
import PDFKit
import PDFReader
import PencilKit

/// The view over the PDF that does the drawing on the Mac.
///
/// PDFKit's page overlays see no mouse — every click goes to its inner
/// document view — so while the pencil is out this sits over the whole PDF
/// view and takes the mouse itself: strokes for the pen, boxes and arrows for
/// the shape tools, and for the selection tool the moving, resizing, bending,
/// grouping and typing that Figma makes second nature. What it has drawn goes
/// to the session — ink into the page's drawing, shapes into its sketch — and
/// the page overlays draw the result; this view only ever shows what is in
/// the middle of happening: the stroke under the pointer, the box being
/// dragged out, the handles round the selection, the names of the frames.
///
/// Scrolling and pinching are passed down to the PDF view's scroll view, so
/// the page still moves under the tools the way it does under the pencil on
/// the iPad.
@MainActor
final class SketchInputView: NSView, SketchEditing {
    private weak var pdfView: PDFView?
    private let configuration: ReaderConfiguration
    var session: DocumentSession
    /// Redraws a page's overlays — its shapes and its ink — after this view
    /// hid or unhid part of them.
    var refreshPage: ((Int) -> Void)?
    /// The eraser, over a highlight: the coordinator knows how to take a
    /// mark off and register the undo for it.
    var eraseMark: ((PDFPage, CGPoint) -> Void)?
    var onToast: ((String) -> Void)?

    private var state: SketchState { configuration.sketch }

    // MARK: State

    /// What is chosen: the outermost elements — a group, not the things in
    /// it — and pen strokes by their index.
    struct Selection: Equatable {
        var pageIndex: Int?
        var elements: Set<UUID> = []
        var strokes: Set<Int> = []
        var isEmpty: Bool { elements.isEmpty && strokes.isEmpty }
    }

    private(set) var selection = Selection() {
        didSet { if selection != oldValue { selectionDidChange(from: oldValue) } }
    }

    /// The group a double-click went into, whose children are chosen one
    /// at a time until the selection leaves it.
    private var entered: UUID?

    /// Where a box's handles are.
    enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
        case start, end, mid
    }

    private enum Drag {
        /// A shape being dragged out.
        case shape(SketchElement)
        /// A text box being dragged out to a width.
        case textBox(origin: CGPoint, current: CGPoint)
        /// A pen or highlighter stroke, in page coordinates.
        case stroke(points: [CGPoint], times: [TimeInterval], began: Date, pressures: [CGFloat])
        /// The eraser passing over the page.
        case erase(drawingBefore: PKDrawing, elementsBefore: [SketchElement], last: CGPoint)
        /// The selection being moved — perhaps onto another page.
        case move(elementsBefore: [SketchElement], drawingBefore: PKDrawing, origin: CGPoint, moved: Bool)
        /// One box being resized by a handle, or a connector's end moved.
        case resize(elementsBefore: [SketchElement], original: SketchElement, handle: Handle, origin: CGPoint)
        /// A connector's middle being pulled.
        case bend(elementsBefore: [SketchElement], original: SketchElement)
        /// A rectangle being dragged over the page to select what it covers.
        case marquee(origin: CGPoint, current: CGPoint, additive: Bool, before: Selection)
        /// A click on empty paper that has not yet become a marquee.
        case pendingClick(origin: CGPoint, additive: Bool, before: Selection)
    }

    private var drag: Drag?
    /// The page a drag began on.
    private var dragPage: (page: PDFPage, index: Int)?
    /// The page the pointer is over during a move — the page the selection
    /// will land on, which is the drag page until the pointer leaves it.
    private var moveTarget: (page: PDFPage, index: Int)?
    /// The elements as they are mid-drag, drawn here instead of the overlay.
    /// During a move they are in the target page's coordinates.
    private var working: [SketchElement] = []
    /// The strokes as they are mid-drag.
    private var workingDrawing: PKDrawing?

    private var textEditor: SketchTextEditor?
    private var editing: (id: UUID, page: PDFPage, index: Int, before: [SketchElement], isNew: Bool)?

    // Removed in `deinit`, which is why they are unsafe rather than isolated.
    nonisolated(unsafe) private var observers: [any NSObjectProtocol] = []
    private var stateObservation: Task<Void, Never>?

    init(pdfView: PDFView, configuration: ReaderConfiguration, session: DocumentSession) {
        self.pdfView = pdfView
        self.configuration = configuration
        self.session = session
        super.init(frame: pdfView.bounds)
        autoresizingMask = [.width, .height]
        wantsLayer = true
        // The page moving under the tools: the handles follow it.
        let centre = NotificationCenter.default
        if let clip = pdfView.documentView?.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            observers.append(centre.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.pageMoved() }
            })
        }
        observers.append(centre.addObserver(forName: .PDFViewScaleChanged, object: pdfView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pageMoved() }
        })
        observers.append(centre.addObserver(forName: .paperTimeSketchChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sketchChangedElsewhere() }
        })
        observeState()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    /// Follows the tool and the style, for the cursor and the redraw.
    private func observeState() {
        stateObservation?.cancel()
        withObservationTracking {
            _ = state.tool
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                toolChanged()
                observeState()
            }
        }
    }

    private func toolChanged() {
        window?.invalidateCursorRects(for: self)
        // Picking a drawing tool lets go of what was chosen and closes the
        // words being typed. Coming back to Select does neither: the text
        // tool itself comes back to Select as it opens the editor, and the
        // observation arrives a moment after it did.
        guard state.tool != .select else { return }
        if !selection.isEmpty { selection = Selection() }
        if textEditor != nil { endEditing(commit: true) }
        needsDisplay = true
    }

    /// The page's elements changed under the selection — an undo, another
    /// device — so whatever it named that is no longer there is let go of.
    private func sketchChangedElsewhere() {
        if let index = selection.pageIndex {
            let present = Set(elements(on: index).map(\.id))
            let kept = selection.elements.intersection(present)
            if kept != selection.elements {
                selection = kept.isEmpty && selection.strokes.isEmpty ? Selection() : Selection(pageIndex: index, elements: kept, strokes: selection.strokes)
            } else {
                refreshSelectionState()
            }
        }
        needsDisplay = true
    }

    private func pageMoved() {
        needsDisplay = true
        if let editor = textEditor, let editing, let element = elements(on: editing.index).first(where: { $0.id == editing.id }) {
            editor.frame = editorFrame(for: element, on: editing.page)
            editor.font = editorFont(for: element, on: editing.page)
        }
    }

    /// Called by the coordinator when the view goes on: the mouse is ours.
    func activate() {
        window?.makeFirstResponder(self)
        state.editor = self
        window?.invalidateCursorRects(for: self)
    }

    /// Called when the pencil goes away: whatever was half done is finished.
    func deactivate() {
        if textEditor != nil { endEditing(commit: true) }
        drag = nil
        dragPage = nil
        moveTarget = nil
        working = []
        workingDrawing = nil
        entered = nil
        selection = Selection()
        if state.editor === self { state.editor = nil }
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }
    override var undoManager: UndoManager? { window?.undoManager }

    // MARK: - Where things are

    private struct Spot {
        let page: PDFPage
        let index: Int
        /// In page coordinates, kept on the page.
        let point: CGPoint
    }

    /// The page under the pointer, and where on it. `clamped` keeps the
    /// point on the page; off, a point past the edge stays past it.
    private func spot(for event: NSEvent, clamped: Bool = true) -> Spot? {
        guard let pdfView else { return nil }
        let inPDF = pdfView.convert(event.locationInWindow, from: nil)
        guard let page = pdfView.page(for: inPDF, nearest: true) else { return nil }
        let index = session.document.index(for: page)
        guard index != NSNotFound else { return nil }
        var point = pdfView.convert(inPDF, to: page)
        if clamped {
            let box = page.bounds(for: pdfView.displayBox)
            point.x = min(max(point.x, box.minX), box.maxX)
            point.y = min(max(point.y, box.minY), box.maxY)
        }
        return Spot(page: page, index: index, point: point)
    }

    /// The pointer's place on a given page, kept on it.
    private func point(of event: NSEvent, on page: PDFPage) -> CGPoint {
        guard let pdfView else { return .zero }
        let inPDF = pdfView.convert(event.locationInWindow, from: nil)
        let box = page.bounds(for: pdfView.displayBox)
        var p = pdfView.convert(inPDF, to: page)
        p.x = min(max(p.x, box.minX), box.maxX)
        p.y = min(max(p.y, box.minY), box.maxY)
        return p
    }

    private func page(at index: Int) -> PDFPage? { session.document.page(at: index) }

    private func pageBox(_ page: PDFPage) -> CGRect {
        page.bounds(for: pdfView?.displayBox ?? .cropBox)
    }

    /// Page coordinates to this view's.
    private func viewPoint(_ point: CGPoint, on page: PDFPage) -> CGPoint {
        guard let pdfView else { return point }
        return convert(pdfView.convert(point, from: page), from: pdfView)
    }

    private func viewRect(_ rect: CGRect, on page: PDFPage) -> CGRect {
        let a = viewPoint(CGPoint(x: rect.minX, y: rect.minY), on: page)
        let b = viewPoint(CGPoint(x: rect.maxX, y: rect.maxY), on: page)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    /// The transform taking the page's coordinates onto this view — worked
    /// out from three points, so a flipped or rotated page comes out right.
    private func transform(for page: PDFPage) -> CGAffineTransform {
        let o = viewPoint(.zero, on: page)
        let x = viewPoint(CGPoint(x: 1, y: 0), on: page)
        let y = viewPoint(CGPoint(x: 0, y: 1), on: page)
        return CGAffineTransform(a: x.x - o.x, b: x.y - o.y, c: y.x - o.x, d: y.y - o.y, tx: o.x, ty: o.y)
    }

    /// Screen points per page point.
    private func scale(for page: PDFPage) -> CGFloat {
        let o = viewPoint(.zero, on: page)
        let x = viewPoint(CGPoint(x: 1, y: 0), on: page)
        return max(hypot(x.x - o.x, x.y - o.y), 0.01)
    }

    /// The reach of a click, in page points: the same six points on screen
    /// whatever the zoom.
    private func tolerance(on page: PDFPage) -> CGFloat { 6 / scale(for: page) }

    private func elements(on index: Int) -> [SketchElement] { session.sketch(forPage: index) }
    private func tree(on index: Int) -> SketchTree { SketchTree(elements(on: index)) }

    // MARK: - What the overlays should leave to us

    /// The elements this view is drawing itself at the moment: mid-drag, or
    /// being typed into. The page overlay leaves them out.
    func hiddenElementIDs(onPage index: Int) -> Set<UUID> {
        var ids: Set<UUID> = []
        if let editing, editing.index == index { ids.insert(editing.id) }
        guard dragPage?.index == index, let drag else { return ids }
        switch drag {
        case .move, .resize, .bend: ids.formUnion(working.map(\.id))
        default: break
        }
        return ids
    }

    /// The pen strokes being moved, which the ink overlay leaves out.
    func hiddenStrokeIndices(onPage index: Int) -> Set<Int> {
        guard dragPage?.index == index, case .move = drag else { return [] }
        return selection.strokes
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        if textEditor != nil { endEditing(commit: true) }
        guard let spot = spot(for: event) else { return }
        window?.makeFirstResponder(self)
        // With several papers open side by side, the inspector follows the
        // pane last clicked in.
        state.editor = self
        let additive = event.modifierFlags.contains(.shift)
        dragPage = (spot.page, spot.index)
        moveTarget = nil

        switch state.tool {
        case .select:
            beginSelecting(at: spot, additive: additive, clicks: event.clickCount)
        case .pen, .highlighter:
            let pressure = event.subtype == .tabletPoint ? CGFloat(event.pressure) : 1
            drag = .stroke(points: [spot.point], times: [0], began: .now, pressures: [pressure])
        case .eraser:
            drag = .erase(drawingBefore: session.drawing(forPage: spot.index), elementsBefore: elements(on: spot.index), last: spot.point)
            erase(at: spot, from: spot.point)
        case .rectangle, .ellipse, .arrow, .line, .frame:
            guard let kind = state.tool.makes else { return }
            var style = state.style
            if kind == .line { style.startHead = .none; style.endHead = .none }
            var element = SketchElement(kind: kind, points: [spot.point, spot.point], style: style)
            if kind == .frame {
                // A frame is a place, not a shape: an outline and a name,
                // whatever the next shape's style was going to be.
                element.style.fill = nil
                element.style.startHead = .none
                element.style.endHead = .none
                element.style.corners = .round
                element.name = nextFrameName(on: spot.index)
            }
            drag = .shape(element)
        case .text:
            drag = .textBox(origin: spot.point, current: spot.point)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag, let (page, index) = dragPage, let pdfView else { return }
        // Stay on the page the drag began on, even when the pointer leaves it
        // — except for a move, which may be taking the selection to another
        // page altogether.
        let p = point(of: event, on: page)
        let shift = event.modifierFlags.contains(.shift)

        switch drag {
        case var .shape(element):
            var end = p
            if shift {
                // A square, a circle, or a line at a clean angle.
                let dx = end.x - element.start.x, dy = end.y - element.start.y
                if element.isConnector {
                    let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
                    let length = hypot(dx, dy)
                    end = CGPoint(x: element.start.x + cos(angle) * length, y: element.start.y + sin(angle) * length)
                } else {
                    let side = max(abs(dx), abs(dy))
                    end = CGPoint(x: element.start.x + side * (dx < 0 ? -1 : 1), y: element.start.y + side * (dy < 0 ? -1 : 1))
                }
            }
            element.points = [element.start, end]
            self.drag = .shape(element)
        case let .textBox(origin, _):
            self.drag = .textBox(origin: origin, current: p)
        case .stroke(var points, var times, let began, var pressures):
            if let last = points.last, hypot(p.x - last.x, p.y - last.y) < 0.6 / scale(for: page) { return }
            points.append(p)
            times.append(Date.now.timeIntervalSince(began))
            pressures.append(event.subtype == .tabletPoint ? CGFloat(event.pressure) : 1)
            self.drag = .stroke(points: points, times: times, began: began, pressures: pressures)
        case let .erase(drawingBefore, elementsBefore, last):
            erase(at: Spot(page: page, index: index, point: p), from: last)
            self.drag = .erase(drawingBefore: drawingBefore, elementsBefore: elementsBefore, last: p)
        case let .move(elementsBefore, drawingBefore, origin, _):
            // The page under the pointer is where the selection is going;
            // the offset from where the drag began keeps the grip.
            let target = spot(for: event) ?? Spot(page: page, index: index, point: p)
            let landing = target.point
            let offset = CGPoint(x: landing.x - origin.x, y: landing.y - origin.y)
            let before = SketchTree(elementsBefore)
            let moving = before.expanded(selection.elements)
            working = elementsBefore.filter { moving.contains($0.id) }.map { $0.translated(by: offset) }
            if !selection.strokes.isEmpty {
                let from = PageGeometry(page: page).canvasPoint(fromPDF: origin)
                let to = PageGeometry(page: target.page).canvasPoint(fromPDF: landing)
                let shift = CGAffineTransform(translationX: to.x - from.x, y: to.y - from.y)
                var strokes = drawingBefore.strokes
                for i in selection.strokes where i < strokes.count {
                    strokes[i].transform = strokes[i].transform.concatenating(shift)
                }
                workingDrawing = PKDrawing(strokes: strokes)
            }
            moveTarget = (target.page, target.index)
            self.drag = .move(elementsBefore: elementsBefore, drawingBefore: drawingBefore, origin: origin, moved: true)
            refreshPage?(index)
        case let .resize(elementsBefore, original, handle, _):
            working = resized(original, by: handle, to: p, shift: shift, in: SketchTree(elementsBefore))
            self.drag = .resize(elementsBefore: elementsBefore, original: original, handle: handle, origin: p)
            refreshPage?(index)
        case let .bend(_, original):
            var bent = original
            bent.setMidpoint(p)
            working = [bent]
            refreshPage?(index)
        case let .pendingClick(origin, additive, before):
            let moved = hypot(p.x - origin.x, p.y - origin.y) * scale(for: page)
            if moved > 3 {
                self.drag = .marquee(origin: origin, current: p, additive: additive, before: before)
                updateMarquee(origin: origin, current: p, additive: additive, before: before, on: page, index: index)
            }
        case let .marquee(origin, _, additive, before):
            self.drag = .marquee(origin: origin, current: p, additive: additive, before: before)
            updateMarquee(origin: origin, current: p, additive: additive, before: before, on: page, index: index)
        }
        _ = pdfView
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            drag = nil
            moveTarget = nil
            working = []
            workingDrawing = nil
            needsDisplay = true
        }
        guard let drag, let (page, index) = dragPage else { return }
        switch drag {
        case let .shape(element):
            let box = element.rect
            let big = element.isConnector
                ? hypot(element.end.x - element.start.x, element.end.y - element.start.y) > 3
                : box.width > 3 && box.height > 3
            guard big else { return }
            let before = elements(on: index)
            var after = before
            after.append(element)
            if element.kind == .frame {
                // Drawn round things, a frame takes them in — as Figma's does.
                let tree = SketchTree(before)
                for root in tree.roots where root != element.id {
                    let inside = tree.bounds(of: root)
                    guard !inside.isNull, element.rect.contains(inside) else { continue }
                    if let i = after.firstIndex(where: { $0.id == root }) { after[i].parent = element.id }
                }
            } else {
                after = adopted([element.id], in: after)
            }
            apply(after, on: index, before: before, name: undoName(for: element.kind))
            // The shape drawn, the pointer goes back to choosing — as it does
            // in Figma — with the new shape chosen, so the panel is about it.
            state.tool = .select
            selection = Selection(pageIndex: index, elements: [element.id])
        case let .textBox(origin, current):
            let width = abs(current.x - origin.x)
            if width * scale(for: page) < 8 {
                createText(at: Spot(page: page, index: index, point: origin), width: nil)
            } else {
                let corner = CGPoint(x: min(origin.x, current.x), y: max(origin.y, current.y))
                createText(at: Spot(page: page, index: index, point: corner), width: width)
            }
        case let .stroke(points, times, _, pressures):
            finishStroke(points: points, times: times, pressures: pressures, on: page, index: index)
        case let .erase(drawingBefore, elementsBefore, _):
            let drawingAfter = session.drawing(forPage: index)
            let elementsAfter = elements(on: index)
            guard drawingAfter != drawingBefore || elementsAfter != elementsBefore else { return }
            registerUndo(
                name: L("지우기", "Erase"), on: index,
                elements: (elementsBefore, elementsAfter), drawing: (drawingBefore, drawingAfter)
            )
        case let .move(elementsBefore, drawingBefore, _, moved):
            guard moved else { return }
            finishMove(from: (page, index), elementsBefore: elementsBefore, drawingBefore: drawingBefore)
        case let .resize(elementsBefore, original, _, _):
            guard working.first(where: { $0.id == original.id }) != original else { refreshPage?(index); return }
            var after = elementsBefore
            for changed in working {
                if let i = after.firstIndex(where: { $0.id == changed.id }) { after[i] = changed }
            }
            apply(after, on: index, before: elementsBefore, name: L("모양 바꾸기", "Reshape"))
        case let .bend(elementsBefore, original):
            guard let changed = working.first, changed != original else { refreshPage?(index); return }
            var after = elementsBefore
            if let i = after.firstIndex(where: { $0.id == changed.id }) { after[i] = changed }
            apply(after, on: index, before: elementsBefore, name: L("모양 바꾸기", "Reshape"))
        case .marquee, .pendingClick:
            break
        }
    }

    /// Puts a moved selection down — on the page it came from, or on the
    /// page the pointer ended over, in which case it leaves one page's
    /// sidecar and joins the other's as one undoable step.
    private func finishMove(from source: (page: PDFPage, index: Int), elementsBefore: [SketchElement], drawingBefore: PKDrawing) {
        let target = moveTarget ?? source
        let tree = SketchTree(elementsBefore)
        let moving = tree.expanded(selection.elements)
        let drawingAfter = workingDrawing ?? drawingBefore

        if target.index == source.index {
            var after = elementsBefore
            for changed in working {
                if let i = after.firstIndex(where: { $0.id == changed.id }) { after[i] = changed }
            }
            after = adopted(tree.outermost(selection.elements), in: after)
            let normalized = SketchTree.normalized(after)
            if normalized != elementsBefore { session.setSketch(normalized, forPage: source.index) }
            if drawingAfter != drawingBefore { session.setDrawing(drawingAfter, forPage: source.index) }
            registerUndo(
                name: L("옮기기", "Move"), on: source.index,
                elements: (elementsBefore, normalized), drawing: (drawingBefore, drawingAfter)
            )
            refreshPage?(source.index)
            refreshSelectionState()
            return
        }

        // Across pages. The elements keep their ids — it is the same box,
        // on the next page — and lose any parent left behind.
        let sourceAfter = elementsBefore.filter { !moving.contains($0.id) }
        let targetBefore = elements(on: target.index)
        var landing = working
        for i in landing.indices where landing[i].parent.map({ !moving.contains($0) }) ?? false {
            landing[i].parent = nil
        }
        var targetAfter = targetBefore + landing
        targetAfter = adopted(Set(landing.filter { $0.parent == nil }.map(\.id)), in: targetAfter)
        targetAfter = SketchTree.normalized(targetAfter)

        var sourceDrawingAfter = drawingBefore
        var targetDrawingBefore = session.drawing(forPage: target.index)
        let targetDrawingAfter: PKDrawing
        var landedStrokes: Set<Int> = []
        if !selection.strokes.isEmpty {
            let taken = selection.strokes.sorted().compactMap { $0 < drawingAfter.strokes.count ? drawingAfter.strokes[$0] : nil }
            sourceDrawingAfter = PKDrawing(strokes: drawingBefore.strokes.enumerated().filter { !selection.strokes.contains($0.offset) }.map(\.element))
            targetDrawingBefore = session.drawing(forPage: target.index)
            targetDrawingAfter = PKDrawing(strokes: targetDrawingBefore.strokes + taken)
            landedStrokes = Set(targetDrawingBefore.strokes.count..<targetDrawingAfter.strokes.count)
        } else {
            targetDrawingAfter = targetDrawingBefore
        }

        undoManager?.beginUndoGrouping()
        if sourceAfter != elementsBefore { session.setSketch(SketchTree.normalized(sourceAfter), forPage: source.index) }
        if sourceDrawingAfter != drawingBefore { session.setDrawing(sourceDrawingAfter, forPage: source.index) }
        registerUndo(
            name: L("다른 쪽으로 옮기기", "Move to Another Page"), on: source.index,
            elements: (elementsBefore, SketchTree.normalized(sourceAfter)), drawing: (drawingBefore, sourceDrawingAfter)
        )
        if targetAfter != targetBefore { session.setSketch(targetAfter, forPage: target.index) }
        if targetDrawingAfter != targetDrawingBefore { session.setDrawing(targetDrawingAfter, forPage: target.index) }
        registerUndo(
            name: L("다른 쪽으로 옮기기", "Move to Another Page"), on: target.index,
            elements: (targetBefore, targetAfter), drawing: (targetDrawingBefore, targetDrawingAfter)
        )
        undoManager?.setActionName(L("다른 쪽으로 옮기기", "Move to Another Page"))
        undoManager?.endUndoGrouping()
        refreshPage?(source.index)
        refreshPage?(target.index)
        selection = Selection(pageIndex: target.index, elements: selection.elements, strokes: landedStrokes)
        refreshSelectionState()
    }

    override func rightMouseDown(with event: NSEvent) {
        // Choose what is under the pointer first, so the menu is about it.
        if state.tool == .select, let spot = spot(for: event),
           let hit = selectable(at: spot), !selection.elements.contains(hit) {
            selection = Selection(pageIndex: spot.index, elements: [hit])
        }
        super.rightMouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, key: String = "", enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            item.isEnabled = enabled
            menu.addItem(item)
        }
        menu.autoenablesItems = false
        let has = hasSelection
        let one = state.selectedOne
        let containers = state.selectedElements.contains(where: \.isContainer)
        add(L("글 고치기", "Edit Text"), #selector(editTextFromMenu), enabled: one.map { !$0.isContainer && !$0.isConnector } ?? false)
        menu.addItem(.separator())
        add(L("묶기", "Group Selection"), #selector(groupFromMenu), enabled: !selection.elements.isEmpty)
        add(L("묶음 풀기", "Ungroup"), #selector(ungroupFromMenu), enabled: containers)
        add(L("프레임으로 감싸기", "Frame Selection"), #selector(frameFromMenu), enabled: has)
        add(state.selectedFrame?.layout == nil ? L("오토 레이아웃 넣기", "Add Auto Layout") : L("오토 레이아웃 빼기", "Remove Auto Layout"),
            #selector(autoLayoutFromMenu), enabled: !selection.elements.isEmpty)
        menu.addItem(.separator())
        add(L("복제", "Duplicate"), #selector(duplicateFromMenu), enabled: !selection.elements.isEmpty)
        add(L("맨 앞으로", "Bring to Front"), #selector(frontFromMenu), enabled: !selection.elements.isEmpty)
        add(L("맨 뒤로", "Send to Back"), #selector(backFromMenu), enabled: !selection.elements.isEmpty)
        menu.addItem(.separator())
        add(L("지우기", "Delete"), #selector(deleteFromMenu), enabled: has)
        return menu
    }

    @objc private func editTextFromMenu() { editSelectedText() }
    @objc private func frameFromMenu() { frameSelection() }
    @objc private func groupFromMenu() { groupSelection() }
    @objc private func ungroupFromMenu() { ungroupSelection() }
    @objc private func autoLayoutFromMenu() { toggleAutoLayout() }
    @objc private func duplicateFromMenu() { duplicateSelection() }
    @objc private func frontFromMenu() { bringSelectionToFront() }
    @objc private func backFromMenu() { sendSelectionToBack() }
    @objc private func deleteFromMenu() { deleteSelection() }

    // Scrolling and zooming belong to the page underneath. Both go to the
    // scroll view, not the PDF view: PDFKit zooms with NSScrollView's own
    // magnification and never implements `magnify(with:)` itself, so a
    // pinch handed to the PDF view went up its responder chain and did
    // nothing — which is why pinching did not zoom while the pen was out.
    override func scrollWheel(with event: NSEvent) {
        pdfView?.documentView?.enclosingScrollView?.scrollWheel(with: event)
    }

    override func magnify(with event: NSEvent) {
        guard let pdfView, let scrollView = pdfView.documentView?.enclosingScrollView else { return }
        // A pinch is a decision against the fitted size; PDFKit would
        // otherwise spring back to it when the fingers lift.
        if pdfView.autoScales { pdfView.autoScales = false }
        scrollView.magnify(with: event)
    }

    override func smartMagnify(with event: NSEvent) {
        guard let pdfView, let scrollView = pdfView.documentView?.enclosingScrollView else { return }
        if pdfView.autoScales { pdfView.autoScales = false }
        scrollView.smartMagnify(with: event)
    }

    // MARK: - Selecting

    private func beginSelecting(at spot: Spot, additive: Bool, clicks: Int) {
        let before = selection
        let tree = tree(on: spot.index)
        if selection.pageIndex != spot.index { entered = nil }

        // A double-click: go into a group, type into what is there, or
        // start a card where there is nothing.
        if clicks == 2 {
            if let hit = element(at: spot) {
                let chosen = tree.selectable(for: hit.id, within: entered)
                if chosen != hit.id, let group = tree[chosen], group.kind == .group {
                    // Into the group, one level: the child under the pointer.
                    entered = chosen
                    selection = Selection(pageIndex: spot.index, elements: [tree.selectable(for: hit.id, within: chosen)])
                    return
                }
                if hit.isContainer || hit.isConnector {
                    selection = Selection(pageIndex: spot.index, elements: [hit.id])
                    return
                }
                selection = Selection(pageIndex: spot.index, elements: [hit.id])
                beginEditing(hit, on: spot.page, index: spot.index, isNew: false)
                return
            }
            // Anywhere inside an empty box — a double-click in a box means
            // "write in here", as it does in Excalidraw.
            if let inside = elements(on: spot.index).last(where: { ($0.kind == .rectangle || $0.kind == .ellipse) && $0.rect.contains(spot.point) }) {
                selection = Selection(pageIndex: spot.index, elements: [inside.id])
                beginEditing(inside, on: spot.page, index: spot.index, isNew: false)
            } else {
                createText(at: spot, width: nil)
            }
            return
        }

        // A handle of the one selected element.
        if selection.pageIndex == spot.index, selection.elements.count == 1, selection.strokes.isEmpty,
           let chosen = selection.elements.first.flatMap({ tree[$0] }),
           let handle = handle(at: spot.point, of: chosen, on: spot.page, in: tree) {
            let current = elements(on: spot.index)
            switch handle {
            case .mid:
                drag = .bend(elementsBefore: current, original: chosen)
                working = [chosen]
            default:
                drag = .resize(elementsBefore: current, original: chosen, handle: handle, origin: spot.point)
                working = current.filter { tree.expanded([chosen.id]).contains($0.id) }
            }
            return
        }

        if let hit = selectable(at: spot) {
            if additive {
                var next = selection.pageIndex == spot.index ? selection : Selection()
                next.pageIndex = spot.index
                if next.elements.contains(hit) { next.elements.remove(hit) } else { next.elements.insert(hit) }
                selection = next
            } else if selection.pageIndex != spot.index || !selection.elements.contains(hit) {
                selection = Selection(pageIndex: spot.index, elements: [hit])
            }
            beginMove(at: spot)
            return
        }

        if let stroke = strokeIndex(at: spot) {
            if additive {
                var next = selection.pageIndex == spot.index ? selection : Selection()
                next.pageIndex = spot.index
                if next.strokes.contains(stroke) { next.strokes.remove(stroke) } else { next.strokes.insert(stroke) }
                selection = next
            } else if selection.pageIndex != spot.index || !selection.strokes.contains(stroke) {
                selection = Selection(pageIndex: spot.index, strokes: [stroke])
            }
            beginMove(at: spot)
            return
        }

        if !additive { selection = Selection(); entered = nil }
        drag = .pendingClick(origin: spot.point, additive: additive, before: additive ? before : Selection())
    }

    private func beginMove(at spot: Spot) {
        let current = elements(on: spot.index)
        drag = .move(
            elementsBefore: current, drawingBefore: session.drawing(forPage: spot.index),
            origin: spot.point, moved: false
        )
        let moving = SketchTree(current).expanded(selection.elements)
        working = current.filter { moving.contains($0.id) }
        workingDrawing = nil
        moveTarget = (spot.page, spot.index)
    }

    /// The topmost element under a point on its page — the thing itself,
    /// before the rule about groups is applied.
    private func element(at spot: Spot) -> SketchElement? {
        let reach = tolerance(on: spot.page)
        return elements(on: spot.index).last { $0.hits(spot.point, tolerance: reach) }
    }

    /// What a click at this spot selects: the outermost group round the
    /// element hit, or the element itself.
    private func selectable(at spot: Spot) -> UUID? {
        guard let hit = element(at: spot) else { return nil }
        return tree(on: spot.index).selectable(for: hit.id, within: entered)
    }

    /// The pen stroke under a point, by index into the page's drawing.
    private func strokeIndex(at spot: Spot) -> Int? {
        let geometry = PageGeometry(page: spot.page)
        let point = geometry.canvasPoint(fromPDF: spot.point)
        let reach = tolerance(on: spot.page) + 2
        let strokes = session.drawing(forPage: spot.index).strokes
        for (i, stroke) in strokes.enumerated().reversed() {
            guard stroke.renderBounds.insetBy(dx: -reach, dy: -reach).contains(point) else { continue }
            let hit = stroke.path.interpolatedPoints(by: .distance(2)).contains { sample in
                let location = sample.location.applying(stroke.transform)
                return hypot(location.x - point.x, location.y - point.y) <= reach + sample.size.width / 2
            }
            if hit { return i }
        }
        return nil
    }

    /// The bounds of a stroke on the page, from its bounds on the canvas.
    private func pageRect(of stroke: PKStroke, on page: PDFPage) -> CGRect {
        let geometry = PageGeometry(page: page)
        let box = stroke.renderBounds
        let corners = [
            CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
            CGPoint(x: box.minX, y: box.maxY), CGPoint(x: box.maxX, y: box.maxY),
        ].map(geometry.pdfPoint(fromCanvas:))
        return CGRect.union(of: corners.map { CGRect(origin: $0, size: .zero) })
    }

    private func updateMarquee(origin: CGPoint, current: CGPoint, additive: Bool, before: Selection, on page: PDFPage, index: Int) {
        let box = CGRect(
            x: min(origin.x, current.x), y: min(origin.y, current.y),
            width: abs(current.x - origin.x), height: abs(current.y - origin.y)
        )
        var next = additive && before.pageIndex == index ? before : Selection()
        next.pageIndex = index
        let tree = tree(on: index)
        var touched: Set<UUID> = []
        for element in elements(on: index) where !element.isContainer && element.bounds.intersects(box) {
            touched.insert(tree.selectable(for: element.id, within: entered))
        }
        next.elements.formUnion(tree.outermost(touched))
        for (i, stroke) in session.drawing(forPage: index).strokes.enumerated() where pageRect(of: stroke, on: page).intersects(box) {
            next.strokes.insert(i)
        }
        selection = next
    }

    private func selectionDidChange(from old: Selection) {
        var picked: [SketchElement] = []
        var box: CGRect?
        var page: CGRect?
        if let index = selection.pageIndex, let pdfPage = self.page(at: index) {
            let tree = tree(on: index)
            picked = elements(on: index).filter { selection.elements.contains($0.id) }
            var union = tree.bounds(of: selection.elements)
            let strokes = session.drawing(forPage: index).strokes
            for i in selection.strokes where i < strokes.count {
                union = union.union(pageRect(of: strokes[i], on: pdfPage))
            }
            box = union.isNull ? nil : union
            page = pageBox(pdfPage)
        }
        if let enteredGroup = entered, selection.elements.isEmpty || !picked.allSatisfy({ tree(on: selection.pageIndex ?? -1).isDescendant($0.id, of: enteredGroup) }) {
            entered = nil
        }
        state.setSelection(picked, strokes: selection.strokes.count, box: box, page: page)
        needsDisplay = true
    }

    /// Tells the panel again after the selection's elements changed under it.
    private func refreshSelectionState() {
        selectionDidChange(from: selection)
    }

    // MARK: - Handles

    private func handles(of element: SketchElement, on page: PDFPage, in tree: SketchTree) -> [(Handle, CGPoint)] {
        if element.isConnector {
            return [(.start, element.start), (.end, element.end), (.mid, element.midpoint)]
        }
        let r = element.kind == .group ? tree.bounds(of: element.id) : element.rect
        return [
            (.topLeft, CGPoint(x: r.minX, y: r.maxY)), (.top, CGPoint(x: r.midX, y: r.maxY)),
            (.topRight, CGPoint(x: r.maxX, y: r.maxY)), (.right, CGPoint(x: r.maxX, y: r.midY)),
            (.bottomRight, CGPoint(x: r.maxX, y: r.minY)), (.bottom, CGPoint(x: r.midX, y: r.minY)),
            (.bottomLeft, CGPoint(x: r.minX, y: r.minY)), (.left, CGPoint(x: r.minX, y: r.midY)),
        ]
    }

    private func handle(at point: CGPoint, of element: SketchElement, on page: PDFPage, in tree: SketchTree) -> Handle? {
        let reach = 7 / scale(for: page)
        return handles(of: element, on: page, in: tree).first { hypot($0.1.x - point.x, $0.1.y - point.y) <= reach }?.0
    }

    /// The element — and, for a container, everything in it — as the handle
    /// leaves it.
    private func resized(_ original: SketchElement, by handle: Handle, to p: CGPoint, shift: Bool, in tree: SketchTree) -> [SketchElement] {
        var element = original
        switch handle {
        case .start:
            element.points = [p, original.end]
            return [element]
        case .end:
            element.points = [original.start, p]
            return [element]
        case .mid:
            return [element]
        default:
            break
        }
        let r = original.kind == .group ? tree.bounds(of: original.id) : original.rect
        var minX = r.minX, maxX = r.maxX, minY = r.minY, maxY = r.maxY
        switch handle {
        case .topLeft: minX = p.x; maxY = p.y
        case .top: maxY = p.y
        case .topRight: maxX = p.x; maxY = p.y
        case .right: maxX = p.x
        case .bottomRight: maxX = p.x; minY = p.y
        case .bottom: minY = p.y
        case .bottomLeft: minX = p.x; minY = p.y
        case .left: minX = p.x
        default: break
        }
        var box = CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
        if shift, original.kind != .text {
            let side = max(box.width, box.height)
            box.size = CGSize(width: side, height: side)
        }
        box.size.width = max(box.width, 4)
        box.size.height = max(box.height, 4)
        switch original.kind {
        case .text:
            // Pulling a text card's handle sets how wide its words may run —
            // which makes it a card of fixed width, as it does in Figma.
            element.textSizing = .autoHeight
            element.rect = CGRect(x: box.minX, y: box.maxY, width: box.width, height: 0)
            element.rect = SketchTypesetter.fittedRect(for: element)
            return [element]
        case .frame:
            element.rect = box
            // Resized by hand, a frame stops hugging its children.
            if element.layout != nil { element.layout?.hugs = false }
            // Its children stay where they are; the frame moves round them.
            return [element] + tree.descendants(of: original.id)
        case .group:
            // The group scales with everything in it.
            var out = [element]
            for child in tree.descendants(of: original.id) { out.append(child.fitted(to: box, from: r)) }
            out[0].rect = box
            return out
        default:
            return [original.fitted(to: box, from: r)]
        }
    }

    // MARK: - Pen

    private func finishStroke(points: [CGPoint], times: [TimeInterval], pressures: [CGFloat], on page: PDFPage, index: Int) {
        guard let inkTool = state.tool.inkTool, let first = points.first else { return }
        let geometry = PageGeometry(page: page)
        let presets = configuration.presets
        let ink: PKInk
        let width: CGFloat
        switch inkTool {
        case .highlighter:
            ink = PKInk(.marker, color: presets.highlighterColor.platformColor)
            width = presets.highlighterWidth
        default:
            let c = presets.penColor.components
            ink = PKInk(.pen, color: NSColor(red: c.red, green: c.green, blue: c.blue, alpha: 1))
            width = presets.penWidth
        }
        var located = points
        var stamps = times
        var forces = pressures
        if located.count == 1 {
            // A dot: a stroke of no length is not drawn; one of almost none is.
            located.append(CGPoint(x: first.x + 0.2, y: first.y))
            stamps.append(0.01)
            forces.append(forces[0])
        }
        let controls = zip(zip(located, stamps), forces).map { pair, force in
            let (point, time) = pair
            // A tablet pen thins the line as it lightens; a mouse draws even.
            let nib = width * (inkTool == .highlighter ? 1 : (0.55 + 0.45 * min(max(force, 0.15), 1)))
            return PKStrokePoint(
                location: geometry.canvasPoint(fromPDF: point), timeOffset: time,
                size: CGSize(width: nib, height: nib), opacity: 1, force: force, azimuth: 0, altitude: .pi / 2
            )
        }
        let stroke = PKStroke(ink: ink, path: PKStrokePath(controlPoints: controls, creationDate: .now))

        if inkTool == .highlighter, presets.fitsToText, StrokeSnapper.snap(stroke, on: page, session: session) {
            // Became a highlight or an underline; the marks' own undo has it.
            return
        }
        let before = session.drawing(forPage: index)
        var strokes = before.strokes
        strokes.append(stroke)
        let after = PKDrawing(strokes: strokes)
        session.setDrawing(after, forPage: index)
        registerUndo(name: L("펜", "Pen Stroke"), on: index, elements: nil, drawing: (before, after))
        refreshPage?(index)
    }

    // MARK: - Eraser

    private func erase(at spot: Spot, from previous: CGPoint) {
        let radius = max(8 / scale(for: spot.page), 3)
        let distance = hypot(spot.point.x - previous.x, spot.point.y - previous.y)
        let steps = max(1, Int(distance / (radius / 2)))
        var drawing = session.drawing(forPage: spot.index)
        var elements = elements(on: spot.index)
        let geometry = PageGeometry(page: spot.page)
        var touched = false
        for step in 0...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let sample = CGPoint(x: previous.x + (spot.point.x - previous.x) * t, y: previous.y + (spot.point.y - previous.y) * t)
            let canvas = geometry.canvasPoint(fromPDF: sample)
            let strokeCount = drawing.strokes.count
            drawing.strokes.removeAll { stroke in
                guard stroke.renderBounds.insetBy(dx: -radius, dy: -radius).contains(canvas) else { return false }
                return stroke.path.interpolatedPoints(by: .distance(3)).contains { point in
                    let location = point.location.applying(stroke.transform)
                    return hypot(location.x - canvas.x, location.y - canvas.y) <= radius
                }
            }
            let elementCount = elements.count
            // The eraser takes an element and what lies inside it.
            let tree = SketchTree(elements)
            let gone = tree.expanded(Set(elements.filter { $0.hits(sample, tolerance: radius) }.map(\.id)))
            elements.removeAll { gone.contains($0.id) }
            if drawing.strokes.count != strokeCount || elements.count != elementCount { touched = true }
            if configuration.presets.eraserErasesMarks { eraseMark?(spot.page, sample) }
        }
        guard touched else { return }
        if drawing != session.drawing(forPage: spot.index) { session.setDrawing(drawing, forPage: spot.index) }
        if elements != self.elements(on: spot.index) { session.setSketch(SketchTree.normalized(pruned(elements)), forPage: spot.index) }
        refreshPage?(spot.index)
    }

    // MARK: - Text

    /// Starts a text card at a point — as wide as its words will be — or,
    /// given a width, a card of that width whose height follows its lines.
    private func createText(at spot: Spot, width: CGFloat?) {
        var style = state.style
        style.startHead = .none
        style.endHead = .none
        var element = SketchElement(
            kind: .text,
            points: [spot.point, CGPoint(x: spot.point.x + (width ?? 24), y: spot.point.y - 1)],
            style: style,
            textSizing: width == nil ? .autoWidth : .autoHeight
        )
        element.rect = SketchTypesetter.fittedRect(for: element)
        var elements = elements(on: spot.index)
        let before = elements
        elements.append(element)
        elements = adopted([element.id], in: elements)
        session.setSketch(SketchTree.normalized(elements), forPage: spot.index)
        drag = nil
        state.tool = .select
        selection = Selection(pageIndex: spot.index, elements: [element.id])
        beginEditing(element, on: spot.page, index: spot.index, isNew: true, before: before)
    }

    private func editorFrame(for element: SketchElement, on page: PDFPage) -> NSRect {
        var rect = element.rect
        if element.kind != .text { rect = rect.insetBy(dx: SketchTypesetter.padding, dy: SketchTypesetter.padding) }
        var frame = viewRect(rect, on: page)
        frame.size.width = max(frame.width, 24)
        frame.size.height = max(frame.height, 12)
        return frame.integral
    }

    private func editorFont(for element: SketchElement, on page: PDFPage) -> NSFont {
        let size = element.style.points * scale(for: page)
        if let family = element.style.fontName,
           let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) {
            return font
        }
        return NSFont.systemFont(ofSize: size)
    }

    /// The frame the moving selection would land in, if it were let go now
    /// — lit up while it is over it, so going into a frame is seen to
    /// happen rather than found out afterwards.
    private var landingFrame: UUID? {
        guard case .move = drag, let target = moveTarget, !working.isEmpty else { return nil }
        let all = elements(on: target.index)
        let moving = Set(working.map(\.id))
        let tree = SketchTree(all)
        let box = SketchTree(working).bounds(of: moving)
        guard !box.isNull else { return nil }
        let centre = CGPoint(x: box.midX, y: box.midY)
        return all.last { candidate in
            candidate.kind == .frame && !moving.contains(candidate.id) && candidate.rect.contains(centre)
                && !moving.contains(where: { tree.isDescendant(candidate.id, of: $0) })
        }?.id
    }

    private func beginEditing(_ element: SketchElement, on page: PDFPage, index: Int, isNew: Bool, before: [SketchElement]? = nil) {
        if textEditor != nil { endEditing(commit: true) }
        let editor = SketchTextEditor(frame: editorFrame(for: element, on: page))
        editor.configure(for: element, font: editorFont(for: element, on: page), scale: scale(for: page))
        editor.onChange = { [weak self] in self?.editorTextChanged() }
        editor.onFinish = { [weak self] in self?.endEditing(commit: true) }
        addSubview(editor)
        textEditor = editor
        editing = (element.id, page, index, before ?? elements(on: index), isNew)
        state.isEditingText = true
        refreshPage?(index)
        window?.makeFirstResponder(editor)
        needsDisplay = true
    }

    /// The words change and the card follows them, live — and the frame
    /// round it, when it has a layout, moves its neighbours to make room.
    private func editorTextChanged() {
        guard let editor = textEditor, let editing else { return }
        var elements = elements(on: editing.index)
        guard let i = elements.firstIndex(where: { $0.id == editing.id }) else { return }
        elements[i].text = editor.string
        if elements[i].kind == .text {
            elements[i].rect = SketchTypesetter.fittedRect(for: elements[i])
        }
        session.setSketch(SketchTree.normalized(elements), forPage: editing.index)
        if let placed = self.elements(on: editing.index).first(where: { $0.id == editing.id }) {
            editor.frame = editorFrame(for: placed, on: editing.page)
        }
        needsDisplay = true
    }

    /// Ends the typing: the words go into the element, an empty card is
    /// thrown away, and the whole thing is one step to undo.
    func endEditing(commit: Bool) {
        guard let editor = textEditor, let editing else { return }
        let index = editing.index
        var elements = elements(on: index)
        if let i = elements.firstIndex(where: { $0.id == editing.id }) {
            let text = editor.string.trimmingCharacters(in: .whitespacesAndNewlines)
            elements[i].text = text
            if elements[i].kind == .text {
                if text.isEmpty {
                    elements.remove(at: i)
                } else {
                    elements[i].rect = SketchTypesetter.fittedRect(for: elements[i])
                }
            }
        }
        editor.removeFromSuperview()
        textEditor = nil
        self.editing = nil
        state.isEditingText = false
        let after = SketchTree.normalized(pruned(elements))
        session.setSketch(after, forPage: index)
        if after != editing.before {
            registerUndo(
                name: L(editing.isNew ? "글 쓰기" : "글 고치기", editing.isNew ? "Add Text" : "Edit Text"),
                on: index, elements: (editing.before, after), drawing: nil
            )
        }
        if !after.contains(where: { $0.id == editing.id }) { selection = Selection() }
        refreshPage?(index)
        refreshSelectionState()
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    // MARK: - Keys

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let characters = (event.charactersIgnoringModifiers ?? "").lowercased()
        let plain = flags.isEmpty || flags == .shift
        if plain {
            switch event.keyCode {
            case 51, 117: deleteSelection(); return
            case 53: escape(); return
            case 36, 76:
                if let one = state.selectedOne {
                    if one.kind == .group { enterSelectedGroup(); return }
                    if !one.isConnector, one.kind != .frame { editSelectedText(); return }
                }
            case 123: nudge(dx: -1, dy: 0, far: flags == .shift); return
            case 124: nudge(dx: 1, dy: 0, far: flags == .shift); return
            case 125: nudge(dx: 0, dy: -1, far: flags == .shift); return
            case 126: nudge(dx: 0, dy: 1, far: flags == .shift); return
            default: break
            }
            if flags.isEmpty, let key = characters.first {
                if let tool = SketchTool.tool(for: key) { state.tool = tool; return }
                if key == "b" { frameSelection(); return }
            }
            if flags == .shift, characters == "a" { toggleAutoLayout(); return }
        }
        if flags == .command {
            switch characters {
            case "d": duplicateSelection(); return
            case "a": selectAllOnPage(); return
            case "g": groupSelection(); return
            default: break
            }
        }
        if flags == [.command, .shift] {
            switch characters {
            case "]": bringSelectionToFront(); return
            case "[": sendSelectionToBack(); return
            case "g": ungroupSelection(); return
            default: break
            }
        }
        if flags == [.command, .option], characters == "g" { frameSelection(); return }
        // Anything else is not ours; the page has no use for it either,
        // and the beep the default would make is not worth hearing.
    }

    /// Escape, in the order Figma takes it: step out of the group, let go
    /// of the selection, put the tool down, then put the pencil away.
    private func escape() {
        if textEditor != nil { endEditing(commit: true); return }
        if let group = entered {
            entered = nil
            selection = Selection(pageIndex: selection.pageIndex, elements: [group])
            return
        }
        if !selection.isEmpty { selection = Selection(); return }
        if state.tool != .select { state.tool = .select; return }
        configuration.mode = .read
    }

    private func nudge(dx: CGFloat, dy: CGFloat, far: Bool) {
        guard let index = selection.pageIndex, hasSelection, let page = page(at: index) else { return }
        let step: CGFloat = far ? 10 : 1
        let offset = CGPoint(x: dx * step, y: dy * step)
        let before = elements(on: index)
        let moving = SketchTree(before).expanded(selection.elements)
        let after = SketchTree.normalized(before.map { moving.contains($0.id) ? $0.translated(by: offset) : $0 })
        let drawingBefore = session.drawing(forPage: index)
        var drawingAfter = drawingBefore
        if !selection.strokes.isEmpty {
            let geometry = PageGeometry(page: page)
            let from = geometry.canvasPoint(fromPDF: .zero), to = geometry.canvasPoint(fromPDF: offset)
            let shift = CGAffineTransform(translationX: to.x - from.x, y: to.y - from.y)
            var strokes = drawingBefore.strokes
            for i in selection.strokes where i < strokes.count { strokes[i].transform = strokes[i].transform.concatenating(shift) }
            drawingAfter = PKDrawing(strokes: strokes)
        }
        if after != before { session.setSketch(after, forPage: index) }
        if drawingAfter != drawingBefore { session.setDrawing(drawingAfter, forPage: index) }
        registerUndo(name: L("옮기기", "Move"), on: index, elements: (before, after), drawing: (drawingBefore, drawingAfter))
        refreshPage?(index)
        refreshSelectionState()
    }

    // MARK: - SketchEditing

    var hasSelection: Bool { !selection.isEmpty }

    func applyStyle(_ change: @escaping (inout SketchStyle) -> Void) {
        guard let index = selection.pageIndex, !selection.elements.isEmpty else { return }
        let before = elements(on: index)
        // A group has no look of its own; restyling it restyles what is in
        // it. A frame has one, and keeps its children as they are.
        let tree = SketchTree(before)
        var targets = selection.elements
        for id in selection.elements where tree[id]?.kind == .group { targets.formUnion(tree.descendantIDs(of: id)) }
        let after = before.map { element -> SketchElement in
            guard targets.contains(element.id), element.kind != .group else { return element }
            var changed = element
            change(&changed.style)
            if changed.kind == .text, changed.style.points != element.style.points || changed.style.textAlign != element.style.textAlign {
                changed.rect = SketchTypesetter.fittedRect(for: changed)
            }
            return changed
        }
        apply(after, on: index, before: before, name: L("스타일", "Restyle"))
    }

    func editSelection(named name: String, _ change: @escaping (inout SketchElement) -> Void) {
        guard let index = selection.pageIndex, !selection.elements.isEmpty else { return }
        let before = elements(on: index)
        let after = before.map { element -> SketchElement in
            guard selection.elements.contains(element.id) else { return element }
            var changed = element
            change(&changed)
            if changed.kind == .text, changed.textSizing != element.textSizing {
                changed.rect = SketchTypesetter.fittedRect(for: changed)
            }
            return changed
        }
        apply(after, on: index, before: before, name: name)
    }

    func deleteSelection() {
        guard let index = selection.pageIndex, hasSelection else { return }
        let before = elements(on: index)
        let gone = SketchTree(before).expanded(selection.elements)
        let after = SketchTree.normalized(pruned(before.filter { !gone.contains($0.id) }))
        let drawingBefore = session.drawing(forPage: index)
        var drawingAfter = drawingBefore
        if !selection.strokes.isEmpty {
            drawingAfter = PKDrawing(strokes: drawingBefore.strokes.enumerated().filter { !selection.strokes.contains($0.offset) }.map(\.element))
        }
        selection = Selection()
        if after != before { session.setSketch(after, forPage: index) }
        if drawingAfter != drawingBefore { session.setDrawing(drawingAfter, forPage: index) }
        registerUndo(name: L("지우기", "Delete"), on: index, elements: (before, after), drawing: (drawingBefore, drawingAfter))
        refreshPage?(index)
    }

    func duplicateSelection() {
        guard let index = selection.pageIndex, !selection.elements.isEmpty else { return }
        let before = elements(on: index)
        let (copies, roots) = copied(selection.elements, from: before, shift: CGPoint(x: 12, y: -12))
        apply(before + copies, on: index, before: before, name: L("복제", "Duplicate"))
        selection = Selection(pageIndex: index, elements: roots)
    }

    /// A frame round the selection — XMind's frame round a topic, Figma's
    /// frame round a selection: it takes the elements in as its children,
    /// and encloses any handwriting that was chosen with them.
    func frameSelection() {
        guard let index = selection.pageIndex, hasSelection, let page = page(at: index) else { return }
        let before = elements(on: index)
        let tree = SketchTree(before)
        var box = tree.bounds(of: selection.elements)
        let strokes = session.drawing(forPage: index).strokes
        for i in selection.strokes where i < strokes.count {
            box = box.union(pageRect(of: strokes[i], on: page))
        }
        guard !box.isNull else { return }
        let pad: CGFloat = 8
        box = box.insetBy(dx: -pad, dy: -pad)
        var style = state.style
        style.fill = nil
        style.startHead = .none
        style.endHead = .none
        style.corners = .round
        var frame = SketchElement(kind: .frame, points: [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.maxY)], style: style)
        frame.name = nextFrameName(on: index)
        frame.parent = commonParent(of: selection.elements, in: tree)
        var after = before
        let lowest = after.indices.first { selection.elements.contains(after[$0].id) } ?? after.count
        after.insert(frame, at: lowest)
        for i in after.indices where selection.elements.contains(after[i].id) { after[i].parent = frame.id }
        apply(after, on: index, before: before, name: L("프레임", "Frame"))
        selection = Selection(pageIndex: index, elements: [frame.id])
    }

    func groupSelection() {
        guard let index = selection.pageIndex, !selection.elements.isEmpty else { return }
        let before = elements(on: index)
        let tree = SketchTree(before)
        let members = tree.outermost(selection.elements)
        let box = tree.bounds(of: members)
        guard !box.isNull else { return }
        var group = SketchElement(kind: .group, points: [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.maxY)])
        group.parent = commonParent(of: members, in: tree)
        var after = before
        let lowest = after.indices.first { members.contains(after[$0].id) } ?? after.count
        after.insert(group, at: lowest)
        for i in after.indices where members.contains(after[i].id) { after[i].parent = group.id }
        apply(after, on: index, before: before, name: L("묶기", "Group"))
        entered = nil
        selection = Selection(pageIndex: index, elements: [group.id])
    }

    /// Takes the selected groups and frames apart: their children take
    /// their place, and the container goes.
    func ungroupSelection() {
        guard let index = selection.pageIndex, !selection.elements.isEmpty else { return }
        let before = elements(on: index)
        let tree = SketchTree(before)
        let containers = selection.elements.filter { tree[$0]?.isContainer ?? false }
        guard !containers.isEmpty else { return }
        var after = before
        var freed: Set<UUID> = []
        for id in containers {
            guard let container = tree[id] else { continue }
            for i in after.indices where after[i].parent == id {
                after[i].parent = container.parent
                freed.insert(after[i].id)
            }
        }
        after.removeAll { containers.contains($0.id) }
        apply(after, on: index, before: before, name: L("묶음 풀기", "Ungroup"))
        entered = nil
        selection = Selection(pageIndex: index, elements: freed.union(selection.elements.subtracting(containers)))
    }

    /// Auto layout, the way ⇧A gives it in Figma: on a frame, a column (or
    /// a row, when its children already lie in one) that it then keeps; on
    /// loose elements, a new frame round them that has one; on a frame that
    /// has one, nothing but the frame again.
    func toggleAutoLayout() {
        guard let index = selection.pageIndex, !selection.elements.isEmpty else { return }
        let before = elements(on: index)
        let tree = SketchTree(before)
        if let frame = state.selectedFrame {
            if frame.layout != nil {
                editSelection(named: L("오토 레이아웃 빼기", "Remove Auto Layout")) { $0.layout = nil }
                return
            }
            var after = before
            guard let i = after.firstIndex(where: { $0.id == frame.id }) else { return }
            let children = tree.children(of: frame.id)
            let direction = Self.guessedDirection(for: children.map { tree.bounds(of: $0.id) })
            after[i].layout = SketchLayout(direction: direction)
            after = ordered(children.map(\.id), along: direction, in: after, tree: tree)
            apply(after, on: index, before: before, name: L("오토 레이아웃", "Auto Layout"))
            return
        }
        // Loose elements: a frame is put round them first, then laid out.
        frameSelection()
        guard let frame = state.selectedFrame else { return }
        let now = elements(on: index)
        let nowTree = SketchTree(now)
        var after = now
        guard let i = after.firstIndex(where: { $0.id == frame.id }) else { return }
        let children = nowTree.children(of: frame.id)
        let direction = Self.guessedDirection(for: children.map { nowTree.bounds(of: $0.id) })
        after[i].layout = SketchLayout(direction: direction)
        after = ordered(children.map(\.id), along: direction, in: after, tree: nowTree)
        apply(after, on: index, before: now, name: L("오토 레이아웃", "Auto Layout"))
    }

    /// A row when the children spread more sideways than up and down.
    private static func guessedDirection(for boxes: [CGRect]) -> SketchLayout.Direction {
        guard boxes.count > 1 else { return .vertical }
        let union = CGRect.union(of: boxes)
        let widest = boxes.map(\.width).max() ?? 0
        let tallest = boxes.map(\.height).max() ?? 0
        return (union.width - widest) > (union.height - tallest) ? .horizontal : .vertical
    }

    /// The children put in the order they lie — top to bottom, or left to
    /// right — so a layout that starts keeps them where the eye had them.
    private func ordered(_ ids: [UUID], along direction: SketchLayout.Direction, in elements: [SketchElement], tree: SketchTree) -> [SketchElement] {
        let sorted = ids.sorted { a, b in
            let ra = tree.bounds(of: a), rb = tree.bounds(of: b)
            return direction == .vertical ? ra.maxY > rb.maxY : ra.minX < rb.minX
        }
        guard sorted != ids else { return elements }
        // Reorder the array so these children (and only these) appear in the
        // sorted order at the slots they occupied.
        var out = elements
        let slots = out.indices.filter { ids.contains(out[$0].id) }
        let byID = Dictionary(uniqueKeysWithValues: out.map { ($0.id, $0) })
        for (slot, id) in zip(slots, sorted) { out[slot] = byID[id]! }
        return out
    }

    func bringSelectionToFront() {
        guard let index = selection.pageIndex, !selection.elements.isEmpty else { return }
        let before = elements(on: index)
        // Among siblings: `normalized` gathers each parent's children in
        // array order, so putting the chosen ones last puts them on top of
        // their siblings and nowhere else.
        let after = before.filter { !selection.elements.contains($0.id) } + before.filter { selection.elements.contains($0.id) }
        apply(after, on: index, before: before, name: L("맨 앞으로", "Bring to Front"))
    }

    func sendSelectionToBack() {
        guard let index = selection.pageIndex, !selection.elements.isEmpty else { return }
        let before = elements(on: index)
        let after = before.filter { selection.elements.contains($0.id) } + before.filter { !selection.elements.contains($0.id) }
        apply(after, on: index, before: before, name: L("맨 뒤로", "Send to Back"))
    }

    func selectAllOnPage() {
        guard let pdfView, let page = pdfView.currentPage else { return }
        let index = session.document.index(for: page)
        guard index != NSNotFound else { return }
        entered = nil
        selection = Selection(
            pageIndex: index,
            elements: Set(tree(on: index).roots),
            strokes: Set(session.drawing(forPage: index).strokes.indices)
        )
    }

    func editSelectedText() {
        guard let index = selection.pageIndex, let page = page(at: index), let one = state.selectedOne,
              !one.isContainer, !one.isConnector
        else { return }
        beginEditing(one, on: page, index: index, isNew: false)
    }

    /// Into the selected group: its first child is chosen, and the next
    /// clicks choose among its children.
    func enterSelectedGroup() {
        guard let index = selection.pageIndex, let group = state.selectedOne, group.kind == .group,
              let first = tree(on: index).children(of: group.id).first else { return }
        entered = group.id
        selection = Selection(pageIndex: index, elements: [first.id])
    }

    func align(_ alignment: SketchAlignment) {
        guard let index = selection.pageIndex, !selection.elements.isEmpty, let page = page(at: index) else { return }
        let before = elements(on: index)
        let tree = SketchTree(before)
        let members = tree.outermost(selection.elements)
        // What to line up with: each other when there are several; the
        // frame round it when there is one and it is in a frame; the page.
        let reference: CGRect
        if members.count > 1 {
            reference = tree.bounds(of: members)
        } else if let only = members.first, let parent = tree[only]?.parent, let frame = tree[parent], frame.kind == .frame {
            reference = frame.rect.insetBy(dx: frame.layout?.padding ?? 0, dy: frame.layout?.padding ?? 0)
        } else {
            reference = pageBox(page)
        }
        var after = before
        for id in members {
            let box = tree.bounds(of: id)
            guard !box.isNull else { continue }
            var delta = CGPoint.zero
            switch alignment {
            case .left: delta.x = reference.minX - box.minX
            case .centerX: delta.x = reference.midX - box.midX
            case .right: delta.x = reference.maxX - box.maxX
            case .top: delta.y = reference.maxY - box.maxY
            case .centerY: delta.y = reference.midY - box.midY
            case .bottom: delta.y = reference.minY - box.minY
            }
            guard abs(delta.x) > 0.01 || abs(delta.y) > 0.01 else { continue }
            let moving = tree.expanded([id])
            for i in after.indices where moving.contains(after[i].id) { after[i] = after[i].translated(by: delta) }
        }
        apply(after, on: index, before: before, name: alignment.label)
    }

    func setSelectionOrigin(x: CGFloat?, top: CGFloat?) {
        guard let index = selection.pageIndex, !selection.elements.isEmpty, let page = page(at: index) else { return }
        let before = elements(on: index)
        let tree = SketchTree(before)
        let members = tree.outermost(selection.elements)
        let box = tree.bounds(of: members)
        guard !box.isNull else { return }
        let pageTop = pageBox(page).maxY
        var delta = CGPoint.zero
        if let x { delta.x = x - box.minX }
        if let top { delta.y = (pageTop - top) - box.maxY }
        guard abs(delta.x) > 0.01 || abs(delta.y) > 0.01 else { return }
        let moving = tree.expanded(members)
        let after = before.map { moving.contains($0.id) ? $0.translated(by: delta) : $0 }
        apply(after, on: index, before: before, name: L("옮기기", "Move"))
    }

    func setSelectionSize(width: CGFloat?, height: CGFloat?) {
        guard let index = selection.pageIndex, let one = state.selectedOne, !one.isConnector else { return }
        let before = elements(on: index)
        let tree = SketchTree(before)
        let old = one.kind == .group ? tree.bounds(of: one.id) : one.rect
        var box = old
        if let width { box.size.width = max(width, 1) }
        if let height { box.origin.y = old.maxY - max(height, 1); box.size.height = max(height, 1) }
        guard box != old else { return }
        let changed = resized(one, by: .bottomRight, to: CGPoint(x: box.maxX, y: box.minY), shift: false, in: tree)
        var after = before
        for element in changed {
            if let i = after.firstIndex(where: { $0.id == element.id }) { after[i] = element }
        }
        apply(after, on: index, before: before, name: L("크기 바꾸기", "Resize"))
    }

    // MARK: - The tree, kept in order

    /// Elements just moved or made, given the frame they landed in — the
    /// topmost frame whose box holds their middle — or set loose if they
    /// left one. Groups are not taken apart by this: a thing dragged out
    /// of its group stays in the group.
    private func adopted(_ ids: Set<UUID>, in elements: [SketchElement]) -> [SketchElement] {
        let tree = SketchTree(elements)
        var out = elements
        let moving = tree.expanded(ids)
        for id in ids {
            guard let i = out.firstIndex(where: { $0.id == id }) else { continue }
            if let parent = out[i].parent, tree[parent]?.kind == .group { continue }
            let box = tree.bounds(of: id)
            guard !box.isNull else { continue }
            let centre = CGPoint(x: box.midX, y: box.midY)
            let home = elements.last { candidate in
                candidate.kind == .frame && !moving.contains(candidate.id) && candidate.rect.contains(centre)
                    && !tree.isDescendant(candidate.id, of: id)
            }
            out[i].parent = home?.id
        }
        return out
    }

    /// Without the groups nothing is left in. A frame stays; it is a place.
    private func pruned(_ elements: [SketchElement]) -> [SketchElement] {
        var out = elements
        while true {
            let tree = SketchTree(out)
            let empty = out.filter { $0.kind == .group && !tree.hasChildren($0.id) }.map(\.id)
            guard !empty.isEmpty else { return out }
            out.removeAll { empty.contains($0.id) }
        }
    }

    private func commonParent(of ids: Set<UUID>, in tree: SketchTree) -> UUID? {
        let parents = Set(ids.map { tree[$0]?.parent })
        return parents.count == 1 ? parents.first ?? nil : nil
    }

    private func nextFrameName(on index: Int) -> String {
        let count = elements(on: index).filter { $0.kind == .frame }.count
        return L("프레임 \(count + 1)", "Frame \(count + 1)")
    }

    /// Copies of these elements and everything in them, with new ids and
    /// the parent links carried across — the outermost copies loose.
    private func copied(_ ids: Set<UUID>, from elements: [SketchElement], shift: CGPoint) -> (copies: [SketchElement], roots: Set<UUID>) {
        let tree = SketchTree(elements)
        let members = tree.outermost(ids)
        let taking = tree.expanded(members)
        var newID: [UUID: UUID] = [:]
        for id in taking { newID[id] = UUID() }
        var copies: [SketchElement] = []
        for element in elements where taking.contains(element.id) {
            var copy = shift == .zero ? element : element.translated(by: shift)
            copy.id = newID[element.id]!
            copy.createdAt = .now
            copy.parent = element.parent.flatMap { newID[$0] } ?? (members.contains(element.id) ? element.parent : nil)
            copies.append(copy)
        }
        return (copies, Set(members.compactMap { newID[$0] }))
    }

    private func undoName(for kind: SketchElement.Kind) -> String {
        switch kind {
        case .rectangle: L("네모", "Rectangle")
        case .ellipse: L("동그라미", "Ellipse")
        case .arrow: L("화살표", "Arrow")
        case .line: L("선", "Line")
        case .text: L("글", "Text")
        case .frame: L("프레임", "Frame")
        case .group: L("묶기", "Group")
        }
    }

    // MARK: - Carrying a drawing to another page

    /// What the pasteboard carries: the elements as the JSON they already are
    /// in the file, and any handwriting as PencilKit's own data.
    ///
    /// A private type rather than an image, because a drawing pasted onto
    /// another page has to arrive as a drawing — movable, restylable, and
    /// written into that page's sidecar. The plain text of any card goes on
    /// the pasteboard too, so the same copy can be pasted into a note.
    static let sketchPasteboardType = NSPasteboard.PasteboardType("com.imtaeheon.PaperTime.sketch")

    private struct Clipping: Codable {
        var elements: [SketchElement]
        /// PencilKit's own encoding, base64'd so the whole clipping is one JSON.
        var ink: String?
        /// Which page it came from, so pasting back onto it can offset rather
        /// than land exactly on top of the original.
        var fromPage: Int
    }

    @discardableResult
    func copySelection() -> Bool {
        guard let index = selection.pageIndex, !selection.isEmpty else { return false }
        let all = elements(on: index)
        let (picked, _) = copied(selection.elements, from: all, shift: .zero)
        var ink: String?
        let strokes = session.drawing(forPage: index).strokes
        let taken = selection.strokes.sorted().compactMap { $0 < strokes.count ? strokes[$0] : nil }
        if !taken.isEmpty {
            ink = PKDrawing(strokes: taken).dataRepresentation().base64EncodedString()
        }
        guard !picked.isEmpty || ink != nil else { return false }

        let clipping = Clipping(elements: picked, ink: ink, fromPage: index)
        guard let data = try? JSONEncoder().encode(clipping) else { return false }
        let board = NSPasteboard.general
        board.clearContents()
        board.setData(data, forType: Self.sketchPasteboardType)
        // So the same copy can land in a note, or anywhere else.
        let words = picked.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n")
        if !words.isEmpty { board.setString(words, forType: .string) }
        return true
    }

    func cutSelection() {
        guard copySelection() else { return }
        deleteSelection()
    }

    /// Pastes onto whichever page is in view.
    ///
    /// Onto a different page the drawing keeps its coordinates, which is what
    /// "the same place on the next page" means. Back onto the page it came
    /// from it is nudged, so the copy does not hide the original — the same
    /// nudge duplicating uses.
    func pasteSketch() {
        guard let data = NSPasteboard.general.data(forType: Self.sketchPasteboardType),
              let clipping = try? JSONDecoder().decode(Clipping.self, from: data),
              let pdfView, let page = pdfView.currentPage
        else { return }
        let index = session.document.index(for: page)
        let shift = clipping.fromPage == index ? CGPoint(x: 12, y: -12) : .zero

        var landed: Set<UUID> = []
        if !clipping.elements.isEmpty {
            let before = elements(on: index)
            let (copies, roots) = copied(Set(clipping.elements.map(\.id)), from: clipping.elements, shift: shift)
            landed = roots
            apply(before + copies, on: index, before: before, name: L("붙여넣기", "Paste"))
        }

        var strokeRange: Set<Int> = []
        if let ink = clipping.ink,
           let inkData = Data(base64Encoded: ink),
           let pasted = try? PKDrawing(data: inkData) {
            let before = session.drawing(forPage: index)
            let moved = shift == .zero
                ? pasted
                : pasted.transformed(using: CGAffineTransform(translationX: shift.x, y: shift.y))
            let after = PKDrawing(strokes: before.strokes + moved.strokes)
            session.setDrawing(after, forPage: index)
            registerUndo(name: L("붙여넣기", "Paste"), on: index, elements: nil, drawing: (before, after))
            strokeRange = Set(before.strokes.count..<after.strokes.count)
            refreshPage?(index)
        }

        guard !landed.isEmpty || !strokeRange.isEmpty else { return }
        selection = Selection(pageIndex: index, elements: landed, strokes: strokeRange)
    }

    // The Edit menu and ⌘X/⌘C/⌘V both arrive here: this view is the first
    // responder while the pen is out, and it is the only thing in the window
    // that has a drawing to give.
    @objc func copy(_ sender: Any?) { copySelection() }
    @objc func cut(_ sender: Any?) { cutSelection() }
    @objc func paste(_ sender: Any?) { pasteSketch() }

    /// One change to a page's elements, put in tree order, written, made
    /// undoable, and shown.
    private func apply(_ elements: [SketchElement], on index: Int, before: [SketchElement], name: String) {
        let after = SketchTree.normalized(elements)
        guard after != before else { return }
        session.setSketch(after, forPage: index)
        registerUndo(name: name, on: index, elements: (before, after), drawing: nil)
        refreshPage?(index)
        refreshSelectionState()
    }

    /// One undoable step, of shapes and of ink. Registered on the session,
    /// which outlives this view, so the step survives the pencil going away.
    private func registerUndo(
        name: String, on index: Int,
        elements: (before: [SketchElement], after: [SketchElement])?,
        drawing: (before: PKDrawing, after: PKDrawing)?
    ) {
        SketchUndo.register(name: name, on: index, elements: elements, drawing: drawing, in: session, with: undoManager)
    }

    // MARK: - Probing

    /// Runs one scripted gesture, in-process: the events are made here and
    /// handed straight to this view, never posted to the system — so a
    /// script can draw, select, move and type on the test library while
    /// the person at the keyboard goes on with their own work. Page
    /// coordinates throughout. Returns a line to print.
    func performProbe(_ op: String) -> String {
        guard let pdfView, let window, let page = pdfView.currentPage else { return "probe: no page" }
        let index = session.document.index(for: page)
        let parts = op.split(separator: "=", maxSplits: 1).map(String.init)
        let name = parts[0]
        let args = parts.count > 1 ? parts[1].split(separator: ",").map(String.init) : []
        func numbers() -> [CGFloat] { args.compactMap { Double($0) }.map { CGFloat($0) } }
        func inWindow(_ p: CGPoint, on target: PDFPage = page) -> CGPoint { pdfView.convert(pdfView.convert(p, from: target), to: nil) }
        func mouse(_ type: NSEvent.EventType, _ p: CGPoint, on target: PDFPage = page, clicks: Int = 1, flags: NSEvent.ModifierFlags = []) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: inWindow(p, on: target), modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1
            )
        }
        func key(_ characters: String, code: UInt16, flags: NSEvent.ModifierFlags = []) -> NSEvent? {
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: code
            )
        }
        switch name {
        case "tool":
            guard let tool = SketchTool(rawValue: args.first ?? "") else { return "probe: no tool \(args)" }
            state.tool = tool
            return "probe: tool \(tool.rawValue)"
        case "drag", "shiftdrag":
            let n = numbers()
            guard n.count >= 4 else { return "probe: drag needs x1,y1,x2,y2" }
            let flags: NSEvent.ModifierFlags = name == "shiftdrag" ? .shift : []
            let a = CGPoint(x: n[0], y: n[1]), b = CGPoint(x: n[2], y: n[3])
            if let down = mouse(.leftMouseDown, a, flags: flags) { mouseDown(with: down) }
            for step in 1...8 {
                let t = CGFloat(step) / 8
                let p = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
                if let moved = mouse(.leftMouseDragged, p, flags: flags) { mouseDragged(with: moved) }
            }
            if let up = mouse(.leftMouseUp, b, flags: flags) { mouseUp(with: up) }
            return "probe: dragged \(a) → \(b)"
        case "dragpage":
            // `dragpage=<page>,x1,y1,x2,y2`: down on this page, up on another
            // — what carrying a selection to the next page is.
            let n = numbers()
            guard n.count >= 5, let target = session.document.page(at: Int(n[0])) else { return "probe: dragpage needs page,x1,y1,x2,y2" }
            let a = CGPoint(x: n[1], y: n[2]), b = CGPoint(x: n[3], y: n[4])
            if let down = mouse(.leftMouseDown, a) { mouseDown(with: down) }
            if let moved = mouse(.leftMouseDragged, CGPoint(x: a.x + 2, y: a.y - 2)) { mouseDragged(with: moved) }
            for step in 1...4 {
                if let moved = mouse(.leftMouseDragged, b, on: target) { mouseDragged(with: moved) }
                _ = step
            }
            if let up = mouse(.leftMouseUp, b, on: target) { mouseUp(with: up) }
            return "probe: dragged \(a) → page \(Int(n[0])) \(b)"
        case "click", "dblclick", "shiftclick":
            let n = numbers()
            guard n.count >= 2 else { return "probe: click needs x,y" }
            let p = CGPoint(x: n[0], y: n[1])
            let clicks = name == "dblclick" ? 2 : 1
            let flags: NSEvent.ModifierFlags = name == "shiftclick" ? .shift : []
            if let down = mouse(.leftMouseDown, p, clicks: clicks, flags: flags) { mouseDown(with: down) }
            if let up = mouse(.leftMouseUp, p, clicks: clicks, flags: flags) { mouseUp(with: up) }
            return "probe: \(name) at \(p)"
        case "key":
            let which = args.first ?? ""
            let codes: [String: (String, UInt16, NSEvent.ModifierFlags)] = [
                "esc": ("\u{1B}", 53, []), "delete": ("\u{7F}", 51, []), "return": ("\r", 36, []),
                "up": ("", 126, []), "down": ("", 125, []), "left": ("", 123, []), "right": ("", 124, []),
                "shift-up": ("", 126, .shift), "cmd-d": ("d", 2, .command), "cmd-a": ("a", 0, .command),
                "cmd-g": ("g", 5, .command), "cmd-shift-g": ("g", 5, [.command, .shift]), "shift-a": ("a", 0, .shift),
                "cmd-shift-]": ("]", 30, [.command, .shift]), "cmd-shift-[": ("[", 33, [.command, .shift]),
            ]
            if let (chars, code, flags) = codes[which] {
                if let event = key(chars, code: code, flags: flags) { keyDown(with: event) }
            } else if let character = which.first, which.count == 1 {
                if let event = key(String(character), code: 0) { keyDown(with: event) }
            } else {
                return "probe: unknown key \(which)"
            }
            return "probe: key \(which)"
        case "type":
            guard let editor = textEditor else { return "probe: nothing is being edited" }
            editor.insertText(args.joined(separator: ","), replacementRange: editor.selectedRange())
            return "probe: typed into the editor; text now \"\(editor.string)\""
        case "dash":
            guard let dash = SketchStyle.Dash(rawValue: args.first ?? "") else { return "probe: no dash \(args)" }
            state.change { $0.dash = dash }
            return "probe: dash \(dash.rawValue)"
        case "align":
            let all: [String: SketchAlignment] = ["left": .left, "centerx": .centerX, "right": .right, "top": .top, "centery": .centerY, "bottom": .bottom]
            guard let alignment = all[(args.first ?? "").lowercased()] else { return "probe: no alignment \(args)" }
            align(alignment)
            return "probe: aligned \(args.first ?? "")"
        case "layout":
            // `layout=horizontal,gap,padding`
            guard let direction = SketchLayout.Direction(rawValue: args.first ?? "") else { return "probe: no direction \(args)" }
            let n = numbers()
            editSelection(named: "layout") { element in
                var layout = element.layout ?? SketchLayout()
                layout.direction = direction
                if n.count > 1 { layout.gap = n[1] }
                if n.count > 2 { layout.padding = n[2] }
                element.layout = layout
            }
            return "probe: layout \(direction.rawValue)"
        case "size":
            let n = numbers()
            setSelectionSize(width: n.count > 0 ? n[0] : nil, height: n.count > 1 ? n[1] : nil)
            return "probe: size \(n)"
        case "origin":
            let n = numbers()
            setSelectionOrigin(x: n.count > 0 ? n[0] : nil, top: n.count > 1 ? n[1] : nil)
            return "probe: origin \(n)"
        case "undo":
            undoManager?.undo()
            return "probe: undo"
        case "redo":
            undoManager?.redo()
            return "probe: redo"
        case "copy":
            return "probe: copied \(copySelection())"
        case "paste":
            pasteSketch()
            return "probe: pasted; selection now \(selection.elements.count) elements + \(selection.strokes.count) strokes"
        case "page":
            // Walking between pages without a scroll wheel, so "is what I drew
            // still there when I come back" can be asked in a script.
            guard let wanted = Int(args.first ?? ""),
                  let target = session.document.page(at: wanted)
            else { return "probe: no page \(args)" }
            pdfView.go(to: target)
            return "probe: went to page \(wanted)"
        case "report":
            let at = args.first.flatMap(Int.init) ?? index
            var lines = ["probe: page \(at): \(elements(on: at).count) elements, \(session.drawing(forPage: at).strokes.count) strokes, selection \(selection.elements.count) elements + \(selection.strokes.count) strokes on page \(selection.pageIndex.map(String.init) ?? "-"), tool \(state.tool.rawValue), editing \(textEditor != nil), entered \(entered != nil)"]
            let tree = tree(on: at)
            for element in elements(on: at) {
                let r = element.kind == .group ? tree.bounds(of: element.id) : element.rect
                let box = String(format: "(%.0f, %.0f, %.0f, %.0f)", r.minX, r.minY, r.width, r.height)
                let bend = element.bend.map { String(format: " bend(%.0f, %.0f)", $0.x, $0.y) } ?? ""
                let parent = element.parent.map { " in \(String($0.uuidString.prefix(4)))" } ?? ""
                let layout = element.layout.map { " layout \($0.direction.rawValue) gap \($0.gap) pad \($0.padding) hugs \($0.hugs)" } ?? ""
                let name = element.name.map { " \"\($0)\"" } ?? ""
                let sizing = element.kind == .text ? " \(element.sizing.rawValue)" : ""
                lines.append("  \(String(element.id.uuidString.prefix(4))) \(element.kind.rawValue)\(name) \(box)\(bend)\(parent)\(layout)\(sizing) width \(element.style.width) dash \(element.style.dash.rawValue) fill \(element.style.fill == nil ? "none" : "yes") text \"\(element.text)\"")
            }
            return lines.joined(separator: "\n")
        default:
            return "probe: unknown op \(op)"
        }
    }

    // MARK: - Cursor

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor(for: state.tool))
    }

    private func cursor(for tool: SketchTool) -> NSCursor {
        switch tool {
        case .select: .arrow
        case .text: .iBeam
        case .eraser: Self.eraserCursor
        case .pen, .highlighter: .crosshair
        case .rectangle, .ellipse, .arrow, .line, .frame: .crosshair
        }
    }

    /// A ring the size of the eraser's reach.
    private static let eraserCursor: NSCursor = {
        let size = NSSize(width: 20, height: 20)
        let image = NSImage(size: size, flipped: false) { rect in
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
            ring.lineWidth = 1.5
            NSColor.white.withAlphaComponent(0.9).setStroke()
            ring.stroke()
            let inner = NSBezierPath(ovalIn: rect.insetBy(dx: 2.5, dy: 2.5))
            inner.lineWidth = 1
            NSColor.black.withAlphaComponent(0.8).setStroke()
            inner.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 10, y: 10))
    }()

    // MARK: - Drawing what is happening

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        drawFrameNames(in: context)
        // The card being typed into: its box, drawn here under the editor,
        // which draws only the words.
        if let editing, let element = elements(on: editing.index).first(where: { $0.id == editing.id }) {
            var box = element
            box.text = ""
            context.saveGState()
            context.concatenate(transform(for: editing.page))
            SketchRenderer.draw(box, in: context)
            context.restoreGState()
            let outline = viewRect(element.rect, on: editing.page)
            context.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor)
            context.setLineWidth(1)
            context.stroke(outline.insetBy(dx: 0.5, dy: 0.5))
        }
        // The selection, on its page.
        if let index = selection.pageIndex, let page = page(at: index), drag == nil || isMoving {
            drawSelection(on: page, index: index, in: context)
        }
        guard let (page, index) = dragPage else { return }
        let toView = transform(for: page)
        switch drag {
        case let .shape(element):
            context.saveGState()
            context.concatenate(toView)
            SketchRenderer.draw(element, in: context, options: .init(fillAlphaScale: 0.7))
            context.restoreGState()
        case let .textBox(origin, current):
            let box = viewRect(CGRect(
                x: min(origin.x, current.x), y: min(origin.y, current.y),
                width: abs(current.x - origin.x), height: abs(current.y - origin.y)
            ), on: page)
            guard box.width > 2 else { break }
            context.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor)
            context.setLineWidth(1)
            context.stroke(box.insetBy(dx: 0.5, dy: 0.5))
        case let .stroke(points, _, _, _):
            drawLiveStroke(points, on: page, in: context)
        case .move, .resize, .bend:
            let landing = moveTarget?.page ?? page
            context.saveGState()
            context.concatenate(transform(for: landing))
            SketchRenderer.draw(working, in: context, options: .init(fillAlphaScale: 0.7))
            context.restoreGState()
            if let workingDrawing {
                drawStrokes(workingDrawing, indices: selection.strokes, on: landing, in: context)
            }
            if case .move = drag {
                let box = SketchTree(working).bounds(of: Set(working.map(\.id)))
                if !box.isNull { drawBox(viewRect(box, on: landing), dashed: moveTarget?.index != index, in: context) }
            } else {
                let tree = SketchTree(working)
                for element in working where selection.elements.contains(element.id) {
                    drawHandles(of: element, on: landing, in: tree, in: context)
                }
            }
        case let .marquee(origin, current, _, _):
            let box = viewRect(CGRect(
                x: min(origin.x, current.x), y: min(origin.y, current.y),
                width: abs(current.x - origin.x), height: abs(current.y - origin.y)
            ), on: page)
            context.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor)
            context.fill(box)
            context.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.7).cgColor)
            context.setLineWidth(1)
            context.setLineDash(phase: 0, lengths: [4, 3])
            context.stroke(box.insetBy(dx: 0.5, dy: 0.5))
        default:
            break
        }
    }

    private var isMoving: Bool {
        switch drag {
        case .move, .resize, .bend: true
        default: false
        }
    }

    /// Every frame's name, in small type above its top-left corner — the
    /// label Figma gives a frame on the canvas, so a frame is a place with a
    /// name and not an anonymous box.
    private func drawFrameNames(in context: CGContext) {
        guard let pdfView else { return }
        let landing = landingFrame
        // The frame the selection lives in, so it is seen to be inside
        // something — the way Figma lights the parent's name.
        var parents: Set<UUID> = []
        if let index = selection.pageIndex, drag == nil || isMoving {
            let tree = tree(on: index)
            for id in selection.elements {
                if let parent = tree[id]?.parent, tree[parent]?.kind == .frame { parents.insert(parent) }
            }
        }
        for page in pdfView.visiblePages {
            let index = session.document.index(for: page)
            guard index != NSNotFound else { continue }
            let hidden = hiddenElementIDs(onPage: index)
            for frame in elements(on: index) where frame.kind == .frame && !hidden.contains(frame.id) {
                let title = frame.name ?? L("프레임", "Frame")
                let corner = viewPoint(CGPoint(x: frame.rect.minX, y: frame.rect.maxY), on: page)
                let chosen = selection.pageIndex == index && selection.elements.contains(frame.id)
                let isLanding = landing == frame.id && moveTarget?.index == index
                let isParent = parents.contains(frame.id) && selection.pageIndex == index
                if isLanding || isParent {
                    // The frame's edge, in the accent: strong while something
                    // is being dropped into it, faint while something inside
                    // it is merely selected.
                    let box = viewRect(frame.rect, on: page)
                    context.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(isLanding ? 0.95 : 0.4).cgColor)
                    context.setLineWidth(isLanding ? 2 : 1)
                    context.setLineDash(phase: 0, lengths: [])
                    context.stroke(box.insetBy(dx: isLanding ? 1 : 0.5, dy: isLanding ? 1 : 0.5))
                    if isLanding {
                        context.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.05).cgColor)
                        context.fill(box)
                    }
                }
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                    .foregroundColor: chosen || isLanding || isParent ? NSColor.controlAccentColor : NSColor.secondaryLabelColor,
                ]
                NSAttributedString(string: title, attributes: attributes)
                    .draw(at: CGPoint(x: corner.x, y: corner.y + 3))
            }
        }
    }

    private func drawBox(_ box: CGRect, dashed: Bool, in context: CGContext) {
        context.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor)
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: dashed ? [4, 3] : [])
        context.stroke(box.insetBy(dx: 0.5, dy: 0.5))
        context.setLineDash(phase: 0, lengths: [])
    }

    private func drawSelection(on page: PDFPage, index: Int, in context: CGContext) {
        let accent = NSColor.controlAccentColor
        let tree = tree(on: index)
        let elements = elements(on: index).filter { selection.elements.contains($0.id) }
        // The strokes: a dashed box round the lot.
        let strokes = session.drawing(forPage: index).strokes
        var inkBox = CGRect.null
        for i in selection.strokes where i < strokes.count {
            inkBox = inkBox.union(pageRect(of: strokes[i], on: page))
        }
        if !inkBox.isNull {
            drawBox(viewRect(inkBox.insetBy(dx: -3, dy: -3), on: page), dashed: true, in: context)
        }
        guard !isMoving else { return }
        // The group that has been entered, faintly, so it is seen that the
        // thing chosen is inside something.
        if let enteredGroup = entered, let group = tree[enteredGroup] {
            let box = viewRect(tree.bounds(of: group.id), on: page).insetBy(dx: -4, dy: -4)
            context.setStrokeColor(accent.withAlphaComponent(0.35).cgColor)
            context.setLineWidth(1)
            context.setLineDash(phase: 0, lengths: [3, 3])
            context.stroke(box.insetBy(dx: 0.5, dy: 0.5))
            context.setLineDash(phase: 0, lengths: [])
        }
        for element in elements {
            if elements.count > 1 || !inkBox.isNull {
                let box = viewRect(element.isConnector ? element.bounds : tree.bounds(of: element.id), on: page)
                context.setStrokeColor(accent.withAlphaComponent(0.6).cgColor)
                context.setLineWidth(1)
                context.stroke(box.insetBy(dx: 0.5, dy: 0.5))
            }
        }
        if elements.count == 1, inkBox.isNull, let only = elements.first {
            drawHandles(of: only, on: page, in: tree, in: context)
        }
    }

    /// The outline and the handles of one element, in view coordinates.
    private func drawHandles(of element: SketchElement, on page: PDFPage, in tree: SketchTree, in context: CGContext) {
        let accent = NSColor.controlAccentColor
        context.setStrokeColor(accent.withAlphaComponent(0.85).cgColor)
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [])
        if element.isConnector {
            // The curve itself, faintly, so the bend handle is seen to
            // belong to it.
            context.saveGState()
            context.concatenate(transform(for: page))
            context.addPath(SketchRenderer.path(of: element))
            context.setLineWidth(1 / scale(for: page))
            context.setStrokeColor(accent.withAlphaComponent(0.35).cgColor)
            context.strokePath()
            context.restoreGState()
        } else {
            let rect = element.kind == .group ? tree.bounds(of: element.id) : element.rect
            let box = viewRect(rect, on: page).insetBy(dx: -2, dy: -2)
            context.stroke(box.insetBy(dx: 0.5, dy: 0.5))
        }
        for (handle, point) in handles(of: element, on: page, in: tree) {
            let centre = viewPoint(point, on: page)
            let size: CGFloat = handle == .mid ? 9 : 7
            let square = CGRect(x: centre.x - size / 2, y: centre.y - size / 2, width: size, height: size)
            context.setFillColor(NSColor.white.cgColor)
            context.setStrokeColor(accent.cgColor)
            context.setLineWidth(1.2)
            if handle == .mid || element.isConnector {
                context.fillEllipse(in: square)
                context.strokeEllipse(in: square)
            } else {
                context.fill(square)
                context.stroke(square)
            }
        }
    }

    private func drawLiveStroke(_ points: [CGPoint], on page: PDFPage, in context: CGContext) {
        guard let inkTool = state.tool.inkTool, let first = points.first else { return }
        let presets = configuration.presets
        let s = scale(for: page)
        let color: NSColor
        let width: CGFloat
        switch inkTool {
        case .highlighter:
            color = presets.highlighterColor.platformColor.withAlphaComponent(0.35)
            width = presets.highlighterWidth
        default:
            let c = presets.penColor.components
            color = NSColor(red: c.red, green: c.green, blue: c.blue, alpha: 1)
            width = presets.penWidth
        }
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(width * s)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.move(to: viewPoint(first, on: page))
        if points.count == 1 {
            let p = viewPoint(first, on: page)
            context.addLine(to: CGPoint(x: p.x + 0.1, y: p.y))
        }
        for point in points.dropFirst() { context.addLine(to: viewPoint(point, on: page)) }
        context.strokePath()
    }

    /// Pen strokes drawn plainly — a polyline of their nib width — while
    /// they are being moved; PencilKit draws them properly once they land.
    private func drawStrokes(_ drawing: PKDrawing, indices: Set<Int>, on page: PDFPage, in context: CGContext) {
        let geometry = PageGeometry(page: page)
        let s = scale(for: page)
        for i in indices where i < drawing.strokes.count {
            let stroke = drawing.strokes[i]
            let samples = stroke.path.interpolatedPoints(by: .distance(2))
            var points: [CGPoint] = []
            var width: CGFloat = 2
            for sample in samples {
                points.append(viewPoint(geometry.pdfPoint(fromCanvas: sample.location.applying(stroke.transform)), on: page))
                width = sample.size.width
            }
            guard let first = points.first else { continue }
            let alpha: CGFloat = stroke.ink.inkType == .marker ? 0.35 : 1
            context.setStrokeColor(stroke.ink.color.withAlphaComponent(alpha).cgColor)
            context.setLineWidth(width * s)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.move(to: first)
            for point in points.dropFirst() { context.addLine(to: point) }
            context.strokePath()
        }
    }
}

/// The words of an element, being typed, over the page where they will be.
///
/// Figma's way: no field. The words appear in their own face, size and
/// colour on the page itself, with a caret; the card behind them is drawn by
/// the view underneath, so what is seen while typing is what will be there
/// when the typing stops.
final class SketchTextEditor: NSTextView {
    var onChange: (() -> Void)?
    var onFinish: (() -> Void)?
    /// Typing undoes on its own stack. On the window's, the text view
    /// opened a group for its coalesced typing and never closed it, and
    /// every shape drawn afterwards fell into that one group — one ⌘Z then
    /// took the lot back. The words become one step on the window's stack
    /// when the editing ends.
    private let ownUndoManager = UndoManager()
    override var undoManager: UndoManager? { ownUndoManager }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        setUp()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    required init?(coder: NSCoder) { nil }

    private func setUp() {
        isRichText = false
        isFieldEditor = false
        allowsUndo = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isVerticallyResizable = false
        isHorizontallyResizable = false
        textContainer?.widthTracksTextView = true
        textContainer?.lineFragmentPadding = 0
        delegate = self
        drawsBackground = false
        focusRingType = .none
    }

    @MainActor
    func configure(for element: SketchElement, font: NSFont, scale: CGFloat) {
        self.font = font
        string = element.text
        let stroke = element.style.stroke
        textColor = NSColor(red: stroke.red, green: stroke.green, blue: stroke.blue, alpha: 1)
        insertionPointColor = textColor ?? .textColor
        if element.kind == .text {
            textContainerInset = NSSize(width: SketchTypesetter.padding * scale, height: SketchTypesetter.padding * scale)
            switch element.style.textAlign {
            case .left: alignment = .left
            case .center: alignment = .center
            case .right: alignment = .right
            }
        } else {
            textContainerInset = .zero
            alignment = .center
        }
        typingAttributes = [.font: font, .foregroundColor: textColor ?? .textColor]
        // Existing words are selected, so typing replaces them; a new card
        // has nothing to select and the caret simply waits.
        selectAll(nil)
    }

    override func cancelOperation(_ sender: Any?) { onFinish?() }

    override func keyDown(with event: NSEvent) {
        // Return makes a new line; Command-Return, like Escape, finishes.
        if (event.keyCode == 36 || event.keyCode == 76), event.modifierFlags.contains(.command) {
            onFinish?()
            return
        }
        super.keyDown(with: event)
    }
}

extension SketchTextEditor: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) { onChange?() }
}

/// Undo for the sketch layer and the pen, in one step per gesture.
@MainActor
enum SketchUndo {
    static func register(
        name: String, on index: Int,
        elements: (before: [SketchElement], after: [SketchElement])?,
        drawing: (before: PKDrawing, after: PKDrawing)?,
        in session: DocumentSession, with undoManager: UndoManager?
    ) {
        guard let undoManager, elements != nil || drawing != nil else { return }
        let elementsChanged = elements.map { $0.before != $0.after } ?? false
        let drawingChanged = drawing.map { $0.before != $0.after } ?? false
        guard elementsChanged || drawingChanged else { return }
        undoManager.setActionName(name)
        undoManager.registerUndo(withTarget: session) { session in
            MainActor.assumeIsolated {
                if let elements, elementsChanged { session.setSketch(elements.before, forPage: index) }
                if let drawing, drawingChanged {
                    session.setDrawing(drawing.before, forPage: index)
                    NotificationCenter.default.post(
                        name: .paperTimeInkChanged, object: session, userInfo: ["pages": [index]]
                    )
                }
                register(
                    name: name, on: index,
                    elements: elements.map { ($0.after, $0.before) },
                    drawing: drawing.map { ($0.after, $0.before) },
                    in: session, with: undoManager
                )
            }
        }
    }
}

/// So the Edit menu greys out Copy when nothing is selected, and Paste when
/// the pasteboard has no drawing on it.
extension SketchInputView: NSUserInterfaceValidations {
    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)), #selector(cut(_:)):
            return !selection.isEmpty
        case #selector(paste(_:)):
            return NSPasteboard.general.data(forType: SketchInputView.sketchPasteboardType) != nil
        default:
            return true
        }
    }
}
#endif
