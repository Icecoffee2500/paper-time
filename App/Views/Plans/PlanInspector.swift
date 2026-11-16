import LibraryStore
import PaperCore
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The paper's place in the plans, and what is kept beside it: two sections
/// at the top of the Info tab.
struct PlanInspectorSections: View {
    let model: LibraryModel
    let paper: LoadedPaper
    @Environment(\.undoManager) private var undoManager
    @State private var showsDay = false
    @State private var linkText = ""
    @State private var message: String?
    @State private var dropping = false

    var body: some View {
        Section(L("계획", "Plan")) {
            LabeledContent(L("읽을 날", "Read On")) {
                let behind = model.isBehind(paper)
                let text = paper.schedule.map { PlanText.full($0) + (behind ? L(" · 밀림", " · Overdue") : "") } ?? L("정하기", "Set Date")
                let style: PlanText.ChipStyle = paper.schedule == nil ? .none : behind ? .behind : paper.schedule == model.today ? .today : .plain
                Button { showsDay = true } label: { DayChipLabel(text: text, style: style) }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showsDay, arrowEdge: .bottom) {
                        DayPicker(today: model.today, current: paper.schedule) { day in
                            showsDay = false
                            setDay(day)
                        }
                    }
            }
            LabeledContent(L("계획", "Plan")) {
                let plans = model.plans(containing: paper.id)
                VStack(alignment: .trailing, spacing: 3) {
                    if plans.isEmpty {
                        Text(L("없음", "None")).foregroundStyle(.tertiary)
                    }
                    ForEach(plans) { plan in
                        Button {
                            model.scope = .plan(plan.id)
                        } label: {
                            Text(plan.name + (plan.section(of: paper.id).map { " · " + $0.name } ?? ""))
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .help(L("이 계획 보기", "Show this plan"))
                    }
                    let others = model.plans.filter { !$0.contains(paper.id) }
                    if !others.isEmpty {
                        Menu(L("계획에 넣기", "Add to Plan")) {
                            ForEach(others) { plan in
                                Button(plan.name) { Task { await model.addToPlan(plan.id, papers: [paper.id]) } }
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .font(.caption)
                    }
                }
            }
            LabeledContent(L("진행", "Progress")) {
                ProgressCell(fraction: model.progress(of: paper), page: paper.state.lastPageIndex > 0 ? paper.state.lastPageIndex + 1 : 0,
                             pages: paper.meta.file.pageCount, isRead: paper.state.readingStatus == .read)
            }
        }

        Section {
            if let address = model.paperLink(of: paper) {
                MaterialRow(kind: .paper, title: MaterialLink.title(ofAddress: address),
                            detail: L("논문 · 서지에서 저절로", "Paper · From the record"),
                            open: { open(address: address) }, remove: nil, rename: nil, reveal: nil)
            }
            ForEach(paper.links) { link in
                MaterialRow(
                    kind: link.kind, title: link.displayTitle, detail: detail(of: link),
                    open: { open(link) },
                    remove: { Task { await model.removeLink(link.id, from: paper.id) } },
                    rename: { Task { await rename(link) } },
                    reveal: link.file == nil ? nil : { reveal(link) }
                )
            }
            HStack(spacing: 7) {
                Image(systemName: "link").foregroundStyle(.tertiary)
                TextField(L("주소를 붙여넣어요", "Paste a link"), text: $linkText)
                    .textFieldStyle(.plain)
                    .onSubmit { Task { await addLink() } }
            }
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(Capsule().fill(Color.primary.opacity(0.05)))
            if let line = detection {
                HStack(spacing: 6) {
                    if let kind = detectedKind { KindTile(kind: kind, width: 22, height: 20) }
                    Text(line).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(L("자료", "Materials"))
        } footer: {
            Text(L("파일을 여기로 끌어다 놓으면 PDF 옆에 복사해서 붙여요.", "Drop files here to copy them beside the PDF."))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            Task {
                let count = await model.attachFiles(files, to: paper.id)
                message = count > 0 ? L("파일 \(count)개를 붙였어요.", count == 1 ? "Added 1 file." : "Added \(count) files.") : nil
            }
            return true
        }
    }

    private var detectedKind: MaterialKind? {
        MaterialLink.address(linkText).map(MaterialLink.kind(ofAddress:))
    }

    private var detection: String? {
        if let message, linkText.isEmpty { return message }
        let text = linkText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        guard let kind = detectedKind else { return L("주소가 아니에요", "That isn't an address") }
        return kind.detected + L(" · Enter로 붙여요", " · Press Return to add")
    }

    private func detail(of link: PaperMaterial) -> String {
        if link.file != nil { return link.kind.name + L(" · 파일 · PDF 옆에 있어요", " · File beside the PDF") }
        return link.kind.name + " · " + MaterialLink.host(of: link.url ?? "")
    }

    private func addLink() async {
        switch await model.addLink(linkText, to: paper.id) {
        case let .added(kind):
            linkText = ""
            message = kind.added
        case .notAnAddress:
            message = nil
        case .failed:
            message = L("붙이지 못했어요.", "Couldn't add it.")
        }
    }

    private func setDay(_ day: PlanDay?) {
        Task { @MainActor in
            let before = await model.setDays([paper.id: day])
            guard let undoManager else { return }
            undoManager.registerUndo(withTarget: model) { model in
                MainActor.assumeIsolated { _ = Task { await model.setDays(before) } }
            }
            undoManager.setActionName(L("날짜 바꾸기", "Change Day"))
        }
    }

    private func open(_ link: PaperMaterial) {
        #if os(macOS)
        model.open(link, of: paper)
        #endif
    }

    private func open(address: String) {
        #if os(macOS)
        model.openAddress(address)
        #endif
    }

    private func reveal(_ link: PaperMaterial) {
        #if os(macOS)
        if let url = model.materialURL(link, of: paper) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        #endif
    }

    private func rename(_ link: PaperMaterial) async {
        #if os(macOS)
        guard let name = await Ask.text(title: L("자료 이름 바꾸기", "Rename Material"), message: nil,
                                        placeholder: link.displayTitle, initial: link.title ?? "") else { return }
        await model.renameLink(link.id, of: paper.id, to: name)
        #endif
    }
}

/// One material: a tinted tile, its name, what and where it is.
struct MaterialRow: View {
    let kind: MaterialKind
    let title: String
    let detail: String
    let open: () -> Void
    let remove: (() -> Void)?
    let rename: (() -> Void)?
    let reveal: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            KindTile(kind: kind, width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let remove {
                Button(action: remove) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .opacity(hovering ? 1 : 0)
                .help(L("빼기", "Remove"))
                .accessibilityLabel(L("자료 빼기", "Remove Material"))
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
        .help(L("눌러서 열기", "Click to open"))
        .contextMenu {
            Button(L("열기", "Open"), action: open)
            if let reveal { Button(L("Finder에서 보기", "Show in Finder"), action: reveal) }
            if let rename { Button(L("이름 바꾸기…", "Rename…"), action: rename) }
            if let remove {
                Divider()
                Button(L("빼기", "Remove"), role: .destructive, action: remove)
            }
        }
    }
}

/// The materials list as the inspector shows it, outside a form — for
/// `ImageRenderer`, which draws a form empty (`PlanProbe`).
struct MaterialsPreview: View {
    let model: LibraryModel
    let paper: LoadedPaper

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("자료", "Materials")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
            if let address = model.paperLink(of: paper) {
                MaterialRow(kind: .paper, title: MaterialLink.title(ofAddress: address),
                            detail: L("논문 · 서지에서 저절로", "Paper · From the record"),
                            open: {}, remove: nil, rename: nil, reveal: nil)
            }
            ForEach(paper.links) { link in
                MaterialRow(kind: link.kind, title: link.displayTitle,
                            detail: link.kind.name + " · " + MaterialLink.host(of: link.url ?? ""),
                            open: {}, remove: {}, rename: nil, reveal: nil)
            }
            HStack(spacing: 7) {
                Image(systemName: "link").foregroundStyle(.tertiary)
                Text("youtube.com/watch?v=cql-talk").font(.system(size: 12.5))
                Spacer()
            }
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(Capsule().fill(Color.primary.opacity(0.05)))
            HStack(spacing: 6) {
                KindTile(kind: .video, width: 22, height: 20)
                Text(MaterialKind.video.detected + L(" · Enter로 붙여요", " · Press Return to add"))
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        }
    }
}
