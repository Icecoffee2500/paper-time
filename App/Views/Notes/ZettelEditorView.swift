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
            Divider()
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
                if let note {
                    Text(note.id)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .help("The note's permanent identifier")
                }
                Toggle(isOn: $showsRaw) {
                    Label("Raw", systemImage: "chevron.left.forwardslash.chevron.right")
                        .labelStyle(.titleAndIcon)
                }
                .toggleStyle(.button)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Show the note as Markdown, syntax and all")

                Menu {
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

            TextField("Title", text: $title)
                .textFieldStyle(.plain)
                .font(.title3.weight(.semibold))

            if let note, !note.tags.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(note.tags, id: \.self) { tag in
                            Text("#\(tag)")
                                .font(.caption)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(.quaternary))
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
                        pageIndex: anchor.pageIndex, rect: anchor.rect
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
        TextEditor(text: $body_)
            .font(.body)
            .padding(.horizontal, 8)
        #endif
    }

    @ViewBuilder
    private func connections(_ note: Zettel?) -> some View {
        let inbound = notes.linkedFrom(noteID)
        let outbound = notes.linksOut(of: noteID)
        if !inbound.isEmpty || !outbound.isEmpty {
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if !outbound.isEmpty {
                        connectionList("Links to", notes: outbound, symbol: "arrow.up.right")
                    }
                    if !inbound.isEmpty {
                        connectionList("Linked from", notes: inbound, symbol: "arrow.down.left")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .frame(maxHeight: 160)
        }
    }

    private func connectionList(
        _ heading: String, notes list: [Zettel], symbol: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(heading)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(list) { other in
                Button {
                    flush()
                    notes.requestedNoteID = other.id
                } label: {
                    Label(other.displayTitle, systemImage: symbol)
                        .font(.callout)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.link)
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
