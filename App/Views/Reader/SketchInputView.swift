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
/// the shape tools, and for the selection tool the moving, resizing, bending
/// and typing that Excalidraw and Figma make second nature. What it has drawn
/// goes to the session — ink into the page's drawing, shapes into its sketch
/// — and the page overlays draw the result; this view only ever shows what is
/// in the middle of happening: the stroke under the pointer, the box being
/// dragged out, the handles round the selection.
///
/// Scrolling and pinching are passed down to the PDF view, so the page still
/// moves under the tools the way it does under the pencil on the iPad.
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

    struct Selection: Equatable {
        var pageIndex: Int?
        var elements: Set<UUID> = []
        var strokes: Set<Int> = []
        var isEmpty: Bool { elements.isEmpty && strokes.isEmpty }
    }

    private(set) var selection = Selection() {
        didSet { if selection != oldValue { selectionDidChange(from: oldValue) } }
    }

    /// Where a box's handles are.
    enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
        case start, end, mid
    }

    private enum Drag {
        /// A shape being dragged out.
        case shape(SketchElement)
        /// A pen or highlighter stroke, in page coordinates.
        case stroke(points: [CGPoint], times: [TimeInterval], began: Date, pressures: [CGFloat])
        /// The eraser passing over the page.
        case erase(drawingBefore: PKDrawing, elementsBefore: [SketchElement], last: CGPoint)
        /// The selection being moved.
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
    /// The page a drag is happening on, fixed at its start.
    private var dragPage: (page: PDFPage, index: Int)?
    /// The elements as they are mid-drag, drawn here instead of the overlay.
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
            MainActor.assumeIsolated { self?.needsDisplay = true }
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
        working = []
        workingDrawing = nil
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

    private func spot(for event: NSEvent) -> Spot? {
        guard let pdfView else { return nil }
        let inPDF = pdfView.convert(event.locationInWindow, from: nil)
        guard let page = pdfView.page(for: inPDF, nearest: true) else { return nil }
        let index = session.document.index(for: page)
        guard index != NSNotFound else { return nil }
        let box = page.bounds(for: pdfView.displayBox)
        var point = pdfView.convert(inPDF, to: page)
        point.x = min(max(point.x, box.minX), box.maxX)
        point.y = min(max(point.y, box.minY), box.maxY)
        return Spot(page: page, index: index, point: point)
    }

    private func page(at index: Int) -> PDFPage? { session.document.page(at: index) }

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
        let additive = event.modifierFlags.contains(.shift)
        dragPage = (spot.page, spot.index)

        switch state.tool {
        case .select:
            beginSelecting(at: spot, additive: additive, clicks: event.clickCount)
        case .pen, .highlighter:
            let pressure = event.subtype == .tabletPoint ? CGFloat(event.pressure) : 1
            drag = .stroke(points: [spot.point], times: [0], began: .now, pressures: [pressure])
        case .eraser:
            drag = .erase(drawingBefore: session.drawing(forPage: spot.index), elementsBefore: elements(on: spot.index), last: spot.point)
            erase(at: spot, from: spot.point)
        case .rectangle, .ellipse, .arrow, .line:
            guard let kind = state.tool.makes else { return }
            var style = state.style
            if kind == .line { style.startHead = .none; style.endHead = .none }
            drag = .shape(SketchElement(kind: kind, points: [spot.point, spot.point], style: style))
        case .text:
            createText(at: spot)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag, let (page, index) = dragPage, let pdfView else { return }
        // Stay on the page the drag began on, even when the pointer leaves it.
        let inPDF = pdfView.convert(event.locationInWindow, from: nil)
        let box = page.bounds(for: pdfView.displayBox)
        var p = pdfView.convert(inPDF, to: page)
        p.x = min(max(p.x, box.minX), box.maxX)
        p.y = min(max(p.y, box.minY), box.maxY)
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
            let offset = CGPoint(x: p.x - origin.x, y: p.y - origin.y)
            working = elementsBefore.filter { selection.elements.contains($0.id) }.map { $0.translated(by: offset) }
            if !selection.strokes.isEmpty {
                let geometry = PageGeometry(page: page)
                let from = geometry.canvasPoint(fromPDF: origin), to = geometry.canvasPoint(fromPDF: p)
                let shift = CGAffineTransform(translationX: to.x - from.x, y: to.y - from.y)
                var strokes = drawingBefore.strokes
                for i in selection.strokes where i < strokes.count {
                    strokes[i].transform = strokes[i].transform.concatenating(shift)
                }
                workingDrawing = PKDrawing(strokes: strokes)
            }
            self.drag = .move(elementsBefore: elementsBefore, drawingBefore: drawingBefore, origin: origin, moved: true)
            refreshPage?(index)
        case let .resize(elementsBefore, original, handle, _):
            working = [resized(original, by: handle, to: p, shift: shift)]
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
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            drag = nil
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
            var elements = elements(on: index)
            let before = elements
            elements.append(element)
            commit(elements, on: index, before: before, name: undoName(for: element.kind))
            // The shape drawn, the pointer goes back to choosing — as it does
            // in Excalidraw and Figma — with the new shape chosen, so the
            // panel is about it.
            state.tool = .select
            selection = Selection(pageIndex: index, elements: [element.id])
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
            var after = elementsBefore
            for changed in working {
                if let i = after.firstIndex(where: { $0.id == changed.id }) { after[i] = changed }
            }
            let drawingAfter = workingDrawing ?? drawingBefore
            if after != elementsBefore { session.setSketch(after, forPage: index) }
            if drawingAfter != drawingBefore { session.setDrawing(drawingAfter, forPage: index) }
            registerUndo(
                name: L("옮기기", "Move"), on: index,
                elements: (elementsBefore, after), drawing: (drawingBefore, drawingAfter)
            )
            refreshPage?(index)
        case let .resize(elementsBefore, original, _, _), let .bend(elementsBefore, original):
            guard let changed = working.first, changed != original else { refreshPage?(index); return }
            var after = elementsBefore
            if let i = after.firstIndex(where: { $0.id == changed.id }) { after[i] = changed }
            commit(after, on: index, before: elementsBefore, name: L("모양 바꾸기", "Reshape"))
        case .marquee, .pendingClick:
            break
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        // Choose what is under the pointer first, so the menu is about it.
        if state.tool == .select, let spot = spot(for: event),
           let hit = element(at: spot), !selection.elements.contains(hit.id) {
            selection = Selection(pageIndex: spot.index, elements: [hit.id])
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
        let one = selection.elements.count == 1 && selection.strokes.isEmpty
        add(L("글 고치기", "Edit Text"), #selector(editTextFromMenu), enabled: one)
        add(L("테두리 두르기", "Frame Selection"), #selector(frameFromMenu), enabled: has)
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
    @objc private func duplicateFromMenu() { duplicateSelection() }
    @objc private func frontFromMenu() { bringSelectionToFront() }
    @objc private func backFromMenu() { sendSelectionToBack() }
    @objc private func deleteFromMenu() { deleteSelection() }

    // Scrolling and zooming belong to the page underneath.
    override func scrollWheel(with event: NSEvent) {
        pdfView?.documentView?.enclosingScrollView?.scrollWheel(with: event)
    }

    override func magnify(with event: NSEvent) { pdfView?.magnify(with: event) }
    override func smartMagnify(with event: NSEvent) { pdfView?.smartMagnify(with: event) }

    // MARK: - Selecting

    private func beginSelecting(at spot: Spot, additive: Bool, clicks: Int) {
        let before = selection
        let current = elements(on: spot.index)

        // A double-click: type into what is there, or start a card where
        // there is nothing.
        if clicks == 2 {
            // On an element's line, or anywhere inside an empty box — a
            // double-click in a box means "write in here", as it does in
            // Excalidraw.
            let inside = current.last { $0.isBox && $0.rect.contains(spot.point) }
            if let hit = element(at: spot) ?? inside {
                selection = Selection(pageIndex: spot.index, elements: [hit.id])
                beginEditing(hit, on: spot.page, index: spot.index, isNew: false)
            } else {
                createText(at: spot)
            }
            return
        }

        // A handle of the one selected element.
        if selection.pageIndex == spot.index, selection.elements.count == 1, selection.strokes.isEmpty,
           let chosen = current.first(where: { selection.elements.contains($0.id) }),
           let handle = handle(at: spot.point, of: chosen, on: spot.page) {
            switch handle {
            case .mid:
                drag = .bend(elementsBefore: current, original: chosen)
            default:
                drag = .resize(elementsBefore: current, original: chosen, handle: handle, origin: spot.point)
            }
            working = [chosen]
            return
        }

        if let hit = element(at: spot) {
            if additive {
                var next = selection.pageIndex == spot.index ? selection : Selection()
                next.pageIndex = spot.index
                if next.elements.contains(hit.id) { next.elements.remove(hit.id) } else { next.elements.insert(hit.id) }
                selection = next
            } else if selection.pageIndex != spot.index || !selection.elements.contains(hit.id) {
                selection = Selection(pageIndex: spot.index, elements: [hit.id])
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

        if !additive { selection = Selection() }
        drag = .pendingClick(origin: spot.point, additive: additive, before: additive ? before : Selection())
    }

    private func beginMove(at spot: Spot) {
        drag = .move(
            elementsBefore: elements(on: spot.index), drawingBefore: session.drawing(forPage: spot.index),
            origin: spot.point, moved: false
        )
        working = elements(on: spot.index).filter { selection.elements.contains($0.id) }
        workingDrawing = nil
    }

    /// The topmost element under a point on its page.
    private func element(at spot: Spot) -> SketchElement? {
        let reach = tolerance(on: spot.page)
        return elements(on: spot.index).last { $0.hits(spot.point, tolerance: reach) }
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
        for element in elements(on: index) where element.bounds.intersects(box) {
            next.elements.insert(element.id)
        }
        for (i, stroke) in session.drawing(forPage: index).strokes.enumerated() where pageRect(of: stroke, on: page).intersects(box) {
            next.strokes.insert(i)
        }
        selection = next
    }

    private func selectionDidChange(from old: Selection) {
        let elements = selection.pageIndex.map { index in
            self.elements(on: index).filter { selection.elements.contains($0.id) }
        } ?? []
        state.setSelection(elements, strokes: selection.strokes.count)
        needsDisplay = true
    }

    /// Tells the panel again after the selection's elements changed under it.
    private func refreshSelectionState() {
        selectionDidChange(from: selection)
    }

    // MARK: - Handles

    private func handles(of element: SketchElement, on page: PDFPage) -> [(Handle, CGPoint)] {
        if element.isConnector {
            return [(.start, element.start), (.end, element.end), (.mid, element.midpoint)]
        }
        let r = element.rect
        return [
            (.topLeft, CGPoint(x: r.minX, y: r.maxY)), (.top, CGPoint(x: r.midX, y: r.maxY)),
            (.topRight, CGPoint(x: r.maxX, y: r.maxY)), (.right, CGPoint(x: r.maxX, y: r.midY)),
            (.bottomRight, CGPoint(x: r.maxX, y: r.minY)), (.bottom, CGPoint(x: r.midX, y: r.minY)),
            (.bottomLeft, CGPoint(x: r.minX, y: r.minY)), (.left, CGPoint(x: r.minX, y: r.midY)),
        ]
    }

    private func handle(at point: CGPoint, of element: SketchElement, on page: PDFPage) -> Handle? {
        let reach = 7 / scale(for: page)
        return handles(of: element, on: page).first { hypot($0.1.x - point.x, $0.1.y - point.y) <= reach }?.0
    }

    private func resized(_ original: SketchElement, by handle: Handle, to p: CGPoint, shift: Bool) -> SketchElement {
        var element = original
        switch handle {
        case .start:
            element.points = [p, original.end]
            return element
        case .end:
            element.points = [original.start, p]
            return element
        case .mid:
            return element
        default:
            break
        }
        let r = original.rect
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
        if original.kind == .text {
            // A text card is only ever as tall as its words; the handle sets
            // how wide they may run.
            let size = SketchTypesetter.cardSize(for: original.text, size: original.style.textSize, width: box.width)
            box = CGRect(x: box.minX, y: box.maxY - size.height, width: box.width, height: size.height)
            element.rect = box
            return element
        }
        return original.fitted(to: box, from: r)
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
            elements.removeAll { $0.hits(sample, tolerance: radius) }
            if drawing.strokes.count != strokeCount || elements.count != elementCount { touched = true }
            if configuration.presets.eraserErasesMarks { eraseMark?(spot.page, sample) }
        }
        guard touched else { return }
        if drawing != session.drawing(forPage: spot.index) { session.setDrawing(drawing, forPage: spot.index) }
        if elements != self.elements(on: spot.index) { session.setSketch(elements, forPage: spot.index) }
        refreshPage?(spot.index)
    }

    // MARK: - Text

    private func createText(at spot: Spot) {
        var style = state.style
        style.startHead = .none
        style.endHead = .none
        let size = SketchTypesetter.cardSize(for: "", size: style.textSize)
        let element = SketchElement(
            kind: .text,
            points: [spot.point, CGPoint(x: spot.point.x + max(size.width, 24), y: spot.point.y - size.height)],
            style: style
        )
        var elements = elements(on: spot.index)
        let before = elements
        elements.append(element)
        session.setSketch(elements, forPage: spot.index)
        drag = nil
        state.tool = .select
        selection = Selection(pageIndex: spot.index, elements: [element.id])
        beginEditing(element, on: spot.page, index: spot.index, isNew: true, before: before)
    }

    private func editorFrame(for element: SketchElement, on page: PDFPage) -> NSRect {
        var rect = element.rect
        if element.kind != .text { rect = rect.insetBy(dx: SketchTypesetter.padding, dy: SketchTypesetter.padding) }
        var frame = viewRect(rect, on: page)
        frame.size.width = max(frame.width, 40)
        frame.size.height = max(frame.height, 16)
        return frame.integral
    }

    private func editorFont(for element: SketchElement, on page: PDFPage) -> NSFont {
        NSFont.systemFont(ofSize: element.style.textSize.points * scale(for: page))
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

    private func editorTextChanged() {
        guard let editor = textEditor, let editing else { return }
        var elements = elements(on: editing.index)
        guard let i = elements.firstIndex(where: { $0.id == editing.id }) else { return }
        elements[i].text = editor.string
        if elements[i].kind == .text {
            // The card grows with its words, from its top-left corner, and
            // wraps once it is wider than a column.
            let natural = SketchTypesetter.cardSize(for: editor.string, size: elements[i].style.textSize)
            let width = min(max(natural.width, 24), 300)
            let size = natural.width > 300
                ? SketchTypesetter.cardSize(for: editor.string, size: elements[i].style.textSize, width: width)
                : natural
            let r = elements[i].rect
            elements[i].rect = CGRect(x: r.minX, y: r.maxY - size.height, width: width, height: size.height)
        }
        session.setSketch(elements, forPage: editing.index)
        editor.frame = editorFrame(for: elements[i], on: editing.page)
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
                    let natural = SketchTypesetter.cardSize(for: text, size: elements[i].style.textSize)
                    let width = min(max(natural.width, 24), 300)
                    let size = natural.width > 300
                        ? SketchTypesetter.cardSize(for: text, size: elements[i].style.textSize, width: width)
                        : natural
                    let r = elements[i].rect
                    elements[i].rect = CGRect(x: r.minX, y: r.maxY - size.height, width: width, height: size.height)
                }
            }
        }
        editor.removeFromSuperview()
        textEditor = nil
        self.editing = nil
        state.isEditingText = false
        if elements != editing.before {
            session.setSketch(elements, forPage: index)
            registerUndo(
                name: L(editing.isNew ? "글 쓰기" : "글 고치기", editing.isNew ? "Add Text" : "Edit Text"),
                on: index, elements: (editing.before, elements), drawing: nil
            )
        } else {
            session.setSketch(elements, forPage: index)
        }
        if !elements.contains(where: { $0.id == editing.id }) { selection = Selection() }
        refreshPage?(index)
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
                if selection.elements.count == 1 { editSelectedText(); return }
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
        }
        if flags == .command {
            switch characters {
            case "d": duplicateSelection(); return
            case "a": selectAllOnPage(); return
            default: break
            }
        }
        if flags == [.command, .shift] {
            switch characters {
            case "]": bringSelectionToFront(); return
            case "[": sendSelectionToBack(); return
            default: break
            }
        }
        // Anything else is not ours; the page has no use for it either,
        // and the beep the default would make is not worth hearing.
    }

    /// Escape, in the order Excalidraw takes it: let go of the selection,
    /// then put the tool down, then put the pencil away.
    private func escape() {
        if textEditor != nil { endEditing(commit: true); return }
        if !selection.isEmpty { selection = Selection(); return }
        if state.tool != .select { state.tool = .select; return }
        configuration.mode = .read
    }

    private func nudge(dx: CGFloat, dy: CGFloat, far: Bool) {
        guard let index = selection.pageIndex, hasSelection, let page = page(at: index) else { return }
        let step: CGFloat = far ? 10 : 1
        let offset = CGPoint(x: dx * step, y: dy * step)
        let before = elements(on: index)
        let after = before.map { selection.elements.contains($0.id) ? $0.translated(by: offset) : $0 }
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
        let after = before.map { element -> SketchElement in
            guard selection.elements.contains(element.id) else { return element }
            var changed = element
            change(&changed.style)
            if changed.kind == .text, changed.style.textSize != element.style.textSize {
                let size = SketchTypesetter.cardSize(for: changed.text, size: changed.style.textSize, width: changed.rect.width)
                let r = changed.rect
                changed.rect = CGRect(x: r.minX, y: r.maxY - size.height, width: r.width, height: size.height)
            }
            return changed
        }
        guard after != before else { return }
        commit(after, on: index, before: before, name: L("스타일", "Restyle"))
        refreshSelectionState()
    }

    func deleteSelection() {
        guard let index = selection.pageIndex, hasSelection else { return }
        let before = elements(on: index)
        let after = before.filter { !selection.elements.contains($0.id) }
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
        var after = before
        var copies: Set<UUID> = []
        for element in before where selection.elements.contains(element.id) {
            var copy = element.translated(by: CGPoint(x: 12, y: -12))
            copy.id = UUID()
            copy.createdAt = .now
            after.append(copy)
            copies.insert(copy.id)
        }
        commit(after, on: index, before: before, name: L("복제", "Duplicate"))
        selection = Selection(pageIndex: index, elements: copies)
    }

    /// A box round the selection: the frame XMind puts round a topic, drawn
    /// round anything — three shapes, a paragraph of handwriting, both.
    func frameSelection() {
        guard let index = selection.pageIndex, hasSelection, let page = page(at: index) else { return }
        let before = elements(on: index)
        var box = CGRect.union(of: before.filter { selection.elements.contains($0.id) }.map(\.bounds))
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
        let frame = SketchElement(
            kind: .rectangle,
            points: [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.maxY)],
            style: style
        )
        // Behind what it frames, so the frame never covers a word.
        var after = before
        let lowest = after.indices.first { selection.elements.contains(after[$0].id) } ?? after.count
        after.insert(frame, at: lowest)
        commit(after, on: index, before: before, name: L("테두리", "Frame"))
        selection = Selection(pageIndex: index, elements: [frame.id])
    }

    func bringSelectionToFront() {
        guard let index = selection.pageIndex, !selection.elements.isEmpty else { return }
        let before = elements(on: index)
        let after = before.filter { !selection.elements.contains($0.id) } + before.filter { selection.elements.contains($0.id) }
        commit(after, on: index, before: before, name: L("맨 앞으로", "Bring to Front"))
    }

    func sendSelectionToBack() {
        guard let index = selection.pageIndex, !selection.elements.isEmpty else { return }
        let before = elements(on: index)
        let after = before.filter { selection.elements.contains($0.id) } + before.filter { !selection.elements.contains($0.id) }
        commit(after, on: index, before: before, name: L("맨 뒤로", "Send to Back"))
    }

    func selectAllOnPage() {
        guard let pdfView, let page = pdfView.currentPage else { return }
        let index = session.document.index(for: page)
        guard index != NSNotFound else { return }
        selection = Selection(
            pageIndex: index,
            elements: Set(elements(on: index).map(\.id)),
            strokes: Set(session.drawing(forPage: index).strokes.indices)
        )
    }

    func editSelectedText() {
        guard let index = selection.pageIndex, selection.elements.count == 1, let page = page(at: index),
              let element = elements(on: index).first(where: { selection.elements.contains($0.id) })
        else { return }
        beginEditing(element, on: page, index: index, isNew: false)
    }

    // MARK: - Committing, and undoing

    private func undoName(for kind: SketchElement.Kind) -> String {
        switch kind {
        case .rectangle: L("네모", "Rectangle")
        case .ellipse: L("동그라미", "Ellipse")
        case .arrow: L("화살표", "Arrow")
        case .line: L("선", "Line")
        case .text: L("글", "Text")
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
        let picked = elements(on: index).filter { selection.elements.contains($0.id) }
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
            var after = before
            for element in clipping.elements {
                var copy = shift == .zero ? element : element.translated(by: shift)
                copy.id = UUID()
                copy.createdAt = .now
                after.append(copy)
                landed.insert(copy.id)
            }
            commit(after, on: index, before: before, name: L("붙여넣기", "Paste"))
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

    private func commit(_ elements: [SketchElement], on index: Int, before: [SketchElement], name: String) {
        guard elements != before else { return }
        session.setSketch(elements, forPage: index)
        registerUndo(name: name, on: index, elements: (before, elements), drawing: nil)
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
        func inWindow(_ p: CGPoint) -> CGPoint { pdfView.convert(pdfView.convert(p, from: page), to: nil) }
        func mouse(_ type: NSEvent.EventType, _ p: CGPoint, clicks: Int = 1, flags: NSEvent.ModifierFlags = []) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: inWindow(p), modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
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
            var lines = ["probe: page \(index): \(elements(on: index).count) elements, \(session.drawing(forPage: index).strokes.count) strokes, selection \(selection.elements.count) elements + \(selection.strokes.count) strokes, tool \(state.tool.rawValue), editing \(textEditor != nil)"]
            for element in elements(on: index) {
                let r = element.rect
                let box = String(format: "(%.0f, %.0f, %.0f, %.0f)", r.minX, r.minY, r.width, r.height)
                let bend = element.bend.map { String(format: " bend(%.0f, %.0f)", $0.x, $0.y) } ?? ""
                lines.append("  \(element.kind.rawValue) \(box)\(bend) width \(element.style.width) dash \(element.style.dash.rawValue) fill \(element.style.fill == nil ? "none" : "yes") text \"\(element.text)\"")
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
        case .rectangle, .ellipse, .arrow, .line: .crosshair
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
        case let .stroke(points, _, _, _):
            drawLiveStroke(points, on: page, in: context)
        case .move, .resize, .bend:
            context.saveGState()
            context.concatenate(toView)
            SketchRenderer.draw(working, in: context, options: .init(fillAlphaScale: 0.7))
            context.restoreGState()
            if let workingDrawing {
                drawStrokes(workingDrawing, indices: selection.strokes, on: page, in: context)
            }
            for element in working { drawHandles(of: element, on: page, in: context) }
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
        _ = index
    }

    private var isMoving: Bool {
        switch drag {
        case .move, .resize, .bend: true
        default: false
        }
    }

    private func drawSelection(on page: PDFPage, index: Int, in context: CGContext) {
        let accent = NSColor.controlAccentColor
        let elements = elements(on: index).filter { selection.elements.contains($0.id) }
        // The strokes: a dashed box round the lot.
        let strokes = session.drawing(forPage: index).strokes
        var inkBox = CGRect.null
        for i in selection.strokes where i < strokes.count {
            inkBox = inkBox.union(pageRect(of: strokes[i], on: page))
        }
        if !inkBox.isNull {
            let box = viewRect(inkBox.insetBy(dx: -3, dy: -3), on: page)
            context.setStrokeColor(accent.withAlphaComponent(0.8).cgColor)
            context.setLineWidth(1)
            context.setLineDash(phase: 0, lengths: [4, 3])
            context.stroke(box.insetBy(dx: 0.5, dy: 0.5))
            context.setLineDash(phase: 0, lengths: [])
        }
        guard !isMoving else { return }
        for element in elements {
            if elements.count > 1 || !inkBox.isNull {
                let box = viewRect(element.bounds, on: page)
                context.setStrokeColor(accent.withAlphaComponent(0.6).cgColor)
                context.setLineWidth(1)
                context.stroke(box.insetBy(dx: 0.5, dy: 0.5))
            }
        }
        if elements.count == 1, inkBox.isNull, let only = elements.first {
            drawHandles(of: only, on: page, in: context)
        }
    }

    /// The outline and the handles of one element, in view coordinates.
    private func drawHandles(of element: SketchElement, on page: PDFPage, in context: CGContext) {
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
            let box = viewRect(element.rect, on: page).insetBy(dx: -2, dy: -2)
            context.stroke(box.insetBy(dx: 0.5, dy: 0.5))
        }
        for (handle, point) in handles(of: element, on: page) {
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
        wantsLayer = true
        layer?.cornerRadius = 3
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
            if let fill = element.style.fill?.flattenedOnWhite {
                drawsBackground = true
                backgroundColor = NSColor(red: fill.red, green: fill.green, blue: fill.blue, alpha: 1)
            } else {
                drawsBackground = true
                backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.85)
            }
            alignment = .left
        } else {
            textContainerInset = .zero
            drawsBackground = true
            backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.85)
            alignment = .center
        }
        typingAttributes = [.font: font, .foregroundColor: textColor ?? .textColor]
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
#endif


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
