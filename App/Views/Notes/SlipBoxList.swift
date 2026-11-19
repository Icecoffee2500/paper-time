import PaperCore
import SwiftUI

/// One of the slip-box's places, as a list (1.1): 문헌 노트 — the notes
/// written against a paper, a book or a document, filtered by the source's
/// kind — or 지식, the notes of no paper, in one area or all of them.
///
/// Search across the place and the tags written in the notes are the two
/// ways in; the links between notes are the third, and they live in the
/// notes themselves.
struct SlipBoxList: View {
    let model: LibraryModel
    /// The place this list shows when it is pinned in a pane of its own
    /// rather than following the sidebar (`Workspace`).
    var pinnedScope: LibraryModel.Scope? = nil
    /// What pressing a note does besides opening it — a pinned list puts it
    /// on the page.
    var onOpenNote: ((String) -> Void)? = nil
    /// How the notes are ordered: the last edited first, the last written
    /// first, or by name. Kept between launches; a probe changes nothing.
    @AppStorage("slipBoxNoteOrder") private var orderRaw = NoteOrder.edited.rawValue
    /// Which sources' notes 문헌 노트 shows — "" for all of them.
    @AppStorage("literatureNoteKind") private var kindRaw = ""

    private var notes: NotesModel { model.notes }
    private var order: NoteOrder { NoteOrder(rawValue: orderRaw) ?? .edited }
    private var kindFilter: ShelfKind? { ShelfKind(rawValue: kindRaw) }

    /// The area shown, when this is 지식 — `.some(nil)` for all of it.
    private var knowledgeArea: String?? {
        if case let .knowledge(area) = pinnedScope ?? model.scope { return .some(area) }
        return nil
    }
    private var isLiterature: Bool { knowledgeArea == nil }

    /// The kind of source a literature note was written against; a paper
    /// this library no longer has counts as a paper.
    private func kind(of note: Zettel) -> ShelfKind {
        note.paperID.flatMap { model.paper($0) }?.meta.shelfKind ?? .paper
    }

    /// Every note of this place, before the search and the chips.
    private var placeNotes: [Zettel] {
        if let area = knowledgeArea { return notes.knowledge(in: area) }
        return notes.literature
    }

    /// What the list shows: this place's notes, narrowed by the search and the
    /// tag, and — in 문헌 노트 — by the source's kind, in the chosen order.
    private var shown: [Zettel] {
        let narrowed = Set(notes.visible.map(\.id))
        var result = placeNotes.filter { narrowed.contains($0.id) }
        if isLiterature, let kindFilter { result = result.filter { kind(of: $0) == kindFilter } }
        return order.sorted(result)
    }

    private var title: String {
        if let area = knowledgeArea { return KnowledgeArea.title(area) }
        return L("문헌 노트", "Literature Notes")
    }

    private var symbol: String {
        if let area = knowledgeArea { return area.map { $0.isEmpty ? "tray" : "folder" } ?? "lightbulb" }
        return "text.quote"
    }

