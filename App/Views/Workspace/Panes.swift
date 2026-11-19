#if os(macOS)
import AppKit
import LibraryStore
import PaperCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - The head every pane wears

/// What a pane's head needs to say and to do: what the pane shows, its ⌄
/// menu, and its ×. Handed down to whichever head the pane's content already
/// has — a shelf's, the reader's title — so the controls join that head
/// rather than putting a second bar over it (`Workspace.swift`).
struct PaneHead {
    var id: UUID
    var title: String
    var symbol: String
    /// False for the last pane: its × is there, dimmed, and does nothing.
    var canClose: Bool
    var close: @MainActor () -> Void
    var choose: @MainActor (PaneContent) -> Void
}

struct PaneHeadKey: EnvironmentKey {
    static let defaultValue: PaneHead? = nil
}

extension EnvironmentValues {
    var paneHead: PaneHead? {
        get { self[PaneHeadKey.self] }
        set { self[PaneHeadKey.self] = newValue }
    }
}

/// The ⌄ and the × at the end of a pane's head.
struct PaneHeadControls: View {
    @Environment(\.paneHead) private var head
    @Environment(AppModel.self) private var app

    var body: some View {
        if let head {
            HStack(spacing: 6) {
                Menu {
                    if let model = app.library {
                        PaneMenuItems(entries: PaneMenu.entries(model: model), choose: head.choose)
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.primary.opacity(0.06)))
                        .contentShape(Circle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(L("이 칸에 띄울 것 바꾸기", "Change what this pane shows"))
                PaneCloseButton(enabled: head.canClose) { head.close() }
            }
        }
    }
}

extension View {
    /// The pane's head as the handle that moves it: dragged, it carries the
    /// pane, and dropped on another pane's edge or middle it moves there.
    func paneDragHandle() -> some View { modifier(PaneDragHandle()) }
}

private struct PaneDragHandle: ViewModifier {
    @Environment(\.paneHead) private var head

    func body(content: Content) -> some View {
        // Outside a pane — a picture of a board, a sheet — the head is only
        // a head, and dragging it carries nothing.
        if let head {
            content.onDrag {
                .pane(head.id)
            } preview: {
                Label(head.title, systemImage: head.symbol)
                    .font(.system(size: 12.5, weight: .semibold))
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(Capsule().fill(.regularMaterial))
            }
        } else {
            content
        }
    }
}

/// A slim head, for what fills a pane without one of its own — a note being
/// written, a project, a pane of papers side by side.
struct PaneHeadBar: View {
    let symbol: String
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .contentShape(.rect)
            .paneDragHandle()
            Spacer(minLength: 8)
            PaneHeadControls()
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }
}

/// A small round × that closes the pane it stands in.
struct PaneCloseButton: View {
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.primary.opacity(0.06)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .pressable(cornerRadius: 10)
        // The last pane's: there, so the head keeps its shape, and quiet,
        // because a window with nothing in it is not somewhere to be.
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(enabled ? L("이 칸 닫기", "Close This Pane") : L("마지막 칸은 닫을 수 없어요", "The last pane stays open"))
        .accessibilityLabel(L("칸 닫기", "Close Pane"))
    }
}

// MARK: - What a pane can show

/// The things a pane can be made to show: the ⌄ menu, the «+» column's menu.
struct PaneMenuEntry: Identifiable {
    var id: String
    var title: String
    var symbol: String
    var content: PaneContent?
    var children: [PaneMenuEntry] = []
}

