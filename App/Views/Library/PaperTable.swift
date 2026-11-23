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
    /// The size it is given, without asking AppKit. Left to itself SwiftUI
    /// asks an AppKit view for its layout traits on every pass of the
    /// window's layout, and AppKit answers by updating the constraints of
    /// the view's whole subtree — for a table, every row on screen, each
    /// row's SwiftUI body with it. That was most of what a pane opening or
    /// closing cost (2026-11-19, `--papertime-perf`).
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSViewType, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

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
        /// A passage found by what it means rather than by its words.
        case meaning(String)
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
    /// The paper the list was last asked to go to (`LibraryModel.reveal`).
    var reveal: LibraryModel.RevealRequest? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> TableEnclosure {
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
        return TableEnclosure(scroll)
    }

    func updateNSView(_ enclosure: TableEnclosure, context: Context) {
        context.coordinator.apply(self)
    }

    static func dismantleNSView(_ enclosure: TableEnclosure, coordinator: Coordinator) {
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
            applyReveal()
        }

        private var revealed = 0

        /// Goes to the row asked for, once per request (see `BoardTable`).
        private func applyReveal() {
            guard let table, let reveal = owner.reveal, reveal.serial != revealed,
                  Date.now.timeIntervalSince(reveal.at) < 2,
                  let row = owner.entries.firstIndex(of: .paper(reveal.paper)) else { return }
            revealed = reveal.serial
            DispatchQueue.main.async { [weak table] in table?.centre(row: row) }
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
                // Pinned to the leading edge. A SwiftUI view narrower than
                // its hosting view sits in the middle of it, so a passage
                // whose sentence and title were both short was the one row
                // that started a hundred points in from the rest — every
                // other passage was wide enough to fill the column. The
                // headings are the exception on purpose: a group row is
                // drawn centred.
                if case .heading = entry {
                    return AnyView(owner.note(entry).padding(.horizontal, 10).environment(owner.app))
                }
                return AnyView(
                    owner.note(entry)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .environment(owner.app)
                )
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
        private var host: RowDragHost?

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
            let made = RowDragHost(rootView: view)
            // The row is the size the table gives it, and says nothing back.
            // Left to its defaults a hosting view works out its smallest,
            // largest and natural sizes each time its content changes and
            // posts them as constraints — a second pass over the row's whole
            // layout for every row that scrolls into view, and a change in
            // constraints that sent the window's own SwiftUI (the board, its
            // header, the sidebar) through layout again on every step of a
            // scroll (2026-11-23: 95 ms a step on a shelf of 505).
            made.sizingOptions = []
            made.safeAreaRegions = []
            made.frame = bounds
            made.autoresizingMask = [.width, .height]
            addSubview(made)
            host = made
        }
    }
}

/// What a table of ours stands in, between it and SwiftUI: the place where
/// the table's housekeeping stops.
///
/// A table takes row views out and puts them back as it scrolls, and every
/// one of those tells AppKit «constraints under here may need updating».
/// AppKit passes that up the view tree, container by container, until it
/// reaches the view SwiftUI keeps an AppKit view in — which reads it as «the
/// view's size may have changed» and invalidates the layout it sits in: the
/// window's whole SwiftUI, laid out again for every step of a scroll. On a
/// shelf of 505 documents that was 50–95 ms a step where the table's own work
/// is a fraction of it (2026-11-23; `--papertime-scroll-test` names who
/// told the root it needs layout).
///
/// The table's size is whatever it is given (`sizeThatFits` says so), so
/// nothing above has anything to learn from the message. It is stopped here
/// and answered here: the enclosure asks for its own layout, and in it has
/// the table's subtree update whatever constraints it holds.
///
/// The message is AppKit's own, not in its headers. Should it be renamed,
/// this never runs and scrolling costs what it did before — nothing breaks.
final class TableEnclosure: NSView {
    let scroll: NSScrollView
    private var owesConstraints = false

    init(_ scroll: NSScrollView) {
        self.scroll = scroll
        super.init(frame: .zero)
        scroll.frame = bounds
        scroll.autoresizingMask = [.width, .height]
        addSubview(scroll)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc(_informContainerThatSubviewsNeedUpdateConstraints)
    func subviewsNeedUpdateConstraints() {
        guard !owesConstraints else { return }
        owesConstraints = true
        needsLayout = true
    }

    override func layout() {
        if owesConstraints {
            owesConstraints = false
            scroll.updateConstraintsForSubtreeIfNeeded()
        }
        super.layout()
    }
}

/// The row's SwiftUI, which also starts the drag of its rows.
///
/// A table starts dragging rows from its own `mouseDown` — and a row made of
/// SwiftUI never lets the press down to the table: the hosting view takes it
/// for the row's taps (`PaperTable` found the same for clicks). So no row of
/// the list could be dragged at all (2026-11-18, «드래그 앤 드랍이 전혀 안되는데»).
/// The row's host watches the press move instead and, past a few points,
/// starts the drag the table would have: the rows chosen (or only the one
/// pressed, when it is not among them), written by the table's own data
/// source, so every drop target reads the same `PaperTransfer`.
final class RowDragHost: NSHostingView<AnyView> {
    private var pressedAt: NSPoint?
    private var source: RowDragSource?

