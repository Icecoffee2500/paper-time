#if os(macOS)
import AppKit
import PDFKit
import SwiftUI
import LibraryStore
import PaperCore

/// Reading plans, looked at without a hand on the machine.
///
/// Only with a probe library (`--papertime-library=`): the sample writes plan
/// files and days into the library it is given.
///
/// - `--papertime-plan-sample=1` makes two plans of the library's papers,
///   with sections, days about today (some behind, some this week, some
///   none), reading states and a few materials.
/// - `--papertime-scope=plan|plan2|week|all` goes to the first plan, the
///   second, «This Week», or «All».
/// - `--papertime-plan-view=table|calendar|list` shows the shelf that way.
/// - `--papertime-plan-group=section|week|status` groups a plan's table.
/// - `--papertime-plan-select=<n>` picks the n-th paper of the shelf.
/// - `--papertime-plan-report=1` says what the plans and the shelf hold.
/// - `--papertime-plan-sort=year` sorts the boards it draws (`-year` the other
///   way, `title` by title).
/// - `--papertime-plan-slide=<points>` draws a narrow table with its columns
///   slid that far.
/// - `--papertime-plan-window=1` opens and shuts the inspector in a window
///   of its own and says whether the window still fits the screen.
/// - `--papertime-plan-render=<folder>` draws the board, a paper's
///   materials and the two pickers into PNGs, light and dark, and quits.
@MainActor
enum PlanProbe {
    static func run(model: LibraryModel) async {
        guard Boot.isSet("PAPERTIME_LIBRARY") else { return }
        func say(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }

        if Boot.isSet("PAPERTIME_PLAN_CHECK") { await check(model, say: say) }
        if Boot.isSet("PAPERTIME_PLAN_SAMPLE") { await sample(model, say: say) }
        switch Boot.setting("PAPERTIME_SCOPE") {
        case "plan": if let id = model.plans.first?.id { model.scope = .plan(id) }
        case "plan2": if model.plans.count > 1 { model.scope = .plan(model.plans[1].id) }
        case "week": model.scope = .thisWeek
        case "all", "papers": model.scope = .papers
        case "books": model.scope = .books
        case "documents": model.scope = .documents
        default: break
        }
        if let raw = Boot.setting("PAPERTIME_PLAN_VIEW"), let view = LibraryModel.ShelfView(rawValue: raw) {
            model.setShelfView(view, for: model.scope)
        }
        if let raw = Boot.setting("PAPERTIME_PLAN_SELECT"), let index = Int(raw), model.visiblePapers.indices.contains(index) {
            model.selection = [model.visiblePapers[index].id]
        }
        if Boot.isSet("PAPERTIME_PLAN_REPORT") {
            // `--papertime-plan-report-after=<seconds>`: after the lookups and
            // the supplements have had their turn.
            if let wait = Double(Boot.setting("PAPERTIME_PLAN_REPORT_AFTER") ?? "") {
                try? await Task.sleep(for: .seconds(wait))
            }
            report(model, say: say)
        }
        if Boot.isSet("PAPERTIME_PLAN_WINDOW"), let app = WindowProbe.model {
            await windowCheck(app: app, say: say)
        }
        if let directory = Boot.setting("PAPERTIME_PLAN_RENDER"), let app = WindowProbe.model {
            try? await Task.sleep(for: .seconds(Double(Boot.setting("PAPERTIME_PLAN_RENDER_AFTER") ?? "") ?? 2))
            render(to: directory, model: model, app: app, say: say)
            await renderGuidance(to: directory, model: model, app: app, say: say)
            NSApp.terminate(nil)
        }
    }

