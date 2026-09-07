import PaperCore
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// An editable, reorderable author byline.
///
/// Structured name parsing from a PDF header is often wrong for the middle of
/// an author list, so "Paste names" exists as a one-tap way to replace the
/// whole list from whatever the source (an abstract page, a BibTeX entry) had.
struct AuthorListEditor: View {
    @Binding var authors: [CSLName]

    /// Collapsed until asked for.
    ///
    /// Two text fields per author is forty controls on a paper with twenty of
    /// them, and building those is a visible part of the wait when a paper is
    /// opened. The byline reads fine as text; editing is one click away.
    @State private var isEditing = false

    var body: some View {
        Section("Authors") {
            DisclosureGroup(isExpanded: $isEditing) {
                ForEach(authors.indices, id: \.self) { index in
                    HStack {
                        TextField("Given", text: binding(at: index, \.given))
                            .textContentType(.givenName)
                        TextField("Family", text: binding(at: index, \.family))
                            .textContentType(.familyName)
                    }
                }
                .onMove { authors.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { authors.remove(atOffsets: $0) }

                Button {
                    authors.append(CSLName())
                } label: {
                    Label("Add Author", systemImage: "person.badge.plus")
                }

                Button {
                    pasteNames()
                } label: {
                    Label("Paste Names", systemImage: "doc.on.clipboard")
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(byline)
                        .lineLimit(isEditing ? 1 : 3)
                        .foregroundStyle(authors.isEmpty ? .secondary : .primary)
                    Text(authors.count == 1 ? "1 author" : "\(authors.count) authors")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var byline: String {
        authors.isEmpty
            ? "No authors"
            : authors.map(\.displayName).joined(separator: ", ")
    }

    private func binding(at index: Int, _ keyPath: WritableKeyPath<CSLName, String?>) -> Binding<String> {
        Binding(
            get: { authors[index][keyPath: keyPath] ?? "" },
            set: { authors[index][keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }

    /// Splits a pasted author block on `;`, `,` or ` and `, then hands each
    /// piece to `CSLName.parse` and replaces the list in one action.
    private func pasteNames() {
        guard let text = pasteboardString(), !text.isEmpty else { return }

        let normalized = text.replacingOccurrences(
            of: " and ",
            with: ";",
            options: .caseInsensitive
        )
        let pieces = normalized
            .components(separatedBy: CharacterSet(charactersIn: ";,"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !pieces.isEmpty else { return }
        authors = pieces.map(CSLName.parse)
    }

    private func pasteboardString() -> String? {
        #if os(macOS)
        NSPasteboard.general.string(forType: .string)
        #else
        UIPasteboard.general.string
        #endif
    }
}
