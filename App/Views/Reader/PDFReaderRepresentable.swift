import Foundation
import InkEngine
import PDFKit
import PDFReader
import PencilKit
import SwiftUI

#if canImport(UIKit)
import UIKit
typealias PlatformViewRepresentable = UIViewRepresentable
#else
import AppKit
typealias PlatformViewRepresentable = NSViewRepresentable
#endif

/// Hosts a `PDFView` and, on devices with a pencil, a drawing canvas over each
/// page.
///
/// The canvases are supplied through `PDFPageOverlayViewProvider`, which places
/// them in page coordinates and keeps them aligned through scrolling and
/// zooming — the alternative, positioning canvases by hand, drifts the moment
/// the layout changes. `PKCanvasView` does not exist on macOS, so the Mac shows
/// the ink that is stored in the PDF itself and offers text markup instead.
struct PDFReaderRepresentable: PlatformViewRepresentable {
    let session: DocumentSession
    let configuration: ReaderConfiguration
    let link: ReaderLink
    /// Read here so that a change to the document's marks re-runs `update`,
    /// which is where the view is told to repaint.
    var revision: Int
    @Binding var currentPageIndex: Int
    var onSelectionChange: (PDFSelection?, CGRect) -> Void
    /// The system edit menu's "Add Note", which the reader turns into the
    /// note editor.
    var onNoteRequested: () -> Void
    /// Shows a short confirmation for actions that leave nothing on screen.
    var onToast: (String) -> Void

    func makeCoordinator() -> ReaderCoordinator {
        ReaderCoordinator(
            session: session,
            configuration: configuration,
            link: link,
            onPageChange: { currentPageIndex = $0 },
            onSelectionChange: onSelectionChange,
            onNoteRequested: onNoteRequested,
            onToast: onToast
        )
    }

    #if canImport(UIKit)
    func makeUIView(context: Context) -> PDFView { context.coordinator.makePDFView() }
    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.adopt(
            session: session,
            onSelectionChange: onSelectionChange,
            onToast: onToast
        )
        context.coordinator.update(view, revision: revision)
    }
    static func dismantleUIView(_ view: PDFView, coordinator: ReaderCoordinator) {
        coordinator.tearDown()
    }
    #else
    func makeNSView(context: Context) -> PDFView { context.coordinator.makePDFView() }
    func updateNSView(_ view: PDFView, context: Context) {
        context.coordinator.adopt(
            session: session,
            onSelectionChange: onSelectionChange,
            onToast: onToast
        )
        context.coordinator.update(view, revision: revision)
    }
    static func dismantleNSView(_ view: PDFView, coordinator: ReaderCoordinator) {
        coordinator.tearDown()
    }
    #endif
}

@MainActor
final class ReaderCoordinator: NSObject {
    /// Not `let`: the coordinator outlives any one pass of the view tree, and
    /// a coordinator holding last week's session would show one document and
    /// write another.
    private var session: DocumentSession
    private let configuration: ReaderConfiguration
    private let link: ReaderLink
    private let onPageChange: (Int) -> Void
    private var onSelectionChange: (PDFSelection?, CGRect) -> Void
    private let onNoteRequested: () -> Void
    private var onToast: (String) -> Void

    private weak var pdfView: PDFView?
    private var shownRevision = 0
    private var appliedLayout: ReaderConfiguration.PageLayout?
    #if os(macOS)
    private let markupPanel = MarkupPanelController()
    private var markupTask: Task<Void, Never>?
    #endif
    #if canImport(UIKit)
    private var canvases: [Int: PKCanvasView] = [:]
    private let toolPicker = PKToolPicker()
    #endif

    init(
        session: DocumentSession,
        configuration: ReaderConfiguration,
        link: ReaderLink,
        onPageChange: @escaping (Int) -> Void,
        onSelectionChange: @escaping (PDFSelection?, CGRect) -> Void,
        onNoteRequested: @escaping () -> Void,
        onToast: @escaping (String) -> Void
    ) {
        self.session = session
        self.configuration = configuration
        self.link = link
        self.onPageChange = onPageChange
        self.onSelectionChange = onSelectionChange
        self.onNoteRequested = onNoteRequested
        self.onToast = onToast
        super.init()
    }

    /// Takes the values from the latest pass of the view tree.
    func adopt(
        session: DocumentSession,
        onSelectionChange: @escaping (PDFSelection?, CGRect) -> Void,
        onToast: @escaping (String) -> Void
    ) {
        self.session = session
        self.onSelectionChange = onSelectionChange
        self.onToast = onToast
    }

