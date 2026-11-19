#if os(macOS)
import AppKit
import LibraryStore
import PaperCore
import UniformTypeIdentifiers

/// A paper dropped on the sidebar without a hand on the machine.
///
/// A drag cannot be scripted — the session runs on the real pointer, and
/// events sent at the system go to whatever is in front. But a drop is only
/// the destination being told about one: so this makes the drag's
/// information itself (`ProbeDrag`, a real pasteboard carrying what the
/// table writes) and hands it to the view AppKit would have — the deepest
/// one under the row that registered for the type — through the same
/// `draggingEntered` → `performDragOperation` → `concludeDragOperation` a
/// real drop goes through.
///
/// - `--papertime-drop-probe-rows=1` lists the sidebar's rows: index,
///   frame, the view that would take a drop.
/// - `--papertime-drop-probe=3,3,9` drops the first paper of the shelf on
///   rows 3, 3 and 9, one after another, and says after each what the paper
///   now is — kind, status, star, plans.
/// - `--papertime-drop-probe-mask=move|copy|both` — what the source allows
///   (the table allows `move` inside the app).
enum DropProbe {
    @MainActor
    static func run(model: LibraryModel) async {
        let listing = Boot.isSet("PAPERTIME_DROP_PROBE_ROWS")
        let steps = (Boot.setting("PAPERTIME_DROP_PROBE") ?? "").split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard listing || !steps.isEmpty, Boot.setting("PAPERTIME_LIBRARY") != nil else { return }
        try? await Task.sleep(for: .seconds(2))
        guard let window = NSApp.windows.first(where: { $0.contentView != nil && $0.isVisible || $0.contentView?.subviews.isEmpty == false }),
              let content = window.contentView else { return say("drop probe: no window") }
        let tables = allViews(in: content).compactMap { $0 as? NSTableView }
            .sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
        guard let sidebar = tables.first else { return say("drop probe: no sidebar table") }
        let source = tables.dropFirst().first
        say("drop probe: sidebar \(type(of: sidebar)) rows \(sidebar.numberOfRows), source \(source.map { "\(type(of: $0))" } ?? "none")")
        if listing {
            for row in 0..<sidebar.numberOfRows {
                let rect = sidebar.rect(ofRow: row)
                let center = sidebar.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
                let target = destination(at: center, in: window)
                say("drop probe: row \(row) y \(Int(center.y)) h \(Int(rect.height)) → \(target.map { "\(type(of: $0))" } ?? "nothing") (AppKit: \(appKitDestination(at: center, in: window).map { "\(type(of: $0))" } ?? "none"))")
                if row == 5, let frame = content.superview, var view = frame.hitTest(frame.convert(center, from: nil)) {
                    // The chain under one row, and what each registered.
                    while true {
                        say("drop probe:   \(type(of: view)) \(view.registeredDraggedTypes.map(\.rawValue).prefix(6))")
                        guard let up = view.superview else { break }
                        view = up
                    }
                }
            }
        }
        guard let paper = model.visiblePapers.first else { return say("drop probe: no paper on the shelf") }
        let mask: NSDragOperation = switch Boot.setting("PAPERTIME_DROP_PROBE_MASK") {
        case "copy": .copy
        case "both": [.copy, .move]
        default: .move
        }
        say("drop probe: carrying “\(paper.meta.displayTitle.prefix(40))” mask \(mask.rawValue)")
        report(model, paper.id, "before")
        var sequence = 900
        for row in steps {
            guard row < sidebar.numberOfRows else { say("drop probe: no row \(row)"); continue }
            sequence += 1
            let rect = sidebar.rect(ofRow: row)
            let point = sidebar.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
            let pasteboard = NSPasteboard(name: .init("com.imtaeheon.PaperTime.dropProbe"))
            pasteboard.clearContents()
            let item = NSPasteboardItem()
            if let json = try? JSONEncoder().encode(PaperTransfer(id: paper.id, title: "")) {
                item.setData(json, forType: .init(UTType.paperTimePaper.identifier))
            }
            pasteboard.writeObjects([item])
            if Boot.setting("PAPERTIME_DROP_PROBE_PATH") == "fallback" {
                // The table's own way: the drag ended over the row unaccepted.
                let taken = SidebarDrops.deliver(pasteboard, atScreen: window.convertPoint(toScreen: point), model: model)
                say("drop probe: row \(row) fallback taken \(taken)")
            } else {
                guard let target = allViews(in: content).first(where: { $0 is DropCatcherView }) else {
                    say("drop probe: no catcher over the sidebar")
                    break
                }
                let drag = ProbeDrag(window: window, location: point, pasteboard: pasteboard, mask: mask, source: source, sequence: sequence)
                let entered = target.draggingEntered(drag)
                let updated = target.draggingUpdated(drag)
                let performed = target.performDragOperation(drag)
                target.concludeDragOperation(drag)
                say("drop probe: row \(row) catcher entered \(entered.rawValue) updated \(updated.rawValue) performed \(performed)")
            }
            try? await Task.sleep(for: .seconds(1.2))
            report(model, paper.id, "after row \(row)")
        }
        try? await Task.sleep(for: .seconds(0.5))
        NSApp.terminate(nil)
    }

