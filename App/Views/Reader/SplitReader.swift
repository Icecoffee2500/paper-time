#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers

/// Several papers in the page area at once — two halves, or up to four
/// quarters — each a reader of its own, the way a Mac tiles windows dragged
/// to the edges of the screen.
///
/// The pane in focus is the paper the window is "about": the inspector, the
/// notes and the toolbar act on it, and it borrows the window's own reader
/// handle to make that so. Clicking in a pane focuses it.
struct SplitReaderView: View {
    let model: LibraryModel
    let configuration: ReaderConfiguration
    /// The window's handle, held by the pane in focus.
    let link: ReaderLink
    let arrangement: SplitArrangement
    @Environment(AppModel.self) private var app

    private static let gap: CGFloat = 8

    var body: some View {
        HStack(spacing: Self.gap) {
            column(arrangement.left)
            if let right = arrangement.right { column(right) }
        }
        .padding(Self.gap)
    }

    private func column(_ column: SplitArrangement.Column) -> some View {
        VStack(spacing: Self.gap) {
            // Keyed by the pane, not the paper: two panes of one paper are
            // two readers, each with its own place in the document.
            pane(column.top).id(column.top.id)
            if let bottom = column.bottom { pane(bottom).id(bottom.id) }
        }
    }

    @ViewBuilder
    private func pane(_ pane: SplitArrangement.Pane) -> some View {
        if let paper = model.paper(pane.paper) {
            let id = pane.paper
            let focused = app.focusedPane(in: arrangement, model: model)?.id == pane.id
            let handle = focused ? link : app.paneLink(for: pane.id)
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Text(paper.meta.displayTitle)
                        .font(.subheadline.weight(focused ? .semibold : .regular))
                        .foregroundStyle(focused ? .primary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    Button {
                        // The paper closes with its last pane; a paper in
                        // two panes stays open in the other.
                        app.closePane(pane, model: model)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.borderless)
                    .help(L("닫기", "Close"))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(.rect)
                .onTapGesture { app.focus(pane, model: model) }
                // The title is the handle: drag it to another zone to move
                // the pane there (the pane's id says it is a move, not a
                // second pane of the paper).
                .draggable(PaperTransfer(id: id, title: paper.meta.displayTitle, pane: pane.id))

                ReaderScreen(library: model, paper: paper, configuration: configuration, link: handle)
                    .onAppear {
                        handle.activated = { app.focus(pane, model: model); model.keepOpen(id) }
                    }
                    .onChange(of: ObjectIdentifier(handle)) { _, _ in
                        handle.activated = { app.focus(pane, model: model); model.keepOpen(id) }
                    }
            }
            .clipShape(RoundedRectangle(cornerRadius: Corner.popover, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Corner.popover, style: .continuous)
                    .strokeBorder(focused ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.08), lineWidth: focused ? 1.5 : 0.5)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(DockDropDelegate.space)) } action: { frame in
                app.splitPaneFrames[pane.id] = frame
            }
        }
    }
}

/// ⌘W, while papers are side by side: closes the pane in focus and leaves
/// the window standing. With one pane left the key goes on to the window,
/// which closes as it always did. A local monitor rather than a menu
/// command, so the File menu's own Close keeps its place and its key.
struct ClosePaneShortcut: NSViewRepresentable {
    /// The size it is given, without asking AppKit. Left to itself SwiftUI
    /// asks an AppKit view for its layout traits on every pass of the
    /// window's layout, and AppKit answers by updating the constraints of
    /// the view's whole subtree — for a table, every row on screen, each
    /// row's SwiftUI body with it. That was most of what a pane opening or
    /// closing cost (2026-11-19, `--papertime-perf`).
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSViewType, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    /// Closes the focused pane; true when there was one to close.
    let close: () -> Bool

    func makeNSView(context: Context) -> Catcher {
        let catcher = Catcher()
        catcher.close = close
        return catcher
    }

    func updateNSView(_ view: Catcher, context: Context) { view.close = close }

    final class Catcher: NSView {
        var close: (() -> Bool)?
        nonisolated(unsafe) private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                      event.charactersIgnoringModifiers?.lowercased() == "w"
                else { return event }
                return (self.close?() ?? false) ? nil : event
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

/// Where the dragged paper would go, drawn over the page area while it is
/// being dragged: the half or the quarter lights up.
/// Where a dragged paper would land on the page.
enum DockTarget: Equatable {
    /// A new pane at an edge of the page.
    case zone(DockZone)
    /// In place of a pane's paper — the one reader when nothing stands side
    /// by side (nil).
    case open(UUID?)
}

/// Where the dragged paper would go, drawn over the page area while it is
/// being dragged: a half or a quarter for a new pane, or the pane it would
/// replace.
struct DockZoneOverlay: View {
    let target: DockTarget?
    /// The side-by-side panes' frames in the page's space.
    var frames: [UUID: CGRect] = [:]

    var body: some View {
        GeometryReader { proxy in
            switch target {
            case let .zone(zone)?:
                let rect = Self.rect(for: zone, in: proxy.size)
                RoundedRectangle(cornerRadius: Corner.popover, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: Corner.popover, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 2)
                    )
                    .overlay { label(zone == .left || zone == .topLeft || zone == .bottomLeft
                                     ? L("왼쪽에 나란히", "Side by Side on the Left") : L("오른쪽에 나란히", "Side by Side on the Right")) }
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .animation(Motion.tap, value: zone)
            case let .open(pane)?:
                let w = proxy.size.width, h = proxy.size.height
                let rect = pane.flatMap { frames[$0] }?.insetBy(dx: 6, dy: 6)
                    ?? CGRect(x: w * 0.3 + 4, y: 8, width: w * 0.4 - 8, height: h - 16)
                RoundedRectangle(cornerRadius: Corner.popover, style: .continuous)
                    .fill(Color.accentColor.opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: Corner.popover, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    )
                    .overlay { label(pane == nil ? L("여기에 열기", "Open Here") : L("이 칸에 열기", "Open in This Pane")) }
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            case nil:
                EmptyView()
            }
        }
        .allowsHitTesting(false)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
    }

