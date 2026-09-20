import PaperCore
import SwiftUI

/// A map of content, seen as a map.
///
/// The note is Markdown — headings, and links under them — and can be
/// written as such; but read, it is a board: a column per heading, a card
/// per note with its opening words and where it came from, and beside the
/// board the notes that echo the map and are not on it yet, each a press
/// away from being filed. Milo's point is that the map is the home a note
/// has instead of a folder; this is the home with the door open.
struct MapView: View {
    let model: LibraryModel
    let mapID: String
    let link: ReaderLink

    @State private var editsText = false

    private var notes: NotesModel { model.notes }

    var body: some View {
        if editsText {
            ZettelEditorView(notes: notes, noteID: mapID, link: link)
                .frame(maxWidth: 760)
                .overlay(alignment: .topTrailing) { modeToggle.padding(12) }
        } else if let map = notes.note(mapID) {
            VStack(alignment: .leading, spacing: 0) {
                header(map)
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(Array(map.outline.enumerated()), id: \.offset) { _, section in
                            column(section)
                        }
                        unfiled(map)
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 20)
                }
                .scrollIndicators(.never)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func header(_ map: Zettel) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Label(map.displayTitle, systemImage: "map")
                .font(.title2.weight(.semibold))
                .lineLimit(1)
            Text(L("노트 \(map.outline.reduce(0) { $0 + $1.entries.count })개", "\(map.outline.reduce(0) { $0 + $1.entries.count }) notes"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            modeToggle
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    /// Map or text: the same note, two ways to hold it.
    private var modeToggle: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { editsText.toggle() }
        } label: {
            Label(editsText ? L("지도로 보기", "Show as Map") : L("글로 편집하기", "Edit as Text"),
                  systemImage: editsText ? "map" : "chevron.left.forwardslash.chevron.right")
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .help(editsText ? L("지도를 보드로 보기", "Show the map as a board") : L("지도를 Markdown으로 편집하기", "Edit the map as Markdown"))
    }

    /// One heading and its cards.
    private func column(_ section: MapSection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(section.title.isEmpty ? "—" : section.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 4)
            ForEach(section.entries, id: \.id) { entry in
                if let note = notes.note(entry.id) {
                    card(note)
                } else {
                    Text(entry.label.isEmpty ? entry.id : entry.label)
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .padding(10)
                }
            }
        }
        .frame(width: 230, alignment: .leading)
    }

    private func card(_ note: Zettel) -> some View {
        Button {
            notes.openNoteID = note.id
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(note.displayTitle)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                if !note.previewBody.isEmpty {
                    Text(note.previewBody)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                if let paperID = note.paperID, let paper = model.paper(paperID) {
                    Text(paper.meta.csl.fullTitle ?? paper.meta.displayTitle)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: Corner.row, style: .continuous).fill(.background))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .pressable()
    }

    /// Notes that echo the map and are not on it: the door left open.
    @ViewBuilder
    private func unfiled(_ map: Zettel) -> some View {
        let housed = Set(map.outline.flatMap { $0.entries.map(\.id) }) .union([map.id])
        let echoes = notes.resonance(with: map.title + "\n" + map.body, excluding: housed, limit: 6)
            .filter { $0.note.kind == .note }
        if !echoes.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label(L("울리지만 아직 안 올린 노트", "Resonates, not filed"), systemImage: "waveform")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                    .padding(.horizontal, 4)
                ForEach(echoes, id: \.note.id) { echo in
                    HStack(alignment: .top, spacing: 6) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(echo.note.displayTitle).font(.callout).lineLimit(2)
                            Text(echo.shared.joined(separator: " · ")).font(.caption2).foregroundStyle(.tint).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Button {
                            notes.add(echo.note.id, toMap: map.id)
                        } label: {
                            Image(systemName: "plus.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .help(L("이 노트를 지도에 올리기", "Put this note on the map"))
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: Corner.row, style: .continuous).fill(Color.accentColor.opacity(0.07)))
                }
            }
            .frame(width: 230, alignment: .leading)
        }
    }
}
