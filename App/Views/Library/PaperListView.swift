import LibraryStore
import PaperCore
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The middle column: every paper in the current scope, searchable and sortable.
struct PaperListView: View {
    @Bindable var model: LibraryModel
    @Environment(AppModel.self) private var app

    var body: some View {
        content
            .dropDestination(for: URL.self) { urls, _ in
                let pdfURLs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
                guard !pdfURLs.isEmpty else { return false }
                Task { await model.importDocuments(at: pdfURLs) }
                return true
            }
    }

    @ViewBuilder
    private var content: some View {
        if model.papers.isEmpty {
            if model.looseDocuments.isEmpty {
                ContentUnavailableView(
                    "No Papers Yet",
                    systemImage: "doc.badge.plus",
                    description: Text("Drag PDFs here, or use Add PDFs to build your library.")
                )
            } else {
                // Pointing the app at a folder that already holds PDFs is the
                // obvious thing to do; landing on an empty library after doing
                // it is not.
                ContentUnavailableView {
                    Label("Papers Found in This Folder", systemImage: "tray.and.arrow.down")
                } description: {
                    Text(looseDescription)
                } actions: {
                    Button("Add \(model.looseDocuments.count) PDFs") {
                        Task { await model.adoptLooseDocuments() }
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                }
            }
        } else if model.visiblePapers.isEmpty {
            ContentUnavailableView.search(text: model.searchText)
        } else {
            List(selection: $model.selection) {
                if !model.looseDocuments.isEmpty {
                    Section {
                        Button {
                            Task { await model.adoptLooseDocuments() }
                        } label: {
                            Label(
                                "Add \(model.looseDocuments.count) more PDFs from this folder",
                                systemImage: "tray.and.arrow.down"
                            )
                        }
                    }
                }
                ForEach(model.visiblePapers) { paper in
                    PaperRow(
                        paper: paper,
                        tags: paper.meta.tagIDs.compactMap { model.tag(for: $0) },
                        attachmentCount: model.attachmentCount(of: paper.id),
                        isResolving: model.resolving.contains(paper.id),
                        subtitleFields: SubtitleField.parse(app.settings.listSubtitleFields),
                        model: model
                    )
                    .tag(paper.id)
                    #if os(iOS)
                    // A `Set` selection only takes taps in edit mode on
                    // iOS, so the row opens the paper itself.
                    .contentShape(.rect)
                    .onTapGesture {
                        model.selection = [paper.id]
                        app.compactColumn = .detail
                    }
                    #endif
                }
            }
            // The same list style as the source list, so a selected paper and
            // a selected scope are drawn with one shape rather than two.
            #if os(macOS)
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            #endif
            .hiddenScrollers()
            // Pulled down past its top, the list opens the search — the
            // way a Home Screen does, and with a trackpad the way an
            // overscroll does. The gesture that says "give me something"
            // gets the field that gives everything.
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top < -72
            } action: { _, pulled in
                guard pulled, !app.showsSearchPalette else { return }
                app.showsSearchPalette = true
            }
        }
    }

    private var looseDescription: String {
        let count = model.looseDocuments.count
        let noun = count == 1 ? "PDF" : "PDFs"
        return """
            This folder already holds \(count) \(noun). Adding them looks each one \
            up and gives it a record. The PDFs are not moved, renamed or copied — \
            they stay exactly where they are.
            """
    }

}

/// One row in the paper list.
///
/// Everything it draws arrives as a value, and it is `Equatable`, so changing
/// one paper redraws one row. Reading the model from inside the row made all
/// of them depend on the whole library: resolving metadata for a fresh import
/// rebuilt every row in the list, twice per paper.
struct PaperRow: View, Equatable {
    let paper: LoadedPaper
    let tags: [Tag]
    let attachmentCount: Int
    let isResolving: Bool
    let subtitleFields: [SubtitleField]
    /// Actions only; never read for display.
    let model: LibraryModel

