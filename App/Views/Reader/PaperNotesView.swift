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

    private var notes: NotesModel { model.notes }

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
            HStack(spacing: 8) {
                Text(mine.count == 1 ? "1 note" : "\(mine.count) notes")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button {
                    openID = notes.create(paperID: paperID).id
                } label: {
                    Label("New Note", systemImage: "square.and.pencil")
                }
                .buttonStyle(.borderless)
                .help("Write a new note about this paper")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()

            if mine.isEmpty {
                ContentUnavailableView {
                    Label("No Notes Yet", systemImage: "note.text")
                } description: {
                    Text("One thought per note. Select a passage and press ⌘L to link to it.")
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
                                    Label("Delete", systemImage: "trash")
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
