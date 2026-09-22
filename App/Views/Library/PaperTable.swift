#if os(macOS)
import AppKit
import LibraryStore
import PaperCore
import SwiftUI
import UniformTypeIdentifiers

/// The library list, on a table that does not measure what it is not showing.
///
/// `List` — and `ScrollView` with a `LazyVStack` inside it, which was the cheap
/// hope — lay out every row they are given, whether or not it is on screen.
/// Measured on a Release build against a settled library, a scroll step cost
/// 36ms at 270 papers and 86ms at 600, and it never settles: five sweeps over
/// the same forty positions came back 84.6, 85.8, 86.9, 87.8, 87.4ms. The
/// profile says where it goes — `-[NSTableRowView _uncachedAutomaticRowHeight]`
/// through the constraint engine into `NSHostingView`, which runs that row's
/// whole SwiftUI view graph to find out how tall it is. Per row. Per layout.
///
/// An `NSTableView` we own is told the heights instead. It makes views only for
/// the rows on screen, and its total height is a sum of numbers. Measured the
/// same way: 13.5ms at 270 and 19.5ms at 600, flat across five sweeps.
///
/// The rows are still SwiftUI — the same `PaperRow` the list drew. What changed
/// is who is asked how tall they are, and how often.
struct PaperTable: NSViewRepresentable {
    /// What a row stands for.
    ///
    /// Everything the list used to hold in sections lives here as an entry, so
    /// that one scroll view carries the lot: the papers, the headings over
    /// them, and the rows that speak for the folder rather than for a paper.
    enum Entry: Hashable {
        case paper(UUID)
        /// A heading. Not selectable, and drawn as a group row.
        case heading(String)
        /// A row the list draws itself, told apart by name so its height can be
        /// found again without rebuilding it.
        case note(String)
        case passage(String)
    }

