#if os(macOS)
import AppKit
import LibraryStore
import PaperCore
import SwiftUI
import UniformTypeIdentifiers

/// What a row of a board is.
enum BoardEntry: Hashable {
    /// A heading over a run of papers, keyed by what it groups.
    case group(String)
    case paper(UUID)
    /// The row at the foot of a plan that takes addresses.
    case add
}

/// A board's rows, on a table that is told how tall they are — the reason
/// `PaperTable` exists, and the same answer: views only for the rows on
/// screen, heights that are numbers. One SwiftUI view per row, drawn like
/// the demo's grid; the table only scrolls, selects and carries drags.
struct BoardTable: NSViewRepresentable {
    let entries: [BoardEntry]
    /// Bumped when what a row says changes without the rows changing.
    let revision: Int
    /// The board's sideways slide, which a horizontal swipe (or ⇧ and the
    /// wheel) moves while the columns are too wide for the table.
    var slide: BoardSlide?
    var slideLimit: CGFloat = 0
    @Binding var selection: Set<UUID>
    let row: (BoardEntry, Bool) -> AnyView
    /// Whether rows can be dragged into a new order (a plan, by section).
    let reorders: Bool
    /// Papers dropped above the row at the index.
    let drop: ([UUID], Int) -> Bool
    let open: (UUID) -> Void

