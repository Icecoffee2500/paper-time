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
                }
            }
        } else if model.visiblePapers.isEmpty {
            ContentUnavailableView.search(text: model.searchText)
        } else {
            List(selection: $model.selectedPaperID) {
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
                    PaperRow(paperID: paper.id, model: model)
                        .tag(paper.id)
                }
            }
        }
    }

    private var looseDescription: String {
        let count = model.looseDocuments.count
        let noun = count == 1 ? "PDF" : "PDFs"
        return """
            This folder already holds \(count) \(noun). Adding them files each one \
            into its own folder here, with its bibliographic record beside it. \
            The files stay in this folder — nothing is copied elsewhere or deleted.
            """
    }

}

/// One row in the paper list.
struct PaperRow: View {
    let paperID: UUID
    let model: LibraryModel

    /// Read from the model on every redraw rather than captured once. A row
    /// that holds its own copy of the paper keeps showing stale state after
    /// anything else in the window changes it.
    private var paper: LoadedPaper? {
        model.papers.first { $0.id == paperID }
    }

    var body: some View {
        if let paper {
            row(paper)
        }
    }

    @ViewBuilder
    private func row(_ paper: LoadedPaper) -> some View {
        HStack(alignment: .top, spacing: 8) {
            statusButton(paper)

            VStack(alignment: .leading, spacing: 4) {
                Text(paper.meta.displayTitle)
                    .font(.headline)
                    .lineLimit(2)
                Text(subtitle(paper))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !tags(paper).isEmpty {
                    HStack(spacing: 4) {
                        ForEach(tags(paper)) { tag in
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

            if !model.attachments(of: paper.id).isEmpty {
                Label(
                    "\(model.attachments(of: paper.id).count)",
                    systemImage: "paperclip"
                )
                .labelStyle(.titleAndIcon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Has supplementary material")
            }

            favoriteButton(paper)

            if model.resolving.contains(paper.id) {
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
            guard let dropped = items.first, dropped.id != paper.id else { return false }
            Task { await model.attach(dropped.id, to: paper.id) }
            return true
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
        var parts: [String] = []
        if !paper.meta.displayAuthors.isEmpty { parts.append(paper.meta.displayAuthors) }
        if let year = paper.meta.csl.year { parts.append(String(year)) }
        if let venue = paper.meta.csl.containerTitle, !venue.isEmpty { parts.append(venue) }
        return parts.joined(separator: " · ")
    }

    private func tags(_ paper: LoadedPaper) -> [Tag] {
        paper.meta.tagIDs.compactMap { model.tag(for: $0) }
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
