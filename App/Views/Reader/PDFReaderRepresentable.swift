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
    @Binding var currentPageIndex: Int
    var onSelectionChange: (PDFSelection?) -> Void

    func makeCoordinator() -> ReaderCoordinator {
        ReaderCoordinator(
            session: session,
            configuration: configuration,
            onPageChange: { currentPageIndex = $0 },
            onSelectionChange: onSelectionChange
        )
    }

    #if canImport(UIKit)
    func makeUIView(context: Context) -> PDFView { context.coordinator.makePDFView() }
    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.update(view)
    }
    static func dismantleUIView(_ view: PDFView, coordinator: ReaderCoordinator) {
        coordinator.tearDown()
    }
    #else
    func makeNSView(context: Context) -> PDFView { context.coordinator.makePDFView() }
    func updateNSView(_ view: PDFView, context: Context) {
        context.coordinator.update(view)
    }
    static func dismantleNSView(_ view: PDFView, coordinator: ReaderCoordinator) {
        coordinator.tearDown()
    }
    #endif
}

@MainActor
final class ReaderCoordinator: NSObject {
    private let session: DocumentSession
    private let configuration: ReaderConfiguration
    private let onPageChange: (Int) -> Void
    private let onSelectionChange: (PDFSelection?) -> Void

    private weak var pdfView: PDFView?
    #if canImport(UIKit)
    private var canvases: [Int: PKCanvasView] = [:]
    private let toolPicker = PKToolPicker()
    #endif

    init(
        session: DocumentSession,
        configuration: ReaderConfiguration,
        onPageChange: @escaping (Int) -> Void,
        onSelectionChange: @escaping (PDFSelection?) -> Void
    ) {
        self.session = session
        self.configuration = configuration
        self.onPageChange = onPageChange
        self.onSelectionChange = onSelectionChange
        super.init()
    }

    func makePDFView() -> PDFView {
        #if canImport(UIKit)
        let view = MarkupCapablePDFView()
        view.onMarkup = { [weak self] kind, color in
            guard let self, let selection = view.currentSelection else { return }
            self.session.addMarkup(for: selection, kind: kind, color: color)
        }
        #else
        let view = PDFView()
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

        pdfView = view
        restoreReadingPosition(in: view)
        return view
    }

    func update(_ view: PDFView) {
        if view.document !== session.document { view.document = session.document }
        apply(layout: configuration.layout, to: view)
        applyTint(to: view)
        updateCanvasInteraction()
    }

    func tearDown() {
        NotificationCenter.default.removeObserver(self)
        #if canImport(UIKit)
        toolPicker.setVisible(false, forFirstResponder: PKCanvasView())
        canvases.removeAll()
        #endif
    }

    // MARK: - Layout

    private func apply(layout: ReaderConfiguration.PageLayout, to view: PDFView) {
        switch layout {
        case .continuous:
            view.displayMode = .singlePageContinuous
            view.displayDirection = .vertical
        case .singlePage:
            view.displayMode = .singlePage
            view.displayDirection = .horizontal
        case .twoUp:
            view.displayMode = .twoUpContinuous
            view.displayDirection = .vertical
        }
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

    @objc private func selectionChanged(_ notification: Notification) {
        let selection = pdfView?.currentSelection
        onSelectionChange(selection?.string?.isEmpty == false ? selection : nil)
    }

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
