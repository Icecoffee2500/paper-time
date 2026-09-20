import PaperCore
import SwiftUI

/// What the reader has written while reading this paper.
///
/// The notes themselves live in the library's slip-box, not under the paper —
/// a thought is worth keeping past the paper that caused it — so this is the
/// slip-box seen from one paper: the notes written against it, and a way to
/// write another.
struct PaperNotesView: View {
    let model: LibraryModel
    let paperID: UUID
    let link: ReaderLink

    @State private var openID: String?
    /// Notes from elsewhere that echo the pages being read, and the words
    /// they share with them.
    @State private var echoes: [(note: Zettel, shared: [String])] = []
    /// The paper's pages, sampled, for judging how rare a word is; read once
    /// per paper, a few pages per turn of the run loop.
    @State private var background: [String] = []
    @State private var backgroundOf: URL?

    private var notes: NotesModel { model.notes }

    /// Everything the echoes depend on, so they are asked for again when any
    /// of it changes — and not before the page has stopped turning.
    private var echoKey: String {
        "\(link.currentPageIndex)|\(notes.revision)|\(background.count)|\(link.bookGutter > 0)|\(paperID)"
    }

    var body: some View {
        Group {
            if let openID, notes.note(openID) != nil {
                ZettelEditorView(
                    notes: notes,
                    noteID: openID,
                    link: link,
                    onClose: { self.openID = nil }
                )
            } else {
                list
            }
        }
        .onChange(of: paperID) { _, _ in openID = nil }
        .task(id: link.session?.document.documentURL) { await readBackground() }
        .task(id: echoKey) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            refreshEchoes()
        }
        // Command-L with no note open carries on with the last one written
        // about this paper, or starts one.
        .onChange(of: link.pendingNoteAnchor) { _, anchor in
            guard anchor != nil, openID == nil else { return }
            openID = notes.notes(forPaper: paperID).first?.id ?? notes.create(paperID: paperID).id
        }
        // Following a link from inside another note.
        .onChange(of: notes.requestedNoteID) { _, id in
            guard let id else { return }
            openID = id
            notes.requestedNoteID = nil
        }
    }

    private var list: some View {
        let mine = notes.notes(forPaper: paperID)
        return VStack(spacing: 0) {
            if !echoes.isEmpty {
                resonance
                Divider()
            }
            if link.hasSelection, !notes.drafts.isEmpty {
                draftsStrip
                Divider()
            }
            HStack(spacing: 8) {
                Text(mine.count == 1 ? L("노트 1개", "1 note") : L("노트 \(mine.count)개", "\(mine.count) notes"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button {
                    openID = notes.create(paperID: paperID).id
                } label: {
                    Label(L("새 노트", "New Note"), systemImage: "square.and.pencil")
                }
                .buttonStyle(.borderless)
                .help(L("이 논문에 새 노트 쓰기", "Write a new note about this paper"))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()

            if mine.isEmpty {
                ContentUnavailableView {
                    Label(L("아직 노트가 없다", "No Notes Yet"), systemImage: "note.text")
                } description: {
                    Text(L("노트 하나에 생각 하나. 구절을 고르고 ⌘L을 누르면 그곳에 이어진다.", "One thought per note. Select a passage and press ⌘L to link to it."))
                }
            } else {
                List {
                    ForEach(mine) { note in
                        NoteRow(note: note)
                            .contentShape(.rect)
                            .pressable(inset: 6)
                            .onTapGesture { openID = note.id }
                            .contextMenu {
                                Button(role: .destructive) { notes.delete(note.id) } label: {
                                    Label(L("지우기", "Delete"), systemImage: "trash")
                                }
                            }
                    }
                }
                .listStyle(.inset)
                // An inset list paints its own opaque white, which is why the
                // lists were the one white rectangle in a window of glass. The
                // panel behind them is the background now.
                .scrollContentBackground(.hidden)
                .hiddenScrollers()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Resonance

extension PaperNotesView {
    /// The slip-box reading along: notes written against other papers that
    /// share their rarer words with the pages on screen, named with the
    /// words they share. Luhmann's box was a conversation partner; this is
    /// the box speaking first, since nobody searches for a note they have
    /// forgotten they wrote.
    private var resonance: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Label(L("공명", "Resonance"), systemImage: "waveform")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tint)
                Text(L("다른 논문에서", "from other papers"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            .help(L("이 쪽의 드문 낱말을 함께 쓰는 다른 논문의 노트다 — 함께 쓰는 낱말은 파란색으로 보인다. 누르면 열리고, 쪽에서 구절을 고르고 ❝를 누르면 그 노트에 들어간다.", "Notes written against other papers that share this page's rarer words — the shared words are shown in blue. Click one to open it; select a passage on the page and ❝ drops it into that note."))
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 2)

            ForEach(echoes, id: \.note.id) { echo in
                echoRow(echo)
            }
            .padding(.horizontal, 10)
        }
        .padding(.bottom, 8)
        .animation(.snappy(duration: 0.25), value: echoes.map(\.note.id))
    }

    private func echoRow(_ echo: (note: Zettel, shared: [String])) -> some View {
        Button {
            openID = echo.note.id
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(echo.note.displayTitle)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if link.hasSelection {
                        // The selection, dropped into that note: the echo
                        // made into a link, which is what a slip-box is for.
                        Button {
                            link.pendingNoteAnchor = link.selectionAnchor()
                            openID = echo.note.id
                        } label: {
                            Image(systemName: "quote.opening")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .help(L("고른 구절을 이 노트로", "Drop the selected passage into this note"))
                    }
                }
                if let source = source(of: echo.note) {
                    Text(source)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                // Why: the words the note and the page share, so the echo
                // can be judged at a glance rather than taken on trust.
                Text(echo.shared.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.tint)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .pressable()
    }

    /// With a passage selected, the drafts it can go into — with its paper's
    /// citation attached, which is what makes it a citation later.
    private var draftsStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(L("초안으로", "Into a draft"), systemImage: "doc.text")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tint)
                .padding(.horizontal, 16)
                .padding(.top, 10)
            ForEach(notes.drafts) { draft in
                Button {
                    link.pendingNoteAnchor = link.selectionAnchor()
                    openID = draft.id
                } label: {
                    HStack {
                        Text(draft.displayTitle).font(.callout).lineLimit(1)
                        Spacer(minLength: 4)
                        Image(systemName: "quote.opening").font(.caption)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .pressable()
                .padding(.horizontal, 10)
            }
        }
        .padding(.bottom, 8)
    }

    /// The paper a note was written against, named.
    private func source(of note: Zettel) -> String? {
        guard let paperID = note.paperID else { return L("논문 없이 쓴 노트", "A note of your own") }
        return model.paper(paperID)?.meta.csl.fullTitle
    }

    private func refreshEchoes() {
        Trace.time("echoes: find") { refreshEchoesNow() }
    }

    private func refreshEchoesNow() {
        guard let document = link.session?.document else { echoes = []; return }
        let index = link.currentPageIndex
        // In a book both pages of the spread are under the eyes.
        var pages = [index]
        if link.bookGutter > 0 {
            let left = index - index % 2
            pages = [left, left + 1]
        }
        let text = pages.compactMap { document.page(at: $0)?.string }.joined(separator: "\n")
        guard !text.isEmpty else { echoes = []; return }
        let mine = Set(notes.notes(forPaper: paperID).map(\.id))
        echoes = notes.resonance(with: text, background: background, excluding: mine, limit: 4)
    }

    /// Reads a sample of the paper's pages, a few per turn of the run loop,
    /// so the words' rarity can be judged against the paper itself.
    private func readBackground() async {
        guard let document = link.session?.document else { return }
        let url = document.documentURL
        if let url, backgroundOf == url, !background.isEmpty { return }
        let count = document.pageCount
        let sample = min(count, 40)
        var texts: [String] = []
        for step in 0..<sample {
            let index = sample <= 1 ? 0 : step * (count - 1) / (sample - 1)
            let text = Trace.time("echoes: read one page") { document.page(at: index)?.string }
            if let text, !text.isEmpty { texts.append(text) }
            if step % 4 == 3 { await Task.yield() }
            if Task.isCancelled { return }
        }
        background = texts
        backgroundOf = url
    }
}

/// One note as it appears in a list of them.
struct NoteRow: View {
    let note: Zettel
    var showsSource: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(note.displayTitle)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                // When it was written, at the right edge where a date goes.
                Text(note.created.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            // What is left after the title, not the whole preview: a note with
            // no title of its own takes its first words as one, and showing
            // the preview under it printed the same sentence twice.
            if !note.previewBody.isEmpty {
                Text(note.previewBody)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            if showsSource != nil || !note.tags.isEmpty {
                HStack(spacing: 6) {
                    if let showsSource {
                        Text(showsSource).lineLimit(1)
                    }
                    ForEach(note.tags.prefix(3), id: \.self) { tag in
                        Text("#\(tag)")
                            .foregroundStyle(.tint)
                    }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
    }
}