@MainActor
enum PaneMenu {
    /// 논문 · 책 · 문서 · 이번 주 · 계획 ▸ · 문헌 노트 · 지식 · 프로젝트 ▸ · 노트.
    static func entries(model: LibraryModel) -> [PaneMenuEntry] {
        func shelf(_ scope: LibraryModel.Scope, _ title: String) -> PaneMenuEntry {
            let key = scope.paneKey ?? ""
            return PaneMenuEntry(id: key, title: title, symbol: ShelfTitle.symbol(of: scope), content: .shelf(key))
        }
        let plans = model.plans.map { shelf(.plan($0.id), $0.name) }
        let projects = [shelf(.projects(nil), L("모든 프로젝트", "All Projects"))]
            + model.projects.map { shelf(.projects($0.id), $0.name) }
        return [
            shelf(.papers, L("논문", "Papers")),
            shelf(.books, L("책", "Books")),
            shelf(.documents, L("문서", "Documents")),
            shelf(.thisWeek, L("이번 주", "This Week")),
            PaneMenuEntry(id: "plans", title: L("계획", "Plans"), symbol: ShelfTitle.symbol(of: .plan(UUID())),
                          content: nil, children: plans),
            shelf(.notes, L("문헌 노트", "Literature Notes")),
            shelf(.knowledge(nil), L("지식", "Knowledge")),
            PaneMenuEntry(id: "projects-menu", title: L("프로젝트", "Projects"), symbol: "flag",
                          content: nil, children: projects),
            PaneMenuEntry(id: "note", title: L("노트", "Note"), symbol: "square.and.pencil", content: .note(nil)),
        ]
    }

    /// The «+» column's menu: a new pane of any of those — the page too, when
    /// none is open — and the panes closed, to have back.
    static func plusMenu(app: AppModel, model: LibraryModel) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(.sectionHeader(title: L("새 칸", "New Pane")))
        if !app.showsReader {
            menu.addItem(ActionMenuItem(title: ShortcutAction.reader.title, symbol: "text.page") { app.addPane(.page) })
        }
        for entry in entries(model: model) {
            menu.addItem(item(entry) { app.addPane($0) })
        }
        menu.addItem(.separator())
        let reopen = NSMenuItem(title: L("닫은 칸 다시 열기", "Reopen Closed Pane"), action: nil, keyEquivalent: "")
        let closed = NSMenu()
        closed.autoenablesItems = false
        for pane in app.closedPanes.reversed() {
            closed.addItem(ActionMenuItem(title: pane.title, symbol: nil) { app.reopenClosedPane(pane.pane.id) })
        }
        reopen.submenu = closed
        reopen.isEnabled = !app.closedPanes.isEmpty
        menu.addItem(reopen)
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: L("인스펙터", "Inspector")))
        for item in inspectorItems(app: app) { menu.addItem(item) }
        return menu
    }

    /// The inspector, docked or floating — wherever it was left, and whether
    /// it shows at all (2026-11-18: «info 창을 한번 지우면, 그 다음에
    /// floating으로 띄우고 싶으면 어떻게 해야 하지?»).
    static func inspectorItems(app: AppModel) -> [NSMenuItem] {
        let docked = ActionMenuItem(title: L("옆에 붙여 보기", "Show Docked"), symbol: "sidebar.right") {
            app.showInspector(floating: false)
        }
        docked.state = app.showsInspector && !app.inspectorFloats ? .on : .off
        let floating = ActionMenuItem(title: L("띄워 보기", "Show Floating"), symbol: "macwindow.on.rectangle") {
            app.showInspector(floating: true)
        }
        floating.state = app.showsInspector && app.inspectorFloats ? .on : .off
        return [docked, floating]
    }

    private static func item(_ entry: PaneMenuEntry, choose: @escaping @MainActor (PaneContent) -> Void) -> NSMenuItem {
        if !entry.children.isEmpty || entry.content == nil {
            let parent = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
            parent.image = NSImage(systemSymbolName: entry.symbol, accessibilityDescription: nil)
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            if entry.children.isEmpty {
                let none = NSMenuItem(title: L("없어요", "None"), action: nil, keyEquivalent: "")
                none.isEnabled = false
                submenu.addItem(none)
            }
            for child in entry.children { submenu.addItem(item(child, choose: choose)) }
            parent.submenu = submenu
            return parent
        }
        let content = entry.content!
        return ActionMenuItem(title: entry.title, symbol: entry.symbol) { choose(content) }
    }

    /// The menu as lines — what `--papertime-pane-menu=1` prints, since a
    /// menu is a window of its own that a probe must not put up.
    static func describe(_ menu: NSMenu, depth: Int = 0) -> [String] {
        menu.items.flatMap { item -> [String] in
            let pad = String(repeating: "  ", count: depth)
            let line = item.isSeparatorItem ? pad + "———"
                : pad + item.title + (item.isEnabled ? "" : " (dimmed)") + (item.submenu != nil ? " ▸" : "")
            return [line] + (item.submenu.map { describe($0, depth: depth + 1) } ?? [])
        }
    }
}