    static func rect(for zone: DockZone, in size: CGSize) -> CGRect {
        let inset: CGFloat = 8
        let w = size.width, h = size.height
        switch zone {
        case .left: return CGRect(x: inset, y: inset, width: w / 2 - inset * 1.5, height: h - inset * 2)
        case .right: return CGRect(x: w / 2 + inset / 2, y: inset, width: w / 2 - inset * 1.5, height: h - inset * 2)
        case .topLeft: return CGRect(x: inset, y: inset, width: w / 2 - inset * 1.5, height: h / 2 - inset * 1.5)
        case .topRight: return CGRect(x: w / 2 + inset / 2, y: inset, width: w / 2 - inset * 1.5, height: h / 2 - inset * 1.5)
        case .bottomLeft: return CGRect(x: inset, y: h / 2 + inset / 2, width: w / 2 - inset * 1.5, height: h / 2 - inset * 1.5)
        case .bottomRight: return CGRect(x: w / 2 + inset / 2, y: h / 2 + inset / 2, width: w / 2 - inset * 1.5, height: h / 2 - inset * 1.5)
        }
    }

    /// The zone a point in the page area asks for: the outer quarter of the
    /// width on either side, split into a top, a middle and a bottom. The
    /// middle half of the width is no zone — a drop there does nothing, so a
    /// drag that wanders over the page does not rearrange it.
    static func zone(at point: CGPoint, in size: CGSize) -> DockZone? {
        guard size.width > 0, size.height > 0 else { return nil }
        let fx = point.x / size.width, fy = point.y / size.height
        let onLeft = fx < 0.3, onRight = fx > 0.7
        guard onLeft || onRight else { return nil }
        if fy < 0.33 { return onLeft ? .topLeft : .topRight }
        if fy > 0.67 { return onLeft ? .bottomLeft : .bottomRight }
        return onLeft ? .left : .right
    }
}

/// Takes a dragged paper and reads where over the page it is.
struct DockDropDelegate: DropDelegate {
    /// The page's coordinate space, where the panes' frames and the drop's
    /// location are both read.
    static let space = "paperTimePage"

    let size: () -> CGSize
    let arrangement: () -> SplitArrangement?
    let frames: () -> [UUID: CGRect]
    @Binding var target: DockTarget?
    /// A paper put at an edge — a new pane.
    let drop: (PaperTransfer, DockZone) -> Void
    /// A paper put on a pane — in place of its paper (nil: the one reader).
    let open: (PaperTransfer, UUID?) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.paperTimePaper])
    }

    func dropEntered(info: DropInfo) { target = aim(info.location) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        target = aim(info.location)
        // `.copy`, never `.move`: AppKit refuses an answer the drag's source
        // did not allow, and a SwiftUI `.draggable` source is not known to
        // allow a move (`SidebarDrops.operation(allowedBy:)`).
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) { target = nil }

    func performDrop(info: DropInfo) -> Bool {
        let landing = aim(info.location)
        target = nil
        guard let landing, let provider = info.itemProviders(for: [.paperTimePaper]).first else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.paperTimePaper.identifier) { data, _ in
            guard let data, let transfer = try? JSONDecoder().decode(PaperTransfer.self, from: data) else { return }
            Task { @MainActor in
                switch landing {
                case let .zone(zone): drop(transfer, zone)
                case let .open(pane): open(transfer, pane)
                }
            }
        }
        return true
    }

    private func aim(_ point: CGPoint) -> DockTarget? {
        Self.target(at: point, in: size(), arrangement: arrangement(), frames: frames())
    }

    /// One reader: the outer three tenths on either side make a new pane,
    /// the rest opens here. Side by side: a thin strip at either outer edge
    /// adds a pane (while there are fewer than four), and anywhere else is
    /// the pane under the pointer — its paper is replaced.
    static func target(at point: CGPoint, in size: CGSize, arrangement: SplitArrangement?, frames: [UUID: CGRect]) -> DockTarget? {
        guard size.width > 0, size.height > 0 else { return nil }
        guard let arrangement else {
            if let zone = DockZoneOverlay.zone(at: point, in: size) { return .zone(zone) }
            return .open(nil)
        }
        let fx = point.x / size.width, fy = point.y / size.height
        if arrangement.panes.count < 4, fx < 0.1 || fx > 0.9 {
            let left = fx < 0.1
            if fy < 0.33 { return .zone(left ? .topLeft : .topRight) }
            if fy > 0.67 { return .zone(left ? .bottomLeft : .bottomRight) }
            return .zone(left ? .left : .right)
        }
        let shown = arrangement.panes.compactMap { pane in frames[pane.id].map { (pane.id, $0) } }
        if let hit = shown.first(where: { $0.1.contains(point) }) { return .open(hit.0) }
        // In a gap between panes: the nearest.
        func distance(_ rect: CGRect) -> CGFloat {
            let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
            let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
            return dx * dx + dy * dy
        }
        return shown.min { distance($0.1) < distance($1.1) }.map { .open($0.0) } ?? .open(arrangement.panes.first?.id)
    }
}
#endif
