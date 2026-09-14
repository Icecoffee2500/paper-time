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
    /// The open paper, so a result found in the text of another one can send
    /// the reader to the line it was found on.
    let link: ReaderLink
    @Environment(AppModel.self) private var app
    /// How far past its top the list has been pulled.
    ///
    /// How far, not merely whether: the words have to come in with the pull,
    /// or they are one more thing that appears without being asked for.
    @State private var pull: CGFloat = 0
    /// What the same query turned up inside the papers, when the list is
    /// showing the results of a search.
    @State private var passages: [PaperTextIndex.Hit] = []
    @State private var scanning = false

    var body: some View {
        content
            // Here rather than on the list: with nothing matching by title
            // the list is not on screen at all, and that is exactly the
            // search whose answer is inside the papers.
            .task(id: searchKey) { await scanText() }
            .dropDestination(for: URL.self) { urls, _ in
                let pdfURLs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
                guard !pdfURLs.isEmpty else { return false }
                Task { await model.importDocuments(at: pdfURLs) }
                return true
            }
    }

    /// What an empty shelf says. Each one is empty for its own reason, and
    /// the reason is what tells you whether anything is wrong — nothing is,
    /// in every case here.
    private var emptyShelf: (title: String, symbol: String, note: String) {
        switch model.scope {
        case .unread:
            ("Nothing Unread", "circle", "Every paper in the library has been opened.")
        case .reading:
            ("Nothing Being Read", "circle.lefthalf.filled", "Set a paper's status to Reading and it will wait for you here.")
        case .read:
            ("Nothing Read Yet", "checkmark.circle", "Papers you mark as Read gather here.")
        case .favorites:
            ("No Favorites", "star", "Star a paper and it will be here whenever you want it.")
        case .needsReview:
            ("Nothing to Review", "exclamationmark.triangle", "No paper's details are in doubt.")
        case .collection:
            ("This Collection Is Empty", "folder", "Drag papers onto it in the sidebar to put them in.")
        case .tag:
            ("Nothing With This Tag", "tag", "Tag a paper and it will appear here.")
        case .author:
            ("Nothing by This Author", "person", "No paper in the library carries this name.")
        default:
            ("Nothing Here", "tray", "This shelf is empty.")
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
        } else if model.visiblePapers.isEmpty, !hasPassages {
            // An empty shelf is not a failed search. "Check the spelling"
            // in front of Favorites, which nothing has been starred into
            // yet, reads as though the app has lost something.
            if !model.searchText.isEmpty || model.scope == .searchResults {
                ContentUnavailableView.search(text: model.searchText)
            } else {
                ContentUnavailableView {
                    Label(emptyShelf.title, systemImage: emptyShelf.symbol)
                } description: {
                    Text(emptyShelf.note)
                }
            }
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
                Section {
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
                } header: {
                    // Only while a search is being shown. Everywhere else the
                    // list is one list and a heading over it would be a label
                    // on a thing that has no counterpart.
                    if hasPassages, !model.visiblePapers.isEmpty {
                        Text("In the Titles")
                    }
                }

                if hasPassages {
                    Section("In the Papers") {
                        ForEach(passages, id: \.passage) { hit in
                            passageRow(hit)
                        }
                        if scanning {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Reading the papers…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
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
            //
            // It used to happen without warning: the list sprang back and a
            // palette was suddenly there, and nothing had said it would be.
            // Now the pull uncovers the words for it, and going past them is
            // what opens it — so the gesture is something you can stop doing.
            .overlay(alignment: .top) { pullHint }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                -(geometry.contentOffset.y + geometry.contentInsets.top)
            } action: { _, distance in
                pull = distance
                guard distance > Self.pullThreshold, !app.showsSearchPalette else { return }
                app.showsSearchPalette = true
            }
        }
    }

    /// What the text search answers to: the query, and only while the list is
    /// showing a search at all.
    private var searchKey: String { isSearch ? model.searchQuery : "" }

    private var isSearch: Bool { model.scope == .searchResults }
    /// Whether the text of the papers has something to say about this search.
    private var hasPassages: Bool { isSearch && (scanning || !passages.isEmpty) }

    /// One paper whose *text* holds the query: the sentence it is in, and
    /// where. Pressing it opens the paper at that line rather than at the
    /// page it was left on.
    private func passageRow(_ hit: PaperTextIndex.Hit) -> some View {
        Button {
            openPassage(hit.passage, in: model, link: link)
            #if os(iOS)
            app.compactColumn = .detail
            #endif
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "text.magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.tint)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(hit.snippet)
                        .font(.callout)
                        .lineLimit(2)
                    Text(passageSubtitle(hit))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 2)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func passageSubtitle(_ hit: PaperTextIndex.Hit) -> String {
        let page = ReleaseNotes.string("\(hit.passage.pageIndex + 1)쪽",
                                       "p. \(hit.passage.pageIndex + 1)")
        let more = hit.count > 1
            ? ReleaseNotes.string(" · \(hit.count)번", " · \(hit.count) matches") : ""
        return "\(hit.title) · \(page)\(more)"
    }

    /// Reads the library for the words the search was made of.
    ///
    /// The same work the palette does, kept when the palette is dismissed:
    /// pressing Return on a search should not throw away the half of the
    /// answer that was not in any title.
    private func scanText() async {
        passages = []
        guard isSearch else {
            scanning = false
            return
        }
        let query = model.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count > 1 else { return }
        let named = Set(model.visiblePapers.map(\.id))
        let sources = model.papers
            .filter { $0.meta.parentID == nil && !named.contains($0.id) }
            .sorted {
                ($0.state.lastOpenedAt ?? .distantPast) > ($1.state.lastOpenedAt ?? .distantPast)
            }
            .map {
                PaperTextIndex.Source(id: $0.id, url: $0.documentURL,
                                      title: $0.meta.displayTitle)
            }
        scanning = true
        for await hit in PaperTextIndex.shared.hits(for: query, in: sources) {
            passages.append(hit)
        }
        scanning = false
    }

    /// How far the list must be pulled before the search opens.
    private static let pullThreshold: CGFloat = 72

    /// What the pull uncovers, and what crossing it will do.
    ///
    /// It fades in over the first two thirds of the pull and firms up at the
    /// end, so the last stretch of the gesture is the part that says "now".
    /// It never takes a touch: the pull belongs to the list.
    private var pullHint: some View {
        let progress = min(max(pull / (Self.pullThreshold * 0.66), 0), 1)
        let armed = pull > Self.pullThreshold * 0.9
        return HStack(spacing: 6) {
            Image(systemName: "rectangle.and.text.magnifyingglass")
            Text("Search Everything")
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(armed ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        .opacity(progress)
        .scaleEffect(0.92 + progress * 0.08)
        // Carried down by the pull rather than pinned to the edge, so it
        // reads as something the gesture is uncovering.
        .offset(y: max(0, pull * 0.34) + 4)
        .animation(.snappy(duration: 0.14), value: armed)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
        // A view rather than the items themselves. A `@ViewBuilder` closure
        // here is run when the row is built, so every row in the library was
        // making its whole menu — a reading-status picker, a submenu holding
        // thirty other papers, and two passes over the library to work out
        // what could go in it — before anybody had right-clicked anything.
        // A `View` is a struct until it is shown, and its body runs when the
        // menu opens: once, for one row.
        .contextMenu { PaperMenu(paper: paper, model: model) }
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

/// What a right-click on a paper offers.
///
/// Its own view, and that is the point: see `PaperRow`.
private struct PaperMenu: View {
    let paper: LoadedPaper
    let model: LibraryModel

    var body: some View {
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

        let candidates = self.candidates
        Menu("Attach To") {
            ForEach(candidates.prefix(30)) { candidate in
                Button(candidate.meta.displayTitle) {
                    Task { await model.attach(paper.id, to: candidate.id) }
                }
            }
        }
        .disabled(
            paper.meta.parentID != nil
                || !model.attachments(of: paper.id).isEmpty
                || candidates.isEmpty
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

    /// The papers this one could be attached to, asked for once rather than
    /// twice: the submenu wants them and so did the test for whether there
    /// are any, and each ask was a pass over the library and a sort.
    private var candidates: [LoadedPaper] {
        model.attachmentCandidates(for: paper.id)
    }

    private func statusBinding(_ paper: LoadedPaper) -> Binding<PaperState.ReadingStatus> {
        Binding(
            get: { paper.state.readingStatus },
            set: { newValue in
                Task { await model.setReadingStatus(newValue, for: paper.id) }
            }
        )
    }

    private func label(for status: PaperState.ReadingStatus) -> String {
        switch status {
        case .unread: "Unread"
        case .reading: "Reading"
        case .read: "Read"
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
