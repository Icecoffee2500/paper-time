import Foundation
import InkEngine
import CoreImage
import PDFKit
import PDFReader
import PencilKit
import SwiftUI

#if canImport(UIKit)
import UIKit
typealias PlatformEdgeInsets = UIEdgeInsets
typealias PlatformViewRepresentable = UIViewRepresentable
#else
import AppKit
typealias PlatformEdgeInsets = NSEdgeInsets
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
        context.coordinator.link = link
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
    /// Swappable: with papers side by side the pane in focus borrows the
    /// window's own handle, and gives it back when focus moves on.
    var link: ReaderLink
    private let onPageChange: (Int) -> Void
    private var onSelectionChange: (PDFSelection?, CGRect) -> Void
    private let onNoteRequested: () -> Void
    private var onToast: (String) -> Void

    private weak var pdfView: PDFView?
    private var shownRevision = 0
    private var appliedLayout: ReaderConfiguration.PageLayout?
    private var appliedTint: ReaderConfiguration.PageTint?
    private var appliedMode: ReaderConfiguration.Mode?
    private var appliedFingerDrawing: Bool?
    /// The crop that makes the document a book, while it is one.
    private var bookTrim: BookTrim?
    #if os(macOS)
    /// Over the PDF view while the pencil is out; kept between outings so
    /// its selection state does not have to be rebuilt.
    private var sketchInput: SketchInputView?
    #endif
    /// Trims every page to the paper's content: see `BookTrim`.
    private func trimForBook(_ document: PDFDocument) {
        if let bookTrim, bookTrim.document === document, bookTrim.isApplied { return }
        untrim()
        let trim = BookTrim(document: document)
        trim.apply()
        bookTrim = trim
    }

    private func untrim() {
        bookTrim?.restore()
        bookTrim = nil
        link.bookGutter = 0
    }

    /// Measures the pages about to be shown and re-crops them on their own
    /// centre, laying the spread out again if any changed.
    private func trimAround(_ page: PDFPage, in view: PDFView) {
        guard let bookTrim, bookTrim.isApplied else { return }
        let index = session.document.index(for: page)
        guard index != NSNotFound else { return }
        let spread = index - index % 2
        if bookTrim.ensure([spread, spread + 1]) {
            view.layoutDocumentView()
            #if os(macOS)
            fitSpread(in: view)
            #endif
        }
        // The spreads either side, after this one is on screen.
        DispatchQueue.main.async { [weak bookTrim] in
            _ = bookTrim?.ensure([spread + 2, spread + 3, spread - 2, spread - 1])
        }
    }

    #if os(macOS)
    /// Keeps the spread centred: PDFKit lays a spread out with a full page
    /// break at either end as well as between the pages, so the document is
    /// wider than the view, and where the excess goes depends on how the view
    /// was last scrolled — to the left edge for a page turn, wherever a jump
    /// left it for a destination. This puts it back in the middle.
    private var clipObserver: (any NSObjectProtocol)?
    private var centering = false
    private let markupPanel = MarkupPanelController()
    private var markupTask: Task<Void, Never>?
    private var scrollMonitor: Any?
    /// ← and → in a book, which PDFKit leaves unanswered.
    private var arrowMonitor: Any?
    /// Refits the spread to the view's width while a book is open.
    private var spreadObserver: (any NSObjectProtocol)?

    /// Scrolls the spread to the middle of the view when the document is
    /// wider than the view; when it is narrower, PDFKit centres it itself.
    /// Measured against the view, not the clip: a scroller can take a strip
    /// off the clip's width, and a spread centred in the clip sat that much
    /// to one side of the window.
    private func centerSpread(in view: PDFView) {
        guard appliedLayout == .book, !centering,
              let scrollView = view.subviews.compactMap({ $0 as? NSScrollView }).first,
              let documentView = scrollView.documentView, view.scaleFactor > 0
        else { return }
        let clip = scrollView.contentView
        let excess = documentView.frame.width - clip.bounds.width
        guard excess > 0.5 else { return }
        let shown = view.visiblePages.map { view.convert($0.bounds(for: view.displayBox), from: $0) }
        guard let minX = shown.map(\.minX).min(), let maxX = shown.map(\.maxX).max() else { return }
        let offset = (minX + maxX) / 2 - view.bounds.midX
        guard abs(offset) > 0.5 else { return }
        let target = min(max(clip.bounds.origin.x + offset / view.scaleFactor, documentView.frame.minX), documentView.frame.minX + excess)
        guard abs(clip.bounds.origin.x - target) > 0.25 else { return }
        centering = true
        clip.scroll(to: CGPoint(x: target, y: clip.bounds.origin.y))
        scrollView.reflectScrolledClipView(clip)
        centering = false
    }

    private func setCenterLock(_ isOn: Bool, in view: PDFView) {
        if let clipObserver { NotificationCenter.default.removeObserver(clipObserver) }
        clipObserver = nil
        guard isOn, let scrollView = view.subviews.compactMap({ $0 as? NSScrollView }).first else { return }
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        clipObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip, queue: nil
        ) { [weak self, weak view] _ in
            MainActor.assumeIsolated {
                guard let self, let view else { return }
                self.centerSpread(in: view)
            }
        }
    }

    /// Scales a two-page spread to the width of the view.
    ///
    /// `autoScales` fits a spread to the view's *height*, so both pages are
    /// wholly visible and, on a wide window, small. A book is read across, so
    /// the width is what should be filled: two pages, the gutter, and a hair
    /// of margin on each side.
    private func fitSpread(in view: PDFView) {
        guard view.displayMode == .twoUp,
              let page = view.currentPage ?? view.document?.page(at: 0)
        else { return }
        let bounds = page.bounds(for: view.displayBox)
        let width = view.bounds.width - 24, height = view.bounds.height - 16
        guard bounds.width > 0, bounds.height > 0, width > 100, height > 100 else { return }
        view.autoScales = false
        // As large as the spread can be with nothing cut off: the two pages
        // across the width, unless the pages are then taller than the view,
        // in which case the height decides. Filling the width alone put the
        // top and bottom lines of every page out of sight.
        let gap = view.pageBreakMargins.left + view.pageBreakMargins.right
        view.scaleFactor = min(width / (bounds.width * 2 + gap), height / bounds.height)
        view.layoutDocumentView()
        centerSpread(in: view)
        // How wide the gutter came out on screen, for the contents to fit in.
        let shown = view.visiblePages
            .map { view.convert($0.bounds(for: view.displayBox), from: $0) }
            .sorted { $0.minX < $1.minX }
        if shown.count >= 2 {
            // Edge to edge, plus the trim each page keeps beside its text:
            // the whole stretch with no words in it.
            link.bookGutter = max(0, shown[1].minX - shown[0].maxX) + 2 * BookTrim.margin * view.scaleFactor
        }
    }
    private var clickMonitor: Any?
    private var pinchMonitor: Any?
    private var scrolled: CGFloat = 0
    private var markupObservers: [NSObjectProtocol] = []
    #endif
    #if canImport(UIKit)
    private var canvases: [Int: PKCanvasView] = [:]
    private var overlays: [Int: PageOverlay] = [:]
    private var originalTouchTypes: [NSNumber]?
    private var appliedToolKey: String?
    /// The canvas last drawn on, whose undo stack the strip's arrows work.
    private weak var lastCanvas: PKCanvasView?
    /// Strokes each canvas had when last seen, so a new one can be told apart
    /// from an erasure.
    private var strokeCounts: [Int: Int] = [:]
    private var isRewritingCanvas = false
    private var editMenu: UIEditMenuInteraction?
    private var tappedMarkID: UUID?

    static func scrollView(in view: UIView) -> UIScrollView? {
        for child in view.subviews {
            if let scroll = child as? UIScrollView { return scroll }
            if let found = scrollView(in: child) { return found }
        }
        return nil
    }

    #endif

    /// Another device's ink for these pages arrived; the overlays show it.
    @objc private func inkChanged(_ notification: Notification) {
        guard notification.object as? DocumentSession === session,
              let pages = notification.userInfo?["pages"] as? [Int] else { return }
        for index in pages {
            #if canImport(UIKit)
            canvases[index]?.drawing = session.drawing(forPage: index)
            strokeCounts[index] = session.drawing(forPage: index).strokes.count
            #endif
            if let page = session.document.page(at: index) {
                #if os(macOS)
                InkOverlayView.refresh(page)
                #endif
                hideOwnedInk(on: page, index: index)
                pdfView?.annotationsChanged(on: page)
            }
        }
    }

    /// Under an overlay the file's copy of our ink is not drawn. The sidecar
    /// is where the ink lives — the canvas draws it on the iPad, the ink
    /// overlay on the Mac — and a page with ink in the file always has one,
    /// made from the file if need be. Drawing the PDF's annotations too
    /// doubled every line and left a ghost behind an erased one, until the
    /// twenty-megabyte PDF caught up.
    private func hideOwnedInk(on page: PDFPage, index: Int) {
        for annotation in page.annotations
        where (InkConverter.isOwned(annotation) || SketchWriter.isOwned(annotation)) && annotation.shouldDisplay {
            annotation.shouldDisplay = false
        }
    }

    /// A page's sketch changed — drawn here, undone, or arrived from another
    /// device: the overlay drawing it draws again.
    @objc private func sketchChanged(_ notification: Notification) {
        guard notification.object as? DocumentSession === session,
              let pages = notification.userInfo?["pages"] as? [Int] else { return }
        for index in pages {
            guard let page = session.document.page(at: index) else { continue }
            SketchOverlayView.refresh(page)
        }
    }

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
        #if os(macOS)
        sketchInput?.session = session
        #endif
    }

    func makePDFView() -> PDFView {
        #if canImport(UIKit)
        let view = MarkupCapablePDFView()
        view.onMarkup = { [weak self] kind, color in
            guard let self, let selection = view.currentSelection else { return }
            self.session.addMarkup(for: selection, kind: kind, color: color)
        }
        view.onNote = { [weak self] in self?.onNoteRequested() }
        view.onLayout = { [weak self, weak view] width in
            guard let self, let view, appliedLayout == .book, fittedSpreadWidth != width else { return }
            fitSpread(in: view)
        }
        #else
        let view = MarkupCapablePDFView()
        view.onMarkup = { [weak self] kind, color in
            guard let self, let selection = view.currentSelection else { return }
            let made = session.addMarkup(for: selection, kind: kind, color: color)
            registerUndo(made, name: markupActionName(kind), in: view)
            hideMarkupPanel()
        }
        view.onNote = { [weak self] in
            guard let self, let selection = view.currentSelection else { return }
            showMarkupPanel(for: selection, in: view, composing: true)
        }
        view.onRemoveMark = { [weak self] annotation in
            guard let self, let id = Self.markID(of: annotation),
                  let descriptor = session.markup(withID: id)
            else { return }
            session.removeMarkup(id: id)
            registerRemovalUndo([descriptor], name: "Remove Mark", in: view)
        }
        view.onRecolorMark = { [weak self] annotation, color in
            guard let self, let id = Self.markID(of: annotation) else { return }
            session.recolor(id: id, to: color)
        }

        #endif
        #if os(macOS)
        // No table mode. On macOS 26 PDFKit hands every page that comes into
        // view to Vision, and where it finds a table it draws a frame with
        // handles and lets the mouse select cells and nothing else — a drag
        // that starts inside the table cannot reach the sentence beside it.
        // The switch is PDFKit's own, not in the headers, so it is asked for
        // by name and left alone if a future PDFKit no longer has it. Turning
        // it off also stops the background analysis that rewrote pages under
        // the reader (see CLAUDE.md), and the selections it produced whose
        // lines had no place.
        let analysis = NSSelectorFromString("setDocumentAnalysisEnabled:")
        if view.responds(to: analysis) {
            view.setValue(false, forKey: "documentAnalysisEnabled")
        }
        #endif
        // Before the document: PDFKit asks the provider as it lays pages
        // out, and a provider that arrives after the pages does not get asked
        // for them.
        view.pageOverlayViewProvider = self
        view.document = session.document
        view.autoScales = true
        view.displaysPageBreaks = true
        view.pageShadowsEnabled = true
        #if canImport(UIKit)
        view.usePageViewController(false)
        #endif
        apply(layout: configuration.layout, to: view)
        appliedLayout = configuration.layout
        shownRevision = session.revision

        NotificationCenter.default.addObserver(
            self, selector: #selector(inkChanged), name: .paperTimeInkChanged, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(sketchChanged), name: .paperTimeSketchChanged, object: nil
        )
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(self, selector: #selector(undoInk), name: .paperTimeInkUndo, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(redoInk), name: .paperTimeInkRedo, object: nil)
        #endif
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pageChanged),
            name: .PDFViewPageChanged,
            object: view
        )
        #if os(macOS)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(ultraCopySelection),
            name: .paperTimeUltraCopy,
            object: nil
        )
        #endif
        #if os(macOS)
        // PDFKit tells us when a mark is clicked; overriding `mouseDown` does
        // not, because the click lands on its inner document view.
        // The controls belong to one selection on one page. Scrolling, turning
        // the page, zooming or leaving the window all end that.
        for name in [
            Notification.Name.PDFViewScaleChanged,
            .PDFViewPageChanged,
            NSScrollView.didLiveScrollNotification,
            NSWindow.didResignKeyNotification,
        ] {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(dismissMarkupPanel),
                name: name,
                object: nil
            )
        }
        #endif
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
            (.paperTimeZoomIn, #selector(zoomIn)),
            (.paperTimeZoomOut, #selector(zoomOut)),
            (.paperTimeActualSize, #selector(actualSize)),
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
        // A tap on a mark opens its menu — colours and Remove — as a click
        // does on the Mac. Taps elsewhere are left to PDFKit.
        let markTap = UITapGestureRecognizer(target: self, action: #selector(markTapped(_:)))
        markTap.cancelsTouchesInView = false
        markTap.delaysTouchesEnded = false
        markTap.delegate = self
        view.addGestureRecognizer(markTap)
        let interaction = UIEditMenuInteraction(delegate: self)
        view.addInteraction(interaction)
        editMenu = interaction
        #endif

        pdfView = view
        #if os(macOS)
        // The reader's own scrollers: thin and fading, so nothing sits in the
        // margin of the page while it is being read.
        for scrollView in view.subviews.compactMap({ $0 as? NSScrollView }) {
            scrollView.scrollerStyle = .overlay
            scrollView.verticalScroller?.controlSize = .small
        }
        installMarkClickMonitor(in: view)
        installPinchMonitor(in: view)
        installMarkupShortcuts(for: view)
        if let plan = Boot.setting("PAPERTIME_MARK_TEST") { markWithoutAMouse(plan, in: view) }
        if Boot.isSet("PAPERTIME_DRAW") || Boot.isSet("PAPERTIME_SKETCH_SHOT") { sketchProbe(in: view) }
        if Boot.isSet("PAPERTIME_WATCH_THREADS") { watchNotificationThreads() }
        #endif
        restoreReadingPosition(in: view)
        return view
    }

    func update(_ view: PDFView, revision: Int) {
        Trace.time("reader: update") { updateNow(view, revision: revision) }
    }

    private func updateNow(_ view: PDFView, revision: Int) {
        if let input = sketchInput { input.session = session }
        if view.document !== session.document {
            // The overlays belong to the pages of the paper being left, and
            // they are kept by page *number*. Handed on to the next paper,
            // page 1's canvas brought the last paper's ink with it, and page
            // 1's marks had no overlay of their own: `redraw` hides a mark
            // from PDFKit so the overlay can draw it rounded, and with the
            // overlay pointing at another document's page nothing drew it at
            // all. A highlight went on being made — the list showed it — and
            // the page stayed blank. One paper, one set of overlays.
            #if canImport(UIKit)
            discardPageViews()
            #endif
            view.document = session.document
            if appliedLayout == .book {
                trimForBook(session.document)
                #if os(macOS)
                DispatchQueue.main.async { [weak self, weak view] in
                    guard let self, let view else { return }
                    self.fitSpread(in: view)
                }
                #endif
            }
            shownRevision = revision
            #if os(macOS)
            hideMarkupPanel()
            // The selection and the half-drawn shape belonged to the last
            // paper; the pencil is put back on this one below.
            sketchInput?.deactivate()
            appliedMode = nil
            #endif
            restoreReadingPosition(in: view)
        } else if revision != shownRevision {
            shownRevision = revision
            redraw(view)
        }
        #if os(macOS)
        // The monitors are installed when the view is made, but the view now
        // outlives individual papers and a teardown would leave it without one.
        if clickMonitor == nil { installMarkClickMonitor(in: view) }
        if pinchMonitor == nil { installPinchMonitor(in: view) }
        #endif
        if appliedLayout != configuration.layout {
            appliedLayout = configuration.layout
            apply(layout: configuration.layout, to: view)
        }
        if appliedTint != configuration.effectiveTint {
            appliedTint = configuration.effectiveTint
            applyTint(to: view)
        }
        if appliedMode != configuration.mode || appliedFingerDrawing != configuration.fingerDrawing {
            appliedMode = configuration.mode
            appliedFingerDrawing = configuration.fingerDrawing
            updateCanvasInteraction()
        }
        #if canImport(UIKit)
        if appliedToolKey != configuration.toolKey {
            appliedToolKey = configuration.toolKey
            for canvas in canvases.values { canvas.tool = configuration.currentTool }
        }
        #endif

        // A find result asks the reader to bring it into view; acting on it
        // here keeps the PDF view the only thing that knows how to scroll.
        if let requested = link.scrollRequest {
            view.setCurrentSelection(requested, animate: true)
            view.scrollSelectionToVisible(nil)
            link.scrollRequest = nil
        }

        // Only if it is this paper's. An anchor naming another paper is a
        // request to open that one, and the reader still showing the old one
        // was answering it — scrolling to page nine of the wrong document and
        // leaving nothing for the right one to act on.
        if let anchor = link.anchorRequest,
           anchor.paperID == nil || anchor.paperID == session.paper.id {
            reveal(anchor, in: view)
            link.anchorRequest = nil
        }
        if let destination = link.destinationRequest {
            view.go(to: destination)
            link.destinationRequest = nil
            #if os(macOS)
            if appliedLayout == .book, let page = destination.page {
                trimAround(page, in: view)
                centerSpread(in: view)
            }
            #endif
            // Said outright: PDFKit posts its page-changed notification
            // before `currentPage` has moved for a destination jump, so the
            // status bar was left naming the spread you had just left.
            if let page = destination.page {
                let index = session.document.index(for: page)
                if index != NSNotFound { onPageChange(index) }
            }
        }
    }

    /// Forces PDFKit to re-render the pages it has cached.
    ///
    /// Adding an annotation changes the page but not the image PDFKit already
    /// drew from it, so without this a new highlight only shows up after the
    /// page is scrolled away and back.
    private func redraw(_ view: PDFView) {
        Trace.time("reader: redraw") { redrawNow(view) }
    }

    private func redrawNow(_ view: PDFView) {
        #if canImport(UIKit)
        view.clearSelection()
        for page in visiblePages(of: view) {
            // Hiding a mark from PDFKit is only safe where something else
            // will draw it. A page whose overlay has not been asked for yet
            // keeps PDFKit's own square mark until it has one — visibly
            // square beats invisible.
            let index = session.document.index(for: page)
            guard overlays[index]?.page === page else { continue }
            // A mark just added is a flat annotation until the overlay has
            // taken it over; do that now and have the cached page repainted.
            _ = RoundedMarks.takeOver(page)
            view.annotationsChanged(on: page)
            MarkOverlayView.refresh(page)
        }
        view.layoutDocumentView()
        #else
        view.clearSelection()
        // Ink that arrived from another device is a new annotation on a page
        // PDFKit has already drawn; tell it so, or the cached page stays.
        for page in visiblePages(of: view) { view.annotationsChanged(on: page) }
        view.layoutDocumentView()
        view.needsDisplay = true
        #endif
    }

    /// The pages on screen — both of them in a spread, where a mark made on
    /// the facing page was left to PDFKit's own square drawing because only
    /// the current page was ever repainted.
    private func visiblePages(of view: PDFView) -> [PDFPage] {
        let shown = view.visiblePages
        if !shown.isEmpty { return shown }
        return view.currentPage.map { [$0] } ?? []
    }

    /// Scrolls a mark into view and flashes the text under it.
    private func reveal(_ anchor: ReaderLink.Anchor, in view: PDFView) {
        guard let page = session.document.page(at: anchor.pageIndex) else { return }
        // A place on the page was not worked out — go to the page itself
        // rather than to its bottom-left corner, which is where an empty
        // rectangle would send it.
        guard !anchor.rect.isEmpty else {
            view.go(to: page)
            onPageChange(anchor.pageIndex)
            return
        }
        // A little room around the mark, so it lands inside the page rather
        // than jammed against the top edge.
        let padded = anchor.rect.insetBy(dx: -24, dy: -80)
        view.go(to: padded, on: page)
        onPageChange(anchor.pageIndex)
        if let selection = page.selection(for: anchor.rect) {
            view.setCurrentSelection(selection, animate: true)
        }
    }

    func tearDown() {
        NotificationCenter.default.removeObserver(self)
        #if os(macOS)
        hideMarkupPanel()
        for monitor in [scrollMonitor, arrowMonitor, clickMonitor, pinchMonitor].compactMap({ $0 }) {
            NSEvent.removeMonitor(monitor)
        }
        for observer in markupObservers { NotificationCenter.default.removeObserver(observer) }
        markupObservers = []
        for observer in [spreadObserver, clipObserver].compactMap({ $0 }) { NotificationCenter.default.removeObserver(observer) }
        spreadObserver = nil
        clipObserver = nil
        sketchInput?.deactivate()
        sketchInput?.removeFromSuperview()
        sketchInput = nil
        untrim()
        scrollMonitor = nil
        arrowMonitor = nil
        clickMonitor = nil
        pinchMonitor = nil
        #endif
        #if canImport(UIKit)
        canvases.removeAll()
        overlays.removeAll()
        #endif
    }

    // MARK: - Layout

    /// Two-up used to mean `twoUpContinuous` down a vertical scroll, which is
    /// two columns of a scrolling document rather than a book. A spread should
    /// turn, not scroll: `twoUp` horizontally, with `displaysAsBook` so the
    /// first page sits alone on the right the way a cover does.
    private func apply(layout: ReaderConfiguration.PageLayout, to view: PDFView) {
        // The page you were on survives the change. Switching the display
        // mode makes PDFKit lay the document out again, and it came back at
        // the last page — so ⌘1 read as "go to the end" rather than "one
        // page at a time, here".
        let staying = view.currentPage
        defer {
            if let staying {
                DispatchQueue.main.async { [weak view] in view?.go(to: staying) }
            }
        }

        untrim()
        applyTint(to: view)
        // The space between two pages of a spread. Wide, and the same for
        // every paper, because the pages have been trimmed to their text:
        // this gap plus the trim is the whole gutter.
        view.pageBreakMargins = layout == .book
            ? PlatformEdgeInsets(top: 4.75, left: 84, bottom: 4.75, right: 84)
            : PlatformEdgeInsets(top: 4.75, left: 4.75, bottom: 4.75, right: 4.75)

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
            trimForBook(session.document)
            view.displayMode = .twoUp
            view.displayDirection = .horizontal
            // Pages 1 and 2 face each other. `displaysAsBook` puts the first
            // page alone on the right as a cover, which a novel has and a
            // paper does not — a paper's first spread is its title and its
            // introduction, side by side.
            view.displaysAsBook = false
        }

        #if os(macOS)
        setBookScrolling(layout == .book, in: view)
        setCenterLock(layout == .book, in: view)
        // A book fills the window: two pages across it, not two pages fitted
        // to its height and floating small in the middle. Fitted again
        // whenever the view's width changes, which in focus mode it does as
        // the columns leave.
        if layout == .book {
            view.postsFrameChangedNotifications = true
            if spreadObserver == nil {
                spreadObserver = NotificationCenter.default.addObserver(
                    forName: NSView.frameDidChangeNotification, object: view, queue: .main
                ) { [weak self, weak view] _ in
                    MainActor.assumeIsolated {
                        guard let self, let view, self.appliedLayout == .book else { return }
                        self.fitSpread(in: view)
                    }
                }
            }
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view else { return }
                self.fitSpread(in: view)
            }
        } else {
            if let spreadObserver { NotificationCenter.default.removeObserver(spreadObserver) }
            spreadObserver = nil
            view.autoScales = true
        }
        #endif

        #if canImport(UIKit)
        // The page view controller gives the paged modes a real swipe-to-turn
        // gesture with the curl-free horizontal transition Books uses. It has
        // to be off for continuous scrolling or the scroll is taken over.
        // Only the single page turns with the page view controller: it shows
        // one page at a time, which made a book of two pages show one.
        view.usePageViewController(layout == .singlePage, withViewOptions: nil)
        setBookSwipes(layout == .book, in: view)
        // A book fills the width, as on the Mac; anything else fits itself.
        if layout == .book {
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view else { return }
                fitSpread(in: view)
            }
        } else {
            view.autoScales = true
            fittedSpreadWidth = 0
        }
        #endif
    }

    #if canImport(UIKit)
    private var fittedSpreadWidth: CGFloat = 0
    /// Whether a spread is in the middle of being carried across the view, so
    /// a second flick does not stack another pair of pictures on the first.
    private var isTurningPages = false
    /// The swipes that turn a spread, while the reader is a book.
    private var bookSwipes: [UISwipeGestureRecognizer] = []

    /// A book turns by a swipe across it, as it does in Books.
    ///
    /// Nothing else here can turn it. The page view controller shows one page
    /// at a time and a spread is two, so it is off; and the spread is fitted
    /// to the view, which leaves the scroll view a few points of slack and no
    /// more — a swipe dragged the two pages sideways and let go, and the book
    /// stayed on the same spread. The scroll view's own pan is made to wait
    /// on these, so a deliberate drag still moves a spread that has been
    /// zoomed into while a flick turns the page.
    private func setBookSwipes(_ on: Bool, in view: PDFView) {
        for swipe in bookSwipes { view.removeGestureRecognizer(swipe) }
        bookSwipes = []
        guard on else { return }
        let turns: [(UISwipeGestureRecognizer.Direction, Selector)] = [
            (.left, #selector(goToNextPage)),
            (.right, #selector(goToPreviousPage)),
        ]
        for (direction, action) in turns {
            let swipe = UISwipeGestureRecognizer(target: self, action: action)
            swipe.direction = direction
            view.addGestureRecognizer(swipe)
            bookSwipes.append(swipe)
        }
        guard let scrollView = Self.scrollView(in: view) else { return }
        for swipe in bookSwipes { scrollView.panGestureRecognizer.require(toFail: swipe) }
    }

    /// Two pages across the view, as large as they can be with nothing cut
    /// off — the same rule the Mac applies. Done again when the width changes.
    func fitSpread(in view: PDFView) {
        guard view.displayMode == .twoUp,
              let page = view.currentPage ?? view.document?.page(at: 0) else { return }
        let bounds = page.bounds(for: view.displayBox)
        let width = view.bounds.width - 24, height = view.bounds.height - 16
        guard bounds.width > 0, bounds.height > 0, width > 100, height > 100 else { return }
        view.autoScales = false
        // Autoscaling leaves its own fit behind as the floor and the
        // ceiling; a scale set with those still in place is clamped to it.
        view.minScaleFactor = 0.1
        view.maxScaleFactor = 8
        let gap = view.pageBreakMargins.left + view.pageBreakMargins.right
        view.scaleFactor = min(width / (bounds.width * 2 + gap), height / bounds.height)
        fittedSpreadWidth = view.bounds.width
        view.layoutDocumentView()
    }
    #endif

    private func applyTint(to view: PDFView) {
        #if canImport(UIKit)
        switch configuration.effectiveTint {
        case .none:
            view.backgroundColor = .systemGroupedBackground
            view.pageShadowsEnabled = true
        case .sepia:
            view.backgroundColor = UIColor(red: 0.96, green: 0.93, blue: 0.86, alpha: 1)
            view.pageShadowsEnabled = true
        case .dim:
            view.backgroundColor = UIColor(white: 0.12, alpha: 1)
            view.pageShadowsEnabled = false
        case .glass:
            // Nothing of its own behind the pages, and no shadow around them:
            // both are opaque, and the point is to see the panel through the
            // paper. The white of the page itself goes in `ReaderScreen`,
            // which is where the compositing can be done.
            view.backgroundColor = .clear
            view.pageShadowsEnabled = false
        }
        #else
        // Sepia and Dimmed used to colour the space around the page and leave
        // the page white, so the tint showed as a border. The paper is what
        // has to change. Sepia is the glass trick with a sepia ground behind
        // it: the page's white multiplies away to the ground and the ink
        // stays ink. Dimmed cannot be a multiply — black ink over a dark
        // ground is nothing — so it is an inversion with the hue turned
        // back round, the way every reader's night mode is made: white paper
        // becomes dark, black ink becomes light, and a colour keeps its hue.
        let tint = configuration.effectiveTint
        switch tint {
        case .none:
            // In a spread the ground is the paper's own white and there is
            // no shadow under the pages: two white cards on a grey ground
            // read as two cards, and one white field with two pages in it
            // reads as a book. Scrolling layouts keep the window's ground.
            let book = configuration.layout == .book
            view.backgroundColor = book ? .textBackgroundColor : .windowBackgroundColor
            view.pageShadowsEnabled = !book
        case .sepia, .glass:
            view.backgroundColor = .clear
            view.pageShadowsEnabled = false
        case .dim:
            view.backgroundColor = .clear
            view.pageShadowsEnabled = false
        }
        setGlassCompositing(on: view, tint == .glass || tint == .sepia)
        setNightFilter(on: view, tint == .dim)
        NightMode.isOn = tint == .dim
        // The figures overlay draws only under the dimmed tint; ask every
        // page to draw again so they appear or go.
        for page in view.visiblePages { MarkOverlayView.refresh(page) }
        view.needsDisplay = true
        #endif
    }

    #if os(macOS)
    /// Inverts the page's luminance and puts its colours back.
    private func setNightFilter(on view: PDFView, _ on: Bool) {
        view.wantsLayer = true
        guard on else { view.layer?.filters = nil; return }
        guard let invert = CIFilter(name: "CIColorInvert"),
              let hue = CIFilter(name: "CIHueAdjust", parameters: [kCIInputAngleKey: Double.pi])
        else { return }
        view.layer?.filters = [invert, hue]
    }
    #endif

    #if os(macOS)
    /// Multiplies the whole PDF view against whatever is drawn behind it, so
    /// the white of the paper falls away to the panel's glass and only the ink
    /// is left.
    ///
    /// Done on the layer rather than with SwiftUI's `.blendMode`, which never
    /// reached the panel: the panel clips its content to a rounded rectangle,
    /// and a clip is a compositing boundary — the blend was sealed inside it
    /// with nothing behind to multiply with. A compositing filter on the
    /// layer is the same operation stated where Core Animation will honour it.
    private func setGlassCompositing(on view: PDFView, _ on: Bool) {
        view.wantsLayer = true
        view.layer?.compositingFilter = on ? "multiplyBlendMode" : nil
    }
    #endif

    private func restoreReadingPosition(in view: PDFView) {
        let index = session.paper.state.lastPageIndex
        guard index > 0, index < session.document.pageCount,
              let page = session.document.page(at: index)
        else { return }
        view.go(to: page)
    }

    // MARK: - Notifications

    @objc private func pageChanged(_ notification: Notification) {
        noteDocumentHistory()
        guard let view = pdfView, let page = view.currentPage else { return }
        #if os(macOS)
        if appliedLayout == .book { trimAround(page, in: view) }
        #endif
        onPageChange(session.document.index(for: page))
    }

    #if canImport(UIKit)
    @objc private func toggleFocusRequested() {
        NotificationCenter.default.post(name: .paperTimeToggleFocus, object: nil)
    }
    #endif

    @objc private func goToNextPage() {
        guard let view = pdfView, view.canGoToNextPage else { return }
        #if canImport(UIKit)
        turningPages(in: view, forward: true) { view.goToNextPage(nil) }
        #else
        view.goToNextPage(nil)
        #endif
    }

    @objc private func goToPreviousPage() {
        guard let view = pdfView, view.canGoToPreviousPage else { return }
        #if canImport(UIKit)
        turningPages(in: view, forward: false) { view.goToPreviousPage(nil) }
        #else
        view.goToPreviousPage(nil)
        #endif
    }

    #if canImport(UIKit)
    /// Pushes the old spread off and the new one on, the way the single page
    /// turns.
    ///
    /// A single page gets its movement from the page view controller, which
    /// cannot show two pages at once and so is off in a book — and a book
    /// without it cut from one spread to the next with no motion at all,
    /// which reads as a glitch rather than a page turning.
    ///
    /// Core Animation does it, not a pair of snapshot views. The snapshots
    /// were the first attempt and they stuttered: taking the picture of the
    /// spread about to arrive means rendering the whole of it on the main
    /// thread before the animation can start, and the pause landed exactly
    /// where the movement should have been. A push transition on the view's
    /// own layer is handed to the render server, which already has the old
    /// spread drawn and needs no picture taken of either.
    private func turningPages(in view: PDFView, forward: Bool, _ turn: () -> Void) {
        guard appliedLayout == .book, !isTurningPages else { turn(); return }
        isTurningPages = true
        let push = CATransition()
        push.type = .push
        push.subtype = forward ? .fromRight : .fromLeft
        push.duration = 0.32
        // The curve the page view controller uses: quick to leave, gentle to
        // arrive. Linear reads as a slide rather than a turn.
        push.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
        view.layer.add(push, forKey: "paperTime.turn")
        turn()
        // Lay the new spread out before the transition is committed, so what
        // is pushed on is the spread and not the blank it would otherwise be
        // for the first frame or two.
        view.layoutIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + push.duration) { [weak self] in
            self?.isTurningPages = false
        }
    }
    #endif

    /// Back: to where a followed link came from, if there is such a place;
    /// otherwise to the paper opened before this one.
    @objc private func goBackInHistory() {
        if let view = pdfView, view.canGoBack {
            view.goBack(nil)
        } else {
            NotificationCenter.default.post(name: .paperTimeBackToPreviousPaper, object: nil)
        }
        noteDocumentHistory()
    }

    private func noteDocumentHistory() {
        link.canGoBackInDocument = pdfView?.canGoBack ?? false
        link.canGoForwardInDocument = pdfView?.canGoForward ?? false
    }

    @objc private func zoomIn() {
        guard let view = pdfView, view.canZoomIn else { return }
        view.zoomIn(nil)
    }

    @objc private func zoomOut() {
        guard let view = pdfView, view.canZoomOut else { return }
        view.zoomOut(nil)
    }

    /// Back to fitting the window, which is where the reader starts.
    @objc private func actualSize() {
        guard let view = pdfView else { return }
        view.autoScales = true
    }

    @objc private func goForwardInHistory() {
        if let view = pdfView, view.canGoForward {
            view.goForward(nil)
        } else {
            NotificationCenter.default.post(name: .paperTimeForwardToNextPaper, object: nil)
        }
        noteDocumentHistory()
    }

    @objc private func selectionChanged(_ notification: Notification) {
        if Boot.isSet("PAPERTIME_WATCH_SELECTION"), let selection = pdfView?.currentSelection {
            Self.describe(selection)
        }
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
        var frame = Self.extent(of: selection, in: view)

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

    /// Prints what PDFKit says about a selection: `--papertime-watch-selection=1`.
    /// For the selections a table produces, where `bounds(for:)` is `nan`.
    private static func describe(_ selection: PDFSelection) {
        let lines = selection.selectionsByLine()
        var out = "selection: \"\((selection.string ?? "").prefix(50))\" string \(selection.string?.count ?? -1) chars, \(selection.pages.count) pages, \(lines.count) lines\n"
        for page in selection.pages {
            out += "  text ranges on page: \((0..<selection.numberOfTextRanges(on: page)).map { selection.range(at: $0, on: page) })\n"
            out += "  page bounds \(selection.bounds(for: page))\n"
            for (i, line) in lines.enumerated().prefix(12) {
                let ranges = (0..<line.numberOfTextRanges(on: page)).map { line.range(at: $0, on: page) }
                let chars = ranges.flatMap { r in
                    [r.location, r.location + max(r.length - 1, 0)].map { page.characterBounds(at: $0) }
                }
                out += "  line \(i) \"\((line.string ?? "").prefix(24))\" bounds \(line.bounds(for: page)) ranges \(ranges) charBounds \(chars)\n"
            }
        }
        FileHandle.standardError.write(Data(out.utf8))
    }

    /// The box round a selection, in the view's coordinates, made only from
    /// the pages that can say where it is.
    ///
    /// `bounds(for:)` comes back as `nan` for some lines of a selection that
    /// crosses a table — once PDFKit's own table analysis has been over the
    /// page — and `nan` passes `isEmpty`, `union`s into everything it touches,
    /// and ends as a window frame AppKit refuses with an exception. Empty
    /// here means "nowhere PDFKit could name", and the callers say what to
    /// do with that.
    private static func extent(of selection: PDFSelection, in view: PDFView) -> CGRect {
        var frame = CGRect.zero
        for page in selection.pages {
            let onPage = selection.bounds(for: page)
            guard onPage.isFinite else { continue }
            let bounds = view.convert(onPage, from: page)
            guard bounds.isFinite else { continue }
            frame = frame.isEmpty ? bounds : frame.union(bounds)
        }
        return frame
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

    /// Reports any notification that arrives on a thread other than the main
    /// one. Every observer in this file is an `@objc` method of a main-actor
    /// class, and a notification delivered on another thread calls it there.
    private func watchNotificationThreads() {
        NotificationCenter.default.addObserver(
            forName: nil, object: nil, queue: nil
        ) { note in
            guard !Thread.isMainThread else { return }
            FileHandle.standardError.write(Data(
                "OFF-MAIN: \(note.name.rawValue) from \(type(of: note.object ?? "nil" as Any))\n".utf8
            ))
        }
    }

    /// Marks a rectangle of a page and takes the mark straight back off,
    /// reporting how long the marking took.
    ///
    /// `--papertime-mark-test=5,70,600,490,140` marks that rectangle of page
    /// six (pages counted from zero), which on this paper is a table. A
    /// selection dragged across a table is a hundred lines in one gesture, and
    /// that is the shape of mark that has to stay quick — there is no way to
    /// drag a mouse from a script, and PDFKit's own drag runs an event loop of
    /// its own that a synthesised event cannot get through.
    private func markWithoutAMouse(_ plan: String, in view: PDFView) {
        Task { @MainActor [weak self, weak view] in
            func say(_ text: String) {
                FileHandle.standardError.write(Data("mark test: \(text)\n".utf8))
            }
            try? await Task.sleep(for: .seconds(2))
            guard let self, let view, let document = view.document else { return say("no view") }
            let numbers = plan.split(separator: ",").compactMap { Double($0) }
            guard let first = numbers.first, let page = document.page(at: Int(first))
            else { return say("no page") }
            let rect = numbers.count >= 5
                ? CGRect(x: numbers[1], y: numbers[2], width: numbers[3], height: numbers[4])
                : page.bounds(for: .cropBox)
            if let zoom = Boot.setting("PAPERTIME_MARK_TEST_ZOOM").flatMap(Double.init) {
                view.autoScales = false
                view.scaleFactor = zoom
            }
            view.go(to: rect, on: page)
            try? await Task.sleep(for: .milliseconds(400))
            if let window = view.window {
                let onScreen = window.convertToScreen(view.convert(view.convert(rect, from: page), to: nil))
                let top = NSScreen.screens.first?.frame.height ?? 0
                say("rect on screen (top-left origin): \(Int(onScreen.minX)) \(Int(top - onScreen.maxY)) \(Int(onScreen.width)) \(Int(onScreen.height))")
            }
            // `--papertime-mark-test-dry=1`: only go there and say where it is.
            // Marking writes the file, the watcher reloads it, and the view
            // scrolls back to wherever it was — under a probe that has just
            // been told where the table is.
            if Boot.isSet("PAPERTIME_MARK_TEST_DRY") { return say("dry: went there, marked nothing") }
            // `--papertime-mark-test-range=1644,11`: select by text range
            // instead — the way a table cell comes in from the mouse.
            let byRange: PDFSelection? = Boot.setting("PAPERTIME_MARK_TEST_RANGE").flatMap { spec in
                let parts = spec.split(separator: ",").compactMap { Int($0) }
                return parts.count == 2 ? page.selection(for: NSRange(location: parts[0], length: parts[1])) : nil
            }
            guard let selection = byRange ?? page.selection(for: rect) else { return say("nothing there") }
            let lines = selection.selectionsByLine()
            for (i, line) in lines.enumerated() {
                say("line \(i) \"\((line.string ?? "").prefix(20))\" bounds \(line.bounds(for: page))")
            }
            let placeless = lines.filter { !$0.bounds(for: page).isFinite }.count
            say("selection bounds \(selection.bounds(for: page)), \(placeless) of \(lines.count) lines without a place")

            let started = Date()
            let made = session.addMarkup(for: selection, kind: .highlight, color: .yellow)
            let took = Date().timeIntervalSince(started) * 1000
            say(String(format: "%d lines, %d rects, %.1f ms",
                       selection.selectionsByLine().count,
                       made.first?.rects.count ?? 0, took))
            // Put the paper back as it was: a probe must not leave marks in
            // somebody's library.
            for descriptor in made { session.removeMarkup(id: descriptor.id) }

            // `--papertime-nan-bar=1`: the exact call that took the app down —
            // the bar asked to stand at a place that is not a number. Before
            // the guards this threw inside a task and the app died a moment
            // later, somewhere else; now it should stand mid-window and say so.
            if Boot.isSet("PAPERTIME_NAN_BAR"), let window = view.window {
                let nowhere = CGRect(x: CGFloat.nan, y: CGFloat.nan, width: 10, height: 10)
                markupPanel.show(anchor: nowhere, over: window, quotedText: "",
                                 onMark: { _, _ in }, onNote: { _ in }, onCopy: {},
                                 onUltraCopy: {}, onDismiss: {})
                try? await Task.sleep(for: .milliseconds(300))
                say("nan bar: showing \(markupPanel.isShowing), panel frame \(markupPanel.frameForTesting.map { "\($0)" } ?? "none")")
            }
        }
    }

    /// Drives the pencil without a hand on it, for checking the drawing
    /// mode from a script: `--papertime-draw=1` takes the pencil out,
    /// `--papertime-sketch-tool=rectangle` picks a tool,
    /// `--papertime-sketch-sample=1` puts a few shapes on the page in view,
    /// and `--papertime-sketch-shot=<path in the container>` writes the
    /// window to a PNG after `--papertime-sketch-shot-after=<seconds>`
    /// (two by default), saying on stderr where the page is on screen so a
    /// real pointer can be sent there. Only with a library named on the
    /// command line: it draws on whatever paper is open.
    private func sketchProbe(in view: PDFView) {
        guard Boot.isSet("PAPERTIME_LIBRARY") else {
            FileHandle.standardError.write(Data("sketch probe: refused — not the test library\n".utf8))
            return
        }
        Task { @MainActor [weak self, weak view] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, let view, let window = view.window else { return }
            func say(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }
            if Boot.isSet("PAPERTIME_DRAW") { configuration.mode = .draw }
            if let name = Boot.setting("PAPERTIME_SKETCH_TOOL"), let tool = SketchTool(rawValue: name) {
                configuration.sketch.tool = tool
            }
            guard let page = view.currentPage else { return say("sketch probe: no page") }
            let index = session.document.index(for: page)
            let box = page.bounds(for: view.displayBox)
            if Boot.isSet("PAPERTIME_SKETCH_SAMPLE") {
                var arrow = SketchElement(kind: .arrow, points: [
                    CGPoint(x: box.minX + 60, y: box.maxY - 200), CGPoint(x: box.minX + 250, y: box.maxY - 120),
                ], style: SketchStyle(stroke: .red))
                arrow.setMidpoint(CGPoint(x: box.minX + 130, y: box.maxY - 100))
                let who = SketchElement(kind: .rectangle, points: [
                    CGPoint(x: box.minX + 260, y: box.maxY - 160), CGPoint(x: box.minX + 400, y: box.maxY - 100),
                ], style: SketchStyle(stroke: .blue, fill: .paleBlue), text: "Who is the intended market?")
                let why = SketchElement(kind: .ellipse, points: [
                    CGPoint(x: box.minX + 60, y: box.maxY - 320), CGPoint(x: box.minX + 200, y: box.maxY - 240),
                ], style: SketchStyle(stroke: .purple, dash: .dashed))
                var card = SketchElement(kind: .text, points: [
                    CGPoint(x: box.minX + 240, y: box.maxY - 240), CGPoint(x: box.minX + 380, y: box.maxY - 270),
                ], style: SketchStyle(stroke: .ink, fill: .paleYellow), text: "user personas\nuser flow path")
                card.style.border = true
                session.setSketch([arrow, who, why, card], forPage: index)
                say("sketch probe: 4 sample elements on page \(index)")
            }
            // `--papertime-sketch-script="tool=rectangle;drag=100,600,300,500;report"`:
            // gestures in page coordinates, run one after another.
            if let script = Boot.setting("PAPERTIME_SKETCH_SCRIPT") {
                try? await Task.sleep(for: .milliseconds(300))
                for op in script.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) where !op.isEmpty {
                    if op.hasPrefix("wait=") {
                        try? await Task.sleep(for: .seconds(Double(op.dropFirst(5)) ?? 0.5))
                        continue
                    }
                    if let input = sketchInput {
                        say(input.performProbe(op))
                    } else {
                        say("sketch probe: no input view — is the pencil out?")
                    }
                    try? await Task.sleep(for: .milliseconds(120))
                }
            }
            let after = Boot.setting("PAPERTIME_SKETCH_SHOT_AFTER").flatMap(Double.init) ?? 2
            // Where the page is, for a pointer: Cocoa (y up from the bottom
            // of the screen) and Quartz (y down from the top).
            let onScreen = window.convertToScreen(view.convert(view.convert(box, from: page), to: nil))
            let screenHeight = NSScreen.screens.first?.frame.height ?? 0
            say("sketch probe: page \(index) cocoa \(Int(onScreen.minX)) \(Int(onScreen.minY)) \(Int(onScreen.width)) \(Int(onScreen.height))")
            say("sketch probe: page \(index) quartz top-left \(Int(onScreen.minX)) \(Int(screenHeight - onScreen.maxY)) size \(Int(onScreen.width)) \(Int(onScreen.height))")
            guard let path = Boot.setting("PAPERTIME_SKETCH_SHOT") else { return }
            try? await Task.sleep(for: .seconds(after))
            guard let content = window.contentView?.superview ?? window.contentView,
                  let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return say("sketch probe: no bitmap") }
            content.cacheDisplay(in: content.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
                say("sketch probe: wrote \(path); page \(index) has \(session.sketch(forPage: index).count) elements, \(session.drawing(forPage: index).strokes.count) strokes, \(session.markups.count) marks")
            }
        }
    }

    private func showMarkupPanel(
        for selection: PDFSelection,
        in view: PDFView,
        composing: Bool = false
    ) {
        guard let window = view.window else { return }
        var onScreen: CGRect
        let frame = Self.extent(of: selection, in: view)
        if !frame.isEmpty {
            onScreen = window.convertToScreen(view.convert(frame, to: nil))
        } else {
            // PDFKit could not say where the selection is — every line of it
            // came back as `nan`, which a selection across a table can do.
            // The words are still selected and can still be marked, so the
            // bar stands where the hand is instead of not at all.
            let pointer = NSEvent.mouseLocation
            onScreen = CGRect(x: pointer.x, y: pointer.y, width: 0, height: 0)
        }
        guard onScreen.isFinite else { return }

        markupPanel.show(
            anchor: onScreen,
            over: window,
            quotedText: selection.string ?? "",
            onMark: { [weak self] kind, color in
                guard let self else { return }
                let made = session.addMarkup(for: selection, kind: kind, color: color)
                registerUndo(made, name: markupActionName(kind), in: view)
                finishMarkup(in: view)
            },
            onNote: { [weak self] comment in
                guard let self else { return }
                let made = session.addNote(for: selection, comment: comment)
                registerUndo(made, name: "Add Note", in: view)
                finishMarkup(in: view)
            },
            onCopy: { [weak self] in
                guard let self else { return }
                copy(selection, asLaTeX: false)
                finishMarkup(in: view)
            },
            onUltraCopy: { [weak self] in
                guard let self else { return }
                copy(selection, asLaTeX: true)
                finishMarkup(in: view)
            },
            onDismiss: { [weak self] in self?.finishMarkup(in: view) },
            composing: composing
        )
    }

    #if os(macOS)
    /// Command-Shift-C, for when the hand is on the keyboard rather than on
    /// the bar that floats over the selection.
    @objc func ultraCopySelection() {
        guard let selection = pdfView?.currentSelection, selection.string?.isEmpty == false else {
            return
        }
        copy(selection, asLaTeX: true)
    }
    #endif

    /// Copies the passage. Ultracopy reads the mathematics back out of the
    /// page and writes it as LaTeX, so a formula survives the trip into a note
    /// instead of arriving as "p" with its subscript missing.
    func copy(_ selection: PDFSelection, asLaTeX: Bool) {
        let text = asLaTeX
            ? MathReader.latex(from: selection)
            : (selection.string ?? "")
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        onToast(asLaTeX ? "Copied with formulas" : "Copied")
    }

    /// Records a markup so Command-Z takes it back.
    ///
    /// Registered with the window's own undo manager rather than a stack of
    /// our own, so it behaves like undo everywhere else on the Mac and does
    /// not steal Command-Z from a text field that has focus.
    private func registerUndo(_ descriptors: [MarkupDescriptor], name: String, in view: PDFView) {
        MarkupUndo.registerCreation(
            descriptors, name: name, in: session, with: view.window?.undoManager
        )
    }

    private func registerRemovalUndo(
        _ descriptors: [MarkupDescriptor], name: String, in view: PDFView
    ) {
        MarkupUndo.registerRemoval(
            descriptors, name: name, in: session, with: view.window?.undoManager
        )
    }

    /// The controls for a mark that is already on the page.
    private func showMarkEditor(for annotation: PDFAnnotation, in view: PDFView) {
        guard let window = view.window,
              let raw = annotation.value(
                  forAnnotationKey: PDFAnnotationKey(rawValue: "/PTMarkupID")
              ) as? String,
              let id = UUID(uuidString: raw),
              let descriptor = session.markup(withID: id)
        else { return }

        guard let page = annotation.page, annotation.bounds.isFinite else { return }
        let inView = view.convert(annotation.bounds, from: page)
        let onScreen = window.convertToScreen(view.convert(inView, to: nil))
        guard onScreen.isFinite else { return }
        markupPanel.showEditor(
            anchor: onScreen,
            over: window,
            onRecolor: { [weak self] color in
                guard let self else { return }
                session.recolor(id: id, to: color)
                hideMarkupPanel()
            },
            onDelete: { [weak self] in
                guard let self else { return }
                session.removeMarkup(id: id)
                registerRemovalUndo([descriptor], name: "Delete Mark", in: view)
                hideMarkupPanel()
            },
            onDismiss: { [weak self] in self?.hideMarkupPanel() }
        )
    }

    private func finishMarkup(in view: PDFView) {
        hideMarkupPanel()
        view.clearSelection()
        onSelectionChange(nil, .zero)
    }

    #if os(macOS)
    /// Notices a click on a mark already on the page.
    ///
    /// Neither overriding `mouseDown` nor `PDFViewAnnotationHit` sees it: the
    /// click lands on PDFKit's inner document view, and the notification is
    /// only posted for the annotations PDFKit handles itself.
    private func installMarkClickMonitor(in view: PDFView) {
        clickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown]
        ) { [weak self, weak view] event in
            guard let self, let view, let window = view.window, event.clickCount == 1 else {
                return event
            }
            // A click inside the controls is theirs. Treating it as a click on
            // the page closed them before their own button could act, which is
            // why picking a colour stopped making a highlight.
            if markupPanel.owns(event.window) { return event }
            guard event.window === window else { return event }

            if markupPanel.isShowing, !markupPanel.isComposingNote {
                hideMarkupPanel()
            }

            let inView = view.convert(event.locationInWindow, from: nil)
            guard view.bounds.contains(inView) else { return event }
            // This pane is the one being read now.
            link.activated?()
            guard let page = view.page(for: inView, nearest: false) else { return event }

            // A click on something drawn — a shape, a card, a stroke — takes
            // the pencil out by itself and goes straight to selecting it, so
            // what was drawn is never a picture you have to unlock first.
            if configuration.mode != .draw, sketchInput?.superview == nil, hitsDrawing(at: inView, on: page, in: view) {
                configuration.mode = .draw
                // Installed now rather than on the next SwiftUI pass, so
                // this very click lands on the overlay.
                updateCanvasInteraction()
                return event
            }

            // PDFKit's own hit test knows a text markup is a set of
            // quadrilaterals rather than the box that encloses them; the
            // bounding box is the fallback for marks it declines to report.
            let onPage = view.convert(inView, to: page)
            let kinds = ["Highlight", "Underline", "StrikeOut", "Text"]
            let byAPI = page.annotation(at: onPage)
            let byBounds = page.annotations.first {
                kinds.contains($0.type ?? "") && $0.bounds.insetBy(dx: -4, dy: -4).contains(onPage)
            }
            guard let hit = byAPI.flatMap({ a in
                ["Highlight", "Underline", "StrikeOut", "Text"].contains(a.type ?? "") ? a : nil
            }) ?? byBounds else { return event }

            view.clearSelection()
            showMarkEditor(for: hit, in: view)
            if let id = Self.markID(of: hit) { link.revealedMarkID = id }
            return nil
        }
    }

    /// Whether a point on a page is on something the pencil drew: a sketch
    /// element or a pen stroke.
    private func hitsDrawing(at inView: CGPoint, on page: PDFPage, in view: PDFView) -> Bool {
        let index = session.document.index(for: page)
        guard index != NSNotFound else { return false }
        let onPage = view.convert(inView, to: page)
        let tolerance = 6 / max(view.scaleFactor, 0.01)
        if session.sketch(forPage: index).contains(where: { $0.hits(onPage, tolerance: tolerance) }) { return true }
        let strokes = session.drawing(forPage: index).strokes
        guard !strokes.isEmpty else { return false }
        let geometry = PageGeometry(page: page)
        let canvas = geometry.canvasPoint(fromPDF: onPage)
        let reach = tolerance + 2
        return strokes.contains { stroke in
            guard stroke.renderBounds.insetBy(dx: -reach, dy: -reach).contains(canvas) else { return false }
            return stroke.path.interpolatedPoints(by: .distance(2)).contains { sample in
                let location = sample.location.applying(stroke.transform)
                return hypot(location.x - canvas.x, location.y - canvas.y) <= reach + sample.size.width / 2
            }
        }
    }

    /// Marking the selection straight from the keyboard, without going to the
    /// bar for it. The colour is whichever the bar would have offered first.
    private func installMarkupShortcuts(for view: MarkupCapablePDFView) {
        let centre = NotificationCenter.default
        for (name, kind) in [
            (Notification.Name.paperTimeHighlight, MarkupDescriptor.Kind.highlight),
            (Notification.Name.paperTimeUnderline, MarkupDescriptor.Kind.underline),
        ] {
            markupObservers.append(centre.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self, weak view] _ in
                MainActor.assumeIsolated {
                    guard let self, let view, let selection = view.currentSelection,
                          !(selection.string ?? "").isEmpty
                    else { return }
                    let made = self.session.addMarkup(
                        for: selection, kind: kind, color: .yellow
                    )
                    self.registerUndo(made, name: self.markupActionName(kind), in: view)
                    view.clearSelection()
                    self.hideMarkupPanel()
                }
            })
        }
    }

    /// Lets a pinch stick.
    ///
    /// `autoScales` means "keep the page fitted to the view", and PDFKit
    /// re-applies that fit when the gesture ends — the page grows under the
    /// fingers and springs back the moment they lift. Zooming by hand is a
    /// statement that the reader no longer wants the fit, so the first pinch
    /// turns it off. Actual Size (Command-0) turns it back on.
    private func installPinchMonitor(in view: PDFView) {
        pinchMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.magnify]
        ) { [weak view] event in
            guard let view, event.window === view.window, view.autoScales else { return event }
            view.autoScales = false
            return event
        }
    }

    /// Turns the page instead of scrolling, while the reader is a book.
    ///
    /// A local event monitor rather than an override on the view: the scroll
    /// lands on PDFKit's own inner document view, which never gives the
    /// `PDFView` subclass a chance at it.
    private func setBookScrolling(_ isOn: Bool, in view: PDFView) {
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }
        if let monitor = arrowMonitor {
            NSEvent.removeMonitor(monitor)
            arrowMonitor = nil
        }
        guard isOn else { return }
        // A book is turned sideways. PDFKit answers ← and → with nothing in a
        // spread — its arrows scroll, and a spread does not scroll — so the
        // two keys that read as "turn the page" did nothing while ↑ and ↓,
        // which read as "scroll", turned it. The event is taken at the window
        // rather than in a `keyDown` override because the key lands in
        // PDFKit's inner document view and never reaches the outer one.
        arrowMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak view] event in
            guard let view, let window = view.window, event.window === window,
                  event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
                  window.firstResponder is NSView,
                  !(window.firstResponder is NSTextView)
            else { return event }
            // ← and →, and the space bar the way every reader has it: space
            // forward, shift-space back.
            let back = event.modifierFlags.contains(.shift)
            switch event.keyCode {
            case 123: if view.canGoToPreviousPage { view.goToPreviousPage(nil) }; return nil
            case 124: if view.canGoToNextPage { view.goToNextPage(nil) }; return nil
            case 49:
                if back { if view.canGoToPreviousPage { view.goToPreviousPage(nil) } }
                else if view.canGoToNextPage { view.goToNextPage(nil) }
                return nil
            default: return event
            }
        }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.scrollWheel]
        ) { [weak self, weak view] event in
            guard let self, let view, let window = view.window,
                  event.window === window,
                  // What is actually under the pointer, from the top of the
                  // window down — not whether the page is somewhere beneath
                  // it. A list floating over the page is over the page, and
                  // a scroll meant for the list was turning pages under it.
                  let hit = window.contentView?.hitTest(event.locationInWindow),
                  hit.isDescendant(of: view)
            else { return event }
            return turnPage(with: event, in: view) ? nil : event
        }
    }

    /// Accumulates a gesture and turns a page once it is decisive.
    private func turnPage(with event: NSEvent, in view: PDFView) -> Bool {
        if event.phase == .began || event.phase == .mayBegin { scrolled = 0 }
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            ? -event.scrollingDeltaX
            : -event.scrollingDeltaY
        scrolled += delta
        let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 60 : 3
        if scrolled > threshold {
            scrolled = 0
            if view.canGoToNextPage { view.goToNextPage(nil) }
        } else if scrolled < -threshold {
            scrolled = 0
            if view.canGoToPreviousPage { view.goToPreviousPage(nil) }
        }
        return true
    }
    #endif

    /// The identifier of a mark under the pointer.
    ///
    /// A mark made in Preview or on an iPad carries no identifier of ours, and
    /// for a long time that was the same as not existing: the reader found it,
    /// then every action on it stopped here. It has one now, derived from
    /// where it sits, so it can be recoloured and removed like any other.
    static func markID(of annotation: PDFAnnotation) -> UUID? {
        TextMarkupWriter.identifier(of: annotation)
    }

    private func markupActionName(_ kind: MarkupDescriptor.Kind) -> String {
        switch kind {
        case .highlight: "Highlight"
        case .underline: "Underline"
        case .strikethrough: "Strikethrough"
        case .note: "Note"
        }
    }

    @objc private func dismissMarkupPanel() {
        guard !markupPanel.isComposingNote else { return }
        hideMarkupPanel()
    }

    private func hideMarkupPanel() {
        markupTask?.cancel()
        markupTask = nil
        markupPanel.hide()
    }
    #endif

    // MARK: - Canvases

    #if canImport(UIKit)
    /// Lets go of every page's canvas and overlay, so the next document is
    /// given fresh ones. PDFKit asks for an overlay again as each page of the
    /// new document is laid out.
    private func discardPageViews() {
        for overlay in overlays.values { overlay.removeFromSuperview() }
        overlays.removeAll()
        canvases.removeAll()
        strokeCounts.removeAll()
        lastCanvas = nil
    }
    #endif

    private func updateCanvasInteraction() {
        #if os(macOS)
        guard let view = pdfView else { return }
        if configuration.mode == .draw {
            hideMarkupPanel()
            view.clearSelection()
            onSelectionChange(nil, .zero)
            let input = sketchInput ?? makeSketchInput(for: view)
            input.session = session
            if input.superview !== view {
                input.frame = view.bounds
                view.addSubview(input)
            }
            input.activate()
        } else if let input = sketchInput {
            input.deactivate()
            input.removeFromSuperview()
            view.window?.makeFirstResponder(view)
        }
        #endif
        #if canImport(UIKit)
        let drawing = configuration.mode == .draw
        for canvas in canvases.values {
            canvas.isUserInteractionEnabled = drawing
            canvas.drawingPolicy = configuration.fingerDrawing ? .anyInput : .pencilOnly
        }
        for overlay in overlays.values { overlay.setInteractive(drawing) }
        // The page view, once it takes touches, can end up first responder
        // with a text-input keyboard behind it; a menu opening then brings
        // the keyboard up. Nothing is being typed while drawing.
        if drawing { pdfView?.window?.endEditing(true) }
        // The page scrolls inside a scroll view whose pan recogniser sees
        // every touch first and, given a pencil stroke, took it as a scroll:
        // the canvas got nothing and the pencil "did not work". While
        // drawing, the pencil belongs to the canvas and a finger scrolls;
        // with finger drawing on, one finger draws and two scroll.
        if let scrollView = pdfView.flatMap(Self.scrollView(in:)) {
            let pan = scrollView.panGestureRecognizer
            if originalTouchTypes == nil { originalTouchTypes = pan.allowedTouchTypes }
            if drawing {
                pan.allowedTouchTypes = [UITouch.TouchType.direct.rawValue as NSNumber, UITouch.TouchType.indirectPointer.rawValue as NSNumber]
                pan.minimumNumberOfTouches = configuration.fingerDrawing ? 2 : 1
            } else {
                pan.allowedTouchTypes = originalTouchTypes ?? pan.allowedTouchTypes
                pan.minimumNumberOfTouches = 1
            }
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
        // The same page, not merely the same page number: an overlay left
        // over from another document would draw that document's ink here.
        if let existing = overlays[index], existing.page === page { return existing }
        // Hide the file's flat marks before PDFKit paints the page: UIKit's
        // PDFView caches the drawn page, so a mark hidden after the first
        // paint kept showing as a square under the rounded one.
        _ = RoundedMarks.takeOver(page)
        hideOwnedInk(on: page, index: index)
        view.annotationsChanged(on: page)

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
        canvas.tool = configuration.currentTool
        canvases[index] = canvas
        // The canvas rides on the same overlay as the rounded marks and the
        // margin mask, so the iPad page looks like the Mac's, plus ink.
        let overlay = PageOverlay(page: page, canvas: canvas) { [weak self] in
            self?.session.sketch(forPage: index) ?? []
        }
        overlay.setInteractive(configuration.mode == .draw)
        // The eraser takes marks off along with strokes: the pencil, run over
        // a highlight, removes it.
        overlay.onErase = { [weak self, weak page] point in
            guard let self, let page, configuration.presets.eraserErasesMarks else { return }
            let hits = page.annotations.filter {
                RoundedMarks.kinds.contains($0.type ?? "") && $0.bounds.insetBy(dx: -3, dy: -3).contains(point)
            }
            for annotation in hits {
                guard let id = TextMarkupWriter.identifier(of: annotation) else { continue }
                session.removeMarkup(id: id)
            }
        }
        overlay.pagePointOfTouch = { [weak self, weak page] touch in
            guard let view = self?.pdfView, let page else { return nil }
            return view.convert(touch.location(in: view), to: page)
        }
        overlay.previousPagePointOfTouch = { [weak self, weak page] touch in
            guard let view = self?.pdfView, let page else { return nil }
            return view.convert(touch.previousLocation(in: view), to: page)
        }
        overlay.onStrokesErased = { [weak self] canvas in
            guard let self else { return }
            strokeCounts[canvas.tag] = canvas.drawing.strokes.count
            session.setDrawing(canvas.drawing, forPage: canvas.tag)
        }
        overlays[index] = overlay
        return overlay
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
        // Keep the canvas so a page scrolled back into view still shows its
        // ink immediately; PDFKit reuses the same instance.
    }
    #else
    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> NSView? {
        // No canvas on the Mac — PencilKit has none here — but the ink is
        // drawn from the same sidecar the iPad draws, so a stroke arrives
        // with the sidecar's few kilobytes and not with the whole PDF. The
        // overlay is also where the highlights get their rounded ends.
        let index = session.document.index(for: page)
        hideOwnedInk(on: page, index: index)
        return PageOverlay(
            page: page,
            drawing: { [weak self] in
                guard let self else { return PKDrawing() }
                let drawing = session.drawing(forPage: index)
                // Strokes being dragged are drawn by the input view meanwhile.
                let hidden = sketchInput?.hiddenStrokeIndices(onPage: index) ?? []
                guard !hidden.isEmpty else { return drawing }
                return PKDrawing(strokes: drawing.strokes.enumerated().filter { !hidden.contains($0.offset) }.map(\.element))
            },
            sketch: { [weak self] in self?.session.sketch(forPage: index) ?? [] },
            hiddenSketch: { [weak self] in self?.sketchInput?.hiddenElementIDs(onPage: index) ?? [] }
        )
    }

    /// The view that takes the mouse while the pencil is out.
    private func makeSketchInput(for view: PDFView) -> SketchInputView {
        MathBridge.install()
        let input = SketchInputView(pdfView: view, configuration: configuration, session: session)
        input.refreshPage = { [weak self] index in
            guard let self, let page = session.document.page(at: index) else { return }
            SketchOverlayView.refresh(page)
            InkOverlayView.refresh(page)
        }
        // The eraser over a highlight or an underline takes it off, with
        // the marks' own undo.
        input.eraseMark = { [weak self, weak view] page, point in
            guard let self, let view else { return }
            let hits = page.annotations.filter {
                RoundedMarks.kinds.contains($0.type ?? "") && $0.bounds.insetBy(dx: -3, dy: -3).contains(point)
            }
            for annotation in hits {
                guard let id = TextMarkupWriter.identifier(of: annotation),
                      let descriptor = session.markup(withID: id) else { continue }
                session.removeMarkup(id: id)
                registerRemovalUndo([descriptor], name: "Erase Mark", in: view)
            }
        }
        input.onToast = { [weak self] message in self?.onToast(message) }
        sketchInput = input
        return input
    }
    #endif
}

