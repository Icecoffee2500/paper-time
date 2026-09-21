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
            pane(column.top)
            if let bottom = column.bottom { pane(bottom) }
        }
    }

    @ViewBuilder
    private func pane(_ id: UUID) -> some View {
        if let paper = model.paper(id) {
            let focused = model.selectedPaperID == id
            let handle = focused ? link : app.paneLink(for: id)
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Text(paper.meta.displayTitle)
                        .font(.subheadline.weight(focused ? .semibold : .regular))
                        .foregroundStyle(focused ? .primary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    Button {
                        app.undock(id, model: model)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.borderless)
                    .help(L("이 칸 닫기", "Close This Pane"))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(.rect)
                .onTapGesture { model.selectedPaperID = id }
                // The title is the handle: drag it to another zone to move
                // the pane there.
                .draggable(PaperTransfer(id: id, title: paper.meta.displayTitle))

                ReaderScreen(library: model, paper: paper, configuration: configuration, link: handle)
                    .onAppear {
                        handle.activated = { model.selectedPaperID = id }
                    }
                    .onChange(of: ObjectIdentifier(handle)) { _, _ in
                        handle.activated = { model.selectedPaperID = id }
                    }
            }
            .clipShape(RoundedRectangle(cornerRadius: Corner.popover, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Corner.popover, style: .continuous)
                    .strokeBorder(focused ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.08), lineWidth: focused ? 1.5 : 0.5)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Where the dragged paper would go, drawn over the page area while it is
/// being dragged: the half or the quarter lights up.
struct DockZoneOverlay: View {
    let zone: DockZone?
    let size: CGSize

    var body: some View {
        GeometryReader { proxy in
            if let zone {
                let rect = Self.rect(for: zone, in: proxy.size)
                RoundedRectangle(cornerRadius: Corner.popover, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: Corner.popover, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 2)
                    )
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .animation(.snappy(duration: 0.15), value: zone)
            }
        }
        .allowsHitTesting(false)
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
    let size: () -> CGSize
    @Binding var zone: DockZone?
    let drop: (UUID, DockZone) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.paperTimePaper])
    }

    func dropEntered(info: DropInfo) {
        zone = DockZoneOverlay.zone(at: info.location, in: size())
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        zone = DockZoneOverlay.zone(at: info.location, in: size())
        return DropProposal(operation: zone == nil ? .forbidden : .move)
    }

    func dropExited(info: DropInfo) {
        zone = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        let target = DockZoneOverlay.zone(at: info.location, in: size())
        zone = nil
        guard let target, let provider = info.itemProviders(for: [.paperTimePaper]).first else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.paperTimePaper.identifier) { data, _ in
            guard let data, let transfer = try? JSONDecoder().decode(PaperTransfer.self, from: data) else { return }
            Task { @MainActor in drop(transfer.id, target) }
        }
        return true
    }
}
#endif
