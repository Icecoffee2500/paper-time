#if os(macOS)
import AppKit
import LibraryStore
import PaperCore
import SwiftUI

/// The window's panes set, dropped on and closed without a hand on the
/// machine (`Workspace.swift`). A drag cannot be scripted, but a drop is only
/// the pane being told about one — so the drops here go to the same handler
/// the panes' drop delegates call, with the same items a drag carries.
///
/// - `--papertime-panes=list,page,shelf:plan:<name>` — the arrangement to
///   start from: `list`, `page`, `note`, `shelf:<key>` (`plan:<name>` and
///   `project:first` name a plan by its name and the first project).
/// - `--papertime-pane-drop=<what>,<pane>,<l|c|r>[;…]` — `what` is
///   `shelf:<key>` or `pane:<index>`; the pane is an index into the row.
/// - `--papertime-pane-close=<n>` — the nth pane's ×.
/// - `--papertime-pane-select=<pane>,<n>` — the nth paper of that pane's shelf
///   chosen as a press there would choose it.
/// - `--papertime-pane-hover=<pane>,<l|c|r>` — the zones lit as a drag over
///   that pane would light them, held for the picture.
/// - `--papertime-inspector-float=1` — the inspector floating.
/// - `--papertime-pane-menu=1` — the «+» menu, printed; with
///   `--papertime-pane-menu-shot=<png>` its items drawn too (the menu itself
///   is a window a probe must not put up).
/// - `--papertime-pane-reopen=1` — ⇧⌘T after the close.
///
/// Every step prints the row as it then stands. Nothing is written to the
/// settings: a probe's run never stores the arrangement.
@MainActor
enum PaneProbe {
    /// A probe that dies does so quietly: `--papertime-quiet-crash=1` (with a
    /// probe's library) ends the process on a crash signal before macOS can
    /// put its crash dialog in front of whoever is at the machine. Asked for,
    /// never assumed — a crash log is worth having when nobody is there.
    nonisolated static func quietCrashIfAsked() {
        guard Boot.setting("PAPERTIME_LIBRARY") != nil, Boot.isSet("PAPERTIME_QUIET_CRASH") else { return }
        for number in [SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT, SIGFPE] {
            signal(number) { _ in
                let text: StaticString = "probe: a crash signal — ended quietly\n"
                _ = write(2, text.utf8Start, text.utf8CodeUnitCount)
                _exit(70)
            }
        }
    }

