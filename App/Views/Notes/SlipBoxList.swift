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
            // One row: the name, the search, the pen. Two rows put the field
            // under the title and pushed the first note down a line for no
            // reason a reader could see.
            HStack(spacing: 10) {
                Text(L("노트", "Notes"))
                    .font(.headline)

                // A capsule with a glass in it, not a bordered box. The
                // bevelled field is the one control on this surface that
                // still looked like a dialog, and a search field is a search
                // field everywhere else on the machine.
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                    TextField(L("노트 찾기", "Search notes"), text: $notes.query)
                        .textFieldStyle(.plain)
                    if !notes.query.isEmpty {
                        Button {
                            model.notes.query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help(L("찾을 말 지우기", "Clear the search"))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(.quaternary.opacity(0.5)))

                Menu {
                    Button {
                        notes.openNoteID = notes.create(paperID: nil).id
                    } label: { Label(L("새 노트", "New Note"), systemImage: "note.text") }
                    Button {
                        notes.openNoteID = notes.create(paperID: nil, kind: .map).id
                    } label: { Label(L("새 지도", "New Map"), systemImage: "map") }
                    Button {
                        notes.openNoteID = notes.create(paperID: nil, kind: .draft).id
                    } label: { Label(L("새 초안", "New Draft"), systemImage: "doc.text") }
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(L("노트·지도·초안 쓰기", "Write a note, a map, or a draft"))
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
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

            // The squeeze: notes with no home that hang together. One line,
            // and a map is one press — Milo's moment, noticed for you.
            if notes.query.isEmpty, notes.selectedTag == nil, let squeeze = notes.suggestions.first {
                squeezeBanner(squeeze)
            }

            if notes.visible.isEmpty {
                ContentUnavailableView {
                    Label(notes.notes.isEmpty ? L("아직 노트가 없어요", "No Notes Yet") : L("맞는 노트가 없어요", "Nothing Matches"),
                          systemImage: "tray")
                } description: {
                    Text(notes.notes.isEmpty
                         ? L("읽으면서 쓴 노트가 여기 모여요. 그 노트를 쓰게 만든 구절에 이어진 채로요.", "Notes you write while reading collect here, linked to the passage that prompted them.")
                         : L("찾는 말에 맞는 노트가 없어요.", "No note matches that search."))
                }
                .frame(maxHeight: .infinity)
            } else {
                // Grouped by the paper they were written against, each group
                // in the order its notes were written, and the groups in the
                // order their first note was — so a note stays where it is.
                List(selection: $notes.openNoteID) {
                    ForEach(groups, id: \.id) { group in
                        Section {
                            ForEach(group.notes) { note in
                                NoteRow(note: note)
                                    .pressable(inset: 6)
                                    .tag(note.id)
                                    // A view, so its body is built when the
                                    // menu opens rather than when the row is:
                                    // the filing menu asks the box for every
                                    // map and every draft it holds, and it
                                    // was asking once per note in the list.
                                    .contextMenu { NoteMenu(note: note, model: model) }
                            }
                        } header: {
                            // The paper as a chip, the same shape the library
                            // folder wears in the source list: a group of
                            // notes is named, not ruled off. A line over
                            // every group and under every note made the box
                            // read as a table.
                            Text(group.title)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(group.id == "-" ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: Corner.control - 2, style: .continuous)
                                        .fill(Color.accentColor.opacity(group.id == "-" ? 0 : 0.12))
                                )
                                .padding(.bottom, 2)
                        }
                    }
                }
                // The source list's style: rounded selection, and no rule
                // between one note and the next.
                .listStyle(.sidebar)
                // An inset list paints its own opaque white, which is why the
                // lists were the one white rectangle in a window of glass. The
                // panel behind them is the background now.
                .scrollContentBackground(.hidden)
                .hiddenScrollers()
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

    private struct NoteGroup {
        let id: String
        let title: String
        var notes: [Zettel]
    }

    /// Where a note can go: onto a map, or into a draft.
    @ViewBuilder


    /// "These notes hang together; make them a map?"
    private func squeezeBanner(_ squeeze: Atlas.Suggestion) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "map")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("노트 \(squeeze.noteIDs.count)개가 한 주제를 보고 있어요", "\(squeeze.noteIDs.count) notes circle one subject"))
                    .font(.callout.weight(.medium))
                Text(squeeze.words.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.tint)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button(L("지도 만들기", "Make a Map")) {
                let map = model.notes.createMap(from: squeeze) { model.paper($0)?.meta.csl.fullTitle }
                model.notes.openNoteID = map.id
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: Corner.row, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    /// The visible notes by paper, notes of no paper last — and the maps
    /// first of all, since a map is where the others live.
    private var groups: [NoteGroup] {
        var found: [NoteGroup] = []
        var index: [String: Int] = [:]
        let maps = notes.visible.filter { $0.kind == .map }
        if !maps.isEmpty { found.append(NoteGroup(id: "maps", title: L("지도", "Maps"), notes: maps)); index["maps"] = found.count - 1 }
        let drafts = notes.visible.filter { $0.kind == .draft }
        if !drafts.isEmpty { found.append(NoteGroup(id: "drafts", title: L("초안", "Drafts"), notes: drafts)); index["drafts"] = found.count - 1 }
        for note in notes.visible where note.kind == .note {
            // A paper this library no longer has is no group of its own:
            // three chips all saying "Notes of my own" said nothing.
            let paper = note.paperID.flatMap { model.paper($0) }
            let key = paper.map { $0.id.uuidString } ?? "-"
            if let at = index[key] {
                found[at].notes.append(note)
            } else {
                let title = paper?.meta.csl.fullTitle ?? paper?.meta.displayTitle ?? L("따로 쓴 노트", "Notes of my own")
                index[key] = found.count
                found.append(NoteGroup(id: key, title: title, notes: [note]))
            }
        }
        let special = ["maps", "drafts"]
        return found.filter { special.contains($0.id) } + found.filter { $0.id != "-" && !special.contains($0.id) } + found.filter { $0.id == "-" }
    }
}

/// The slip-box's detail pane: the note that is open, or an invitation.
struct SlipBoxDetail: View {
    let model: LibraryModel
    /// The handle the note's passage links speak through.
    ///
    /// This was nil, and a nil link is a link that goes nowhere: `⌘L` had
    /// written the passage into the note, the chip was drawn, and clicking it
    /// set an anchor on nothing. The slip-box had no paper open beside it, so
    /// there seemed to be nothing to ask — but the note remembers which paper
    /// it was written against, which is enough to open it.
    let link: ReaderLink
    /// Called when a passage in the open note is clicked, with the paper it
    /// came from.
    var onFollowPassage: (UUID) -> Void = { _ in }

    var body: some View {
        if let id = model.notes.openNoteID, let note = model.notes.note(id) {
            Group {
                if note.kind == .map {
                    MapView(model: model, mapID: id, link: link)
                } else if note.kind == .draft {
                    DraftView(model: model, draftID: id, link: link)
                        .frame(maxWidth: 760)
                } else {
                    ZettelEditorView(notes: model.notes, noteID: id, link: link)
                        .frame(maxWidth: 760)
                }
            }
                .frame(maxWidth: .infinity)
                .onChange(of: link.anchorRequest) { _, request in
                    // The reader consumes the request; this only has to
                    // notice one was made, and say which paper it is for —
                    // the passage's own, or failing that the note's.
                    guard let request,
                          let paperID = request.paperID ?? model.notes.note(id)?.paperID
                    else { return }
                    onFollowPassage(paperID)
                }
                .onChange(of: model.notes.requestedNoteID) { _, requested in
                    guard let requested else { return }
                    model.notes.openNoteID = requested
                    model.notes.requestedNoteID = nil
                }
        } else {
            ContentUnavailableView {
                Label(L("고른 노트가 없어요", "No Note Selected"), systemImage: "note.text")
            } description: {
                Text(L("노트를 고르거나 새로 쓰면 돼요.", "Choose a note, or write a new one."))
            }
            // An empty panel is still a panel. Without this it shrank to the
            // size of the words in it and sat on the ground as a card.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// What a right-click on a note offers: where to file it, and the way out.
///
/// Its own view for the reason `PaperMenu` is one — the body of a view is
/// built when it is shown, and a `@ViewBuilder` closure is built with the row.
private struct NoteMenu: View {
    let note: Zettel
    let model: LibraryModel

    var body: some View {
        if note.kind == .note {
            let maps = model.notes.maps
            let drafts = model.notes.drafts
            if !maps.isEmpty {
                Menu(L("지도에 올리기", "Put on Map")) {
                    ForEach(maps) { map in
                        Button(map.displayTitle) { model.notes.add(note.id, toMap: map.id) }
                    }
                }
            }
            if !drafts.isEmpty {
                Menu(L("초안에 넣기", "Add to Draft")) {
                    ForEach(drafts) { draft in
                        Button(draft.displayTitle) { model.notes.add(note.id, toMap: draft.id) }
                    }
                }
            }
        }
        Button(role: .destructive) { model.notes.delete(note.id) } label: {
            Label(L("지우기", "Delete"), systemImage: "trash")
        }
    }
}
