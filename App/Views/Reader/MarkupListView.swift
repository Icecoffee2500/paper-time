import InkEngine
import PDFReader
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Every highlight, underline and note in the open paper, in reading order.
///
/// Reads from the PDF rather than from a private store, so marks made in
/// Preview or any other reader appear here too.
struct MarkupListView: View {
    let session: DocumentSession
    let link: ReaderLink

    @Environment(\.undoManager) private var undoManager
    @State private var filter = Filter.all
    @State private var editingID: UUID?
    @State private var commentDraft = ""
    @State private var flashID: UUID?

    /// What the list is showing. A reader looking for "what did I write about
    /// this paper" should not have to read past sixty highlights to find it.
    enum Filter: String, CaseIterable, Identifiable {
        case all, highlights, underlines, strikethroughs, notes
        var id: String { rawValue }

        var label: String {
            switch self {
            case .all: "All"
            case .highlights: "Highlights"
            case .underlines: "Underlines"
            case .strikethroughs: "Strikethroughs"
            case .notes: "Notes"
            }
        }

        var symbolName: String {
            switch self {
            case .all: "list.bullet"
            case .highlights: "highlighter"
            case .underlines: "underline"
            case .strikethroughs: "strikethrough"
            case .notes: "text.bubble"
            }
        }

        func matches(_ markup: MarkupDescriptor) -> Bool {
            switch self {
            case .all: true
            case .highlights: markup.kind == .highlight
            case .underlines: markup.kind == .underline
            case .strikethroughs: markup.kind == .strikethrough
            case .notes: markup.kind == .note || !markup.comment.isEmpty
            }
        }
    }

