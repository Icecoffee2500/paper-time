#if os(macOS)
import AppKit
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
        case "all": model.scope = .all
        default: break
        }
        if let raw = Boot.setting("PAPERTIME_PLAN_VIEW"), let view = LibraryModel.ShelfView(rawValue: raw) {
            model.setShelfView(view, for: model.scope)
        }
        if let raw = Boot.setting("PAPERTIME_PLAN_SELECT"), let index = Int(raw), model.visiblePapers.indices.contains(index) {
            model.selection = [model.visiblePapers[index].id]
        }
        if Boot.isSet("PAPERTIME_PLAN_REPORT") { report(model, say: say) }
        if let directory = Boot.setting("PAPERTIME_PLAN_RENDER"), let app = WindowProbe.model {
            try? await Task.sleep(for: .seconds(Double(Boot.setting("PAPERTIME_PLAN_RENDER_AFTER") ?? "") ?? 2))
            render(to: directory, model: model, app: app, say: say)
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
        model.scope = .thisWeek
        draw("week", PlanBoard(model: model, staticRows: true), width: width, dark: false)
        model.scope = .all
        model.setShelfView(.table, for: .all)
        draw("all", PlanBoard(model: model, staticRows: true), width: width, dark: false)
        model.scope = scope
        for dark in [false, true] {
            draw("board", PlanBoard(model: model, staticRows: true), width: width, dark: dark)
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
