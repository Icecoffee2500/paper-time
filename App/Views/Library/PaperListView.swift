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
    /// Kept in an object of its own rather than in this view's own state. The
    /// scroll reports its position continuously, so writing it here rebuilt
    /// this whole view on every tick of every scroll — and rebuilding this
    /// view means building a `PaperRow` for every paper in the library, tags
    /// and all, whether or not any of them is on screen. That is the whole of
    /// why the list got slower as the library grew: measured on a Release
    /// build, a scroll step cost 26ms at 150 papers and 76ms at 600, while
    /// the number of row views on screen never changed from 345. An
    /// `@Observable` object writes only to whoever reads it, and only
    /// `PullHint` reads this.
    @State private var pull = PullProgress()
    /// What the same query turned up inside the papers, when the list is
    /// showing the results of a search.
    @State private var passages: [PaperTextIndex.Hit] = []
    @State private var scanning = false

    var body: some View {
        content
            // On the list itself. It was presented from a `Color.clear` of no
            // size in the background, to save this view from being rebuilt
            // when the request changed — and a sheet presented from a view of
            // no size is a sheet that cannot be closed: `dismiss()` went
            // nowhere, so Cancel and Escape both did nothing. The saving was
            // imaginary anyway; this changes when a sheet opens and when it
            // closes, not sixty times a second like the pull it was modelled
            // on.
            .sheet(
                item: Binding(
                    get: { app.attaching.child },
                    set: { app.attaching.child = $0 }
                )
            ) { child in
                AttachSheet(child: child, model: model) { app.attaching.child = nil }
            }
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
            (L("안 읽은 논문이 없어요", "Nothing Unread"), "circle",
             L("여기 있는 논문은 모두 열어봤어요.", "Every paper here has been opened."))
        case .reading:
            (L("읽는 중인 논문이 없어요", "Nothing Being Read"), "circle.lefthalf.filled",
             L("논문을 읽는 중으로 바꿔두면 여기서 기다려요.", "Mark a paper as Reading and it waits here."))
        case .read:
            (L("읽은 논문이 아직 없어요", "Nothing Read Yet"), "checkmark.circle",
             L("읽음으로 바꾼 논문이 여기 모여요.", "Papers marked as Read collect here."))
        case .favorites:
            (L("즐겨찾기가 아직 없어요", "No Favorites"), "star",
             L("논문에 별을 달아두면 언제든 여기서 찾을 수 있어요.", "Star a paper and it stays here."))
        case .needsReview:
            (L("살펴볼 것이 없어요", "Nothing to Review"), "exclamationmark.triangle",
             L("서지를 한번 봐야 할 논문이 없어요.", "Every record looks right."))
        case .collection:
            (L("이 컬렉션은 비어 있어요", "This Collection Is Empty"), "folder",
             L("옆 목록의 컬렉션 위로 논문을 끌어다 놓아보세요.", "Drag papers onto it in the sidebar."))
        case .tag:
            (L("이 태그를 단 논문이 없어요", "Nothing With This Tag"), "tag",
             L("논문에 이 태그를 달면 여기 나와요.", "Tag a paper and it appears here."))
        case .author:
            (L("이 저자의 논문이 없어요", "Nothing by This Author"), "person",
             L("이 이름이 실린 논문이 라이브러리에 없어요.", "No paper here carries this name."))
        default:
            (L("아직 아무것도 없어요", "Nothing Here"), "tray",
             L("이 선반은 비어 있어요.", "This shelf is empty."))
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.papers.isEmpty {
            if !model.loadFailures.isEmpty {
                // Before anything else, because every other sentence here
                // would be untrue: the library is not empty and no folder
                // needs choosing. The papers are in the folder; their records
                // are what has not arrived.
                ContentUnavailableView {
                    Label(L("기록이 아직 안 왔어요", "Some Records Didn't Arrive"), systemImage: "icloud.slash")
                } description: {
                    Text(unreadableDescription)
                } actions: {
                    Button(L("다시 읽기", "Try Again")) { Task { await model.pullFromCloud() } }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                }
            } else if model.looseDocuments.isEmpty {
                ContentUnavailableView(
                    L("아직 논문이 없어요", "No Papers Yet"),
                    systemImage: "doc.badge.plus",
                    description: Text(L("PDF를 여기 끌어다 놓아보세요. 도구 막대의 PDF 더하기로 골라도 돼요.",
                                        "Drag in a PDF, or choose Add PDFs."))
                )
            } else {
                // Pointing the app at a folder that already holds PDFs is the
                // obvious thing to do; landing on an empty library after doing
                // it is not.
                ContentUnavailableView {
                    Label(L("이 폴더에서 찾은 논문", "Papers Found in This Folder"), systemImage: "tray.and.arrow.down")
                } description: {
                    Text(looseDescription)
                } actions: {
                    Button(L("PDF \(model.looseDocuments.count)개 더하기", "Add \(model.looseDocuments.count) PDFs")) {
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
            // The Mac's middle column is a table of our own; see `PaperTable`
            // for why, and for the numbers. iPad and iPhone keep the list —
            // they show a few dozen papers at a time, `UITableView` under
            // SwiftUI does not measure rows the same way, and a second list to
            // maintain buys nothing there.
            #if os(macOS)
            PaperTable(
                    entries: tableEntries,
                    model: model,
                    app: app,
                    fields: SubtitleField.parse(app.settings.listSubtitleFields),
                    onOpenShelf: model.scope == .open,
                    selection: $model.selection,
                    note: { AnyView(self.noteRow($0)) },
                    onPull: { distance in
                        pull.distance = distance
                        guard distance > Self.pullThreshold, !app.showsSearchPalette else { return }
                        app.showsSearchPalette = true
                    }
                )
                .overlay(alignment: .top) { PullHint(pull: pull, threshold: Self.pullThreshold) }
                .hiddenScrollers()
            #else
            List(selection: $model.selection) {
                if !model.loadFailures.isEmpty {
                    // The list is short by exactly this many papers, all of
                    // which are still in the folder. A short list that says
                    // nothing is the whole of what goes wrong here — and while
                    // this row is showing there is no loose-PDF row below it,
                    // because a folder read in part cannot say what is loose.
                    Section {
                        Button {
                            Task { await model.pullFromCloud() }
                        } label: {
                            Label(
                                L("기록 \(model.loadFailures.count)개가 아직 안 왔어요",
                                  "\(model.loadFailures.count) record\(model.loadFailures.count == 1 ? "" : "s") "
                                    + "\(model.loadFailures.count == 1 ? "hasn't" : "haven't") arrived"),
                                systemImage: "icloud.slash"
                            )
                        }
                        .help(unreadableDescription)
                    }
                }
                if !model.looseDocuments.isEmpty || model.isAdopting || !model.adoptFailures.isEmpty {
                    Section {
                        if model.isAdopting {
                            // Two hundred files is a wait, and a button that
                            // looks the same all the way through it is a button
                            // people press again.
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(L("PDF \(model.adoptingCount)개 더하는 중…",
                                       "Adding \(model.adoptingCount) PDFs…"))
                                    .foregroundStyle(.secondary)
                            }
                        } else if !model.looseDocuments.isEmpty {
                            Button {
                                Task { await model.adoptLooseDocuments() }
                            } label: {
                                Label(
                                    L("이 폴더에 남은 PDF \(model.looseDocuments.count)개 더하기",
                                      "Add \(model.looseDocuments.count) more PDFs from this folder"),
                                    systemImage: "tray.and.arrow.down"
                                )
                            }
                        }
                        if !model.adoptFailures.isEmpty {
                            // The half of the answer that was missing. These
                            // files came off the row without getting a record
                            // and came back on the next read of the folder, so
                            // the button appeared to do nothing — twice over,
                            // because it also said nothing.
                            Label(
                                L("PDF \(model.adoptFailures.count)개는 더하지 못했어요",
                                  "\(model.adoptFailures.count) PDF\(model.adoptFailures.count == 1 ? "" : "s") "
                                    + "couldn't be added"),
                                systemImage: "exclamationmark.triangle"
                            )
                            .foregroundStyle(.secondary)
                            .help(refusedDescription)
                        }
                    }
                }
                // A kind's shelf gathers papers out of every folder at once,
                // and until now they arrived in one undivided run — sixty rows
                // with nothing to say which term or which library each came
                // from. Where they come from more than one folder, each folder
                // gets its name over its own papers.
                if let groups = model.visibleIDsByFolder {
                    let fields = SubtitleField.parse(app.settings.listSubtitleFields)
                    ForEach(groups, id: \.folder) { group in
                        Section(model.folderLabel(for: group.folder)) {
                            ForEach(group.ids, id: \.self) { id in
                                row(for: id, fields: fields, onOpenShelf: false)
                            }
                        }
                    }
                } else {
                Section {
                // Once for the list, not once for every row in it: the
                // setting is a string that has to be taken apart, and taking
                // it apart sixty times to draw sixty rows is sixty times the
                // work for one answer.
                let fields = SubtitleField.parse(app.settings.listSubtitleFields)
                let onOpenShelf = model.scope == .open
                // By identifier, not by paper: see `visiblePaperIDs`.
                ForEach(model.visiblePaperIDs, id: \.self) { id in
                    row(for: id, fields: fields, onOpenShelf: onOpenShelf)
                }
                } header: {
                    // Only while a search is being shown. Everywhere else the
                    // list is one list and a heading over it would be a label
                    // on a thing that has no counterpart.
                    if hasPassages, !model.visiblePapers.isEmpty {
                        Text(L("제목에서", "In the Titles"))
                    }
                }
                }

                if hasPassages {
                    Section(L("논문 안에서", "In the Papers")) {
                        ForEach(passages, id: \.passage) { hit in
                            passageRow(hit)
                        }
                        if scanning {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(L("논문 본문을 읽는 중…", "Reading the papers…"))
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
            .overlay(alignment: .top) { PullHint(pull: pull, threshold: Self.pullThreshold) }
            .onPull { distance in
                pull.distance = distance
                guard distance > Self.pullThreshold, !app.showsSearchPalette else { return }
                app.showsSearchPalette = true
            }
            #endif
        }
    }

    /// Every row the table holds, in the order it holds them.
    ///
    /// What the list kept in sections is one flat run here, because one scroll
    /// view carries the lot and a table's rows are a list of rows. The kinds
    /// are told apart by the entry, not by where they sit.
    private var tableEntries: [PaperTable.Entry] {
        var entries: [PaperTable.Entry] = []
        if !model.loadFailures.isEmpty { entries.append(.note("failures")) }
        if model.isAdopting {
            entries.append(.note("adopting"))
        } else if !model.looseDocuments.isEmpty {
            entries.append(.note("loose"))
        }
        if !model.adoptFailures.isEmpty { entries.append(.note("refused")) }

        if let groups = model.visibleIDsByFolder {
            for group in groups {
                entries.append(.heading(model.folderLabel(for: group.folder)))
                entries.append(contentsOf: group.ids.map { PaperTable.Entry.paper($0) })
            }
        } else {
            if hasPassages, !model.visiblePapers.isEmpty {
                entries.append(.heading(L("제목에서", "In the Titles")))
            }
            entries.append(contentsOf: model.visiblePaperIDs.map { PaperTable.Entry.paper($0) })
        }

        if hasPassages {
            entries.append(.heading(L("논문 안에서", "In the Papers")))
            entries.append(contentsOf: passages.map { PaperTable.Entry.passage(Self.key(of: $0.passage)) })
            if scanning { entries.append(.note("scanning")) }
        }
        return entries
    }

    /// A passage, as a name a table row can be told apart by.
    static func key(of passage: PaperTextIndex.Passage) -> String {
        "\(passage.paperID.uuidString)#\(passage.pageIndex)@\(passage.location)+\(passage.length)"
    }

    /// The rows that speak for the folder rather than for a paper.
    @ViewBuilder
    private func noteRow(_ entry: PaperTable.Entry) -> some View {
        switch entry {
        case let .heading(title):
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 8)
                .padding(.bottom, 2)
        case .note("failures"):
            Button {
                Task { await model.pullFromCloud() }
            } label: {
                Label(
                    L("기록 \(model.loadFailures.count)개가 아직 안 왔어요",
                      "\(model.loadFailures.count) record\(model.loadFailures.count == 1 ? "" : "s") "
                        + "\(model.loadFailures.count == 1 ? "hasn't" : "haven't") arrived"),
                    systemImage: "icloud.slash"
                )
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)
            .help(unreadableDescription)
        case .note("adopting"):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L("PDF \(model.adoptingCount)개 더하는 중…", "Adding \(model.adoptingCount) PDFs…"))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        case .note("loose"):
            Button {
                Task { await model.adoptLooseDocuments() }
            } label: {
                Label(
                    L("이 폴더에 남은 PDF \(model.looseDocuments.count)개 더하기",
                      "Add \(model.looseDocuments.count) more PDFs from this folder"),
                    systemImage: "tray.and.arrow.down"
                )
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)
        case .note("refused"):
            Label(
                L("PDF \(model.adoptFailures.count)개는 더하지 못했어요",
                  "\(model.adoptFailures.count) PDF\(model.adoptFailures.count == 1 ? "" : "s") couldn't be added"),
                systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)
            .help(refusedDescription)
        case .note("scanning"):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L("논문 본문을 읽는 중…", "Reading the papers…"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        case let .passage(key):
            if let hit = passages.first(where: { Self.key(of: $0.passage) == key }) {
                passageRow(hit)
            }
        default:
            EmptyView()
        }
    }

    /// What the text search answers to: the query, and only while the list is
    /// showing a search at all.
    private var searchKey: String { isSearch ? model.searchQuery : "" }

    private var isSearch: Bool { model.scope == .searchResults }
    /// Whether the text of the papers has something to say about this search.

    /// One row of the list, wherever it is drawn from.
    ///
    /// Taken by identifier. The paper is fetched here, where the row is
    /// actually being built, rather than carried through `ForEach` — which
    /// walks its whole collection on every update whether or not a row of it
    /// is on screen.
    @ViewBuilder
    private func row(for id: UUID, fields: [SubtitleField], onOpenShelf: Bool) -> some View {
        if let paper = model.paper(id) {
            builtRow(paper, fields: fields, onOpenShelf: onOpenShelf)
        }
    }

    @ViewBuilder
    private func builtRow(_ paper: LoadedPaper, fields: [SubtitleField], onOpenShelf: Bool) -> some View {
        Trace.tick("row init")
        return PaperRow(
            paper: paper,
            tags: paper.meta.tagIDs.compactMap { model.tag(for: $0) },
            attachmentCount: model.attachmentCount(of: paper.id),
            isResolving: model.resolving.contains(paper.id),
            subtitleFields: fields,
            model: model,
            onOpenShelf: onOpenShelf,
            isKeptOpen: model.isPinned(paper.id)
        )
        .tag(paper.id)
        #if os(iOS)
        // A `Set` selection only takes taps in edit mode on iOS, so the row
        // opens the paper itself.
        .contentShape(.rect)
        .onTapGesture {
            model.selection = [paper.id]
            app.compactColumn = .detail
        }
        #endif
    }

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

    /// Why the list is short, in the two places that say so.
    ///
    /// Not "못 읽었어요": read and unread are what this app calls a paper you
    /// have or have not got to, and a record the folder has not handed over is
    /// neither of those.
    private var unreadableDescription: String {
        L(
            """
            논문 \(model.loadFailures.count)편의 기록이 아직 안 왔어요. 논문은 폴더에 \
            그대로 있어요. 클라우드 폴더라면 파일이 아직 내려오는 중일 수 있어요.
            """,
            """
            \(model.loadFailures.count) of this library's records haven't arrived. \
            Your papers are still in the folder. On a cloud drive, a record may \
            still be on its way down.
            """
        )
    }

    /// Which files the last adoption could not take, by name.
    private var refusedDescription: String {
        let names = model.adoptFailures.prefix(8).joined(separator: "\n")
        let rest = model.adoptFailures.count - min(8, model.adoptFailures.count)
        let more = rest > 0 ? L("\n…그리고 \(rest)개 더", "\n…and \(rest) more") : ""
        return L("파일을 읽을 수 없었어요. 클라우드 폴더라면 아직 내려오는 중일 수 있어요.\n\n",
                 "These files couldn't be read. On a cloud drive, they may still be on their way down.\n\n")
            + names + more
    }

    private var looseDescription: String {
        let count = model.looseDocuments.count
        let noun = count == 1 ? "PDF" : "PDFs"
        return L(
            """
            이 폴더에 PDF가 벌써 \(count)개 있어요. 더하면 하나씩 서지를 찾아 기록을 \
            만들어요. PDF는 있던 자리에 그대로 있어요 — 옮기지도, 이름을 바꾸지도, \
            복사하지도 않아요.
            """,
            """
            This folder already holds \(count) \(noun). Adding them looks up each \
            one and gives it a record. Paper Time never moves, renames or copies \
            a file.
            """
        )
    }

}

/// How far the list has been pulled past its top.
///
/// An object, so that a value which changes on every scroll tick invalidates
/// the one small view that draws it rather than the list beside it.
@Observable
final class PullProgress {
    var distance: CGFloat = 0
}

/// What the pull uncovers, and what crossing it will do.
///
/// It fades in over the first two thirds of the pull and firms up at the end,
/// so the last stretch of the gesture is the part that says "now". It never
/// takes a touch: the pull belongs to the list.
private struct PullHint: View {
    let pull: PullProgress
    let threshold: CGFloat

    var body: some View {
        let distance = pull.distance
        let progress = min(max(distance / (threshold * 0.66), 0), 1)
        let armed = distance > threshold * 0.9
        HStack(spacing: 6) {
            Image(systemName: "rectangle.and.text.magnifyingglass")
            Text(L("전부 찾기", "Search Everything"))
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(armed ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        .opacity(progress)
        .scaleEffect(0.92 + progress * 0.08)
        // Carried down by the pull rather than pinned to the edge, so it
        // reads as something the gesture is uncovering.
        .offset(y: max(0, distance * 0.34) + 4)
        .animation(Motion.tap, value: armed)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
    /// On the Open Papers shelf: the row can close the paper, and says when
    /// it is only a preview.
    var onOpenShelf = false
    var isKeptOpen = false
    @Environment(AppModel.self) private var app

    nonisolated static func == (lhs: PaperRow, rhs: PaperRow) -> Bool {
        lhs.paper == rhs.paper
            && lhs.tags == rhs.tags
            && lhs.attachmentCount == rhs.attachmentCount
            && lhs.isResolving == rhs.isResolving
            && lhs.subtitleFields == rhs.subtitleFields
            && lhs.onOpenShelf == rhs.onOpenShelf
            && lhs.isKeptOpen == rhs.isKeptOpen
    }

    /// Whether the supplement popover is open for this row.
    @State private var showsAttachments = false

    var body: some View {
        Trace.tick("row body")
        return row(paper)
    }

    @ViewBuilder
    private func row(_ paper: LoadedPaper) -> some View {
        HStack(alignment: .top, spacing: 8) {
            pinButton(paper)

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

            statusButton(paper)

            #if os(macOS)
            if onOpenShelf, model.isOpenPaper(paper.id) {
                // Kept open: closed here, the way a tab is.
                Button {
                    app.undock(paper.id, model: model)
                    model.closeOpenPaper(paper.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(L("닫기", "Close"))
            }
            #endif

            if isResolving {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(L("서지를 찾는 중", "Resolving metadata"))
            } else if needsReview(paper) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(L("서지를 한번 봐주세요", "Check this record"))
                    .accessibilityLabel(L("서지를 한번 봐주세요", "Check this record"))
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
            .help(L("보충 자료", "Supplementary material"))
            .accessibilityLabel(L("보충 자료 \(attachmentCount)개", "\(attachmentCount) supplementary files"))
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
    /// Pinned, or not: the pin at the head of the row.
    ///
    /// A pin is something you do. The app keeps a paper on the Open Papers
    /// shelf when you use it — clicking into the page is enough — and for a
    /// while that lit this pin too, so reading a paper appeared to pin it.
    /// What the app does on its own is visible on the shelf; the pin says
    /// only what you said.
    private func pinButton(_ paper: LoadedPaper) -> some View {
        Button {
            #if os(macOS)
            if isKeptOpen {
                app.undock(paper.id, model: model)
                model.closeOpenPaper(paper.id)
            } else {
                model.keepOpen(paper.id, byHand: true)
            }
            #else
            if isKeptOpen { model.closeOpenPaper(paper.id) } else { model.keepOpen(paper.id, byHand: true) }
            #endif
        } label: {
            Image(systemName: isKeptOpen ? "pin.fill" : "pin")
                .foregroundStyle(isKeptOpen ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 16)
        }
        .buttonStyle(.plain)
        .help(isKeptOpen ? L("고정한 논문 — 누르면 닫아요", "Pinned — click to close") : L("고정하기", "Pin"))
        .accessibilityLabel(isKeptOpen ? L("열어 둔 논문", "Kept open") : L("열어 두지 않음", "Not kept open"))
    }

    private func statusButton(_ paper: LoadedPaper) -> some View {
        Menu {
            // The same answer the inspector asks for, where a handful of rows can
        // be corrected one after another without going to the inspector for
        // each — which is what a wrongly answered import feels like.
        Picker(L("종류", "Kind"), selection: kindBinding(paper)) {
            Label(L("논문", "Paper"), systemImage: "text.document").tag(DocumentKind.paper)
            Label(L("책", "Book"), systemImage: "book").tag(DocumentKind.book)
            Label(L("강의자료", "Course Material"), systemImage: "person.crop.rectangle").tag(DocumentKind.lecture)
            Label(L("일반 문서", "Document"), systemImage: "doc").tag(DocumentKind.document)
        }

        Picker(L("읽기 상태", "Reading Status"), selection: statusBinding(paper)) {
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
        .help(L("읽기 상태: \(label(for: paper.state.readingStatus))", "Reading status: \(label(for: paper.state.readingStatus))"))
        .accessibilityLabel(L("읽기 상태: \(label(for: paper.state.readingStatus))", "Reading status: \(label(for: paper.state.readingStatus))"))
    }

    private func kindBinding(_ paper: LoadedPaper) -> Binding<DocumentKind> {
        Binding(
            get: { paper.meta.effectiveKind },
            set: { kind in Task { await model.setKind(kind, for: paper.id) } }
        )
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
        .help(paper.state.isFavorite ? L("즐겨찾기에서 빼기", "Remove from Favorites") : L("즐겨찾기에 더하기", "Add to Favorites"))
        .accessibilityLabel(paper.state.isFavorite ? L("즐겨찾기", "Favorite") : L("즐겨찾기 아님", "Not a favorite"))
        .accessibilityAddTraits(paper.state.isFavorite ? [.isSelected] : [])
    }

    private func subtitle(_ paper: LoadedPaper) -> String {
        Self.subtitle(paper, fields: subtitleFields)
    }

    /// The line under the title. Static because the table works out how tall a
    /// row will be before there is a row, and whether this line is there at all
    /// is what decides it.
    static func subtitle(_ paper: LoadedPaper, fields: [SubtitleField]) -> String {
        let line = fields.compactMap { $0.value(for: paper) }.joined(separator: " · ")
        guard line.isEmpty else { return line }
        // The fields under a title are a bibliography's — authors, year,
        // venue — and a manual has none of them, so the row came out bare.
        // What a document does have is a file and a length; a book has a
        // publisher, which is the one thing worth reading off a shelf of them.
        guard paper.meta.effectiveKind != .paper else { return line }
        let pages = paper.meta.file.pageCount
        return [
            paper.meta.csl.publisher,
            paper.meta.csl.year.map(String.init),
            pages > 0 ? L("\(pages)쪽", "\(pages) pages") : nil,
        ].compactMap { $0 }.joined(separator: " · ")
    }

    /// Neither a document nor a book has a registrar to disagree with, so
    /// neither is ever a thing to review — only a paper whose lookup came back
    /// unsure is.
    private func needsReview(_ paper: LoadedPaper) -> Bool {
        paper.meta.effectiveKind.isLookedUp
            && (paper.meta.confidence == .needsReview || paper.meta.confidence == .unparsed)
    }

    private func label(for status: PaperState.ReadingStatus) -> String {
        switch status {
        case .unread: L("안 읽음", "Unread")
        case .reading: L("읽는 중", "Reading")
        case .read: L("읽음", "Read")
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
    @Environment(AppModel.self) private var app
    var body: some View {
        Button {
            model.selectedPaperID = paper.id
        } label: {
            Label(L("열기", "Open"), systemImage: "book")
        }
        #if os(macOS)
        // Beside the paper already open: a half, or a quarter, of the page.
        Menu {
            dockButton(.left, L("왼쪽에", "Left Half"), "rectangle.lefthalf.inset.filled")
            dockButton(.right, L("오른쪽에", "Right Half"), "rectangle.righthalf.inset.filled")
            Divider()
            dockButton(.topLeft, L("왼쪽 위에", "Top Left"), "rectangle.inset.topleft.filled")
            dockButton(.topRight, L("오른쪽 위에", "Top Right"), "rectangle.inset.topright.filled")
            dockButton(.bottomLeft, L("왼쪽 아래에", "Bottom Left"), "rectangle.inset.bottomleft.filled")
            dockButton(.bottomRight, L("오른쪽 아래에", "Bottom Right"), "rectangle.inset.bottomright.filled")
        } label: {
            Label(L("나란히 열기", "Open Side by Side"), systemImage: "rectangle.split.2x1")
        }
        if model.isOpenPaper(paper.id) {
            Button {
                app.undock(paper.id, model: model)
                model.closeOpenPaper(paper.id)
            } label: {
                Label(L("닫기", "Close"), systemImage: "xmark.circle")
            }
            if model.openPaperIDs.count > 1 {
                Button {
                    for other in model.openPaperIDs where other != paper.id { app.undock(other, model: model) }
                    model.closeOtherOpenPapers(keeping: paper.id)
                } label: {
                    Label(L("다른 논문 모두 닫기", "Close Other Papers"), systemImage: "xmark.circle.fill")
                }
            }
        } else {
            Button {
                model.keepOpen(paper.id, byHand: true)
            } label: {
                Label(L("열어 두기", "Keep Open"), systemImage: "pin")
            }
        }
        #endif

        Picker(L("읽기 상태", "Reading Status"), selection: statusBinding(paper)) {
            ForEach(PaperState.ReadingStatus.allCases, id: \.self) { status in
                Label(label(for: status), systemImage: status.symbolName).tag(status)
            }
        }

        Button {
            Task { await model.toggleFavorite(for: paper.id) }
        } label: {
            Label(
                paper.state.isFavorite ? L("즐겨찾기에서 빼기", "Remove from Favorites") : L("즐겨찾기에 더하기", "Add to Favorites"),
                systemImage: paper.state.isFavorite ? "star.slash" : "star"
            )
        }

        // A picker, not a submenu. The submenu listed the first thirty papers
        // in title order, and the one being looked for is a supplement's
        // parent — as likely to be at Z as at A. On a shelf of two hundred it
        // was usually not there, and a menu that stops at thirty cannot say
        // so.
        Button {
            app.attaching.child = paper
        } label: {
            Label(L("다른 논문에 붙이기…", "Attach To…"), systemImage: "paperclip")
        }
        .disabled(
            paper.meta.parentID != nil
                || !model.attachments(of: paper.id).isEmpty
                || !model.hasAttachmentCandidates(for: paper.id)
        )

        if paper.meta.parentID != nil {
            Button {
                Task { await model.detach(paper.id) }
            } label: {
                Label(L("논문에서 떼기", "Detach from Paper"), systemImage: "paperclip.badge.ellipsis")
            }
        }

        Divider()

        Button {
            copyToPasteboard(paper.meta.bibKey)
        } label: {
            Label(L("BibTeX 키 복사", "Copy BibTeX Key"), systemImage: "doc.on.doc")
        }

        #if os(macOS)
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([paper.documentURL])
        } label: {
            Label(L("Finder에서 보기", "Reveal in Finder"), systemImage: "folder")
        }
        #endif

        Button {
            Task { await model.resolveMetadata(for: paper.id) }
        } label: {
            Label(L("서지 다시 찾기", "Re-run Metadata"), systemImage: "arrow.triangle.2.circlepath")
        }

        Divider()

        Button(role: .destructive) {
            Task { await model.moveToTrash(paper.id) }
        } label: {
            Label(L("휴지통에 넣기", "Move to Trash"), systemImage: "trash")
        }
    }

    #if os(macOS)
    private func dockButton(_ zone: DockZone, _ title: String, _ symbol: String) -> some View {
        Button {
            app.dock(paper.id, at: zone, in: model)
        } label: {
            Label(title, systemImage: symbol)
        }
    }
    #endif

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
        case .unread: L("안 읽음", "Unread")
        case .reading: L("읽는 중", "Reading")
        case .read: L("읽음", "Read")
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
            Text(L("보충 자료", "Supplementary Material"))
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
                        Label(L("논문에서 떼기", "Detach from Paper"), systemImage: "paperclip.badge.ellipsis")
                    }
                }
            }

            Divider()

            Button {
                model.selectedPaperID = parent.id
                isPresented = false
            } label: {
                Label(L("논문으로 돌아가기", "Back to the Paper"), systemImage: "arrow.uturn.backward")
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

extension View {
    /// How far a list has been pulled past its top, as it changes.
    ///
    /// Scroll geometry is a macOS 15 / iOS 18 thing. Before that the pull is
    /// not observed and the list does not open the search this way — the
    /// toolbar button and Command-K still do.
    @ViewBuilder
    func onPull(_ handle: @escaping (CGFloat) -> Void) -> some View {
        if #available(macOS 15, iOS 18, *) {
            onScrollGeometryChange(for: CGFloat.self) { geometry in
                -(geometry.contentOffset.y + geometry.contentInsets.top)
            } action: { _, distance in
                handle(distance)
            }
        } else {
            self
        }
    }
}