    /// The probe's library, before it is opened: copied from a seed when it
    /// is not there yet, or — asked to be discarded — removed with what grew
    /// beside it, and the run ended. Both only inside the app's own
    /// temporary folder, and only in a probe's run. False when the run ends.
    static func prepareLibrary(at url: URL) -> Bool {
        guard Boot.setting("PAPERTIME_LIBRARY") != nil else { return true }
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).standardizedFileURL.path
        let library = url.standardizedFileURL
        guard library.path.hasPrefix(tmp), library.path != tmp else { return true }
        let files = FileManager.default
        if Boot.isSet("PAPERTIME_DISCARD_PROBE_LIBRARY") {
            let name = library.lastPathComponent
            let beside = library.deletingLastPathComponent()
            for each in [name, name + "-text-cache", name + "-text-cache-semantic", name + "-loose-notes"] {
                let gone = beside.appending(path: each, directoryHint: .isDirectory)
                if (try? files.removeItem(at: gone)) != nil { say("probe library: removed \(gone.lastPathComponent)") }
            }
            for shot in Boot.setting("PAPERTIME_DISCARD_SHOTS")?.split(separator: ",") ?? [] {
                let file = URL(fileURLWithPath: tmp).appending(path: String(shot))
                if file.standardizedFileURL.path.hasPrefix(tmp), (try? files.removeItem(at: file)) != nil {
                    say("probe library: removed \(shot)")
                }
            }
            NSApp.terminate(nil)
            return false
        }
        if let seed = Boot.setting("PAPERTIME_LIBRARY_SEED"), !files.fileExists(atPath: library.path) {
            let from = (seed.hasPrefix("/") ? URL(fileURLWithPath: seed) : URL(fileURLWithPath: tmp).appending(path: seed)).standardizedFileURL
            guard from.path.hasPrefix(tmp) else { return true }
            do {
                try files.copyItem(at: from, to: library)
                say("probe library: \(library.lastPathComponent) made from \(from.lastPathComponent)")
            } catch {
                say("probe library: could not copy \(from.lastPathComponent) — \(error.localizedDescription)")
            }
        }
        return true
    }

    /// A picture, written to the log as base64 between two marks, when
    /// `--papertime-shot-to-log=1` asks — the log is a file outside the
    /// container that `Scripts/probe.sh` names.
    nonisolated static func emit(_ png: Data, named name: String) {
        guard Boot.isSet("PAPERTIME_SHOT_TO_LOG") else { return }
        let text = "\n=== shot \(name) begin ===\n" + png.base64EncodedString(options: [.lineLength76Characters]) + "\n=== shot \(name) end ===\n"
        FileHandle.standardError.write(Data(text.utf8))
    }

    static func run(app: AppModel, model: LibraryModel) async {
        guard Boot.setting("PAPERTIME_LIBRARY") != nil else { return }
        let asked = ["PAPERTIME_PANES", "PAPERTIME_PANE_DROP", "PAPERTIME_SPLIT_DROP", "PAPERTIME_PANE_CLOSE", "PAPERTIME_PANE_SELECT",
                     "PAPERTIME_PANE_HOVER", "PAPERTIME_INSPECTOR_FLOAT", "PAPERTIME_PANE_MENU", "PAPERTIME_PANE_REPORT"]
            .contains { Boot.setting($0) != nil }
        guard asked else { return }
        if let spec = Boot.setting("PAPERTIME_PANES") {
            let panes = spec.split(separator: ",").compactMap { pane(String($0), model: model) }
            if !panes.isEmpty { app.panes = Array(panes.prefix(AppModel.mostPanes)) }
        }
        report(app, model, "start")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            report(app, model, "settled")
            shoot("start")
            for step in (Boot.setting("PAPERTIME_PANE_DROP") ?? "").split(separator: ";") {
                let parts = step.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                guard parts.count == 3, let index = Int(parts[1]), app.panes.indices.contains(index) else {
                    say("pane probe: cannot read drop \(step)")
                    continue
                }
                let zone: PaneDropZone = switch parts[2] { case "l": .left; case "r": .right; default: .middle }
                let item: PaneDropItem?
                if let raw = parts[0].stripPrefix("pane:"), let from = Int(raw), app.panes.indices.contains(from) {
                    item = .pane(app.panes[from].id)
                } else if let raw = parts[0].stripPrefix("shelf:") {
                    item = key(raw, model: model).map { .shelf($0) }
                } else if let raw = parts[0].stripPrefix("paper:"), let at = Int(raw), model.visiblePapers.indices.contains(at) {
                    // The n-th paper of the list, as a row dragged from it.
                    item = .paper(model.visiblePapers[at].id, moving: nil)
                } else {
                    item = nil
                }
                guard let item else { say("pane probe: nothing to drop in \(step)"); continue }
                app.drop(item, on: app.panes[index].id, zone: zone, model: model)
                try? await Task.sleep(for: .seconds(0.9))
                report(app, model, "dropped \(parts[0]) on \(index) \(zone)")
                shoot("drop")
            }
            if let raw = Boot.setting("PAPERTIME_PANE_SELECT") {
                let parts = raw.split(separator: ",").compactMap { Int($0) }
                if parts.count == 2, app.panes.indices.contains(parts[0]) {
                    let pane = app.panes[parts[0]]
                    let papers: [LoadedPaper] = if let key = pane.shelfKey, let scope = LibraryModel.Scope(paneKey: key) {
                        model.pinnedShelf(scope, kind: nil).papers
                    } else {
                        model.visiblePapers
                    }
                    if papers.indices.contains(parts[1]) {
                        app.lastPressedPane = pane.id
                        model.selection = [papers[parts[1]].id]
                        try? await Task.sleep(for: .seconds(0.9))
                        report(app, model, "chose «\(papers[parts[1]].meta.displayTitle.prefix(40))» in pane \(parts[0])")
                        shoot("select")
                    }
                }
            }
            // `--papertime-split-drop=<paper n>,<x>,<y>[;…]`: the n-th paper of
            // the list put on the page at that fraction of its width and
            // height — the place found as the drop's would be.
            for step in (Boot.setting("PAPERTIME_SPLIT_DROP") ?? "").split(separator: ";") {
                let parts = step.split(separator: ",").map { String($0) }
                guard parts.count == 3, let n = Int(parts[0]), let fx = Double(parts[1]), let fy = Double(parts[2]),
                      model.visiblePapers.indices.contains(n) else { continue }
                let frames = app.splitPaneFrames.filter { id, _ in app.split?.pane(id) != nil }
                let union = frames.values.reduce(CGRect.null) { $0.union($1) }
                let size = union.isNull ? CGSize(width: 900, height: 900) : CGSize(width: union.maxX + 8, height: union.maxY + 8)
                let point = CGPoint(x: size.width * fx, y: size.height * fy)
                let landing = DockDropDelegate.target(at: point, in: size, arrangement: app.split, frames: frames)
                let paper = model.visiblePapers[n].id
                switch landing {
                case let .zone(zone)?: app.dock(paper, at: zone, in: model)
                case let .open(pane)?: app.open(paper, inPane: pane, moving: nil, model: model)
                case nil: break
                }
                try? await Task.sleep(for: .seconds(0.9))
                report(app, model, "split drop «\(model.paper(paper)?.meta.displayTitle.prefix(20) ?? "")» at \(fx),\(fy) → \(String(describing: landing))")
                shoot("splitdrop")
            }
            if let raw = Boot.setting("PAPERTIME_PANE_CLOSE"), let index = Int(raw), app.panes.indices.contains(index) {
                let pane = app.panes[index]
                app.closePane(pane.id, title: app.title(of: pane, model: model))
                try? await Task.sleep(for: .seconds(0.6))
                report(app, model, "closed \(index)")
                shoot("close")
                if Boot.isSet("PAPERTIME_PANE_REOPEN") {
                    try? await Task.sleep(for: .seconds(1))
                    app.reopenLastClosedPane()
                    try? await Task.sleep(for: .seconds(0.6))
                    report(app, model, "reopened")
                    shoot("reopen")
                }
            }
            if let raw = Boot.setting("PAPERTIME_PANE_HOVER") {
                let parts = raw.split(separator: ",").map(String.init)
                if parts.count == 2, let index = Int(parts[0]), app.panes.indices.contains(index) {
                    let zone: PaneDropZone = switch parts[1] { case "l": .left; case "r": .right; default: .middle }
                    app.paneDropTarget = PaneDropTarget(pane: app.panes[index].id, zone: zone, held: true)
                    say("pane probe: zones lit over pane \(index), \(zone)")
                    try? await Task.sleep(for: .seconds(0.6))
                    shoot("hover")
                }
            }
            if Boot.isSet("PAPERTIME_INSPECTOR_FLOAT") {
                app.setInspectorFloats(true)
                say("pane probe: inspector floating — shown \(app.showsInspector)")
                try? await Task.sleep(for: .seconds(1.2))
                shoot("float")
            }
            if Boot.isSet("PAPERTIME_PANE_MENU") {
                let menu = PaneMenu.plusMenu(app: app, model: model)
                let lines = PaneMenu.describe(menu)
                say("pane probe: the «+» menu —")
                for line in lines { say("pane probe:   " + line) }
                if let path = Boot.setting("PAPERTIME_PANE_MENU_SHOT") { draw(lines, to: path) }
            }
        }
    }

    /// A pane named on the command line.
    private static func pane(_ token: String, model: LibraryModel) -> ContentPane? {
        switch token {
        case "list": return .list
        case "page": return .page
        case "note": return ContentPane(content: .note(nil))
        default:
            guard let raw = token.stripPrefix("shelf:"), let key = key(raw, model: model) else { return nil }
            return ContentPane(content: .shelf(key))
        }
    }

    /// A shelf key, with plans and projects named the way a person would.
    private static func key(_ raw: String, model: LibraryModel) -> String? {
        if let name = raw.stripPrefix("plan:"), UUID(uuidString: name) == nil {
            let plan = name == "first" ? model.plans.first : model.plans.first { $0.name.localizedCaseInsensitiveContains(name) }
            return plan.map { "plan:" + $0.id.uuidString }
        }
        if raw == "project:first" { return model.projects.first.map { "project:" + $0.id.uuidString } }
        return LibraryModel.Scope(paneKey: raw) != nil ? raw : nil
    }

    private static func report(_ app: AppModel, _ model: LibraryModel, _ moment: String) {
        let row = app.panes.enumerated().map { index, pane in
            "\(index):\(describe(pane.content))«\(app.title(of: pane, model: model).prefix(28))»"
        }.joined(separator: " | ")
        let notice = app.paneNotice.map { " — notice «\($0.text)»" + ($0.reopen != nil ? " [다시 열기]" : "") } ?? ""
        let beside = app.split.map { split in " — side by side " + split.panes.map { pane in String((model.paper(pane.paper)?.meta.displayTitle ?? "?").prefix(16)) }.joined(separator: " / ") } ?? ""
        say("pane probe [\(moment)]: \(row) — page shows \(app.pageShowing(model: model)), scope \(model.scope), closed \(app.closedPanes.count), inspector \(app.showsInspector ? (app.inspectorFloats ? "floating" : "docked") : "hidden")\(notice)\(beside)")
    }

    private static func describe(_ content: PaneContent) -> String {
        switch content {
        case .list: "list"
        case .page: "page"
        case let .shelf(key): "shelf(\(key.count > 20 ? String(key.prefix(14)) + "…" : key))"
        case let .note(id): "note(\(id ?? "-"))"
        }
    }

    /// The menu's lines, drawn as a menu would list them.
    private static func draw(_ lines: [String], to path: String) {
        let view = VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                if line.trimmingCharacters(in: .whitespaces) == "———" {
                    Divider().padding(.vertical, 3)
                } else {
                    Text(line).font(.system(size: 13)).foregroundStyle(line.contains("(dimmed)") ? .secondary : .primary)
                }
            }
        }
        .padding(12)
        .frame(width: 260, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.97)))
        .padding(10)
        .background(Color.white)
        .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
            say("pane probe: menu drawn to \(path)")
            emit(png, named: URL(fileURLWithPath: path).lastPathComponent)
        }
    }

    /// `--papertime-pane-shots=<prefix>`: the window after each step, through
    /// the log (`--papertime-shot-to-log=1`).
    private static func shoot(_ step: String) {
        guard let prefix = Boot.setting("PAPERTIME_PANE_SHOTS") else { return }
        WindowProbe.snapshot(named: "\(prefix)-\(step).png")
    }

    private static func say(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
#endif