    /// `--papertime-route=shelf|pane|paper`: which view AppKit hands a drag
    /// of that type to, on a grid over the window — the panes' drop zones
    /// are SwiftUI's, and only AppKit's own answer says a real drag reaches
    /// them.
    @MainActor
    static func routeMap() async {
        guard let which = Boot.setting("PAPERTIME_ROUTE"), Boot.setting("PAPERTIME_LIBRARY") != nil else { return }
        try? await Task.sleep(for: .seconds(3))
        guard let window = NSApp.windows.first(where: { $0.contentView?.subviews.isEmpty == false }),
              let content = window.contentView else { return say("route: no window") }
        let carried: UTType = switch which { case "shelf": .paperTimeShelf; case "pane": .paperTimePane; default: .paperTimePaper }
        let bounds = content.bounds
        for row in 0..<3 {
            var line: [String] = []
            for column in 0..<8 {
                let point = content.convert(NSPoint(x: bounds.width * (CGFloat(column) + 0.5) / 8,
                                                    y: bounds.height * (CGFloat(row) + 0.5) / 3), to: nil)
                let found = appKitDestination(at: point, in: window, type: carried)
                line.append(found.map { String("\(type(of: $0))".prefix(26)) } ?? "—")
            }
            say("route \(which) row \(row): " + line.joined(separator: " | "))
        }
        NSApp.terminate(nil)
    }

    @MainActor
    private static func report(_ model: LibraryModel, _ id: UUID, _ when: String) {
        guard let paper = model.paper(id) else { return say("drop probe: \(when): gone") }
        let plans = model.plans(containing: id).map(\.name)
        say("drop probe: \(when): kind \(paper.meta.shelfKind.rawValue) status \(paper.state.readingStatus.rawValue) star \(paper.state.isFavorite) plans \(plans)")
    }

    /// The view AppKit would hand the drop to — asked of AppKit itself:
    /// `-[NSWindow _findDragTargetFrom:]` reads only the drag's location and
    /// pasteboard, then walks `_hitTest:dragTypes:` from the frame view —
    /// topmost subview first, the deepest visible view under the point that
    /// registered one of the pasteboard's types. (Not `hitTest:`: a view that
    /// answers `hitTest:` with nil still takes drops.)
    @MainActor
    static func appKitDestination(at point: NSPoint, in window: NSWindow, type: UTType = .paperTimePaper) -> NSView? {
        let selector = NSSelectorFromString("_findDragTargetFrom:")
        guard window.responds(to: selector) else { return nil }
        let pasteboard = NSPasteboard(name: .init("com.imtaeheon.PaperTime.dropProbe.route"))
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        if type == .paperTimePaper, let json = try? JSONEncoder().encode(PaperTransfer(id: UUID(), title: "")) {
            item.setData(json, forType: .init(UTType.paperTimePaper.identifier))
        } else {
            item.setData(Data("{}".utf8), forType: .init(type.identifier))
        }
        pasteboard.writeObjects([item])
        let drag = ProbeDrag(window: window, location: point, pasteboard: pasteboard, mask: .move, source: nil, sequence: 1)
        return window.perform(selector, with: drag)?.takeUnretainedValue() as? NSView
    }