/// The entries as SwiftUI menu items — the ⌄ menu.
struct PaneMenuItems: View {
    let entries: [PaneMenuEntry]
    let choose: @MainActor (PaneContent) -> Void

    var body: some View {
        ForEach(entries) { entry in
            if let content = entry.content {
                Button { choose(content) } label: { Label(entry.title, systemImage: entry.symbol) }
            } else {
                Menu {
                    if entry.children.isEmpty { Text(L("없어요", "None")) }
                    ForEach(entry.children) { child in
                        if let content = child.content {
                            Button { choose(content) } label: { Label(child.title, systemImage: child.symbol) }
                        }
                    }
                } label: {
                    Label(entry.title, systemImage: entry.symbol)
                }
            }
        }
    }
}

/// A menu item that runs a closure.
@MainActor
final class ActionMenuItem: NSMenuItem {
    private var handler: (@MainActor () -> Void)?

    init(title: String, symbol: String?, handler: @escaping @MainActor () -> Void) {
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        self.handler = handler
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }

    required init(coder: NSCoder) { fatalError("not from a nib") }

    @objc private func run() { handler?() }
}

// MARK: - Dropping on a pane

/// The three zones over a pane while a sidebar item or a pane is dragged
/// over it: a new pane on the left, open here, a new pane on the right.
struct PaneDropZones: ViewModifier {
    let paneID: UUID
    /// False for a pane held out of sight; it takes nothing.
    let enabled: Bool
    let model: LibraryModel
    @Environment(AppModel.self) private var app
    /// The pane's size, read by a drag — held in a box rather than state:
    /// written on every frame of a pane's motion, state re-ran this modifier
    /// each frame for a number only a drop ever reads.
    @State private var size = SizeBox()

    final class SizeBox { var value: CGSize = .zero }

    func body(content: Content) -> some View {
        let target = app.paneDropTarget?.pane == paneID ? app.paneDropTarget : nil
        let zone = target?.zone
        let box = size
        content
            .overlay { PaneZoneOverlay(zone: zone, paper: target?.paper == true, besidePage: app.showsReader) }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { box.value = $0 }
            .onDrop(of: [.paperTimeShelf, .paperTimePane, .paperTimePaper], delegate: PaneDropDelegate(
                paneID: paneID, enabled: enabled, size: { box.value }, app: app, model: model
            ))
            // The zones stay up only while a drag is really going on: one let
            // go outside the window, or put down with Escape, never says it
            // left (`DockZoneOverlay` learned this first).
            .task(id: zone != nil) {
                guard zone != nil else { return }
                while app.paneDropTarget?.pane == paneID, app.paneDropTarget?.held != true {
                    try? await Task.sleep(for: .milliseconds(250))
                    if NSEvent.pressedMouseButtons == 0, app.paneDropTarget?.held != true { app.paneDropTarget = nil }
                }
            }
    }
}

private struct PaneDropDelegate: DropDelegate {
    let paneID: UUID
    let enabled: Bool
    let size: () -> CGSize
    let app: AppModel
    let model: LibraryModel

    func validateDrop(info: DropInfo) -> Bool {
        guard enabled else { return false }
        if info.hasItemsConforming(to: [.paperTimeShelf, .paperTimePane]) { return true }
        // A paper, on any pane but the page — the page's own zones take it
        // there (`DockDropDelegate`).
        return info.hasItemsConforming(to: [.paperTimePaper]) && app.panes.first { $0.id == paneID }?.content != .page
    }

    private func carriesPaper(_ info: DropInfo) -> Bool {
        !info.hasItemsConforming(to: [.paperTimeShelf, .paperTimePane]) && info.hasItemsConforming(to: [.paperTimePaper])
    }

    /// Where a paper lands: with a page open, the whole pane is one zone —
    /// the paper opens beside the page's — so the middle stands for it.
    private func zone(_ info: DropInfo) -> PaneDropZone {
        if carriesPaper(info), app.showsReader { return .middle }
        return PaneDropZone.at(info.location.x, width: size().width)
    }

