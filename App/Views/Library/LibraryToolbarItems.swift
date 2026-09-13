import SwiftUI
import UniformTypeIdentifiers

/// The list column's toolbar.
///
/// Deliberately one button. Refreshing and re-running metadata resolution are
/// occasional, already carry keyboard shortcuts, and live in the Library menu;
/// keeping them here made a five-button row where the eye had nothing to
/// latch on to.
struct LibraryToolbarItems: ToolbarContent {
    let model: LibraryModel

    @State private var isImportingPDFs = false

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                isImportingPDFs = true
            } label: {
                Label("Add PDFs", systemImage: "doc.badge.plus")
            }
            .fileImporter(
                isPresented: $isImportingPDFs,
                allowedContentTypes: [.pdf],
                allowsMultipleSelection: true
            ) { result in
                guard case let .success(urls) = result else { return }
                Task { await model.importDocuments(at: urls) }
            }
        }

    }
}