    func makePDFView() -> PDFView {
        #if canImport(UIKit)
        let view = MarkupCapablePDFView()
        view.onMarkup = { [weak self] kind, color in
            guard let self, let selection = view.currentSelection else { return }
            self.session.addMarkup(for: selection, kind: kind, color: color)
        }
        view.onNote = { [weak self] in self?.onNoteRequested() }
        #else
        let view = MarkupCapablePDFView()
        view.onMarkup = { [weak self] kind, color in
            guard let self, let selection = view.currentSelection else { return }
            session.addMarkup(for: selection, kind: kind, color: color)
            hideMarkupPanel()
        }
        view.onNote = { [weak self] in
            guard let self, let selection = view.currentSelection else { return }
            showMarkupPanel(for: selection, in: view, composing: true)
        }
        #endif
        view.document = session.document
        view.autoScales = true
        view.displaysPageBreaks = true
        view.pageShadowsEnabled = true
        view.pageOverlayViewProvider = self
        #if canImport(UIKit)
        view.usePageViewController(false)
        #endif
        apply(layout: configuration.layout, to: view)
        appliedLayout = configuration.layout
        shownRevision = session.revision

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pageChanged),
            name: .PDFViewPageChanged,
            object: view
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(selectionChanged),
            name: .PDFViewSelectionChanged,
            object: view
        )

        // These menu commands used to post notifications nobody listened for.
        for (name, selector) in [
            (Notification.Name.paperTimeNextPage, #selector(goToNextPage)),
            (.paperTimePreviousPage, #selector(goToPreviousPage)),
            (.paperTimeGoBack, #selector(goBackInHistory)),
            (.paperTimeGoForward, #selector(goForwardInHistory)),
        ] {
            NotificationCenter.default.addObserver(
                self,
                selector: selector,
                name: name,
                object: nil
            )
        }

        #if canImport(UIKit)
        // Two fingers, two taps: nothing in PDFKit claims that combination, so
        // it cannot be confused with selecting text, turning a page, or the
        // double-tap that zooms.
        let focusGesture = UITapGestureRecognizer(
            target: self,
            action: #selector(toggleFocusRequested)
        )
        focusGesture.numberOfTouchesRequired = 2
        focusGesture.numberOfTapsRequired = 2
        view.addGestureRecognizer(focusGesture)
        #endif

        pdfView = view
        restoreReadingPosition(in: view)
        return view
    }

    func update(_ view: PDFView, revision: Int) {
        if view.document !== session.document {
            view.document = session.document
            shownRevision = revision
        } else if revision != shownRevision {
            shownRevision = revision
            redraw(view)
        }
        if appliedLayout != configuration.layout {
            appliedLayout = configuration.layout
            apply(layout: configuration.layout, to: view)
        }
        applyTint(to: view)
        updateCanvasInteraction()

        // A find result asks the reader to bring it into view; acting on it
        // here keeps the PDF view the only thing that knows how to scroll.
        if let requested = link.scrollRequest {
            view.setCurrentSelection(requested, animate: true)
            view.scrollSelectionToVisible(nil)
            link.scrollRequest = nil
        }

        if let anchor = link.anchorRequest {
            reveal(anchor, in: view)
            link.anchorRequest = nil
        }
    }

    /// Forces PDFKit to re-render the pages it has cached.
    ///
    /// Adding an annotation changes the page but not the image PDFKit already
    /// drew from it, so without this a new highlight only shows up after the
    /// page is scrolled away and back.
    private func redraw(_ view: PDFView) {
        #if canImport(UIKit)
        view.clearSelection()
        for page in visiblePages(of: view) {
            view.setNeedsDisplay(view.convert(page.bounds(for: view.displayBox), from: page))
        }
        view.layoutDocumentView()
        #else
        view.clearSelection()
        view.layoutDocumentView()
        view.needsDisplay = true
        #endif
    }

    private func visiblePages(of view: PDFView) -> [PDFPage] {
        guard let current = view.currentPage else { return [] }
        return [current]
    }

    /// Scrolls a mark into view and flashes the text under it.
    private func reveal(_ anchor: ReaderLink.Anchor, in view: PDFView) {
        guard let page = session.document.page(at: anchor.pageIndex) else { return }
        // A little room around the mark, so it lands inside the page rather
        // than jammed against the top edge.
        let padded = anchor.rect.insetBy(dx: -24, dy: -80)
        view.go(to: padded, on: page)
        if let selection = page.selection(for: anchor.rect) {
            view.setCurrentSelection(selection, animate: true)
        }
    }

    func tearDown() {
        NotificationCenter.default.removeObserver(self)
        #if os(macOS)
        hideMarkupPanel()
        #endif
        #if canImport(UIKit)
        toolPicker.setVisible(false, forFirstResponder: PKCanvasView())
        canvases.removeAll()
        #endif
    }

    // MARK: - Layout

    /// Two-up used to mean `twoUpContinuous` down a vertical scroll, which is
    /// two columns of a scrolling document rather than a book. A spread should
    /// turn, not scroll: `twoUp` horizontally, with `displaysAsBook` so the
    /// first page sits alone on the right the way a cover does.
    private func apply(layout: ReaderConfiguration.PageLayout, to view: PDFView) {
        switch layout {
        case .continuous:
            view.displayMode = .singlePageContinuous
            view.displayDirection = .vertical
            view.displaysAsBook = false
        case .singlePage:
            view.displayMode = .singlePage
            view.displayDirection = .horizontal
            view.displaysAsBook = false
        case .book:
            view.displayMode = .twoUp
            view.displayDirection = .horizontal
            view.displaysAsBook = true
        }

        #if canImport(UIKit)
        // The page view controller gives the paged modes a real swipe-to-turn
        // gesture with the curl-free horizontal transition Books uses. It has
        // to be off for continuous scrolling or the scroll is taken over.
        view.usePageViewController(layout != .continuous, withViewOptions: nil)
        #endif
    }

    private func applyTint(to view: PDFView) {
        #if canImport(UIKit)
        switch configuration.tint {
        case .none:
            view.backgroundColor = .systemGroupedBackground
            view.pageShadowsEnabled = true
        case .sepia:
            view.backgroundColor = UIColor(red: 0.96, green: 0.93, blue: 0.86, alpha: 1)
            view.pageShadowsEnabled = true
        case .dim:
            view.backgroundColor = UIColor(white: 0.12, alpha: 1)
            view.pageShadowsEnabled = false
        }
        #else
        switch configuration.tint {
        case .none: view.backgroundColor = .windowBackgroundColor
        case .sepia: view.backgroundColor = NSColor(red: 0.96, green: 0.93, blue: 0.86, alpha: 1)
        case .dim: view.backgroundColor = NSColor(white: 0.12, alpha: 1)
        }
        #endif
    }

    private func restoreReadingPosition(in view: PDFView) {
        let index = session.paper.state.lastPageIndex
        guard index > 0, index < session.document.pageCount,
              let page = session.document.page(at: index)
        else { return }
        view.go(to: page)
    }

    // MARK: - Notifications

    @objc private func pageChanged(_ notification: Notification) {
        guard let view = pdfView, let page = view.currentPage else { return }
        onPageChange(session.document.index(for: page))
    }

    #if canImport(UIKit)
    @objc private func toggleFocusRequested() {
        NotificationCenter.default.post(name: .paperTimeToggleFocus, object: nil)
    }
    #endif

    @objc private func goToNextPage() {
        guard let view = pdfView, view.canGoToNextPage else { return }
        view.goToNextPage(nil)
    }

    @objc private func goToPreviousPage() {
        guard let view = pdfView, view.canGoToPreviousPage else { return }
        view.goToPreviousPage(nil)
    }

    @objc private func goBackInHistory() {
        guard let view = pdfView, view.canGoBack else { return }
        view.goBack(nil)
    }

    @objc private func goForwardInHistory() {
        guard let view = pdfView, view.canGoForward else { return }
        view.goForward(nil)
    }

    @objc private func selectionChanged(_ notification: Notification) {
        guard let view = pdfView,
              let selection = view.currentSelection,
              selection.string?.isEmpty == false
        else {
            onSelectionChange(nil, .zero)
            #if os(macOS)
            // A selection cleared while the note editor is open is the editor
            // taking focus, not the reader letting go.
            if !markupPanel.isShowing { hideMarkupPanel() }
            #endif
            return
        }

        // Where the selection sits inside the reader, so the markup controls
        // can appear next to the text instead of at the top of the window.
        var frame = CGRect.zero
        for page in selection.pages {
            let bounds = view.convert(selection.bounds(for: page), from: page)
            frame = frame.isEmpty ? bounds : frame.union(bounds)
        }

        #if os(macOS)
        // AppKit views are bottom-left origin unless flipped, while the SwiftUI
        // overlay that draws the markup controls is top-left. Without this the
        // controls appear mirrored about the middle of the page.
        if !view.isFlipped {
            frame.origin.y = view.bounds.height - frame.maxY
        }
        #endif

        onSelectionChange(selection, frame)
        #if os(macOS)
        scheduleMarkupPanel(for: selection, in: view)
        #endif
    }

    // MARK: - Markup panel

    #if os(macOS)
    /// Waits for the drag to finish before showing anything. A selection
    /// reports itself once per character crossed; opening on the first would
    /// anchor the controls to one letter.
    private func scheduleMarkupPanel(for selection: PDFSelection, in view: PDFView) {
        markupTask?.cancel()
        markupTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled, let self else { return }
            showMarkupPanel(for: selection, in: view)
        }
    }

    private func showMarkupPanel(
        for selection: PDFSelection,
        in view: PDFView,
        composing: Bool = false
    ) {
        guard let window = view.window else { return }
        var frame = CGRect.zero
        for page in selection.pages {
            let bounds = view.convert(selection.bounds(for: page), from: page)
            frame = frame.isEmpty ? bounds : frame.union(bounds)
        }
        guard !frame.isEmpty else { return }
        let inWindow = view.convert(frame, to: nil)
        let onScreen = window.convertToScreen(inWindow)

        markupPanel.show(
            anchor: onScreen,
            over: window,
            quotedText: selection.string ?? "",
            onMark: { [weak self] kind, color in
                guard let self else { return }
                session.addMarkup(for: selection, kind: kind, color: color)
                finishMarkup(in: view)
            },
            onNote: { [weak self] comment in
                guard let self else { return }
                session.addNote(for: selection, comment: comment)
                finishMarkup(in: view)
            },
            onCopy: { [weak self] in
                guard let self else { return }
                let text = selection.string ?? ""
                if !text.isEmpty {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                onToast("Copied")
                finishMarkup(in: view)
            },
            onDismiss: { [weak self] in self?.finishMarkup(in: view) },
            composing: composing
        )
    }

    private func finishMarkup(in view: PDFView) {
        hideMarkupPanel()
        view.clearSelection()
        onSelectionChange(nil, .zero)
    }

    private func hideMarkupPanel() {
        markupTask?.cancel()
        markupTask = nil
        markupPanel.hide()
    }
    #endif

    // MARK: - Canvases

    private func updateCanvasInteraction() {
        #if canImport(UIKit)
        let drawing = configuration.mode == .draw
        for canvas in canvases.values {
            canvas.isUserInteractionEnabled = drawing
            canvas.drawingPolicy = configuration.fingerDrawing ? .anyInput : .pencilOnly
        }
        if drawing, configuration.showsToolPicker, let first = canvases.values.first {
            toolPicker.setVisible(true, forFirstResponder: first)
            first.becomeFirstResponder()
        } else if let first = canvases.values.first {
            toolPicker.setVisible(false, forFirstResponder: first)
        }
        #endif
    }
}

// PDFKit calls the overlay provider and the canvas delegate on the main
// thread, but neither protocol is annotated for it in the SDK.
extension ReaderCoordinator: @preconcurrency PDFPageOverlayViewProvider {
    #if canImport(UIKit)
    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        let index = session.document.index(for: page)
        if let existing = canvases[index] { return existing }

        let canvas = PKCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = configuration.fingerDrawing ? .anyInput : .pencilOnly
        canvas.isUserInteractionEnabled = configuration.mode == .draw
        canvas.drawing = session.drawing(forPage: index)
        canvas.delegate = self
        canvas.tag = index
        // The overlay is handed to PDFKit in page coordinates; PencilKit must
        // not add its own scrolling on top of the PDF view's.
        canvas.isScrollEnabled = false
        toolPicker.addObserver(canvas)
        canvas.tool = toolPicker.selectedTool
        canvases[index] = canvas
        return canvas
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
        // Keep the canvas so a page scrolled back into view still shows its
        // ink immediately; PDFKit reuses the same instance.
    }
    #else
    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> NSView? {
        // PencilKit has no canvas on macOS. Ink written on iPad is stored in
        // the PDF as standard annotations, which PDFKit already renders here.
        nil
    }
    #endif
}

#if canImport(UIKit)
extension ReaderCoordinator: @preconcurrency PKCanvasViewDelegate {
    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        session.setDrawing(canvasView.drawing, forPage: canvasView.tag)
    }
}
#endif