    private var shown: [MarkupDescriptor] {
        session.markups.filter(filter.matches)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if shown.isEmpty {
                ContentUnavailableView {
                    Label(emptyTitle, systemImage: filter.symbolName)
                } description: {
                    Text(emptyMessage)
                }
            } else {
                ScrollViewReader { scroller in
                    List {
                        ForEach(shown) { markup in
                            row(markup)
                                .id(markup.id)
                        }
                    }
                    .listStyle(.inset)
                    .hiddenScrollers()
                    .onChange(of: link.revealedMarkID) { _, id in
                        guard let id else { return }
                        reveal(inList: id, using: scroller)
                    }
                    .onAppear {
                        guard let id = link.revealedMarkID else { return }
                        reveal(inList: id, using: scroller)
                    }
                }
            }
        }
        // No navigation title here: this list is presented inside the reader's
        // inspector, and a title set on it replaces the paper's own title in
        // the toolbar.
    }

    /// Says in words what is being shown and how much of it, so the choice
    /// never rests on an icon alone. Laid out across, one press per filter.
    private var header: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(Filter.allCases) { option in
                        chip(option)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .scrollIndicators(.never)
            Divider()
        }
    }

    private func chip(_ option: Filter) -> some View {
        let isOn = filter == option
        let total = count(of: option)
        return Button {
            withAnimation(.snappy(duration: 0.15)) { filter = option }
        } label: {
            HStack(spacing: 5) {
                Text(option.label)
                Text(total, format: .number)
                    .monospacedDigit()
                    .foregroundStyle(isOn ? .white.opacity(0.75) : .secondary)
            }
            .font(.subheadline)
            .foregroundStyle(isOn ? Color.white : .primary)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background {
                Capsule().fill(isOn ? AnyShapeStyle(Color.accentColor)
                                    : AnyShapeStyle(.quaternary))
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(total == 0 && option != .all)
        .opacity(total == 0 && option != .all ? 0.45 : 1)
        .help("\(option.label): \(total)")
    }

    private func count(of filter: Filter) -> Int {
        session.markups.count(where: filter.matches)
    }

    /// Brings a mark clicked on the page into view here, and pulses it so the
    /// eye finds it without hunting.
    private func reveal(inList id: UUID, using scroller: ScrollViewProxy) {
        guard shown.contains(where: { $0.id == id }) else {
            // The mark is filtered out; show everything rather than nothing.
            filter = .all
            DispatchQueue.main.async { reveal(inList: id, using: scroller) }
            return
        }
        withAnimation(.snappy) { scroller.scrollTo(id, anchor: .center) }
        flashID = id
        Task {
            try? await Task.sleep(for: .milliseconds(1400))
            guard flashID == id else { return }
            withAnimation(.easeOut(duration: 0.4)) { flashID = nil }
        }
    }

    @ViewBuilder
    private func row(_ markup: MarkupDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                reveal(markup)
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(color(for: markup.color))
                            .frame(width: 10, height: 10)
                            .accessibilityLabel(markup.color.displayName)
                        Text("Page \(markup.pageIndex + 1)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Label(name(for: markup), systemImage: symbol(for: markup))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .labelStyle(.titleAndIcon)
                    }
                    if !text(of: markup).isEmpty {
                        Text(text(of: markup))
                            .font(.callout)
                            .foregroundStyle(.primary)
                            .lineLimit(5)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if editingID == markup.id {
                HStack(spacing: 8) {
                    TextField("Note", text: $commentDraft, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                        .onSubmit { commitComment(for: markup) }
                    Button("Done") { commitComment(for: markup) }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                }
                .transition(.opacity)
            }
        }
        .padding(.vertical, 2)
        .listRowBackground(
            RoundedRectangle(cornerRadius: Corner.row, style: .continuous)
                .fill(flashID == markup.id ? Color.accentColor.opacity(0.16) : .clear)
                .padding(.horizontal, -4)
        )
        .contextMenu {
            Button {
                startEditing(markup)
            } label: {
                Label(
                    markup.comment.isEmpty ? "Add Note…" : "Edit Note…",
                    systemImage: "square.and.pencil"
                )
            }
            Button {
                copy(markup.quotedText)
            } label: {
                Label("Copy Text", systemImage: "doc.on.doc")
            }
            Divider()
            Button(role: .destructive) {
                delete(markup)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .swipeActions {
            Button(role: .destructive) {
                delete(markup)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            Button {
                startEditing(markup)
            } label: {
                Label("Note", systemImage: "square.and.pencil")
            }
            .tint(.accentColor)
        }
        .animation(.snappy(duration: 0.18), value: editingID)
        .animation(.easeOut(duration: 0.2), value: flashID)
    }

    /// What a row reads as: what the reader wrote about the mark, or failing
    /// that the words they marked.
    private func text(of markup: MarkupDescriptor) -> String {
        markup.comment.isEmpty ? markup.quotedText : markup.comment
    }

    private var emptyTitle: String {
        filter == .all ? "No Marks Yet" : "Nothing \(filter.label) Yet"
    }

    private var emptyMessage: String {
        switch filter {
        case .all: "Select text to highlight it, or draw with your pencil."
        case .notes: "Select a passage and choose the note button to write about it."
        default: "Select text in the paper and pick \(filter.label.lowercased()) from the bar."
        }
    }

    private func reveal(_ markup: MarkupDescriptor) {
        guard let first = markup.rects.first else { return }
        let rect = markup.rects.dropFirst().reduce(first) { $0.union($1) }
        link.anchorRequest = ReaderLink.Anchor(pageIndex: markup.pageIndex, rect: rect)
    }

    private func startEditing(_ markup: MarkupDescriptor) {
        commentDraft = markup.comment
        editingID = markup.id
    }

    private func commitComment(for markup: MarkupDescriptor) {
        session.updateComment(
            commentDraft.trimmingCharacters(in: .whitespacesAndNewlines),
            forMarkup: markup.id
        )
        editingID = nil
        commentDraft = ""
    }

    /// Takes a mark off the page, and remembers it so ⌘Z brings it back.
    private func delete(_ markup: MarkupDescriptor) {
        session.removeMarkup(id: markup.id)
        MarkupUndo.registerRemoval(
            [markup], name: "Delete Mark", in: session, with: undoManager
        )
    }

    private func copy(_ text: String) {
        guard !text.isEmpty else { return }
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    private func name(for markup: MarkupDescriptor) -> String {
        switch markup.kind {
        case .highlight: return "Highlight"
        case .underline: return "Underline"
        case .strikethrough: return "Strikethrough"
        case .note: return "Note"
        }
    }

    private func symbol(for markup: MarkupDescriptor) -> String {
        if !markup.comment.isEmpty { return "text.bubble" }
        switch markup.kind {
        case .highlight: return "highlighter"
        case .underline: return "underline"
        case .strikethrough: return "strikethrough"
        case .note: return "note.text"
        }
    }

    private func color(for markup: MarkupColor) -> Color {
        switch markup {
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .pink: .pink
        case .purple: .purple
        }
    }
}