    var body: some View {
        @Bindable var notes = model.notes
        let shown = shown
        let count = placeNotes.count

        VStack(spacing: 0) {
            // The same head every left column wears (`ShelfHeader`): the
            // tile, the name, how many, the order and the pen; the search under
            // it, full width, the way a table's columns sit under a shelf's head.
            #if os(macOS)
            ShelfHeader(symbol: symbol, title: title,
                        subtitle: L("노트 \(count)개", count == 1 ? "1 note" : "\(count) notes")) {
                HStack(spacing: 10) {
                    orderMenu
                    newNoteButton
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 10)
            searchField
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            #else
            HStack(spacing: 10) {
                Text(title)
                    .font(.headline)
                searchField
                orderMenu
                newNoteButton
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 8)
            #endif

            if isLiterature { kindChips }

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
            if Legacy.slipBoxStructures, !isLiterature, notes.query.isEmpty, notes.selectedTag == nil, let squeeze = notes.suggestions.first {
                squeezeBanner(squeeze)
            }

            if shown.isEmpty {
                ContentUnavailableView {
                    Label(emptyTitle(nothingAtAll: count == 0), systemImage: count == 0 ? symbol : "magnifyingglass")
                } description: {
                    Text(emptyNote(nothingAtAll: count == 0))
                }
                .frame(maxHeight: .infinity)
            } else {
                List(selection: Binding(
                    get: { notes.openNoteID },
                    set: { id in
                        notes.openNoteID = id
                        if let id { onOpenNote?(id) }
                    }
                )) {
                    ForEach(shown) { note in
                        SlipNoteRow(note: note, model: model, kind: isLiterature ? kind(of: note) : nil,
                                    showsArea: knowledgeArea == .some(nil) || (knowledgeArea.flatMap { $0 }.map { note.area != $0 } ?? false),
                                    date: order == .created ? note.created : note.modified)
                            .pressable(inset: 6)
                            .tag(note.id)
                            // Onto an area in the sidebar, to file it there.
                            .draggable(NoteTransfer(id: note.id))
                            // A view, so its body is built when the menu opens
                            // rather than when the row is.
                            .contextMenu { SlipNoteMenu(note: note, model: model) }
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

    private func emptyTitle(nothingAtAll: Bool) -> String {
        guard nothingAtAll else { return L("맞는 노트가 없어요", "Nothing Matches") }
        if isLiterature { return L("아직 문헌 노트가 없어요", "No Literature Notes Yet") }
        if case .some(.some(let area)) = knowledgeArea, !area.isEmpty { return L("이 영역에 노트가 없어요", "Nothing in This Area") }
        return L("아직 지식 노트가 없어요", "No Knowledge Notes Yet")
    }

    private func emptyNote(nothingAtAll: Bool) -> String {
        guard nothingAtAll else {
            return L("찾는 말이나 고른 종류에 맞는 노트가 없어요.", "No note matches the search or the kind chosen.")
        }
        if isLiterature {
            return L("논문을 읽으면서 노트 탭에 쓴 노트가 여기 모여요. 그 노트를 쓰게 만든 구절에 이어진 채로요.",
                     "Notes you write in a paper’s Notes tab collect here, linked to the passage that prompted them.")
        }
        if case .some(.some(let area)) = knowledgeArea, !area.isEmpty {
            return L("옆 목록의 이 영역으로 노트를 끌어다 놓거나, 연필을 눌러 여기서 새로 써요.",
                     "Drag notes onto this area in the sidebar, or press the pencil to write one here.")
        }
        return L("내 말로 정리한 노트를 여기 써요. 오른쪽 위 연필로 시작해요.",
                 "Write what you’ve learned in your own words here. Start with the pencil.")
    }

    /// 논문 · 책 · 문서 — the kinds of source this place's notes were written
    /// against, with how many of each; a press keeps only those.
    @ViewBuilder
    private var kindChips: some View {
        let counted = Dictionary(grouping: placeNotes, by: kind(of:)).mapValues(\.count)
        if counted.count > 1 || kindFilter != nil {
            HStack(spacing: 4) {
                kindChip(nil, count: placeNotes.count)
                ForEach(ShelfKind.allCases.filter { counted[$0] != nil || $0 == kindFilter }, id: \.self) { kind in
                    kindChip(kind, count: counted[kind] ?? 0)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
    }

    private func kindChip(_ kind: ShelfKind?, count: Int) -> some View {
        let on = kindFilter == kind
        return Button {
            withAnimation(Motion.tap) { kindRaw = kind?.rawValue ?? "" }
        } label: {
            HStack(spacing: 5) {
                Text(kind?.label ?? L("모두", "All"))
                Text("\(count)").monospacedDigit().opacity(0.7)
            }
            .font(.system(size: 11.5, weight: on ? .semibold : .regular))
            .foregroundStyle(on ? Color.accentColor : .secondary)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(Capsule().fill(on ? Color.accentColor.opacity(0.13) : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var orderMenu: some View {
        Menu {
            Picker(L("정렬", "Sort By"), selection: $orderRaw) {
                ForEach(NoteOrder.allCases) { order in
                    Text(order.label).tag(order.rawValue)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("정렬: \(order.label)", "Sort: \(order.label)"))
    }

    /// A new note here: in 지식, filed in the area shown; in 문헌 노트, on
    /// the paper chosen in the library — a literature note needs a source.
    @ViewBuilder
    private var newNoteButton: some View {
        if let area = knowledgeArea {
            Button {
                let made = model.notes.create(paperID: nil, area: area ?? "").id
                model.notes.openNoteID = made
                onOpenNote?(made)
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(.borderless)
            .help(L("새 노트", "New Note"))
        } else {
            let paper = model.selectedPaper
            Button {
                guard let paper else { return }
                let made = model.notes.create(paperID: paper.id).id
                model.notes.openNoteID = made
                onOpenNote?(made)
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(.borderless)
            .disabled(paper == nil)
            .help(paper.map { L("‘\($0.meta.displayTitle)’에 노트 쓰기", "Write a Note on “\($0.meta.displayTitle)”") }
                  ?? L("문헌 노트는 논문을 고르고 써요", "Choose a paper to write a literature note"))
        }
    }

    private var searchField: some View {
        @Bindable var notes = model.notes
        // A capsule with a glass in it, not a bordered box. The bevelled
        // field was the one control on this surface that still looked like a
        // dialog, and a search field is a search field everywhere else.
        return HStack(spacing: 6) {
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
        .frame(height: 28)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
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
struct SlipNoteMenu: View {
    let note: Zettel
    let model: LibraryModel

    var body: some View {
        Button(L("열기", "Open")) { model.notes.openNoteID = note.id }
        if note.paperID != nil {
            // A literature note turned into knowledge: a new note of one's
            // own that starts with the way back to its source.
            Button {
                rewriteAsKnowledge()
            } label: {
                Label(L("지식으로 옮겨 쓰기", "Rewrite as Knowledge"), systemImage: "lightbulb")
            }
        } else {
            Menu {
                Button(L("분류 안 함", "Unfiled")) { Task { await model.notes.move(note.id, toArea: "") } }
                    .disabled(note.area.isEmpty)
                if !model.notes.areas.isEmpty { Divider() }
                ForEach(model.notes.areas, id: \.self) { area in
                    Button(String(repeating: "  ", count: KnowledgeArea.depth(area) - 1) + KnowledgeArea.name(area)) {
                        Task { await model.notes.move(note.id, toArea: area) }
                    }
                    .disabled(note.area == area)
                }
            } label: {
                Label(L("영역으로 옮기기", "Move to Area"), systemImage: "folder")
            }
        }
        if Legacy.slipBoxStructures, note.kind == .note {
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
        Divider()
        Button(role: .destructive) { model.notes.delete(note.id) } label: {
            Label(L("지우기", "Delete"), systemImage: "trash")
        }
    }

    private func rewriteAsKnowledge() {
        var fresh = model.notes.create(paperID: nil)
        let label = note.displayTitle.replacingOccurrences(of: "]", with: "").replacingOccurrences(of: "|", with: " ")
        fresh.body = L("출처: [[\(note.id)|\(label)]]\n\n", "From: [[\(note.id)|\(label)]]\n\n")
        model.notes.update(fresh)
        model.scope = .knowledge(nil)
        model.notes.openNoteID = fresh.id
    }
}

/// One note in a slip-box list: its title, where it came from — the
/// source's kind and title, or the area it is filed in — and when.
struct SlipNoteRow: View {
    let note: Zettel
    let model: LibraryModel
    /// The kind of source, for a literature note.
    let kind: ShelfKind?
    /// Whether to say the area — when the list holds more than one.
    let showsArea: Bool
    let date: Date

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(note.displayTitle)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                if let line = secondLine {
                    line
                }
            }
            Spacer(minLength: 6)
            Text(Self.when(date))
                .font(.system(size: 11.5))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
    }

    private var secondLine: AnyView? {
        if let kind {
            let source = note.paperID.flatMap { model.paper($0) }
            return AnyView(HStack(spacing: 6) {
                Text(kind.chip)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(kind.tint)
                    .padding(.horizontal, 6)
                    .frame(height: 17)
                    .background(Capsule().fill(kind.tint.opacity(0.12)))
                Text(source?.meta.displayTitle ?? L("라이브러리에 없는 논문", "A paper no longer here"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            })
        }
        if showsArea {
            return AnyView(Label(KnowledgeArea.title(note.area), systemImage: note.area.isEmpty ? "tray" : "folder")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon))
        }
        let preview = note.body.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return preview.map { line in
            AnyView(Text(String(line).trimmingCharacters(in: .whitespaces))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1))
        }
    }

    /// «14:20» today, «11월 18일» this year, the full date before that.
    static func when(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDate(date, equalTo: .now, toGranularity: .year) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(date: .numeric, time: .omitted)
    }
}
