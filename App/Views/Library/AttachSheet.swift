import LibraryStore
import PaperCore
import SwiftUI

/// Which paper the reader has asked to attach to something else.
///
/// An object rather than state inside the row, because the menu that starts
/// this is torn down the moment it is clicked — a sheet presented from inside
/// a context menu closes with the menu. The list holds this and presents the
/// sheet; the menu only writes to it.
@Observable
public final class AttachRequest {
    public var child: LoadedPaper?
    public init() {}
}

/// Picking the paper a document belongs to.
///
/// This was a submenu of the first thirty titles in alphabetical order, and a
/// supplement's parent is no likelier to be at A than at Z: on a shelf of two
/// hundred, the paper the reader was looking for was usually not among them,
/// and nothing said so. A picker with a field finds it by any word of its
/// title or its file name, and opens on the paper the library would have
/// guessed.
struct AttachSheet: View {
    let child: LoadedPaper
    let model: LibraryModel
    /// Closing is done by putting the request back, not by `dismiss()`.
    ///
    /// `dismiss()` reaches the presentation SwiftUI thinks it is in, and this
    /// sheet was presented from a `Color.clear` of no size tucked into the
    /// list's `.background` — so nothing it said arrived, and the sheet could
    /// not be closed at all: not by Cancel, not by Escape, not by finishing.
    /// The state that opened it is what closes it.
    let close: () -> Void

    @State private var query = ""
    @State private var chosen: UUID?
    @FocusState private var fieldFocused: Bool

    /// Folded once, when the sheet opens, rather than once per keystroke:
    /// ranking the library means folding every title, and the field re-ranks
    /// on every character typed into it.
    @State private var shelf: [AttachmentSearch.Candidate] = []
    @State private var suggested: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            field
            Divider()
            results
            Divider()
            footer
        }
        #if os(macOS)
        .frame(width: 520, height: 560)
        // Its own background. Without one it takes the window's, and the
        // window carries the reader's paper tint — a sheet the colour of
        // somebody's sepia setting, with a white list sitting in the middle of
        // it, because `List` paints its own.
        .background(Color(nsColor: .windowBackgroundColor))
        #endif
        .onAppear(perform: load)
        // The top hit, as it is typed. A picker with a field is a picker you
        // answer by typing and pressing Return; leaving nothing selected means
        // narrowing the list to one paper and still having to reach for it.
        .onChange(of: query) { _, _ in
            chosen = query.isEmpty ? suggested : ranked.first?.id
        }
        #if os(macOS)
        .onExitCommand(perform: close)
        #endif
    }

    // MARK: - Parts

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("어느 논문에 붙일까요?", "Attach to Which Paper?"))
                .font(.headline)
            HStack(spacing: 6) {
                Image(systemName: "paperclip")
                    .foregroundStyle(.secondary)
                Text(child.meta.displayTitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.callout)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(L("제목이나 파일 이름으로 찾기", "Search titles and file names"), text: $query)
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .onSubmit(attach)
            if !query.isEmpty {
                Button {
                    query = ""
                    fieldFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("지우기", "Clear"))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var results: some View {
        let found = ranked
        if found.isEmpty {
            // Not "no papers": the library is full of them, and none of them
            // answers to this. The sentence has to say which of the two it is.
            VStack(spacing: 6) {
                Text(L("찾는 논문이 없어요", "No Paper Matches"))
                    .font(.subheadline.weight(.semibold))
                Text(L("제목의 다른 부분이나 파일 이름으로 찾아보세요.",
                       "Try another part of the title, or the file name."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 24)
        } else {
            List(selection: $chosen) {
                if query.isEmpty, let suggested, let paper = model.paper(suggested) {
                    Section(L("이 논문 같아요", "Looks Like the One")) {
                        row(paper)
                    }
                    Section(L("모든 논문", "All Papers")) {
                        ForEach(found.filter { $0.id != suggested }) { row($0) }
                    }
                } else {
                    ForEach(found) { row($0) }
                }
            }
            #if os(macOS)
            .listStyle(.inset)
            #endif
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(L("취소", "Cancel"), action: close)
                .keyboardShortcut(.cancelAction)
            Button(L("붙이기", "Attach"), action: attach)
                .keyboardShortcut(.defaultAction)
                .disabled(chosen == nil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func row(_ paper: LoadedPaper) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(paper.meta.displayTitle)
                .lineLimit(2)
            Text(paper.meta.file.originalName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
        .tag(paper.id)
        // Double-click is the shortcut for "this one, now" that a list of
        // things to pick from is expected to have.
        .onTapGesture(count: 2) {
            chosen = paper.id
            attach()
        }
    }

    // MARK: - Work

    private var ranked: [LoadedPaper] {
        AttachmentSearch.ranked(shelf, matching: query)
            .compactMap { model.paper($0.id) }
    }

    private func load() {
        shelf = model.attachmentCandidates(for: child.id).map {
            AttachmentSearch.Candidate(
                id: $0.id,
                title: $0.meta.displayTitle,
                fileName: $0.meta.file.originalName
            )
        }
        let me = AttachmentSearch.Candidate(
            id: child.id,
            title: child.meta.csl.fullTitle ?? "",
            fileName: child.meta.file.originalName
        )
        suggested = AttachmentSearch.suggestion(for: me, among: shelf)
        chosen = suggested
        fieldFocused = true
    }

    private func attach() {
        guard let chosen else { return }
        let childID = child.id
        Task { await model.attach(childID, to: chosen) }
        close()
    }
}
