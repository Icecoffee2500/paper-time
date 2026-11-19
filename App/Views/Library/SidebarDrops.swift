#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Dropping papers on the sidebar's rows, done in AppKit.
///
/// The rows used SwiftUI's `.dropDestination`, and in the sidebar's `List` it
/// worked once and then never (2026-11-18, the user: «한번 실행했을 때
/// 되더니, 그 다음부터는 아예 안되네»). What the window showed: no view under a
/// row had registered the paper's type — the list itself takes only SwiftUI's
/// own reordering type — so a drag over it found nowhere to land; whatever
/// once registered it did not survive the list being drawn again. So the
/// drop no longer goes through the list at all:
///
/// - each row that takes papers carries a `SidebarDropMark`, a small AppKit
///   view that holds what the row does with them;
/// - one `SidebarDropCatcher` lies over the whole sidebar, registered for
///   the paper's type and invisible to clicks, and finds the mark whose row
///   is under the pointer — lighting it while the drag is over it;
/// - and when a drag from the paper table ends over a row with nobody having
///   taken it, the table hands it to the same marks (`deliver(_:at:)`), so a
///   drop that AppKit routed nowhere still lands.
@MainActor
enum SidebarDrops {
    static let type = NSPasteboard.PasteboardType(UTType.paperTimePaper.identifier)
    /// A note, dragged from the slip-box's list onto an area.
    static let noteType = NSPasteboard.PasteboardType(UTType.paperTimeNote.identifier)

    /// What a sidebar row says it will do with a drop: a copy — the paper
    /// stays where it was — unless the drag allows only something else.
    /// Answering `.copy` to a drag that allowed only `.move` was a drop AppKit
    /// refused before it reached the row.
    static func operation(allowedBy mask: NSDragOperation) -> NSDragOperation {
        for each: NSDragOperation in [.copy, .generic, .move, .link] where mask.contains(each) { return each }
        return []
    }

    /// Every mark in a window now, held weakly.
    fileprivate static var marks: [WeakMark] = []

    /// The mark whose row is under a point in window coordinates.
    static func mark(at point: NSPoint, in window: NSWindow, notes: Bool = false) -> DropMarkView? {
        marks.removeAll { $0.view == nil }
        return marks.lazy.compactMap(\.view).first { mark in
            mark.window === window && mark.isEnabled && (notes ? mark.noteAction != nil : mark.action != nil)
                && mark.rowFrameInWindow.contains(point)
        }
    }

    /// The notes a drag carries, by identifier.
    static func notes(on pasteboard: NSPasteboard) -> [String] {
        (pasteboard.pasteboardItems ?? []).compactMap { item in
            item.data(forType: noteType).flatMap { try? JSONDecoder().decode(NoteTransfer.self, from: $0) }?.id
        }
    }

    /// The papers a drag carries: each one's identifier, and — when the drag
    /// began on one of several chosen rows — the rest of the choice.
    static func papers(on pasteboard: NSPasteboard, model: LibraryModel) -> [UUID] {
        var seen: Set<UUID> = []
        var ids: [UUID] = []
        for item in pasteboard.pasteboardItems ?? [] {
            guard let data = item.data(forType: type),
                  let carried = try? JSONDecoder().decode(PaperTransfer.self, from: data) else { continue }
            for id in model.draggedPapers(startingAt: carried.id) where seen.insert(id).inserted {
                ids.append(id)
            }
        }
        return ids
    }

    /// A drag from the table that ended with nobody taking it: if it ended
    /// over a row that takes papers, that row takes them.
    @discardableResult
    static func deliver(_ pasteboard: NSPasteboard, atScreen point: NSPoint, model: LibraryModel) -> Bool {
        for window in NSApp.windows where window.isVisible || window.frame.contains(point) {
            let inWindow = window.convertPoint(fromScreen: point)
            guard let mark = mark(at: inWindow, in: window) else { continue }
            let ids = papers(on: pasteboard, model: model)
            guard !ids.isEmpty else { return false }
            mark.take(ids)
            return true
        }
        return false
    }
}

fileprivate struct WeakMark {
    weak var view: DropMarkView?
}

/// What a row does with papers dropped on it, as an AppKit view inside the
/// row so the catcher can find it by where it is.
final class DropMarkView: NSView {
    var action: ((UUID) async -> Void)?
    /// What the row does with a note dropped on it — an area files it.
    var noteAction: ((String) async -> Void)?
    var isEnabled = true
    /// Tells the row to draw its ring.
    var lit: ((Bool) -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        MainActor.assumeIsolated {
            if window != nil, !SidebarDrops.marks.contains(where: { $0.view === self }) {
                SidebarDrops.marks.append(WeakMark(view: self))
            }
        }
    }

