import PaperCore
import SwiftUI

/// The whole slip-box: every note in the library, whichever paper it came from.
///
/// Search across the box and the tags written in the notes are the two ways in;
/// the links between notes are the third, and they live in the notes themselves.
struct SlipBoxList: View {
    let model: LibraryModel

    private var notes: NotesModel { model.notes }

    var body: some View {
        @Bindable var notes = model.notes

        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Notes")
                    .font(.headline)
                Spacer()
                Button {
                    notes.openNoteID = notes.create(paperID: nil).id
                } label: {
                    Label("New Note", systemImage: "square.and.pencil")
                }
                .buttonStyle(.borderless)
                .help("Write a note of your own")
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 6)

            TextField("Search notes", text: $notes.query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            if !notes.tags.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(notes.tags, id: \.tag) { entry in
                            tagChip(entry.tag, count: entry.count)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                }
                .scrollIndicators(.never)
            }
            Divider()

            if notes.visible.isEmpty {
                ContentUnavailableView {
                    Label(notes.notes.isEmpty ? "The Box Is Empty" : "Nothing Matches",
                          systemImage: "tray")
                } description: {
                    Text(notes.notes.isEmpty
                         ? "Notes you write while reading appear here, linked to the passage that caused them."
                         : "No note matches what you are looking for.")
                }
                .frame(maxHeight: .infinity)
            } else {
                List(selection: $notes.openNoteID) {
                    ForEach(notes.visible) { note in
                        NoteRow(note: note, showsSource: source(of: note))
                            .tag(note.id)
                            .contextMenu {
                                Button(role: .destructive) { model.notes.delete(note.id) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                }
                .listStyle(.inset)
                .thinScrollers()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func tagChip(_ tag: String, count: Int) -> some View {
        let isOn = notes.selectedTag == tag
        return Button {
            model.notes.selectedTag = isOn ? nil : tag
        } label: {
            HStack(spacing: 4) {
                Text("#\(tag)")
                Text(count, format: .number)
                    .monospacedDigit()
                    .foregroundStyle(isOn ? .white.opacity(0.75) : .secondary)
            }
            .font(.caption)
            .foregroundStyle(isOn ? Color.white : .primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background {
                Capsule().fill(isOn ? AnyShapeStyle(Color.accentColor)
                                    : AnyShapeStyle(.quaternary))
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// The paper a note was written against, named rather than numbered.
    private func source(of note: Zettel) -> String? {
        guard let paperID = note.paperID, let paper = model.paper(paperID) else { return nil }
        return paper.meta.csl.fullTitle
    }
}

/// The slip-box's detail pane: the note that is open, or an invitation.
struct SlipBoxDetail: View {
    let model: LibraryModel

    var body: some View {
        if let id = model.notes.openNoteID, model.notes.note(id) != nil {
            ZettelEditorView(notes: model.notes, noteID: id, link: nil)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
                .onChange(of: model.notes.requestedNoteID) { _, requested in
                    guard let requested else { return }
                    model.notes.openNoteID = requested
                    model.notes.requestedNoteID = nil
                }
        } else {
            ContentUnavailableView {
                Label("No Note Selected", systemImage: "note.text")
            } description: {
                Text("Choose a note, or write a new one.")
            }
        }
    }
}