#if canImport(UIKit)
extension ReaderCoordinator: @preconcurrency PKCanvasViewDelegate {
    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        lastCanvas = canvasView
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        lastCanvas = canvasView
        guard !isRewritingCanvas else { return }
        let index = canvasView.tag
        let known = strokeCounts[index] ?? 0
        var strokes = canvasView.drawing.strokes
        if configuration.presets.fitsToText, strokes.count > known,
           let page = session.document.page(at: index) {
            // The strokes just finished, newest last. Those that read as a
            // mark on the text become one and leave the canvas.
            var kept: [PKStroke] = Array(strokes[..<known])
            for stroke in strokes[known...] where !snap(stroke, on: page) {
                kept.append(stroke)
            }
            if kept.count != strokes.count {
                strokes = kept
                isRewritingCanvas = true
                canvasView.drawing = PKDrawing(strokes: kept)
                isRewritingCanvas = false
            }
        }
        strokeCounts[index] = strokes.count
        session.setDrawing(canvasView.drawing, forPage: index)
        if let page = session.document.page(at: index), page.annotations.contains(where: { InkConverter.isOwned($0) && $0.shouldDisplay }) {
            hideOwnedInk(on: page, index: index)
            pdfView?.annotationsChanged(on: page)
        }
    }

    /// The same judgement as on the Mac: see `StrokeSnapper`.
    private func snap(_ stroke: PKStroke, on page: PDFPage) -> Bool {
        StrokeSnapper.snap(stroke, on: page, session: session)
    }

    @objc private func undoInk() { (lastCanvas ?? canvases.values.first)?.undoManager?.undo() }
    @objc private func redoInk() { (lastCanvas ?? canvases.values.first)?.undoManager?.redo() }

    @objc private func markTapped(_ gesture: UITapGestureRecognizer) {
        guard configuration.mode != .draw, let view = pdfView else { return }
        let location = gesture.location(in: view)
        guard let page = view.page(for: location, nearest: false) else { return }
        let pagePoint = view.convert(location, to: page)
        guard let annotation = page.annotations.first(where: {
            RoundedMarks.kinds.contains($0.type ?? "") && $0.bounds.insetBy(dx: -2, dy: -2).contains(pagePoint)
        }), let id = TextMarkupWriter.identifier(of: annotation) else { return }
        tappedMarkID = id
        editMenu?.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: location))
    }
}

extension ReaderCoordinator: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}

extension ReaderCoordinator: @preconcurrency UIEditMenuInteractionDelegate {
    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        guard let id = tappedMarkID, let mark = session.markup(withID: id) else { return nil }
        let colors = MarkupColor.allCases.map { color in
            UIAction(title: color.displayName, state: color == mark.color ? .on : .off) { [weak self] _ in
                self?.session.recolor(id: id, to: color)
            }
        }
        let remove = UIAction(title: String(localized: "Remove"), image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
            self?.session.removeMarkup(id: id)
        }
        return UIMenu(children: [UIMenu(options: .displayInline, children: colors), remove])
    }
}
#endif