    static let paperHeight: CGFloat = 36
    static let groupHeight: CGFloat = 36
    static let addHeight: CGFloat = 54

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = Table()
        table.headerView = nil
        table.style = .plain
        table.rowSizeStyle = .custom
        table.usesAutomaticRowHeights = false
        table.selectionHighlightStyle = .none
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.backgroundColor = .clear
        table.gridStyleMask = []
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: false)
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.registerForDraggedTypes([.init(UTType.paperTimePaper.identifier)])
        table.draggingDestinationFeedbackStyle = .gap
        let column = NSTableColumn(identifier: .init("row"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.onOpen = { [weak coordinator = context.coordinator] in coordinator?.openSelected() }
        context.coordinator.table = table

        let scroll = Sliding()
        scroll.coordinator = context.coordinator
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 14, right: 0)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.apply(self)
    }

    /// The table's scroll view, which hands a sideways swipe to the board's
    /// slide instead of ignoring it: the table itself only scrolls up and
    /// down, and the columns slide in SwiftUI, under a pinned title.
    final class Sliding: NSScrollView {
        weak var coordinator: Coordinator?

        override func scrollWheel(with event: NSEvent) {
            guard let coordinator, let slide = coordinator.slide, coordinator.slideLimit > 0 else {
                return super.scrollWheel(with: event)
            }
            var dx = event.scrollingDeltaX
            let dy = event.scrollingDeltaY
            // A mouse's wheel with ⇧ held, where the system has not turned it
            // sideways already.
            if dx == 0, event.modifierFlags.contains(.shift) { dx = dy }
            guard dx != 0, abs(dx) >= abs(dy) || event.modifierFlags.contains(.shift) else {
                return super.scrollWheel(with: event)
            }
            let step = event.hasPreciseScrollingDeltas ? dx : dx * 8
            slide.x = min(max(min(slide.x, coordinator.slideLimit) - step, 0), coordinator.slideLimit)
        }
    }

    final class Table: NSTableView {
        var onOpen: (() -> Void)?

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 36 || event.keyCode == 76 {
                onOpen?()
                return
            }
            super.keyDown(with: event)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private var owner: BoardTable
        weak var table: Table?
        private var applying = false
        private var anchor: UUID?

        init(_ owner: BoardTable) { self.owner = owner }

        var slide: BoardSlide? { owner.slide }
        var slideLimit: CGFloat { owner.slideLimit }

        func apply(_ owner: BoardTable) {
            let before = self.owner
            self.owner = owner
            guard let table else { return }
            if before.entries != owner.entries {
                table.reloadData()
            } else {
                let shown = table.rows(in: table.visibleRect)
                for row in shown.lowerBound..<shown.upperBound where row < owner.entries.count {
                    if let host = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? PaperTable.RowHost {
                        host.show(body(for: row))
                    }
                }
            }
            applySelection()
        }

        private func applySelection() {
            guard let table else { return }
            var wanted = IndexSet()
            for (index, entry) in owner.entries.enumerated() {
                if case let .paper(id) = entry, owner.selection.contains(id) { wanted.insert(index) }
            }
            guard wanted != table.selectedRowIndexes else { return }
            applying = true
            table.selectRowIndexes(wanted, byExtendingSelection: false)
            applying = false
        }

        func numberOfRows(in tableView: NSTableView) -> Int { owner.entries.count }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            guard row < owner.entries.count, case .paper = owner.entries[row] else { return false }
            return true
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard row < owner.entries.count else { return BoardTable.paperHeight }
            switch owner.entries[row] {
            case .paper: return BoardTable.paperHeight
            case .group: return BoardTable.groupHeight
            case .add: return BoardTable.addHeight
            }
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let host = tableView.makeView(withIdentifier: PaperTable.RowHost.name, owner: self) as? PaperTable.RowHost
                ?? PaperTable.RowHost()
            host.show(body(for: row))
            return host
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            Plain()
        }

        private func body(for row: Int) -> AnyView {
            guard row < owner.entries.count else { return AnyView(EmptyView()) }
            let entry = owner.entries[row]
            guard case let .paper(id) = entry else { return owner.row(entry, false) }
            return AnyView(
                owner.row(entry, owner.selection.contains(id))
                    // The row picks itself: a SwiftUI row inside a hosting
                    // view takes the click before the table sees it, the way
                    // `PaperTable` found out.
                    .highPriorityGesture(TapGesture().modifiers(.shift).onEnded { [weak self] in self?.clicked(id, .shift) })
                    .highPriorityGesture(TapGesture().modifiers(.command).onEnded { [weak self] in self?.clicked(id, .command) })
                    .onTapGesture { [weak self] in self?.clicked(id, []) }
                    .simultaneousGesture(TapGesture(count: 2).onEnded { [weak self] in self?.owner.open(id) })
            )
        }

        func clicked(_ id: UUID, _ modifiers: EventModifiers) {
            var picked = owner.selection
            if modifiers.contains(.shift), let anchor,
               let from = owner.entries.firstIndex(of: .paper(anchor)), let to = owner.entries.firstIndex(of: .paper(id)) {
                for step in min(from, to)...max(from, to) {
                    if case let .paper(other) = owner.entries[step] { picked.insert(other) }
                }
            } else if modifiers.contains(.command) {
                if picked.contains(id) { picked.remove(id) } else { picked.insert(id) }
                anchor = id
            } else {
                picked = [id]
                anchor = id
            }
            owner.selection = picked
            if let table, table.window?.firstResponder !== table {
                table.window?.makeFirstResponder(table)
            }
        }

        func openSelected() {
            guard let table else { return }
            for row in table.selectedRowIndexes where row < owner.entries.count {
                if case let .paper(id) = owner.entries[row] {
                    owner.open(id)
                    return
                }
            }
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !applying, let table else { return }
            var picked: Set<UUID> = []
            for row in table.selectedRowIndexes where row < owner.entries.count {
                if case let .paper(id) = owner.entries[row] { picked.insert(id) }
            }
            guard picked != owner.selection else { return }
            owner.selection = picked
        }

        // MARK: Dragging

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            guard row < owner.entries.count, case let .paper(id) = owner.entries[row] else { return nil }
            let item = NSPasteboardItem()
            if let json = try? JSONEncoder().encode(PaperTransfer(id: id, title: "")) {
                item.setData(json, forType: .init(UTType.paperTimePaper.identifier))
            }
            return item
        }

        func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo,
                       proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
            guard owner.reorders else { return [] }
            if operation == .on { tableView.setDropRow(row, dropOperation: .above) }
            return info.draggingSource as? NSTableView === tableView ? .move : .copy
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo,
                       row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            let type = NSPasteboard.PasteboardType(UTType.paperTimePaper.identifier)
            let ids = (info.draggingPasteboard.pasteboardItems ?? []).compactMap { item -> UUID? in
                guard let data = item.data(forType: type) else { return nil }
                return (try? JSONDecoder().decode(PaperTransfer.self, from: data))?.id
            }
            guard !ids.isEmpty else { return false }
            return owner.drop(ids, row)
        }
    }

    /// A row view that draws nothing of its own: the SwiftUI row draws its
    /// selection, the soft wash the demo has rather than the system's blue.
    final class Plain: NSTableRowView {
        override func drawSelection(in dirtyRect: NSRect) {}
        override func drawBackground(in dirtyRect: NSRect) {}
        override var isEmphasized: Bool { get { false } set {} }
    }
}
#endif
