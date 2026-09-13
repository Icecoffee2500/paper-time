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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let onClose {
                    Button(action: onClose) {
                        Label("Notes", systemImage: "chevron.left")
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
                .help("Show the note as Markdown, syntax and all")

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
                            Label("Copy Identifier — \(note.id)", systemImage: "number")
                        }
                        Divider()
                    }
                    Button(role: .destructive) {
                        notes.delete(noteID)
                        onClose?()
                    } label: {
                        Label("Delete Note", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            // The one thing on this surface that should be read first.
            TextField("Title", text: $title)
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
        .padding(.top, 14)
        .padding(.bottom, 4)
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
                Text(
                    """
                    One thought, in your own words.

                    [[ links to another note. #tag files it.
                    Markdown and LaTeX are set as you write them.
                    ⌘L drops a link to the passage you selected.
                    """
                )
                .font(.callout)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 17)
                .padding(.top, 18)
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
                        connectionList("Links to", notes: outbound, symbol: "arrow.up.right")
                    }
                    if !inbound.isEmpty {
                        connectionList("Linked from", notes: inbound, symbol: "arrow.down.left")
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
            Text("Resonates with".uppercased())
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
                    .help(echo.note.kind == .map ? "Put this note on the map" : "Link this note to it")
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
