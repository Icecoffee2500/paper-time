import PaperCore
import SwiftUI

/// One note in the slip-box, open for writing.
///
/// A title, the note itself, and — under it — what this note is connected to.
/// The connections are the point of a Zettelkasten: a note that links to
/// nothing and is linked from nothing is a note that will never be found again.
struct ZettelEditorView: View {
    let notes: NotesModel
    let noteID: String
    let link: ReaderLink?
    /// Shown above the editor; nil in the inspector, where the list is behind
    /// a back button of its own.
    var onClose: (() -> Void)?

    @State private var title = ""
    @State private var body_ = ""
    @State private var loadedID: String?
    /// Shows the Markdown as written, for changing a link or a formula by hand.
    @State private var showsRaw = false

    var body: some View {
        let note = notes.note(noteID)
        let pending = link?.pendingNoteAnchor

        VStack(spacing: 0) {
            header(note)
            editor(pending: pending)
            connections(note)
        }
        .task(id: noteID) { load() }
        .onChange(of: title) { _, _ in save() }
        .onChange(of: body_) { _, _ in save() }
        .onDisappear { flush() }
    }

    // MARK: - Parts

    @ViewBuilder
    private func header(_ note: Zettel?) -> some View {
        // Air between the way back and the title. At six points the two sat
        // on top of each other, and the title — the one thing here meant to
        // be read first — read as a caption under a button.
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                if let onClose {
                    Button(action: onClose) {
                        Label(L("노트", "Notes"), systemImage: "chevron.left")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.borderless)
                }
                Spacer(minLength: 0)

                // Icon only. Spelling "Raw" out put a word in the quietest
                // corner of a writing surface, next to a second word and a
                // twelve-digit number — three things asking to be read before
                // the note itself.
                Toggle(isOn: $showsRaw) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                }
                .toggleStyle(.button)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help(L("노트를 Markdown 원문으로 보기 — 기호까지 그대로", "Show the note as Markdown, syntax and all"))