    private static func sample(_ model: LibraryModel, say: (String) -> Void) async {
        let papers = model.papers.filter { $0.meta.parentID == nil }
            .sorted { $0.meta.displayTitle < $1.meta.displayTitle }
        guard papers.count >= 4 else { return say("plan sample: need at least four papers, have \(papers.count)") }
        for plan in model.plans { await model.deletePlan(plan.id) }
        let today = model.today
        let main = Array(papers.prefix(11))
        guard let first = await model.createPlan(named: "Offline RL 정주행", papers: main.map(\.id)) else {
            return say("plan sample: could not write the plan")
        }
        await model.editPlan(first) { plan in
            let names = ["바탕", "값을 낮춰 잡기", "단순하게", "모델로 풀기"]
            let ids = names.map { plan.addSection(named: $0) }
            for (index, entry) in plan.entries.enumerated() {
                plan.entries[index].section = ids[min(index / 3, ids.count - 1)]
                _ = entry
            }
        }
        // Days: three read last week, one behind, today, this week, next
        // week, and the last two with none.
        let offsets: [Int?] = [-7, -5, -3, -4, 0, 2, 4, 9, 11, nil, nil]
        var days: [UUID: PlanDay?] = [:]
        for (paper, offset) in zip(main, offsets) { days.updateValue(offset.map { today.adding(days: $0) }, forKey: paper.id) }
        await model.setDays(days)
        for (index, paper) in main.enumerated() {
            let status: PaperState.ReadingStatus = index < 3 ? .read : index == 4 ? .reading : .unread
            await model.setReadingStatus(status, for: paper.id)
        }
        if let paper = main.dropFirst(4).first {
            _ = await model.addLink("github.com/sfujim/TD3_BC", to: paper.id)
            _ = await model.addLink("https://youtu.be/talk", to: paper.id)
        }
        if let paper = main.dropFirst(2).first {
            _ = await model.addLink("https://docs.google.com/presentation/d/1abc/edit", to: paper.id)
            _ = await model.addLink("https://colab.research.google.com/drive/1abc", to: paper.id)
        }
        let rest = Array(papers.dropFirst(11).prefix(4))
        if !rest.isEmpty, let second = await model.createPlan(named: "Policy Gradient 복습", papers: rest.map(\.id)) {
            var more: [UUID: PlanDay?] = [:]
            for (paper, offset) in zip(rest, [3, 10, nil, 4]) { more.updateValue(offset.map { today.adding(days: $0) }, forKey: paper.id) }
            await model.setDays(more)
            say("plan sample: second plan \(second) with \(rest.count) papers")
        }
        say("plan sample: \(model.plans.count) plans, first with \(main.count) papers, today \(today.text)")
    }