    /// The view AppKit would hand the drop to: the deepest one under the
    /// point that registered for the type.
    @MainActor
    private static func destination(at point: NSPoint, in window: NSWindow) -> NSView? {
        if let found = appKitDestination(at: point, in: window) { return found }
        guard let frame = window.contentView?.superview,
              var view = frame.hitTest(frame.convert(point, from: nil)) else { return nil }
        let type = NSPasteboard.PasteboardType(UTType.paperTimePaper.identifier)
        while true {
            if view.registeredDraggedTypes.contains(type) { return view }
            guard let up = view.superview else { return nil }
            view = up
        }
    }

    @MainActor
    static func allViews(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { allViews(in: $0) }
    }

    static func say(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}

/// What a drag tells its destination, made by hand.
final class ProbeDrag: NSObject, NSDraggingInfo {
    private let window: NSWindow
    private let location: NSPoint
    private let pasteboard: NSPasteboard
    private let mask: NSDragOperation
    private let source: AnyObject?
    private let sequence: Int

    init(window: NSWindow, location: NSPoint, pasteboard: NSPasteboard, mask: NSDragOperation, source: AnyObject?, sequence: Int) {
        self.window = window
        self.location = location
        self.pasteboard = pasteboard
        self.mask = mask
        self.source = source
        self.sequence = sequence
    }

    var draggingDestinationWindow: NSWindow? { window }
    var draggingSourceOperationMask: NSDragOperation { mask }
    var draggingLocation: NSPoint { location }
    var draggedImageLocation: NSPoint { location }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { source }
    var draggingSequenceNumber: Int { sequence }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {
        var stop: ObjCBool = false
        for (index, item) in (pasteboard.pasteboardItems ?? []).enumerated() {
            block(NSDraggingItem(pasteboardWriter: item), index, &stop)
            if stop.boolValue { break }
        }
    }
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
    /// What the destination last answered — AppKit's own drag info keeps it,
    /// and SwiftUI's hosting view asks for it.
    var lastOperation: NSDragOperation = []
    @objc var _lastDragDestinationOperation: NSDragOperation { lastOperation }
}

/// A paper chosen in Search Everything, and whether the list went to it
/// (`LibraryModel.reveal`).
///
/// `--papertime-reveal=<words in a title>` waits for the library to settle,
/// then asks for the paper twice: once on the shelf it is on (the list must
/// scroll to its row), once from the books shelf it is not on (the shelf
/// must change, then scroll). After each it prints the shelf, the selection,
/// the rows in view and where the paper's row is.
enum RevealProbe {
    @MainActor
    static func run(model: LibraryModel) async {
        guard let words = Boot.setting("PAPERTIME_REVEAL"), Boot.setting("PAPERTIME_LIBRARY") != nil else { return }
        // A library being read in: wait until the count holds for three seconds.
        var last = -1, still = 0
        for _ in 0..<90 where still < 3 {
            try? await Task.sleep(for: .seconds(1))
            if model.papers.count == last { still += 1 } else { still = 0; last = model.papers.count }
        }
        // `@40`: the paper at that place in the list as it stands.
        let placed = words.hasPrefix("@") ? Int(words.dropFirst()).flatMap { model.visiblePapers.indices.contains($0) ? model.visiblePapers[$0] : nil } : nil
        let folded = TextNormalization.foldedTitle(words)
        guard let target = placed ?? model.papers.first(where: {
            $0.meta.parentID == nil && TextNormalization.foldedTitle($0.meta.displayTitle).contains(folded)
        }) ?? model.visiblePapers.last else { return DropProbe.say("reveal: no paper") }
        DropProbe.say("reveal: \(model.papers.count) papers, target «\(target.meta.displayTitle.prefix(50))» \(target.meta.shelfKind)")
        report(model, target.id, "before")
        model.reveal(target.id)
        try? await Task.sleep(for: .seconds(1.5))
        report(model, target.id, "on its shelf")
        model.scope = .books
        try? await Task.sleep(for: .seconds(1))
        report(model, target.id, "books shelf")
        model.reveal(target.id)
        try? await Task.sleep(for: .seconds(1.5))
        report(model, target.id, "from books")
    }