                Menu {
                    if let note {
                        // The identifier is worth keeping and not worth
                        // staring at: it is what another note links to, so it
                        // lives where you go when you want it.
                        Button {
                            #if os(macOS)
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(note.id, forType: .string)
                            #endif
                        } label: {
                            Label(L("식별자 복사 — \(note.id)", "Copy Identifier — \(note.id)"), systemImage: "number")
                        }
                        Divider()
                    }
                    Button(role: .destructive) {
                        notes.delete(noteID)
                        onClose?()
                    } label: {
                        Label(L("노트 지우기", "Delete Note"), systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            // The one thing on this surface that should be read first.
            TextField(L("제목", "Title"), text: $title)
                .textFieldStyle(.plain)
                .font(.title2.weight(.semibold))

            if let note, !note.tags.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(note.tags, id: \.self) { tag in
                            Text("#\(tag)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(.quaternary.opacity(0.6)))
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private func editor(pending: NoteAnchor?) -> some View {
        #if os(macOS)
        ZStack(alignment: .topLeading) {
            NoteEditor(
                markdown: $body_,
                pendingAnchor: Binding(
                    get: { loadedID == noteID ? pending : nil },
                    set: { link?.pendingNoteAnchor = $0 }
                ),
                pendingReveal: Binding(
                    get: { loadedID == noteID ? notes.reveal : nil },
                    set: { notes.reveal = $0 }
                ),
                showsRawText: showsRaw,
                onFollow: { anchor in
                    link?.anchorRequest = ReaderLink.Anchor(
                        pageIndex: anchor.pageIndex, rect: anchor.rect, paperID: anchor.paperID
                    )
                },
                onOpenNote: { id in
                    guard notes.note(id) != nil else { return }
                    flush()
                    notes.requestedNoteID = id
                },
                suggestions: { partial in
                    notes.suggestions(matching: partial, excluding: noteID).map {
                        (id: $0.id, title: $0.displayTitle, subtitle: $0.id)
                    }
                }
            )
            if body_.isEmpty {
                // Over the text view's own first line, in the text view's own
                // type. It used to be a size smaller and a few points up and
                // to the left of where the words actually begin, so the caret
                // — which is always at the very start of an empty note — sat
                // in the middle of the first line of this rather than in front
                // of it.
                //
                // And the hints are one paragraph, not three lines. They were
                // three because they were written as three, with the breaks
                // typed into the string, so widening the pane left them ending
                // raggedly halfway across it. A paragraph goes where the room
                // goes.
                Text(
                    L(
                        """
                        생각 하나를, 내 말로.

                        [[ 로 다른 노트에 잇고, #태그 로 묶어요. Markdown과 LaTeX는 쓰는 대로 조판해서 보여줘요. ⌘L은 고른 구절로 가는 링크를 놓아요.
                        """,
                        """
                        One thought, in your own words.

                        [[ links to another note. #tag files it. Markdown and LaTeX render as you write. ⌘L drops a link to the passage you selected.
                        """
                    )
                )
                .font(.system(size: NoteTypography.baseSize))
                .lineSpacing(4.5)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, NoteEditor.textOrigin.width)
                .padding(.top, NoteEditor.textOrigin.height)
                .allowsHitTesting(false)
            }
        }
        #else
        // The phone and the iPad write in the Markdown itself — the rendered
        // editor is the Mac's for now — so a passage arrives as the block
        // quote it will always be. It was arriving nowhere at all before:
        // ⌘L and the "노트로" button set the anchor and nothing on these
        // devices was listening for it.
        TextEditor(text: $body_)
            .font(.body)
            .padding(.horizontal, 8)
            .onChange(of: pending) { _, anchor in
                guard let anchor, loadedID == noteID else { return }
                if !body_.isEmpty, !body_.hasSuffix("\n") { body_ += "\n" }
                body_ += NoteMarkdown.quotationSource(for: anchor) + "\n"
                link?.pendingNoteAnchor = nil
            }
        #endif
    }

    @ViewBuilder
    private func connections(_ note: Zettel?) -> some View {
        let inbound = notes.linkedFrom(noteID)
        let outbound = notes.linksOut(of: noteID)
        // Notes this one shares its rarer words with and is not yet linked
        // to either way: the links the box would make if it could.
        let linked = Set(inbound.map(\.id) + outbound.map(\.id) + [noteID])
        let echoes = notes.resonance(with: title + "\n" + body_, excluding: linked, limit: 4)
        if !inbound.isEmpty || !outbound.isEmpty || !echoes.isEmpty {
            // No rule across the note. What separates the writing from what it
            // is connected to is the change of scale and a little air, the
            // same way the rest of the window separates one thing from
            // another.
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !outbound.isEmpty {
                        connectionList(L("내가 가리키는 노트", "Links to"), notes: outbound, symbol: "arrow.up.right")
                    }
                    if !inbound.isEmpty {
                        connectionList(L("나를 가리키는 노트", "Linked from"), notes: inbound, symbol: "arrow.down.left")
                    }
                    if !echoes.isEmpty {
                        echoList(echoes)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
            }
            .frame(maxHeight: 190)
            .hiddenScrollers()
        }
    }

    /// The notes that resonate with this one, each with the words shared and
    /// a way to make the echo a link with one press.
    private func echoList(_ echoes: [(note: Zettel, shared: [String])]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("함께 울리는 노트", "Resonates with").uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(.tertiary)

            ForEach(echoes, id: \.note.id) { echo in
                HStack(spacing: 6) {
                    Button {
                        flush()
                        notes.requestedNoteID = echo.note.id
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "waveform")
                                .font(.caption2)
                                .foregroundStyle(.tint)
                            Text(echo.note.displayTitle)
                                .lineLimit(1)
                            Text(echo.shared.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: Corner.row, style: .continuous)
                                .fill(.quaternary.opacity(0.55))
                        )
                        .contentShape(RoundedRectangle(cornerRadius: Corner.row, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    // One press and the echo is written into the note as a
                    // link — the act a slip-box lives on, without the trip
                    // to the other note to find out what it was called. When
                    // the echo is a map, the press goes the other way: this
                    // note is filed on the map.
                    Button {
                        if echo.note.kind == .map {
                            flush()
                            notes.add(noteID, toMap: echo.note.id)
                        } else {
                            let separator = body_.isEmpty || body_.hasSuffix("\n") ? "" : "\n\n"
                            body_ += separator + echo.note.linkMarkdown
                        }
                    } label: {
                        Image(systemName: echo.note.kind == .map ? "map" : "link.badge.plus")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help(echo.note.kind == .map ? L("이 노트를 지도에 올리기", "Put this note on the map") : L("이 노트를 그 노트에 잇기", "Link this note to it"))
                }
            }
        }
    }

    /// One heading and the notes under it, each as a chip.
    ///
    /// Chips rather than links, and for the same reason a passage in the body
    /// is one: a link says "there is more of this elsewhere", and these are
    /// places in the same box. It also means that everywhere in this app, the
    /// thing you can go to is a rounded tint — in the note, under it, and on
    /// the page.
    private func connectionList(
        _ heading: String, notes list: [Zettel], symbol: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(heading.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(.tertiary)

            ForEach(list) { other in
                Button {
                    flush()
                    notes.requestedNoteID = other.id
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: symbol)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(other.displayTitle)
                            .lineLimit(1)
                    }
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: Corner.row, style: .continuous)
                            .fill(.quaternary.opacity(0.55))
                    )
                    .contentShape(RoundedRectangle(cornerRadius: Corner.row, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Keeping it

    private func load() {
        flush()
        guard let note = notes.note(noteID) else { return }
        title = note.title
        body_ = note.body
        loadedID = noteID
    }

    private func save() {
        guard loadedID == noteID, var note = notes.note(noteID) else { return }
        guard note.title != title || note.body != body_ else { return }
        note.title = title
        note.body = body_
        notes.update(note)
    }

    private func flush() {
        guard let loadedID, var note = notes.note(loadedID) else { return }
        note.title = title
        note.body = body_
        notes.update(note)
        Task { await notes.flush(note) }
    }
}