    func dropEntered(info: DropInfo) { aim(info) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        aim(info)
        // `.copy` for both: AppKit refuses an answer the drag's source did
        // not allow, and a SwiftUI `onDrag` source is not known to allow
        // `.move` — a pane moved by its head is moved by us, whatever the
        // cursor's badge says (`SidebarDrops.operation(allowedBy:)`).
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        Task { @MainActor in if app.paneDropTarget?.pane == paneID { app.paneDropTarget = nil } }
    }

    func performDrop(info: DropInfo) -> Bool {
        let zone = zone(info)
        Task { @MainActor in app.paneDropTarget = nil }
        return PaneDrops.load(info.itemProviders(for: [.paperTimeShelf, .paperTimePane, .paperTimePaper])) { item in
            app.drop(item, on: paneID, zone: zone, model: model)
        }
    }

    private func aim(_ info: DropInfo) {
        let target = PaneDropTarget(pane: paneID, zone: zone(info), paper: carriesPaper(info))
        Task { @MainActor in if app.paneDropTarget != target { withAnimation(Motion.tap) { app.paneDropTarget = target } } }
    }
}

@MainActor
enum PaneDrops {
    /// Reads what a shelf or pane drag carries, and hands it on.
    static func load(_ providers: [NSItemProvider], then: @escaping @MainActor (PaneDropItem) -> Void) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.hasItemConformingToTypeIdentifier(UTType.paperTimePane.identifier) {
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.paperTimePane.identifier) { data, _ in
                guard let data, let carried = try? JSONDecoder().decode(PaneTransfer.self, from: data),
                      let id = UUID(uuidString: carried.pane) else { return }
                Task { @MainActor in then(.pane(id)) }
            }
            return true
        }
        if !provider.hasItemConformingToTypeIdentifier(UTType.paperTimeShelf.identifier),
           provider.hasItemConformingToTypeIdentifier(UTType.paperTimePaper.identifier) {
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.paperTimePaper.identifier) { data, _ in
                guard let data, let carried = try? JSONDecoder().decode(PaperTransfer.self, from: data) else { return }
                Task { @MainActor in then(.paper(carried.id, moving: carried.pane)) }
            }
            return true
        }
        _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.paperTimeShelf.identifier) { data, _ in
            guard let data, let carried = try? JSONDecoder().decode(ShelfTransfer.self, from: data) else { return }
            Task { @MainActor in then(.shelf(carried.shelf)) }
        }
        return true
    }
}

/// The zones, drawn: each a pale wash of the accent with its words, the one
/// under the pointer ringed.
struct PaneZoneOverlay: View {
    let zone: PaneDropZone?
    /// A paper, not a sidebar item or a pane.
    var paper = false
    /// Whether a page is open for a paper to stand beside.
    var besidePage = true

    var body: some View {
        GeometryReader { proxy in
            if let zone {
                let width = proxy.size.width, height = proxy.size.height
                let side = width * 0.26
                let inset: CGFloat = 8
                if paper && besidePage {
                    // One zone: the paper opens beside the page's, on this
                    // pane's side of it.
                    region(.middle, lit: true, label: L("논문 옆에 나란히 열기", "Open Beside the Paper"))
                        .frame(width: width - inset * 2, height: height - inset * 2)
                        .offset(x: inset, y: inset)
                        .transition(.opacity)
                } else {
                ZStack(alignment: .topLeading) {
                    region(.left, lit: zone == .left, label: paper ? L("왼쪽에 논문 칸", "Paper on the Left") : L("왼쪽에 새 칸", "New Pane on the Left"))
                        .frame(width: side - inset * 1.5, height: height - inset * 2)
                        .offset(x: inset, y: inset)
                    region(.middle, lit: zone == .middle, label: L("여기에 열기", "Open Here"))
                        .frame(width: width - side * 2 - inset, height: height - inset * 2)
                        .offset(x: side + inset / 2, y: inset)
                    region(.right, lit: zone == .right, label: paper ? L("오른쪽에 논문 칸", "Paper on the Right") : L("오른쪽에 새 칸", "New Pane on the Right"))
                        .frame(width: side - inset * 1.5, height: height - inset * 2)
                        .offset(x: width - side + inset / 2, y: inset)
                }
                .transition(.opacity)
                }
            }
        }
        .allowsHitTesting(false)
        .animation(Motion.tap, value: zone)
    }