    /// The whole row, not just the label the mark sits behind: the count at
    /// the far end of the row is part of where a paper lands.
    var rowFrameInWindow: NSRect {
        var view: NSView? = self
        while let here = view {
            if here is NSTableRowView { return here.convert(here.bounds, to: nil) }
            view = here.superview
        }
        return convert(bounds.insetBy(dx: -8, dy: -3), to: nil)
    }

    func take(_ ids: [UUID]) {
        guard let action else { return }
        Task { @MainActor in
            for id in ids { await action(id) }
        }
    }

    func takeNotes(_ ids: [String]) {
        guard let noteAction else { return }
        Task { @MainActor in
            for id in ids { await noteAction(id) }
        }
    }
}

struct SidebarDropMark: NSViewRepresentable {
    /// The size it is given, without asking AppKit. Left to itself SwiftUI
    /// asks an AppKit view for its layout traits on every pass of the
    /// window's layout, and AppKit answers by updating the constraints of
    /// the view's whole subtree — for a table, every row on screen, each
    /// row's SwiftUI body with it. That was most of what a pane opening or
    /// closing cost (2026-11-19, `--papertime-perf`).
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSViewType, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    let isEnabled: Bool
    var action: ((UUID) async -> Void)?
    var noteAction: ((String) async -> Void)?
    @Binding var lit: Bool

    func makeNSView(context: Context) -> DropMarkView { DropMarkView() }

    func updateNSView(_ view: DropMarkView, context: Context) {
        view.action = action
        view.noteAction = noteAction
        view.isEnabled = isEnabled
        let binding = $lit
        view.lit = { binding.wrappedValue = $0 }
    }
}

/// The layer over the sidebar that takes a dragged paper and finds the row
/// it is over. Clicks go straight through it.
struct SidebarDropCatcher: NSViewRepresentable {
    /// The size it is given, without asking AppKit. Left to itself SwiftUI
    /// asks an AppKit view for its layout traits on every pass of the
    /// window's layout, and AppKit answers by updating the constraints of
    /// the view's whole subtree — for a table, every row on screen, each
    /// row's SwiftUI body with it. That was most of what a pane opening or
    /// closing cost (2026-11-19, `--papertime-perf`).
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSViewType, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    let model: LibraryModel

    func makeNSView(context: Context) -> DropCatcherView {
        let view = DropCatcherView()
        view.registerForDraggedTypes([SidebarDrops.type, SidebarDrops.noteType])
        return view
    }

    func updateNSView(_ view: DropCatcherView, context: Context) {
        view.model = model
    }
}

final class DropCatcherView: NSView {
    var model: LibraryModel?
    private weak var litMark: DropMarkView?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func light(_ mark: DropMarkView?) {
        guard mark !== litMark else { return }
        litMark?.lit?(false)
        litMark = mark
        mark?.lit?(true)
    }

    private func track(_ sender: any NSDraggingInfo) -> NSDragOperation {
        MainActor.assumeIsolated {
            guard let window, let carried = sender.draggingPasteboard.availableType(from: [SidebarDrops.type, SidebarDrops.noteType]) else {
                light(nil)
                return []
            }
            let mark = SidebarDrops.mark(at: sender.draggingLocation, in: window, notes: carried == SidebarDrops.noteType)
            light(mark)
            return mark == nil ? [] : SidebarDrops.operation(allowedBy: sender.draggingSourceOperationMask)
        }
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { track(sender) }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { track(sender) }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) { MainActor.assumeIsolated { light(nil) } }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        MainActor.assumeIsolated {
            defer { light(nil) }
            guard let window, let model else { return false }
            if sender.draggingPasteboard.availableType(from: [SidebarDrops.type]) == nil {
                guard let mark = SidebarDrops.mark(at: sender.draggingLocation, in: window, notes: true) else { return false }
                let notes = SidebarDrops.notes(on: sender.draggingPasteboard)
                guard !notes.isEmpty else { return false }
                mark.takeNotes(notes)
                return true
            }
            guard let mark = SidebarDrops.mark(at: sender.draggingLocation, in: window) else { return false }
            let ids = SidebarDrops.papers(on: sender.draggingPasteboard, model: model)
            guard !ids.isEmpty else { return false }
            mark.take(ids)
            return true
        }
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) { MainActor.assumeIsolated { light(nil) } }
}
#endif
