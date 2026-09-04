import InkEngine
import PDFReader
import SwiftUI

/// Every highlight, underline and note in the open paper, newest page first.
///
/// Reads from the PDF rather than from a private store, so marks made in
/// Preview or any other reader appear here too.
struct MarkupListView: View {
    let session: DocumentSession
    @State private var editingID: UUID?
    @State private var commentDraft = ""

    var body: some View {
        List {
            if session.markups.isEmpty {
                ContentUnavailableView(
                    "No Marks Yet",
                    systemImage: "highlighter",
                    description: Text("Select text to highlight it, or draw with your pencil.")
                )
            }
            ForEach(session.markups) { markup in
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
                        Image(systemName: symbol(for: markup.kind))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    if !markup.quotedText.isEmpty {
                        Text(markup.quotedText)
                            .font(.callout)
                            .lineLimit(4)
                    }
                    if !markup.comment.isEmpty, markup.comment != markup.quotedText {
                        Text(markup.comment)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
                .swipeActions {
                    Button(role: .destructive) {
                        session.removeMarkup(id: markup.id)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        // No navigation title here: this list is presented inside the reader's
        // inspector, and a title set on it replaces the paper's own title in
        // the toolbar.
    }

    private func symbol(for kind: MarkupDescriptor.Kind) -> String {
        switch kind {
        case .highlight: "highlighter"
        case .underline: "underline"
        case .strikethrough: "strikethrough"
        case .note: "note.text"
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