    let entries: [Entry]
    let model: LibraryModel
    let app: AppModel
    let fields: [SubtitleField]
    let onOpenShelf: Bool
    @Binding var selection: Set<UUID>
    /// What the list draws for an entry that is not a paper.
    let note: (Entry) -> AnyView
    /// What a scroll past the top should report — the same pull the list had.
    var onPull: ((CGFloat) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = Table()
        table.headerView = nil
        table.style = .inset
        table.rowSizeStyle = .custom
        table.usesAutomaticRowHeights = false
        table.selectionHighlightStyle = .regular
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: false)
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        let column = NSTableColumn(identifier: .init("paper"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        context.coordinator.table = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.watchScrolling(scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.apply(self)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.stopWatching()
    }

    /// A table that lets the row's own SwiftUI view answer a right-click.
    ///
    /// `NSTableView` puts its own menu up first, and the row's menu — the one
    /// with Open, the reading status, Attach To — lives in the SwiftUI view
    /// inside the cell. Handing the event down means the row keeps the menu it
    /// has always had rather than a second one being written in AppKit.
    final class Table: NSTableView {
        override func menu(for event: NSEvent) -> NSMenu? {
            let point = convert(event.locationInWindow, from: nil)
            let row = row(at: point)
            if row >= 0, !selectedRowIndexes.contains(row) {
                selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            return super.menu(for: event)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private var owner: PaperTable
        weak var table: NSTableView?
        private var observer: NSObjectProtocol?
        /// Heights already worked out, by what the row is made of. A row's
        /// height changes when its own words change, not when the list scrolls.
        private var heights: [Key: CGFloat] = [:]
        private var width: CGFloat = 0
        private var applying = false
        /// The one view heights are measured against — see `measure`.
        private var ruler: NSHostingView<AnyView>?

        /// What decides a row's height: its title (which may wrap to a second
        /// line), whether it has a line under that, and whether it carries
        /// tags. Not the star, not the reading status — those are the same
        /// height whatever they say.
        struct Key: Hashable {
            let entry: Entry
            let title: String
            let hasSubtitle: Bool
            let tags: Int
        }

        init(_ owner: PaperTable) { self.owner = owner }

        func watchScrolling(_ scroll: NSScrollView) {
            observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scroll.contentView,
                queue: .main
            ) { [weak self, weak scroll] _ in
                MainActor.assumeIsolated {
                    guard let self, let scroll else { return }
                    self.owner.onPull?(-scroll.contentView.bounds.origin.y)
                }
            }
        }

        func stopWatching() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }

        func apply(_ owner: PaperTable) {
            let before = self.owner.entries
            self.owner = owner
            guard let table else { return }

            if table.bounds.width != width {
                // Narrower means a title that wrapped once wraps twice. Every
                // height has to be found again, and this is the only time that
                // is true.
                width = table.bounds.width
                heights.removeAll(keepingCapacity: true)
                table.reloadData()
            } else if before != owner.entries {
                table.reloadData()
            } else {
                // The same rows, saying something new — a pin pressed, a star,
                // a reading status. Only what is on screen has a view to tell.
                let shown = table.rows(in: table.visibleRect)
                for row in shown.lowerBound..<shown.upperBound where row < owner.entries.count {
                    if let host = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? RowHost {
                        fill(host, row: row)
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

        // MARK: - What is in the table

        func numberOfRows(in tableView: NSTableView) -> Int { owner.entries.count }

        func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
            guard row < owner.entries.count else { return false }
            if case .heading = owner.entries[row] { return true }
            return false
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            guard row < owner.entries.count else { return false }
            if case .paper = owner.entries[row] { return true }
            return false
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard row < owner.entries.count else { return 24 }
            let key = key(for: owner.entries[row])
            if let known = heights[key] { return known }
            let measured = measure(owner.entries[row], width: tableView.bounds.width)
            heights[key] = measured
            return measured
        }

        private func key(for entry: Entry) -> Key {
            guard case let .paper(id) = entry, let paper = owner.model.paper(id) else {
                return Key(entry: entry, title: "", hasSubtitle: false, tags: 0)
            }
            return Key(
                entry: entry,
                title: paper.meta.displayTitle,
                hasSubtitle: !PaperRow.subtitle(paper, fields: owner.fields).isEmpty,
                tags: paper.meta.tagIDs.count
            )
        }

        /// What the row asks for, asked once.
        ///
        /// The row itself is the ruler — the same SwiftUI view that will be
        /// shown — so the height is right by construction rather than by a
        /// formula that has to be kept in step with the row's layout. It costs
        /// one view-graph pass per distinct row, once, instead of one per row
        /// per layout pass for ever.
        private func measure(_ entry: Entry, width: CGFloat) -> CGFloat {
            // One ruler, held and reused. A library opening for the first time
            // has every row's height to find, and a fresh `NSHostingView` for
            // each of six hundred of them is six hundred view graphs stood up
            // and thrown away — measured as a single 270ms step the first time
            // the list appeared.
            let ruler = self.ruler ?? {
                let made = NSHostingView(rootView: AnyView(EmptyView()))
                self.ruler = made
                return made
            }()
            ruler.rootView = body(for: entry)
            ruler.frame.size.width = max(width, 1)
            ruler.layoutSubtreeIfNeeded()
            return max(ruler.fittingSize.height, 22)
        }

        private func body(for entry: Entry) -> AnyView {
            guard case let .paper(id) = entry, let paper = owner.model.paper(id) else {
                return AnyView(owner.note(entry).padding(.horizontal, 10).environment(owner.app))
            }
            return AnyView(
                PaperRow(
                    paper: paper,
                    tags: paper.meta.tagIDs.compactMap { owner.model.tag(for: $0) },
                    attachmentCount: owner.model.attachmentCount(of: paper.id),
                    isResolving: owner.model.resolving.contains(paper.id),
                    subtitleFields: owner.fields,
                    model: owner.model,
                    onOpenShelf: owner.onOpenShelf,
                    isKeptOpen: owner.model.isPinned(paper.id)
                )
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                // The row picks itself. A row is a SwiftUI view inside a
                // hosting view, and a hosting view answers the click before the
                // table under it ever sees one — which is why right-click
                // worked (the row's own `.contextMenu` took it) and a plain
                // click did nothing at all: there was nobody to take it, and
                // the table never learned a row had been pressed.
                // Three taps, told apart by SwiftUI from the event itself
                // rather than by asking what keys are down at the moment the
                // closure runs. Ambient state is the wrong question: by the
                // time a gesture's closure runs, the event that carried the
                // modifier is over.
                .highPriorityGesture(
                    TapGesture().modifiers(.shift).onEnded { [weak self] in self?.clicked(id, .shift) }
                )
                .highPriorityGesture(
                    TapGesture().modifiers(.command).onEnded { [weak self] in self?.clicked(id, .command) }
                )
                .onTapGesture { [weak self] in self?.clicked(id, []) }
                .environment(owner.app)
            )
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let host = tableView.makeView(withIdentifier: RowHost.name, owner: self) as? RowHost ?? RowHost()
            fill(host, row: row)
            return host
        }

        private func fill(_ host: RowHost, row: Int) {
            guard row < owner.entries.count else { return }
            host.show(body(for: owner.entries[row]))
        }

        /// A row was pressed. Shift takes the run between here and the last
        /// one, command adds or drops this one, and a plain click is just this
        /// one — the three things a Mac list does, done here because this is
        /// where the click arrives.
        private var anchor: UUID?

        func clicked(_ id: UUID, _ modifiers: EventModifiers) {
            Trace.tick("row click")
            var picked = owner.selection
            if modifiers.contains(.shift), let anchor,
               let from = index(of: anchor), let to = index(of: id) {
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
            // …and the keyboard follows the hand. Without this the arrow keys
            // had nothing to move: the table was never made first responder,
            // because the click never reached it.
            if let table, table.window?.firstResponder !== table {
                table.window?.makeFirstResponder(table)
            }
        }

        private func index(of id: UUID) -> Int? {
            owner.entries.firstIndex(of: .paper(id))
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

        // MARK: - Dragging out

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            guard row < owner.entries.count, case let .paper(id) = owner.entries[row],
                  let paper = owner.model.paper(id)
            else { return nil }
            // The same bytes SwiftUI's `Transferable` would have written: the
            // record's JSON under the app's own type, so every drop target in
            // the window — a collection, a reading state, a pane — keeps
            // reading `PaperTransfer` and none of them had to change. The file
            // URL goes alongside for the Finder and for other apps.
            let item = NSPasteboardItem()
            let carried = PaperTransfer(id: id, title: paper.meta.displayTitle)
            if let json = try? JSONEncoder().encode(carried) {
                item.setData(json, forType: .init(UTType.paperTimePaper.identifier))
            }
            item.setString(paper.documentURL.absoluteString, forType: .fileURL)
            item.setString(paper.meta.displayTitle, forType: .string)
            return item
        }
    }

    /// One row's house. The SwiftUI view inside is replaced rather than rebuilt,
    /// so scrolling reuses a handful of them however long the list is.
    final class RowHost: NSTableCellView {
        static let name = NSUserInterfaceItemIdentifier("PaperRowHost")
        private var host: NSHostingView<AnyView>?

        override init(frame: NSRect) {
            super.init(frame: frame)
            identifier = Self.name
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        func show(_ view: AnyView) {
            if let host {
                host.rootView = view
                return
            }
            let made = NSHostingView(rootView: view)
            made.translatesAutoresizingMaskIntoConstraints = false
            addSubview(made)
            NSLayoutConstraint.activate([
                made.leadingAnchor.constraint(equalTo: leadingAnchor),
                made.trailingAnchor.constraint(equalTo: trailingAnchor),
                made.topAnchor.constraint(equalTo: topAnchor),
                made.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            host = made
        }
    }
}
#endif
