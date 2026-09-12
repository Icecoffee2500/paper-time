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
    private var appliedTint: ReaderConfiguration.PageTint?
    private var appliedMode: ReaderConfiguration.Mode?
    private var appliedFingerDrawing: Bool?
    /// The crop that makes the document a book, while it is one.
    private var bookTrim: BookTrim?
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
        #endif
        restoreReadingPosition(in: view)
        return view
    }

    func update(_ view: PDFView, revision: Int) {
        if view.document !== session.document {
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
        if appliedTint != configuration.tint {
            appliedTint = configuration.tint
            applyTint(to: view)
        }
        if appliedMode != configuration.mode || appliedFingerDrawing != configuration.fingerDrawing {
            appliedMode = configuration.mode
            appliedFingerDrawing = configuration.fingerDrawing
            updateCanvasInteraction()
        }

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
        untrim()
        scrollMonitor = nil
        arrowMonitor = nil
        clickMonitor = nil
        pinchMonitor = nil
        #endif
        #if canImport(UIKit)
        toolPicker.setVisible(false, forFirstResponder: PKCanvasView())
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
        switch configuration.tint {
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
        setGlassCompositing(on: view, configuration.tint == .glass || configuration.tint == .sepia)
        setNightFilter(on: view, configuration.tint == .dim)
        NightMode.isOn = configuration.tint == .dim
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

        guard let page = annotation.page else { return }
        let inView = view.convert(annotation.bounds, from: page)
        let onScreen = window.convertToScreen(view.convert(inView, to: nil))
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
            guard view.bounds.contains(inView),
                  let page = view.page(for: inView, nearest: false)
            else { return event }

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
        if let existing = overlays[index] { return existing }

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
        // The canvas rides on the same overlay as the rounded marks and the
        // margin mask, so the iPad page looks like the Mac's, plus ink.
        let overlay = PageOverlay(page: page, canvas: canvas)
        overlays[index] = overlay
        return overlay
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
        // Keep the canvas so a page scrolled back into view still shows its
        // ink immediately; PDFKit reuses the same instance.
    }
    #else
    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> NSView? {
        // No ink canvas on the Mac — PencilKit has none here, and ink written
        // on iPad is in the PDF as ordinary annotations PDFKit draws itself.
        // The overlay is where the highlights are drawn with rounded ends.
        PageOverlay(page: page)
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
