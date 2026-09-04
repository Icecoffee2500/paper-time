import Importers
import LibraryStore
import SwiftUI
import UniformTypeIdentifiers

/// Brings an existing Bookends or Zotero library across.
///
/// The screen shows exactly what will happen before anything is copied,
/// because a migration that silently attaches the wrong PDF to the wrong
/// record is very hard to notice and very annoying to undo.
struct MigrationView: View {
    let model: LibraryModel
    @Environment(\.dismiss) private var dismiss

    @State private var bibliographyURL: URL?
    @State private var attachmentsURL: URL?
    @State private var plan: LibraryMigrator.Plan?
    @State private var isChoosingBibliography = false
    @State private var isChoosingAttachments = false
    @State private var isImporting = false
    @State private var errorMessage: String?
    @State private var result: (imported: Int, failed: Int)?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Bibliography") {
                        Button(bibliographyURL?.lastPathComponent ?? "Choose .bib or .ris…") {
                            isChoosingBibliography = true
                        }
                    }
                    LabeledContent("PDF Folder") {
                        Button(attachmentsURL?.lastPathComponent ?? "Choose folder…") {
                            isChoosingAttachments = true
                        }
                    }
                } header: {
                    Text("What to Import")
                } footer: {
                    Text(
                        """
                        In Bookends choose File ▸ Export and pick BibTeX, then point Paper Time \
                        at the exported file and at your Attachments folder.
                        """
                    )
                }

                if let plan {
                    Section("Preview") {
                        LabeledContent("Records found", value: "\(plan.totalRecords)")
                        LabeledContent("PDFs matched", value: "\(plan.matched.count)")
                        LabeledContent(
                            "Records without a PDF",
                            value: "\(plan.withoutDocuments.count)"
                        )
                        LabeledContent(
                            "PDFs no record mentions",
                            value: "\(plan.orphanedDocuments.count)"
                        )
                    }

                    if !plan.matched.isEmpty {
                        Section("Matches") {
                            ForEach(plan.matched.prefix(50)) { entry in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.record.csl.fullTitle ?? entry.record.bibKey)
                                        .font(.callout)
                                        .lineLimit(2)
                                    Text(entry.documentURL?.lastPathComponent ?? "")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    Text(entry.matchReason)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            if plan.matched.count > 50 {
                                Text("and \(plan.matched.count - 50) more")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if !plan.warnings.isEmpty {
                        Section("Warnings") {
                            ForEach(plan.warnings.prefix(20), id: \.self) { warning in
                                Label(warning, systemImage: "exclamationmark.triangle")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Section {
                        Text(
                            """
                            Imported records start as "needs review". Paper Time re-checks each \
                            one against the DOI, arXiv and OpenAlex records and confirms the ones \
                            it can prove, so mistakes in the old library do not carry over.
                            """
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }

                if let result {
                    Section("Done") {
                        LabeledContent("Papers added", value: "\(result.imported)")
                        if result.failed > 0 {
                            LabeledContent("Failed", value: "\(result.failed)")
                                .foregroundStyle(.orange)
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Import Existing Library")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isImporting ? "Importing…" : "Import") {
                        Task { await runImport() }
                    }
                    .disabled(plan == nil || isImporting)
                }
            }
            .fileImporter(
                isPresented: $isChoosingBibliography,
                allowedContentTypes: [.data],
                allowsMultipleSelection: false
            ) { outcome in
                if case let .success(urls) = outcome { bibliographyURL = urls.first }
                buildPlan()
            }
            .fileImporter(
                isPresented: $isChoosingAttachments,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { outcome in
                if case let .success(urls) = outcome { attachmentsURL = urls.first }
                buildPlan()
            }
        }
    }

    private func buildPlan() {
        guard let bibliographyURL else { return }
        errorMessage = nil
        let scopedBibliography = bibliographyURL.startAccessingSecurityScopedResource()
        let scopedAttachments = attachmentsURL?.startAccessingSecurityScopedResource() ?? false
        defer {
            if scopedBibliography { bibliographyURL.stopAccessingSecurityScopedResource() }
            if scopedAttachments { attachmentsURL?.stopAccessingSecurityScopedResource() }
        }
        do {
            plan = try LibraryMigrator.plan(
                bibliographyAt: bibliographyURL,
                attachmentsFolder: attachmentsURL
            )
        } catch {
            errorMessage = error.localizedDescription
            plan = nil
        }
    }

    private func runImport() async {
        guard let plan else { return }
        isImporting = true
        defer { isImporting = false }

        let scopedAttachments = attachmentsURL?.startAccessingSecurityScopedResource() ?? false
        defer { if scopedAttachments { attachmentsURL?.stopAccessingSecurityScopedResource() } }

        let outcome = await LibraryMigrator.apply(plan, to: model.store)
        result = (outcome.imported.count, outcome.failures.count)
        await model.refresh()
        // Re-verify everything that came across, which is the point of the
        // "needs review" starting state.
        Task { await model.resolveAllPending() }
    }
}
