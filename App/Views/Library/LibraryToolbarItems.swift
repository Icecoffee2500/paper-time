import SwiftUI
import UniformTypeIdentifiers

/// The library window's toolbar: import, bulk metadata resolution, refresh.
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

        ToolbarItem(placement: .automatic) {
            Button {
                Task { await model.resolveAllPending() }
            } label: {
                if model.resolutionQueueDepth > 0 {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Resolve Metadata", systemImage: "wand.and.stars")
                }
            }
            .accessibilityLabel("Resolve Metadata")
            .disabled(model.resolutionQueueDepth > 0)
        }

        ToolbarItem(placement: .automatic) {
            Button {
                Task { await model.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
    }
}