    /// A row asks for its own layout and nobody else's.
    ///
    /// A hosting view that moves — and every row moves on every step of a
    /// scroll — re-examines its safe area, asks for an update, and marks
    /// its constraints as needing one. AppKit carries that mark up the view
    /// tree to the view SwiftUI keeps the table in, and SwiftUI takes it as
    /// «the table's size may have changed»: the window's whole layout — the
    /// board, its header, the sidebar, every pane — ran again for each step,
    /// which was half of what a scroll cost and all of why it grew with the
    /// window rather than with the list (2026-11-23, found by exchanging
    /// `setNeedsLayout:` for two steps and printing who called it on the
    /// root). The row has no constraints to update (`sizingOptions` is
    /// empty, its frame is the cell's), so the mark is kept here and the
    /// update it stood for is done by the row's own layout.
    override var needsUpdateConstraints: Bool {
        get { super.needsUpdateConstraints }
        set {
            if newValue { needsLayout = true } else { super.needsUpdateConstraints = false }
        }
    }

    override func mouseDown(with event: NSEvent) {
        pressedAt = event.locationInWindow
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if let start = pressedAt, source == nil,
           hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) > 4,
           beginDrag(with: event) {
            return
        }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        pressedAt = nil
        super.mouseUp(with: event)
    }

    private var table: NSTableView? {
        var view = superview
        while let current = view {
            if let table = current as? NSTableView { return table }
            view = current.superview
        }
        return nil
    }

    private func beginDrag(with event: NSEvent) -> Bool {
        guard let table, let data = table.dataSource, let start = pressedAt else { return false }
        let pressed = table.row(at: table.convert(start, from: nil))
        guard pressed >= 0 else { return false }
        let rows = table.selectedRowIndexes.contains(pressed) ? table.selectedRowIndexes : IndexSet(integer: pressed)
        let writers = rows.compactMap { data.tableView?(table, pasteboardWriterForRow: $0) }
        guard !writers.isEmpty else { return false }
        let point = convert(event.locationInWindow, from: nil)
        let items = writers.enumerated().map { index, writer -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: writer)
            let image = RowDragImage.make(title: (writer as? NSPasteboardItem)?.string(forType: .string), count: writers.count)
            let offset = CGFloat(min(index, 3)) * 4
            let origin = NSPoint(x: point.x - 14 + offset, y: point.y - image.size.height / 2 + (isFlipped ? offset : -offset))
            // Only the first carries the picture; the rest stack under it.
            item.setDraggingFrame(NSRect(origin: origin, size: image.size), contents: index == 0 ? image : nil)
            return item
        }
        let source = RowDragSource(table: table) { [weak self] in self?.dragEnded(pressedAt: start) }
        self.source = source
        let session = beginDraggingSession(with: items, event: event, source: source)
        session.draggingFormation = NSDraggingFormation.pile
        session.animatesToStartingPositionsOnCancelOrFail = true
        return true
    }

    /// The press the drag began with never ended, as far as the row's
    /// SwiftUI knows: ended now, so the next click is a click.
    private func dragEnded(pressedAt start: NSPoint) {
        source = nil
        pressedAt = nil
        guard let up = NSEvent.mouseEvent(
            with: .leftMouseUp, location: start, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0
        ) else { return }
        super.mouseUp(with: up)
    }
}

/// Where a row drag reports back: what may be done with it, and how it ended
/// — handed to the table's data source as the table's own drag would be.
final class RowDragSource: NSObject, NSDraggingSource {
    weak var table: NSTableView?
    private let ended: () -> Void

    init(table: NSTableView, ended: @escaping () -> Void) {
        self.table = table
        self.ended = ended
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Inside the app every target says what it does: a shelf copies the
        // paper onto itself, a plan's table moves it. Outside, a copy.
        context == .withinApplication ? [.copy, .move, .generic] : .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        MainActor.assumeIsolated {
            if let table, let data = table.dataSource {
                data.tableView?(table, draggingSession: session, endedAt: screenPoint, operation: operation)
            }
            ended()
        }
    }
}

/// The picture under the pointer while rows are dragged: the paper's title in
/// a small rounded card, or how many papers.
enum RowDragImage {
    static func make(title: String?, count: Int) -> NSImage {
        let text = count > 1 ? L("논문 \(count)편", "\(count) papers") : (title?.isEmpty == false ? title! : L("논문", "Paper"))
        let font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        let measured = (text as NSString).size(withAttributes: attributes)
        let size = NSSize(width: min(320, ceil(measured.width) + 26), height: 28)
        return NSImage(size: size, flipped: false) { rect in
            let card = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
            NSColor.windowBackgroundColor.withAlphaComponent(0.96).setFill()
            card.fill()
            NSColor.controlAccentColor.withAlphaComponent(0.55).setStroke()
            card.lineWidth = 1
            card.stroke()
            let line = NSRect(x: 13, y: (rect.height - measured.height) / 2, width: rect.width - 26, height: measured.height)
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            var drawn = attributes
            drawn[.paragraphStyle] = style
            (text as NSString).draw(in: line, withAttributes: drawn)
            return true
        }
    }
}
#endif