    @MainActor
    private static func report(_ model: LibraryModel, _ id: UUID, _ moment: String) {
        let ids = model.visiblePaperIDs
        let index = ids.firstIndex(of: id)
        var view = "no table"
        if let window = NSApp.windows.first(where: { $0.contentView?.subviews.isEmpty == false }),
           let content = window.contentView {
            let tables = DropProbe.allViews(in: content).compactMap { $0 as? NSTableView }
                .filter { $0 is BoardTable.Table || $0 is PaperTable.Table }
            if let table = tables.first {
                let shown = table.rows(in: table.visibleRect)
                let row = (0..<table.numberOfRows).first { table.selectedRowIndexes.contains($0) }
                view = "rows \(shown.lowerBound)..<\(shown.upperBound) of \(table.numberOfRows), selected row \(row.map(String.init) ?? "none")"
                    + (row.map { shown.contains($0) ? " IN VIEW" : " OUT OF VIEW" } ?? "")
            }
        }
        DropProbe.say("reveal [\(moment)]: scope \(model.scope) kind \(model.shownKind) list index \(index.map(String.init) ?? "absent") of \(ids.count) selected \(model.selectedPaperID == id) — \(view)")
    }
}

/// The app doing what a hand does, step by step, so the main thread's
/// stalls (`Hitches`, `--papertime-trace=1`) can be put on the step that
/// caused them, and `sample` taken on a run that is busy the whole time.
///
/// `--papertime-perf=<rounds>`: shelves switched, papers opened, two side by
/// side, a pane added and closed, the inspector floated and docked, the
/// list scrolled — each step printed as `perf: <step>` before it runs.
@MainActor
enum PerfProbe {
    static func run(app: AppModel, model: LibraryModel) async {
        guard let rounds = Int(Boot.setting("PAPERTIME_PERF") ?? ""), Boot.setting("PAPERTIME_LIBRARY") != nil else { return }
        try? await Task.sleep(for: .seconds(4))
        var totals: [String: Double] = [:]
        func step(_ name: String, wait: Double = 0.7, _ work: () -> Void) async {
            let before = Hitches.busySeconds
            work()
            try? await Task.sleep(for: .seconds(wait))
            let spent = (Hitches.busySeconds - before) * 1000
            let kind = String(name.prefix { $0 != " " && $0 != "(" }) + (name.hasPrefix("scope") || name.hasPrefix("open") ? "" : " " + name)
            totals[kind, default: 0] += spent
            DropProbe.say(String(format: "perf: %@ — main thread %.0f ms", name, spent))
        }
        switch Boot.setting("PAPERTIME_PERF_INSPECTOR") {
        case "hide": app.showsInspector = false
        case "float": app.setInspectorFloats(true)
        default: break
        }
        try? await Task.sleep(for: .seconds(1))
        // `--papertime-perf-only=panes`: the list hidden and shown, over and
        // over, with nothing else — for `sample` to see one thing.
        if Boot.setting("PAPERTIME_PERF_ONLY") == "open" {
            try? await Task.sleep(for: .seconds(2))
            let ids = model.visiblePapers.prefix(12).map(\.id)
            for pass in 0..<rounds {
                for (n, id) in ids.enumerated() { await step("open \(pass).\(n)", wait: 0.9) { model.selectedPaperID = id } }
            }
            for (kind, ms) in totals.sorted(by: { $0.value > $1.value }) { DropProbe.say(String(format: "perf total: %@ %.0f ms", kind, ms)) }
            NSApp.terminate(nil)
            return
        }
        if Boot.setting("PAPERTIME_PERF_ONLY") == "scroll" {
            try? await Task.sleep(for: .seconds(2))
            if let window = NSApp.windows.first(where: { $0.contentView?.subviews.isEmpty == false }),
               let content = window.contentView,
               let scroll = DropProbe.allViews(in: content).compactMap({ $0 as? NSScrollView })
                .first(where: { $0.documentView is BoardTable.Table }) {
                let clip = scroll.contentView
                let bottom = max(0, (scroll.documentView?.frame.height ?? 0) - clip.bounds.height)
                DropProbe.say("perf: table \(Int(scroll.documentView?.frame.height ?? 0)) tall, clip \(Int(clip.bounds.height)), \((scroll.documentView as? NSTableView)?.numberOfRows ?? 0) rows")
                for pass in 0..<(rounds * 6) {
                    await step("scroll pass \(pass)", wait: 0.1) {
                        // 24 pt a frame: a trackpad's steady scroll.
                        var y: Double = pass % 2 == 0 ? 0 : bottom
                        let stepY: Double = pass % 2 == 0 ? 24 : -24
                        while (stepY > 0 && y <= bottom) || (stepY < 0 && y >= 0) {
                            clip.setBoundsOrigin(NSPoint(x: 0, y: y))
                            scroll.reflectScrolledClipView(clip)
                            window.displayIfNeeded()
                            y += stepY
                        }
                    }
                }
            }
            for (kind, ms) in totals.sorted(by: { $0.value > $1.value }) { DropProbe.say(String(format: "perf total: %@ %.0f ms", kind, ms)) }
            NSApp.terminate(nil)
            return
        }
        if Boot.setting("PAPERTIME_PERF_ONLY") == "panes" {
            if let first = model.visiblePapers.first?.id { model.selectedPaperID = first }
            try? await Task.sleep(for: .seconds(2))
            for _ in 0..<(rounds * 20) {
                await step("hide the list", wait: 0.35) { app.togglePaperList() }
                await step("show the list", wait: 0.35) { app.togglePaperList() }
            }
            for (kind, ms) in totals.sorted(by: { $0.value > $1.value }) { DropProbe.say(String(format: "perf total: %@ %.0f ms", kind, ms)) }
            NSApp.terminate(nil)
            return
        }
        let folders = model.diskFolders.sorted().prefix(2).map { model.location.url.appending(path: $0, directoryHint: .isDirectory) }
        for round in 0..<rounds {
            DropProbe.say("perf: round \(round)")
            var shelves: [LibraryModel.Scope] = [.papers, .books, .documents, .unread, .reading]
            shelves += folders.map { LibraryModel.Scope.folder($0) }
            shelves += [.notes, .knowledge(nil), .projects(nil), .papers]
            for shelf in shelves { await step("scope \(shelf)") { model.scope = shelf } }
            let ids = model.visiblePapers.prefix(6).map(\.id)
            for (n, id) in ids.enumerated() { await step("open paper \(n)", wait: 1.0) { model.selectedPaperID = id } }
            if ids.count > 2 {
                await step("side by side", wait: 1.2) { app.dock(ids[1], at: .right, in: model) }
                await step("choose while side by side", wait: 1.0) { model.selectedPaperID = ids[2] }
                await step("close side by side", wait: 0.8) { app.split = nil }
            }
            if let page = app.panes.first(where: { $0.content == .page }) {
                await step("add a pane") { app.drop(.shelf("unread"), on: page.id, zone: .right, model: model) }
                if let added = app.panes.last, added.content != .page, added.content != .list {
                    await step("close the pane") { app.closePane(added.id, title: "perf") }
                }
            }
            await step("float the inspector") { app.setInspectorFloats(true) }
            await step("dock the inspector") { app.setInspectorFloats(false) }
            await step("hide the list") { app.togglePaperList() }
            await step("show the list") { app.togglePaperList() }
            if let window = NSApp.windows.first(where: { $0.contentView?.subviews.isEmpty == false }),
               let content = window.contentView,
               let scroll = DropProbe.allViews(in: content).compactMap({ $0 as? NSScrollView })
                .first(where: { $0.documentView is BoardTable.Table }) {
                await step("scroll the list", wait: 0.3) {
                    let clip = scroll.contentView
                    let bottom = max(0, (scroll.documentView?.frame.height ?? 0) - clip.bounds.height)
                    for i in 0...40 {
                        clip.setBoundsOrigin(NSPoint(x: 0, y: bottom * Double(i) / 40))
                        scroll.reflectScrolledClipView(clip)
                        window.displayIfNeeded()
                    }
                }
            }
        }
        for (kind, ms) in totals.sorted(by: { $0.value > $1.value }) {
            DropProbe.say(String(format: "perf total: %@ %.0f ms", kind, ms))
        }
        DropProbe.say("perf: done")
        try? await Task.sleep(for: .seconds(1))
        NSApp.terminate(nil)
    }
}
#endif