    /// Every edit, and then the files read back: what the board did is what
    /// the folder holds.
    private static func check(_ model: LibraryModel, say: (String) -> Void) async {
        var failures = 0
        func expect(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            say("plan check: \(ok ? "ok  " : "FAIL") \(what)")
        }
        let papers = model.papers.filter { $0.meta.parentID == nil }.prefix(6).map(\.id)
        guard papers.count == 6 else { return say("plan check: need six papers") }
        for plan in model.plans { await model.deletePlan(plan.id) }
        for paper in papers {
            await model.setReadingStatus(.unread, for: paper)
            for link in model.paper(paper)?.links ?? [] { await model.removeLink(link.id, from: paper) }
        }
        guard let id = await model.createPlan(named: "검사 계획", papers: Array(papers.prefix(4))) else {
            return expect(false, "create")
        }
        expect(model.plan(id)?.entries.count == 4, "created with four papers")
        await model.addToPlan(id, papers: [papers[3], papers[4], papers[5]])
        expect(model.plan(id)?.entries.count == 6, "adding skips the one it has")
        await model.editPlan(id) { plan in
            let a = plan.addSection(named: "바탕")
            plan.move([papers[2], papers[0]], toEndOf: a)
        }
        let groups = model.plan(id)?.groups ?? []
        expect(groups.count == 2 && groups[1].papers == [papers[2], papers[0]], "a section with two papers, in the order moved")
        await model.editPlan(id) { $0.move([papers[5]], before: papers[2]) }
        expect(model.plan(id)?.groups.last?.papers == [papers[5], papers[2], papers[0]], "moved before a paper takes its section")

        let today = model.today
        await model.setDays([papers[0]: today.adding(days: -2), papers[1]: today, papers[2]: nil])
        expect(model.paper(papers[0])?.schedule == today.adding(days: -2), "a day given")
        expect(model.isBehind(model.paper(papers[0])!), "two days ago and unread is behind")
        await model.setReadingStatus(.read, for: papers[0])
        expect(!model.isBehind(model.paper(papers[0])!), "read is never behind")
        await model.setReadingStatus(.unread, for: papers[0])
        let spread = model.spread(id, weekdays: [0, 2, 4], perDay: 2, from: today)
        expect(spread.count == 6 && spread.allSatisfy { [0, 2, 4].contains($0.1.weekday) }, "spread: six papers on Mon/Wed/Fri, two a day")
        await model.setDays(Dictionary(spread.map { ($0.0, Optional($0.1)) }, uniquingKeysWith: { a, _ in a }))
        let pushed = model.pushedAWeek(id)
        await model.setDays(pushed)
        expect(spread.allSatisfy { model.paper($0.0)?.schedule == $0.1.adding(days: 7) }, "pushed a week")
        let undo = await model.setDays([papers[3]: nil])
        expect(model.paper(papers[3])?.schedule == nil, "a day cleared")
        await model.setDays(undo)
        expect(model.paper(papers[3])?.schedule != nil, "the clear undone")

        let added = await model.addLink("github.com/sfujim/TD3_BC", to: papers[1])
        expect(added == .added(.code), "a GitHub address is code")
        expect(await model.addLink("not a link", to: papers[1]) == .notAnAddress, "words are not an address")
        let scratch = FileManager.default.temporaryDirectory.appending(path: "검사 발표자료.pptx")
        try? Data("slides".utf8).write(to: scratch)
        expect(LibraryModel.holdsPDF([URL(fileURLWithPath: "/tmp/x.PDF")]) && !LibraryModel.holdsPDF([scratch]), "a PDF is told apart")
        let copied = await model.attachFiles([scratch], to: papers[1])
        expect(copied == 1, "a file copied beside the PDF")
        let links = model.paper(papers[1])?.links ?? []
        expect(links.count == 2 && links[1].kind == .slides && links[1].file != nil, "the file is slides, kept by its path")
        if let link = links.last, let paper = model.paper(papers[1]), let url = model.materialURL(link, of: paper) {
            expect(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)), "the copy is in the folder: \(link.file ?? "")")
        }
        await model.renameLink(links[0].id, of: papers[1], to: "TD3+BC 코드")
        expect(model.paper(papers[1])?.links.first?.displayTitle == "TD3+BC 코드", "renamed")
        await model.removeLink(links[0].id, from: papers[1])
        expect(model.paper(papers[1])?.links.count == 1, "removed")

        // Read it all back from disk, as another launch would.
        let memory = (model.plan(id), papers.map { model.paper($0)?.schedule }, model.paper(papers[1])?.links)
        await model.refresh()
        expect(model.plan(id) == memory.0, "the plan reads back the same")
        expect(papers.map { model.paper($0)?.schedule } == memory.1, "the days read back the same")
        expect(model.paper(papers[1])?.links == memory.2, "the materials read back the same")

        // Another device edits the plan file: heard, and read.
        if let root = model.planRoots[id] {
            let url = LibraryLayout.planURL(id: id, inLibrary: root)
            if var plan = try? FileOperations.decode(ReadingPlan.self, at: url) {
                plan.name = "다른 기기에서 바꾼 이름"
                try? FileOperations.encodeAndWrite(plan, to: url)
                await model.folderDidChange(paths: [url.path(percentEncoded: false)])
                expect(model.plan(id)?.name == "다른 기기에서 바꾼 이름", "a plan changed elsewhere is read again")
            }
        }
        await model.deletePlan(id)
        expect(model.plan(id) == nil, "deleted")
        say("plan check: \(failures == 0 ? "all passed" : "\(failures) failed")")
    }

    private static func report(_ model: LibraryModel, say: (String) -> Void) {
        say("plans: \(model.plans.count), this week \(model.thisWeekCount), today \(model.today.text) (\(PlanText.weekday(model.today)))")
        for plan in model.plans {
            say("plan \(plan.name): \(plan.entries.count) papers, sections \(plan.sections.map(\.name))")
            for group in plan.groups {
                let rows = group.papers.compactMap(model.paper).map { paper in
                    "\(paper.state.readingStatus.rawValue.prefix(1)) \(paper.schedule?.text ?? "—") \(paper.links.count)L \(paper.meta.displayTitle.prefix(28))"
                }
                say("  [\(group.section?.name ?? "·")] " + rows.joined(separator: " | "))
            }
        }
        if let first = model.plans.first {
            let spread = model.spread(first.id, weekdays: [0, 2, 4], perDay: 1, from: model.today)
            say("spread \(first.name) MWF 1/day from today: \(spread.map { $0.1.text })")
        }
        say("shelf \(model.scope) as \(model.shelfView(for: model.scope).rawValue): \(model.visiblePapers.count) papers, selected \(model.selectedPaper?.meta.displayTitle.prefix(30) ?? "—")")
        for paper in model.papers where model.attachmentCount(of: paper.id) > 0 {
            let children = model.attachments(of: paper.id).map(\.meta.file.originalName)
            say("supplements of \(paper.meta.displayTitle.prefix(40)): \(children)")
        }
        for paper in model.papers.filter({ $0.meta.parentID == nil }) {
            let csl = paper.meta.csl
            say("venue: \(csl.type.rawValue) | \(csl.containerTitle ?? "—") | \(csl.year.map(String.init) ?? "—") | \(paper.meta.displayTitle.prefix(40))")
        }
    }

    /// `--papertime-plan-window=1`: the window that grew past the screen.
    ///
    /// On 2026-11-16 opening the inspector beside the table made the window
    /// wider than the screen, and fitting it back by double-clicking the
    /// title bar a few times quit the app («update constraints count»). This
    /// takes the probe's own window — off every display, never unhidden —
    /// sizes it to the main screen, opens and closes the inspector, sets the
    /// frame back to the screen's the way a zoom does, and says each time
    /// whether the window still fits. Not a second window of its own: two
    /// windows with the library's toolbar are one toolbar family, and the
    /// family's sync threw in `NSToolbar` and quit the probe.
    private static func windowCheck(app: AppModel, say: (String) -> Void) async {
        guard let screen = NSScreen.main else { return say("plan window: no screen") }
        let size = screen.visibleFrame.size
        try? await Task.sleep(for: .seconds(1))
        guard let window = NSApp.windows.first(where: { $0.toolbar != nil && $0.contentView != nil && !WindowProbe.isOnAScreen($0) }) else {
            return say("plan window: no window of the probe's off every screen — nothing checked")
        }
        window.setFrame(NSRect(origin: window.frame.origin, size: size), display: true)
        guard !WindowProbe.isOnAScreen(window) else {
            window.orderOut(nil)
            return say("plan window: the window landed on a screen — put away, nothing checked")
        }
        var fits = true
        /// How wide the first view of a kind is on the window, as laid out.
        func width(of kind: NSView.Type) -> String {
            var stack: [NSView] = window.contentView.map { [$0] } ?? []
            while let view = stack.popLast() {
                if type(of: view) == kind || view.isKind(of: kind) {
                    let shown = (view.enclosingScrollView ?? view).frame.width
                    return String(Int(shown))
                }
                stack += view.subviews
            }
            return "—"
        }
        func measure(_ label: String) {
            let wide = window.frame.width
            let ok = wide <= size.width + 1 && window.contentMinSize.width <= size.width + 1
            fits = fits && ok
            say("plan window \(label): inspector \(app.showsInspector ? "open" : "shut") frame \(Int(wide))×\(Int(window.frame.height)) "
                + "min \(Int(window.contentMinSize.width))×\(Int(window.contentMinSize.height)) screen \(Int(size.width)) "
                + "table \(width(of: BoardTable.Table.self)) page \(width(of: PDFView.self)) "
                + (ok ? "fits" : "PAST THE SCREEN"))
        }
        try? await Task.sleep(for: .seconds(1.5))
        measure("start")
        for step in 1...6 {
            app.toggleInspector()
            try? await Task.sleep(for: .seconds(0.8))
            measure("toggle \(step)")
            // What a zoom does: the frame set to the screen's, here where it
            // already is.
            window.setFrame(NSRect(origin: window.frame.origin, size: size), display: true)
            try? await Task.sleep(for: .seconds(0.4))
            measure("zoom \(step)")
        }
        // Narrower than the columns would like: the table and the inspector
        // give way, the window stays where it is put.
        window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: 1000, height: size.height)), display: true)
        try? await Task.sleep(for: .seconds(0.6))
        let narrow = window.frame.width
        say("plan window narrow: asked 1000, frame \(Int(narrow)) \(narrow <= 1001 ? "held" : "GREW")")
        // Where the table and the page stand in the window, for widths that
        // leave the table at its narrowest: the table must end before the
        // page begins — a board that asks for more than its column spills
        // under its neighbours.
        func span(of kind: NSView.Type) -> (CGFloat, CGFloat)? {
            var stack: [NSView] = window.contentView.map { [$0] } ?? []
            while let view = stack.popLast() {
                if view.isKind(of: kind) {
                    let shown = view.enclosingScrollView ?? view
                    let frame = shown.convert(shown.bounds, to: nil)
                    return (frame.minX, frame.maxX)
                }
                stack += view.subviews
            }
            return nil
        }
        if !app.showsInspector { app.toggleInspector() }
        for wide in [1600.0, 1440, 1320] {
            window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: wide, height: size.height)), display: true)
            try? await Task.sleep(for: .seconds(0.8))
            // A sideways swipe, made here and handed to the table's own
            // scroll view — never posted to the system.
            if wide == 1440 {
                var stack: [NSView] = window.contentView.map { [$0] } ?? []
                var sliding: BoardTable.Sliding?
                while let view = stack.popLast() {
                    if let found = view as? BoardTable.Sliding { sliding = found; break }
                    stack += view.subviews
                }
                if let sliding, let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: -60, wheel3: 0),
                   let event = NSEvent(cgEvent: cg) {
                    let before = sliding.coordinator?.slide?.x ?? -1
                    sliding.scrollWheel(with: event)
                    let after = sliding.coordinator?.slide?.x ?? -1
                    let limit = sliding.coordinator?.slideLimit ?? 0
                    say("plan window swipe: slide \(Int(before)) → \(Int(after)) of \(Int(limit)) "
                        + (after > before ? "moved" : "DID NOT MOVE"))
                    sliding.coordinator?.slide?.x = 0
                } else {
                    say("plan window swipe: no sliding table")
                }
            }
            if let table = span(of: BoardTable.Table.self), let page = span(of: PDFView.self) {
                say("plan window \(Int(wide)): table \(Int(table.0))–\(Int(table.1)) (\(Int(table.1 - table.0))) page \(Int(page.0))–\(Int(page.1)) (\(Int(page.1 - page.0))) "
                    + (table.1 <= page.0 ? "apart" : "TABLE SPILLS UNDER THE PAGE"))
            } else {
                say("plan window \(Int(wide)): table or page not found")
            }
        }
        say("plan window: \(fits && narrow <= 1001 ? "fits every time" : "DID NOT FIT")")
    }

    /// The pieces that tell a newcomer what to do: the New Plan sheet, an
    /// empty plan, and a plan with no days yet.
    private static func renderGuidance(to directory: String, model: LibraryModel, app: AppModel, say: (String) -> Void) async {
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        func draw(_ name: String, _ view: some View, width: Double) {
            let renderer = ImageRenderer(content: view.frame(width: width)
                .background(Color(nsColor: .windowBackgroundColor)).environment(app))
            renderer.scale = 2
            guard let image = renderer.cgImage,
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                return say("plan render: \(name) drew nothing")
            }
            let url = folder.appending(path: name + ".png")
            try? png.write(to: url)
            say("plan render: wrote \(url.path) \(image.width)×\(image.height)")
        }
        let papers = model.papers.filter { $0.meta.parentID == nil }
        draw("new-plan", NewPlanSheet(model: model, name: "Offline RL 정주행", chosen: papers.prefix(4).map(\.id),
                                      givesDays: true, rendering: true) {}, width: 540)
        let scope = model.scope
        if let empty = await model.createPlan(named: "빈 계획") {
            model.scope = .plan(empty)
            draw("empty-plan", PlanBoard(model: model, staticRows: true).frame(height: 620), width: 1000)
            await model.deletePlan(empty)
        }
        let undated = papers.filter { $0.schedule == nil }.prefix(3).map(\.id)
        if !undated.isEmpty, let fresh = await model.createPlan(named: "날짜 없는 계획", papers: Array(undated)) {
            model.scope = .plan(fresh)
            draw("days-strip", PlanBoard(model: model, staticRows: true), width: 1000)
            await model.deletePlan(fresh)
        }
        model.scope = scope
    }

    /// The board drawn by `ImageRenderer` into PNGs, light and dark — no
    /// window shown, nothing unhidden. On 2026-11-16 a shot that unhid the
    /// probe to photograph its window had AppKit pull the window onto a
    /// display before the gate could put it away; this draws the same views
    /// instead. The table is drawn as plain rows (the renderer cannot draw an
    /// `NSTableView`), the calendar without its scroll view.
    private static func render(to directory: String, model: LibraryModel, app: AppModel, say: (String) -> Void) {
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let width = Double(Boot.setting("PAPERTIME_PLAN_RENDER_WIDTH") ?? "") ?? 1000
        func draw(_ name: String, _ view: some View, width: Double, dark: Bool) {
            let framed = view
                .frame(width: width)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(app)
                .environment(\.colorScheme, dark ? .dark : .light)
            let renderer = ImageRenderer(content: framed)
            renderer.scale = 2
            guard let image = renderer.cgImage,
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                return say("plan render: \(name) drew nothing")
            }
            let url = folder.appending(path: name + (dark ? "-dark" : "") + ".png")
            try? png.write(to: url)
            say("plan render: wrote \(url.path) \(image.width)×\(image.height)")
        }
        let today = model.today
        // Every board: the plan as a table and as a calendar, the week, and
        // a plain shelf as a table.
        let scope = model.scope
        if let plan = model.plans.first {
            model.scope = .plan(plan.id)
            model.setShelfView(.calendar, for: model.scope)
            draw("calendar", PlanBoard(model: model, staticRows: true), width: width, dark: false)
            draw("calendar", PlanBoard(model: model, staticRows: true), width: width, dark: true)
            model.setShelfView(.table, for: model.scope)
        }
        // The rest stand in the list column now, beside the page.
        let column = Double(Boot.setting("PAPERTIME_PLAN_COLUMN_WIDTH") ?? "") ?? 620
        model.scope = .thisWeek
        draw("week", PlanBoard(model: model, staticRows: true), width: column, dark: false)
        // Each kind's shelf under its own columns, then a shelf of every
        // kind — «Unread» — which shows the kind picked last, with its chips.
        for (name, shelf) in [("papers", LibraryModel.Scope.papers), ("books", .books), ("documents", .documents), ("unread", .unread)] {
            model.scope = shelf
            draw("shelf-" + name, PlanBoard(model: model, staticRows: true), width: column, dark: false)
        }
        model.scope = .unread
        draw("shelf-unread", PlanBoard(model: model, staticRows: true), width: column, dark: true)
        model.scope = scope
        for dark in [false, true] {
            draw("board", PlanBoard(model: model, staticRows: true), width: column, dark: dark)
            if let paper = model.selectedPaper {
                draw("materials", MaterialsPreview(model: model, paper: paper).padding(16), width: 300, dark: dark)
            }
            draw("day-picker", DayPicker(today: today, current: today.adding(days: 4)) { _ in }, width: 256, dark: dark)
            if let id = model.plans.first?.id {
                draw("spread", SpreadPicker(model: model, planID: id) { _ in }, width: 268, dark: dark)
            }
        }
    }
}
#endif