    private func region(_ which: PaneDropZone, lit: Bool, label: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: Corner.popover, style: .continuous)
        return shape
            .fill(Color.accentColor.opacity(lit ? 0.16 : 0.12))
            .overlay(shape.strokeBorder(Color.accentColor.opacity(lit ? 0.85 : 0), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
            .overlay {
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.accentColor.opacity(lit ? 0.16 : 0.08)))
                    .padding(6)
            }
    }
}

// MARK: - The «+» column

/// The slim column at the end of the pane row: always there, so a pane
/// closed is never a pane lost. Pressed, it offers a new pane of anything
/// and the panes closed; a sidebar item or a pane dropped on it goes at the
/// end of the row.
struct PlusColumn: View {
    static let width: CGFloat = 22
    let model: LibraryModel
    @Environment(AppModel.self) private var app
    @State private var hovering = false
    @State private var targeted = false
    @State private var anchor = MenuAnchorBox()

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        let lit = hovering || targeted
        Color.clear
            .frame(width: Self.width)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .trailing) {
                // Wider under the pointer, into the gap beside it — so the
                // panes do not move when the pointer passes.
                shape
                    .fill(Color.accentColor.opacity(lit ? (targeted ? 0.16 : 0.08) : 0))
                    .overlay(shape.strokeBorder(lit ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.35),
                                                style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    .overlay {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(lit ? Color.accentColor : Color.secondary)
                    }
                    .frame(width: lit ? Self.width + 8 : Self.width)
                    .animation(Motion.tap, value: lit)
            }
            .contentShape(.rect)
            .background(MenuAnchor(box: anchor))
            .onHover { hovering = $0 }
            .onTapGesture(coordinateSpace: .local) { location in
                guard let view = anchor.view, let model = app.library else { return }
                let menu = PaneMenu.plusMenu(app: app, model: model)
                menu.popUp(positioning: nil, at: NSPoint(x: location.x, y: location.y), in: view)
            }
            .onDrop(of: [.paperTimeShelf, .paperTimePane, .paperTimePaper], isTargeted: $targeted) { providers in
                PaneDrops.load(providers) { app.dropAtEnd($0) }
            }
            .help(L("칸 더하기 — 눌러서 고르거나, 옆 목록의 항목을 여기로 끌어와요",
                    "Add a pane — press to choose, or drag an item from the sidebar here"))
            .accessibilityLabel(L("칸 더하기", "Add Pane"))
            .accessibilityAddTraits(.isButton)
    }
}

/// Holds the AppKit view a menu is popped up from.
@MainActor
final class MenuAnchorBox {
    weak var view: NSView?
}

private struct MenuAnchor: NSViewRepresentable {
    /// The size it is given, without asking AppKit. Left to itself SwiftUI
    /// asks an AppKit view for its layout traits on every pass of the
    /// window's layout, and AppKit answers by updating the constraints of
    /// the view's whole subtree — for a table, every row on screen, each
    /// row's SwiftUI body with it. That was most of what a pane opening or
    /// closing cost (2026-11-19, `--papertime-perf`).
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSViewType, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    let box: MenuAnchorBox

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        box.view = view
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) { box.view = view }

    final class AnchorView: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

// MARK: - The capsule at the foot

/// «… 칸을 닫았어요 · 다시 열기», and the refusal of a fifth pane.
struct PaneNoticeCapsule: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let notice = app.paneNotice {
            HStack(spacing: 10) {
                Text(notice.text)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let reopen = notice.reopen {
                    Button(L("다시 열기", "Reopen")) {
                        withAnimation(Motion.move) { app.paneNotice = nil }
                        app.reopenClosedPane(reopen)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(Capsule().fill(Color.white.opacity(0.18)))
                    .help(L("다시 열기 (⇧⌘T)", "Reopen (⇧⌘T)"))
                }
            }
            .foregroundStyle(colorScheme == .dark ? Color.black : .white)
            .padding(.leading, 16)
            .padding(.trailing, notice.reopen == nil ? 16 : 8)
            .frame(minHeight: 36)
            .background(Capsule().fill(colorScheme == .dark ? Color(white: 0.92) : Color(white: 0.17)))
            .shadow(color: .black.opacity(0.2), radius: 14, y: 6)
            .padding(.bottom, 22)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(notice.id)
        }
    }
}

// MARK: - A pane that holds one note

