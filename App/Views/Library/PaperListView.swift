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
            .searchable(text: $model.searchText, prompt: "Search titles, authors, venues")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    sortMenu
                }
            }
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
                    PaperRow(paper: paper, model: model)
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

    private var sortMenu: some View {
        Menu {
            Picker("Sort By", selection: $model.sortOrder) {
                ForEach(LibraryModel.SortOrder.allCases) { order in
                    Text(order.displayName).tag(order)
                }
            }
            Divider()
            Toggle("Ascending", isOn: $model.sortAscending)
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
    }
}

/// One row in the paper list.
struct PaperRow: View {
    let paper: LoadedPaper
    let model: LibraryModel

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(paper.meta.displayTitle)
                    .font(.headline)
                    .lineLimit(2)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
            trailingAccessories
        }
        .contextMenu { contextMenuContent }
    }

    private var subtitle: String {
        var parts: [String] = []
        if !paper.meta.displayAuthors.isEmpty { parts.append(paper.meta.displayAuthors) }
        if let year = paper.meta.csl.year { parts.append(String(year)) }
        if let venue = paper.meta.csl.containerTitle, !venue.isEmpty { parts.append(venue) }
        return parts.joined(separator: " · ")
    }

    private var tags: [Tag] {
        paper.meta.tagIDs.compactMap { model.tag(for: $0) }
    }

    @ViewBuilder
    private var trailingAccessories: some View {
        HStack(spacing: 6) {
            // A button, not a label: the app should never decide on the user's
            // behalf that opening a paper means they are reading it.
            Button {
                Task { await advanceReadingStatus() }
            } label: {
                Image(systemName: paper.state.readingStatus.symbolName)
                    .foregroundStyle(paper.state.readingStatus == .read ? .green : .secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .help("\(readingStatusLabel) — click to change")
            .accessibilityLabel("Reading status: \(readingStatusLabel)")
            .accessibilityHint("Changes to the next status")

            if paper.state.isFavorite {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                    .accessibilityLabel("Favorite")
            }

            if model.resolving.contains(paper.id) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Resolving metadata")
            } else if needsReview {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("Metadata needs review")
                    .accessibilityLabel("Metadata needs review")
            }
        }
        .font(.subheadline)
    }

    private var needsReview: Bool {
        paper.meta.confidence == .needsReview || paper.meta.confidence == .unparsed
    }

    private var readingStatusLabel: String {
        switch paper.state.readingStatus {
        case .unread: "Unread"
        case .reading: "Reading"
        case .read: "Read"
        }
    }

    /// Unread → Reading → Read → Unread.
    private func advanceReadingStatus() async {
        var state = paper.state
        state.readingStatus = switch state.readingStatus {
        case .unread: .reading
        case .reading: .read
        case .read: .unread
        }
        await model.update(state: state, for: paper.id)
    }

    @ViewBuilder
    private var contextMenuContent: some View {
        Button {
            model.selectedPaperID = paper.id
        } label: {
            Label("Open", systemImage: "book")
        }

        Button {
            var state = paper.state
            state.readingStatus = state.readingStatus == .read ? .unread : .read
            Task { await model.update(state: state, for: paper.id) }
        } label: {
            Label(
                paper.state.readingStatus == .read ? "Mark as Unread" : "Mark as Read",
                systemImage: "checkmark.circle"
            )
        }

        Button {
            var state = paper.state
            state.isFavorite.toggle()
            Task { await model.update(state: state, for: paper.id) }
        } label: {
            Label(
                paper.state.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                systemImage: "star"
            )
        }

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
