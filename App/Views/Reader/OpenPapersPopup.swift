#if os(macOS)
import AppKit
import LibraryStore
import PaperCore
import SwiftUI
import UniformTypeIdentifiers

/// The open papers, summoned over the page — ⇧⌘O, the way ⇧⌘L brings the
/// contents. A list of what is open, the one showing marked; a click shows
/// another, ⌘-click opens it in a window of its own, and a row dragged off
/// the window becomes a window where it lands, the way a browser's tab
/// does. Dragged to the page's edge it docks there instead.
struct OpenPapersPopup: View {
    let model: LibraryModel
    let dismiss: () -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow

    private var papers: [LoadedPaper] {
        var ids = model.openPaperIDs
        if let showing = model.selectedPaperID, !ids.contains(showing) { ids.append(showing) }
        return ids.compactMap(model.paper)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L("열린 논문", "Open Papers"))
                Spacer()
                Text(L("끌어서 옆에, 창 밖으로 끌면 새 창", "Drag beside · drag out for a window"))
                    .foregroundStyle(.tertiary)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 6)

            if papers.isEmpty {
                Text(L("열린 논문이 없어요.", "Nothing is open."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(papers) { paper in row(paper) }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)
                }
                .scrollIndicators(.never)
            }
        }
        .frame(width: 420)
        .frame(maxHeight: 460)
        .fixedSize(horizontal: false, vertical: true)
        .liquidGlass(.floating, in: RoundedRectangle(cornerRadius: Corner.panel, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: Corner.panel, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 6)
        .background {
            keys
            ClickOutsideWatcher(onClick: dismiss)
        }
    }

    private func row(_ paper: LoadedPaper) -> some View {
        let showing = model.selectedPaperID == paper.id
        let kept = model.isOpenPaper(paper.id)
        return HStack(alignment: .center, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: showing ? "circle.fill" : "circle")
                    .font(.system(size: 6))
                    .foregroundStyle(showing ? Color.accentColor : Color.secondary.opacity(0.4))
                    .frame(width: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(paper.meta.displayTitle)
                        .font(.callout.weight(showing ? .semibold : .regular))
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        Text([paper.meta.displayAuthors, paper.meta.csl.year.map(String.init) ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if !kept {
                            Text(L("미리보기", "Preview")).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
            // On top of the words, not behind them: a click on a row has to
            // land every time, and the AppKit view that turns a pull into a
            // drag is the surest thing to put it on. The buttons sit beside
            // it, outside its reach.
            .overlay(
                DragOutHandle(
                    transfer: PaperTransfer(id: paper.id, title: paper.meta.displayTitle),
                    onClick: { command in
                        if command {
                            open(paper.id, at: nil)
                        } else {
                            show(paper.id)
                        }
                    },
                    onDragOutside: { point in open(paper.id, at: point) }
                )
            )
            Button {
                open(paper.id, at: nil)
            } label: {
                Image(systemName: "macwindow.badge.plus").font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(L("새 창으로 열기 (⌘클릭, ⌘↩)", "Open in New Window (⌘-click, ⌘↩)"))
            Button {
                close(paper.id)
            } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(L("닫기 (⌫)", "Close (⌫)"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Corner.row, style: .continuous)
                .fill(Color.accentColor.opacity(showing ? 0.1 : 0))
        )
    }

    /// Shows a paper and keeps it: chosen from this list, it is in use.
    private func show(_ id: UUID) {
        model.selectedPaperID = id
        model.keepOpen(id)
    }

    private func close(_ id: UUID) {
        app.undock(id, model: model)
        model.closeOpenPaper(id)
    }

    /// ↑ and ↓ move along the list, showing each paper as they pass — the
    /// keys the list column answers to, so the popup answers to them too.
    private func step(_ offset: Int) {
        let all = papers
        guard !all.isEmpty else { return }
        guard let current = model.selectedPaperID, let index = all.firstIndex(where: { $0.id == current }) else {
            show(all[0].id)
            return
        }
        let next = min(max(index + offset, 0), all.count - 1)
        guard next != index else { return }
        show(all[next].id)
    }

    /// The keys, as buttons nobody sees: the way Escape is taken.
    private var keys: some View {
        Group {
            Button("", action: dismiss).keyboardShortcut(.cancelAction)
            Button("") { step(1) }.keyboardShortcut(.downArrow, modifiers: [])
            Button("") { step(-1) }.keyboardShortcut(.upArrow, modifiers: [])
            Button("") {
                if let id = model.selectedPaperID { show(id) }
                dismiss()
            }
            .keyboardShortcut(.return, modifiers: [])
            Button("") { if let id = model.selectedPaperID { open(id, at: nil) } }
                .keyboardShortcut(.return, modifiers: .command)
            Button("") { if let id = model.selectedPaperID { close(id) } }
                .keyboardShortcut(.delete, modifiers: [])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
    }

    /// A window of its own for the paper, put where the drag ended when
    /// there was one.
    private func open(_ id: UUID, at point: NSPoint?) {
        model.keepOpen(id)
        openWindow(id: "paper", value: id)
        guard let point else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard let window = NSApp.keyWindow, window.identifier?.rawValue.hasPrefix("paper") == true else { return }
            window.setFrameTopLeftPoint(NSPoint(x: point.x - 40, y: point.y + 20))
        }
    }
}

/// A view behind a row that turns a press into a click and a pull into a
/// drag — an AppKit drag session, so it can tell where the drag ended and
/// whether anything took it. Nothing took it and it ended off every window
/// of ours: that is "dragged out", and a new window is made there.
private struct DragOutHandle: NSViewRepresentable {
    let transfer: PaperTransfer
    let onClick: (_ command: Bool) -> Void
    let onDragOutside: (NSPoint) -> Void

    func makeNSView(context: Context) -> Handle {
        let handle = Handle()
        handle.transfer = transfer
        handle.onClick = onClick
        handle.onDragOutside = onDragOutside
        return handle
    }

    func updateNSView(_ view: Handle, context: Context) {
        view.transfer = transfer
        view.onClick = onClick
        view.onDragOutside = onDragOutside
    }

    final class Handle: NSView, NSDraggingSource {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        var transfer: PaperTransfer?
        var onClick: ((Bool) -> Void)?
        var onDragOutside: ((NSPoint) -> Void)?
        private var pressedAt: NSPoint?
        private var dragging = false

        override func mouseDown(with event: NSEvent) {
            pressedAt = event.locationInWindow
            dragging = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard let pressedAt, !dragging, let transfer else { return }
            let moved = hypot(event.locationInWindow.x - pressedAt.x, event.locationInWindow.y - pressedAt.y)
            guard moved > 4 else { return }
            dragging = true
            let item = NSPasteboardItem()
            if let data = try? JSONEncoder().encode(transfer) {
                item.setData(data, forType: NSPasteboard.PasteboardType(UTType.paperTimePaper.identifier))
            }
            item.setString(transfer.title, forType: .string)
            let dragged = NSDraggingItem(pasteboardWriter: item)
            let image = Self.tag(for: transfer.title)
            let at = convert(event.locationInWindow, from: nil)
            dragged.setDraggingFrame(
                NSRect(x: at.x - image.size.width / 2, y: at.y - image.size.height / 2, width: image.size.width, height: image.size.height),
                contents: image
            )
            beginDraggingSession(with: [dragged], event: event, source: self)
        }

        override func mouseUp(with event: NSEvent) {
            defer { pressedAt = nil }
            guard !dragging else { return }
            onClick?(event.modifierFlags.contains(.command))
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            [.move, .copy]
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            dragging = false
            pressedAt = nil
            // Something took it — the page's edge, a shelf — and did its own thing.
            guard operation.isEmpty else { return }
            // Let go over one of our windows and nothing wanted it: nothing.
            let overOurs = NSApp.windows.contains { $0.isVisible && $0.frame.contains(screenPoint) }
            guard !overOurs else { return }
            onDragOutside?(screenPoint)
        }

        /// A small card with the title, to carry under the pointer.
        private static func tag(for title: String) -> NSImage {
            let text = NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.labelColor,
            ])
            let width = min(text.size().width + 24, 320)
            let size = NSSize(width: width, height: 30)
            return NSImage(size: size, flipped: false) { rect in
                NSColor.windowBackgroundColor.withAlphaComponent(0.95).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
                text.draw(in: NSRect(x: 12, y: 7, width: rect.width - 24, height: 16))
                return true
            }
        }
    }
}

/// Notices a click outside the view this sits behind, and says so.
private struct ClickOutsideWatcher: NSViewRepresentable {
    let onClick: () -> Void

    func makeNSView(context: Context) -> Watcher {
        let watcher = Watcher()
        watcher.onClick = onClick
        return watcher
    }

    func updateNSView(_ view: Watcher, context: Context) { view.onClick = onClick }

    final class Watcher: NSView {
        var onClick: (() -> Void)?
        nonisolated(unsafe) private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                let inView = self.convert(event.locationInWindow, from: nil)
                if !self.bounds.contains(inView) { self.onClick?() }
                return event
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

/// One paper in a window of its own.
struct PaperWindow: View {
    let paperID: UUID?
    @Environment(AppModel.self) private var app
    @Environment(\.controlActiveState) private var activeState
    @State private var configuration = ReaderConfiguration()
    @State private var link = ReaderLink()

    var body: some View {
        Group {
            if let paperID, let library = app.library, let paper = library.paper(paperID) {
                VStack(spacing: 0) {
                    HStack {
                        Text(paper.meta.displayTitle)
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                        Button {
                            configuration.mode = configuration.mode == .draw ? .read : .draw
                        } label: {
                            Label(L("그리기", "Draw"), systemImage: configuration.mode == .draw ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless)
                        .tint(configuration.mode == .draw ? Color.accentColor : .primary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 6)
                    ReaderScreen(library: library, paper: paper, configuration: configuration, link: link)
                }
                .navigationTitle(paper.meta.displayTitle)
                // The menu's key, only when this is the window in front.
                .onReceive(NotificationCenter.default.publisher(for: .paperTimeToggleDraw)) { _ in
                    guard activeState == .key else { return }
                    configuration.mode = configuration.mode == .draw ? .read : .draw
                }
            } else {
                ContentUnavailableView(L("이 논문은 라이브러리에 없어요", "This paper is not in the library"), systemImage: "doc.questionmark")
            }
        }
        .frame(minWidth: 480, minHeight: 400)
        .translucentWindow()
        .windowBackdrop()
    }
}
#endif