    nonisolated static func == (lhs: PaperRow, rhs: PaperRow) -> Bool {
        lhs.paper == rhs.paper
            && lhs.tags == rhs.tags
            && lhs.attachmentCount == rhs.attachmentCount
            && lhs.isResolving == rhs.isResolving
            && lhs.subtitleFields == rhs.subtitleFields
    }

    /// Whether the supplement popover is open for this row.
    @State private var showsAttachments = false

    var body: some View {
        row(paper)
    }

    @ViewBuilder
    private func row(_ paper: LoadedPaper) -> some View {
        HStack(alignment: .top, spacing: 8) {
            statusButton(paper)

            VStack(alignment: .leading, spacing: 4) {
                Text(paper.meta.displayTitle)
                    .font(.headline)
                    .lineLimit(2)
                let subtitle = subtitle(paper)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(tags) { tag in
                            Text(tag.name)
                                .font(.footnote)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(tag.color.swiftUIColor.opacity(0.18), in: Capsule())
                                .foregroundStyle(tag.color.swiftUIColor)
                        }
                    }
                }
            }

            Spacer(minLength: 8)

            attachmentsButton(paper)

            favoriteButton(paper)

            if isResolving {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Resolving metadata")
            } else if needsReview(paper) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("Metadata needs review")
                    .accessibilityLabel("Metadata needs review")
            }
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
        .contextMenu { contextMenuContent(paper) }
        // Dragging a paper onto a sidebar row files it there; dropping one
        // paper onto another attaches it as supplementary material.
        .draggable(PaperTransfer(id: paper.id, title: paper.meta.displayTitle))
        .dropDestination(for: PaperTransfer.self) { items, _ in
            guard let dropped = items.first else { return false }
            let ids = model.draggedPapers(startingAt: dropped.id).filter { $0 != paper.id }
            guard !ids.isEmpty else { return false }
            Task { for id in ids { await model.attach(id, to: paper.id) } }
            return true
        }
    }

    /// The paperclip: how many supplements a paper has, and a way into them.
    ///
    /// A badge alone told the reader that something existed and gave them no
    /// way to reach it. This is a button, and it opens the list.
    @ViewBuilder
    private func attachmentsButton(_ paper: LoadedPaper) -> some View {
        if attachmentCount > 0 {
            Button {
                showsAttachments = true
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "paperclip")
                    Text("\(attachmentCount)")
                        .monospacedDigit()
                }
                .font(.caption)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .help("Supplementary material")
            .accessibilityLabel("\(attachmentCount) supplementary files")
            .popover(isPresented: $showsAttachments, arrowEdge: .bottom) {
                AttachmentPopover(
                    parent: paper,
                    attachments: model.attachments(of: paper.id),
                    model: model,
                    isPresented: $showsAttachments
                )
            }
        }
    }

    /// A menu, not a cycling button: three states in a fixed order means two
    /// wrong guesses before the right one, and no way to see what the options
    /// were.
    @ViewBuilder
    private func statusButton(_ paper: LoadedPaper) -> some View {
        Menu {
            Picker("Reading Status", selection: statusBinding(paper)) {
                ForEach(PaperState.ReadingStatus.allCases, id: \.self) { status in
                    Label(label(for: status), systemImage: status.symbolName)
                        .tag(status)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: paper.state.readingStatus.symbolName)
                .foregroundStyle(paper.state.readingStatus == .read ? .green : .secondary)
                .contentTransition(.symbolEffect(.replace))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Reading status: \(label(for: paper.state.readingStatus))")
        .accessibilityLabel("Reading status: \(label(for: paper.state.readingStatus))")
    }

    private func statusBinding(_ paper: LoadedPaper) -> Binding<PaperState.ReadingStatus> {
        Binding(
            get: { paper.state.readingStatus },
            set: { newValue in
                Task { await model.setReadingStatus(newValue, for: paper.id) }
            }
        )
    }

    @ViewBuilder
    private func favoriteButton(_ paper: LoadedPaper) -> some View {
        Button {
            Task { await model.toggleFavorite(for: paper.id) }
        } label: {
            Image(systemName: paper.state.isFavorite ? "star.fill" : "star")
                .foregroundStyle(paper.state.isFavorite ? AnyShapeStyle(.yellow) : AnyShapeStyle(.tertiary))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .help(paper.state.isFavorite ? "Remove from Favorites" : "Add to Favorites")
        .accessibilityLabel(paper.state.isFavorite ? "Favorite" : "Not a favorite")
        .accessibilityAddTraits(paper.state.isFavorite ? [.isSelected] : [])
    }

    private func subtitle(_ paper: LoadedPaper) -> String {
        subtitleFields.compactMap { $0.value(for: paper) }.joined(separator: " · ")
    }

    private func needsReview(_ paper: LoadedPaper) -> Bool {
        paper.meta.confidence == .needsReview || paper.meta.confidence == .unparsed
    }

    private func label(for status: PaperState.ReadingStatus) -> String {
        switch status {
        case .unread: "Unread"
        case .reading: "Reading"
        case .read: "Read"
        }
    }

    @ViewBuilder
    private func contextMenuContent(_ paper: LoadedPaper) -> some View {
        Button {
            model.selectedPaperID = paper.id
        } label: {
            Label("Open", systemImage: "book")
        }

        Picker("Reading Status", selection: statusBinding(paper)) {
            ForEach(PaperState.ReadingStatus.allCases, id: \.self) { status in
                Label(label(for: status), systemImage: status.symbolName).tag(status)
            }
        }

        Button {
            Task { await model.toggleFavorite(for: paper.id) }
        } label: {
            Label(
                paper.state.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                systemImage: paper.state.isFavorite ? "star.slash" : "star"
            )
        }

        Menu("Attach To") {
            ForEach(model.attachmentCandidates(for: paper.id).prefix(30)) { candidate in
                Button(candidate.meta.displayTitle) {
                    Task { await model.attach(paper.id, to: candidate.id) }
                }
            }
        }
        .disabled(
            paper.meta.parentID != nil
                || !model.attachments(of: paper.id).isEmpty
                || model.attachmentCandidates(for: paper.id).isEmpty
        )

        if paper.meta.parentID != nil {
            Button {
                Task { await model.detach(paper.id) }
            } label: {
                Label("Detach from Paper", systemImage: "paperclip.badge.ellipsis")
            }
        }

        Divider()

        Button {
            copyToPasteboard(paper.meta.bibKey)
        } label: {
            Label("Copy BibTeX Key", systemImage: "doc.on.doc")
        }

        #if os(macOS)
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([paper.documentURL])
        } label: {
            Label("Reveal in Finder", systemImage: "folder")
        }
        #endif

        Button {
            Task { await model.resolveMetadata(for: paper.id) }
        } label: {
            Label("Re-run Metadata", systemImage: "arrow.triangle.2.circlepath")
        }

        Divider()

        Button(role: .destructive) {
            Task { await model.moveToTrash(paper.id) }
        } label: {
            Label("Move to Trash", systemImage: "trash")
        }
    }

    private func copyToPasteboard(_ string: String) {
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
        #else
        UIPasteboard.general.string = string
        #endif
    }
}

/// The supplements attached to one paper.
///
/// Opening one puts it in the reader, which is the whole point of attaching it:
/// a supplement you cannot read is a supplement you have lost.
private struct AttachmentPopover: View {
    let parent: LoadedPaper
    let attachments: [LoadedPaper]
    let model: LibraryModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Supplementary Material")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)

            Divider()

            ForEach(attachments) { attachment in
                Button {
                    model.selectedPaperID = attachment.id
                    isPresented = false
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(attachment.meta.displayTitle)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Text(attachment.meta.file.originalName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if model.selectedPaperID == attachment.id {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                    .contentShape(.rect)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button {
                        Task { await model.detach(attachment.id) }
                        isPresented = false
                    } label: {
                        Label("Detach from Paper", systemImage: "paperclip.badge.ellipsis")
                    }
                }
            }

            Divider()

            Button {
                model.selectedPaperID = parent.id
                isPresented = false
            } label: {
                Label("Back to the Paper", systemImage: "arrow.uturn.backward")
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 6)
        }
        .frame(width: 300)
    }
}