/// One note beside the work in front: a list to pick it from, then the note.
struct NotePane: View {
    let model: LibraryModel
    let link: ReaderLink
    let paneID: UUID
    let noteID: String?
    @Environment(AppModel.self) private var app
    @State private var query = ""

    private func open(_ id: String?) {
        guard let index = app.paneIndex(paneID) else { return }
        app.panes[index].content = .note(id)
        app.storePanes()
    }

    var body: some View {
        VStack(spacing: 0) {
            if let id = noteID, let note = model.notes.note(id) {
                PaneHeadBar(symbol: "square.and.pencil", title: note.displayTitle)
                HStack {
                    Button {
                        open(nil)
                    } label: {
                        Label(L("다른 노트", "Other Notes"), systemImage: "chevron.left")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                ZettelEditorView(notes: model.notes, noteID: id, link: link)
            } else {
                PaneHeadBar(symbol: "square.and.pencil", title: L("노트", "Note"))
                picker
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var picker: some View {
        let folded = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let notes = NoteOrder.edited.sorted(model.notes.notes).filter {
            folded.isEmpty || $0.displayTitle.lowercased().contains(folded) || $0.body.lowercased().contains(folded)
        }
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.callout).foregroundStyle(.tertiary)
                    TextField(L("노트 찾기", "Search notes"), text: $query).textFieldStyle(.plain)
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Capsule().fill(Color.primary.opacity(0.05)))
                Button {
                    open(model.notes.create(paperID: nil).id)
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.borderless)
                .help(L("새 지식 노트", "New Knowledge Note"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            if notes.isEmpty {
                ContentUnavailableView(
                    folded.isEmpty ? L("노트가 없어요", "No Notes") : L("맞는 노트가 없어요", "Nothing Matches"),
                    systemImage: "note.text",
                    description: Text(folded.isEmpty ? L("연필을 눌러 새로 써요.", "Press the pencil to write one.") : "")
                )
                .frame(maxHeight: .infinity)
            } else {
            List {
                ForEach(notes.prefix(200)) { note in
                    Button {
                        open(note.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(note.displayTitle).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                            Text(note.paperID != nil ? L("문헌 노트", "Literature note") : KnowledgeArea.title(note.area))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .draggable(NoteTransfer(id: note.id))
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .hiddenScrollers()
            }
        }
    }
}

// MARK: - A pinned sidebar item

/// One sidebar item, kept where it is whatever the sidebar is on: a shelf's
/// table, a plan, the notes of a place, the projects or one project.
struct PinnedShelf: View {
    let model: LibraryModel
    let link: ReaderLink
    let paneID: UUID
    let key: String
    /// A paper pressed here: the page shows it.
    let openPaper: (UUID) -> Void
    @Environment(AppModel.self) private var app

    var body: some View {
        if let scope = LibraryModel.Scope(paneKey: key), exists(scope) {
            switch scope {
            case .notes, .knowledge:
                SlipBoxList(model: model, pinnedScope: scope) { _ in
                    // The note on the page — which, while the sidebar is on
                    // a shelf, has to be told to show a note.
                    app.showOnPage(.note, model: model)
                    app.ensurePagePane(after: paneID)
                }
            case .projects(nil):
                ProjectList(model: model, pinnedPick: { id in
                    guard let id else { return }
                    app.showOnPage(.project(id), model: model)
                    app.ensurePagePane(after: paneID)
                }, pinnedSelection: { if case let .project(id) = app.pageShowing(model: model) { id } else { nil } }())
            case let .projects(id?):
                VStack(spacing: 0) {
                    PaneHeadBar(symbol: "flag", title: model.project(id)?.name ?? L("프로젝트", "Project"))
                    ProjectPage(model: model, openPaper: openPaper, pinnedID: id)
                }
            default:
                PlanBoard(model: model, shownScope: scope, onOpen: openPaper)
            }
        } else {
            VStack(spacing: 0) {
                PaneHeadBar(symbol: "questionmark.folder", title: L("없는 항목", "Not Found"))
                ContentUnavailableView(L("이 칸이 보이던 것이 없어졌어요", "What This Pane Showed Is Gone"),
                                       systemImage: "questionmark.folder",
                                       description: Text(L("⌄ 메뉴에서 다른 것을 골라주세요.", "Choose something else from the ⌄ menu.")))
                    .frame(maxHeight: .infinity)
            }
        }
    }

    /// A plan or a project deleted, a collection or tag gone.
    private func exists(_ scope: LibraryModel.Scope) -> Bool {
        switch scope {
        case let .plan(id): model.plan(id) != nil
        case let .projects(id?): model.project(id) != nil
        case let .collection(id): model.collections.collections.contains { $0.id == id }
        case let .tag(id): model.manifest.tags.contains { $0.id == id }
        default: true
        }
    }
}

// MARK: - The inspector, floating

/// The inspector as a card over the window: dragged by its head, resized
/// from its corner, kept inside the window — so the panes have its room and
/// it is still one press away (`Workspace`).
struct FloatingInspector<Content: View>: View {
    /// The room it floats in.
    let container: CGSize
    @Binding var inspectorTab: InspectorTab
    let hasPaper: Bool
    @ViewBuilder let content: () -> Content
    @Environment(AppModel.self) private var app
    /// Where it is while a hand moves it; written down when the hand lets go.
    @State private var moving: CGRect?
    @State private var start: CGRect?

    static var size: CGSize { CGSize(width: 340, height: 560) }
    private static var margin: CGFloat { 12 }
    private static var least: CGSize { CGSize(width: 290, height: 300) }

    /// Inside the room, whatever it was asked to be.
    private func kept(_ rect: CGRect) -> CGRect {
        let m = Self.margin
        let width = min(max(rect.width, Self.least.width), max(container.width - m * 2, Self.least.width))
        let height = min(max(rect.height, Self.least.height), max(container.height - m * 2, Self.least.height))
        let x = min(max(rect.minX, m), max(container.width - width - m, m))
        let y = min(max(rect.minY, m), max(container.height - height - m, m))
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// The first place it goes: the right, where it was docked — under the
    /// panes' heads, so the last pane's ⌄ and × stay in reach.
    private var first: CGRect {
        let top: CGFloat = 64
        return CGRect(x: container.width - Self.size.width - Self.margin, y: top,
                      width: Self.size.width, height: min(Self.size.height, container.height - top - Self.margin))
    }

    /// As round as the system's own floating glass (iOS 27's sheets and
    /// the macOS 26 inspector): a sheet of glass, not a box with a border.
    static var corner: CGFloat { 26 }

    var body: some View {
        let frame = kept(moving ?? app.floatingInspectorFrame ?? first)
        let shape = RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
        VStack(spacing: 0) {
            head(frame)
            content()
                // The content sits on the glass, not on a page of its own.
                .scrollContentBackground(.hidden)
        }
        .frame(width: frame.width, height: frame.height)
        // Liquid Glass where the system has it (macOS 26): the real thing,
        // which bends and tints what is behind it — the user asked for the
        // floating inspector to be glass the way iOS 27 is (2026-11-19).
        // Before 26, the material it was.
        .background { FloatingGlass(cornerRadius: Self.corner) }
        .clipShape(shape)
        .overlay(alignment: .bottomTrailing) { grip(frame) }
        .shadow(color: .black.opacity(0.12), radius: 30, y: 12)
        .offset(x: frame.minX, y: frame.minY)
    }

    private func head(_ frame: CGRect) -> some View {
        HStack(spacing: 8) {
            if hasPaper {
                Picker(L("정보 패널", "Inspector"), selection: $inspectorTab) {
                    ForEach(InspectorTab.allCases) { tab in Text(tab.label).tag(tab) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            } else {
                Text(L("정보 패널", "Inspector"))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if #available(macOS 26.0, *) {
                // The system's glass buttons, the ones a floating glass sheet
                // wears on iOS 27: a capsule and a circle of glass.
                Button {
                    app.setInspectorFloats(false)
                } label: {
                    Label(L("붙이기", "Dock"), systemImage: "sidebar.right")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .help(L("창 오른쪽에 붙이기", "Dock at the window’s right"))
                Button {
                    app.hideInspector()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.small)
                .help(L("정보 패널 숨기기", "Hide the Inspector"))
            } else {
                Button {
                    app.setInspectorFloats(false)
                } label: {
                    Text(L("붙이기", "Dock"))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 9)
                        .frame(height: 22)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .pressable(cornerRadius: 11)
                .help(L("창 오른쪽에 붙이기", "Dock at the window’s right"))
                PaneCloseButton { app.hideInspector() }
                    .help(L("정보 패널 숨기기", "Hide the Inspector"))
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .padding(.top, 6)
        .frame(height: 46)
        .contentShape(.rect)
        .gesture(
            DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { value in
                    let from = start ?? frame
                    start = from
                    moving = kept(from.offsetBy(dx: value.translation.width, dy: value.translation.height))
                }
                .onEnded { _ in settle() }
        )
    }

    /// The corner it is resized from.
    private func grip(_ frame: CGRect) -> some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.tertiary)
            .rotationEffect(.degrees(90))
            .frame(width: 18, height: 18)
            .contentShape(.rect)
            .padding(3)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let from = start ?? frame
                        start = from
                        moving = kept(CGRect(x: from.minX, y: from.minY,
                                             width: from.width + value.translation.width,
                                             height: from.height + value.translation.height))
                    }
                    .onEnded { _ in settle() }
            )
            .help(L("끌어서 크기 바꾸기", "Drag to resize"))
    }

    private func settle() {
        if let moving { app.setFloatingInspectorFrame(moving) }
        moving = nil
        start = nil
    }
}

/// The floating inspector's sheet: `NSGlassEffectView` on macOS 26 and
/// later — the system's Liquid Glass, which refracts and tints what is behind
/// it — and the regular material before. (SwiftUI in this SDK has the glass
/// buttons and no `glassEffect`; `LiquidGlass.swift` says why the app's own
/// panes are assembled by hand.)
struct FloatingGlass: NSViewRepresentable {
    /// The size it is given, without asking AppKit. Left to itself SwiftUI
    /// asks an AppKit view for its layout traits on every pass of the
    /// window's layout, and AppKit answers by updating the constraints of
    /// the view's whole subtree — for a table, every row on screen, each
    /// row's SwiftUI body with it. That was most of what a pane opening or
    /// closing cost (2026-11-19, `--papertime-perf`).
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSViewType, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = cornerRadius
            return glass
        }
        let material = NSVisualEffectView()
        material.material = .popover
        material.blendingMode = .withinWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = cornerRadius
        material.layer?.cornerCurve = .continuous
        material.layer?.masksToBounds = true
        return material
    }

    func updateNSView(_ view: NSView, context: Context) {
        if #available(macOS 26.0, *), let glass = view as? NSGlassEffectView {
            glass.cornerRadius = cornerRadius
        }
    }
}

// MARK: - Which pane was pressed

/// Where each pane is in the window, for the press watcher.
@MainActor
final class PaneFrames {
    var frames: [UUID: CGRect] = [:]
}

/// Notes which pane a press landed in — a paper chosen in a pane with no
/// page open opens one to that pane's right. A local monitor: it sees this
/// app's own presses and lets every one of them through.
struct PanePressWatcher: NSViewRepresentable {
    /// The size it is given, without asking AppKit. Left to itself SwiftUI
    /// asks an AppKit view for its layout traits on every pass of the
    /// window's layout, and AppKit answers by updating the constraints of
    /// the view's whole subtree — for a table, every row on screen, each
    /// row's SwiftUI body with it. That was most of what a pane opening or
    /// closing cost (2026-11-19, `--papertime-perf`).
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSViewType, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    let frames: PaneFrames
    let pressed: @MainActor (UUID) -> Void

    func makeNSView(context: Context) -> Watcher {
        let view = Watcher()
        view.frames = frames
        view.pressed = pressed
        return view
    }

    func updateNSView(_ view: Watcher, context: Context) {
        view.frames = frames
        view.pressed = pressed
    }

    final class Watcher: NSView {
        var frames: PaneFrames?
        var pressed: (@MainActor (UUID) -> Void)?
        nonisolated(unsafe) private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, let window = self.window, event.window === window,
                          let root = window.contentView else { return }
                    // SwiftUI's window space: from the top left of the content.
                    let point = root.convert(event.locationInWindow, from: nil)
                    let top = root.isFlipped ? point : NSPoint(x: point.x, y: root.bounds.height - point.y)
                    if let hit = self.frames?.frames.first(where: { $0.value.contains(top) })?.key {
                        self.pressed?(hit)
                    }
                }
                return event
            }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
#endif
