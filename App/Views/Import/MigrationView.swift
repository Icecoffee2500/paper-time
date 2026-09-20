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
                    LabeledContent(L("서지 파일", "Bibliography")) {
                        Button(bibliographyURL?.lastPathComponent ?? L(".bib 또는 .ris 고르기…", "Choose .bib or .ris…")) {
                            isChoosingBibliography = true
                        }
                    }
                    LabeledContent(L("PDF 폴더", "PDF Folder")) {
                        Button(attachmentsURL?.lastPathComponent ?? L("폴더 고르기…", "Choose folder…")) {
                            isChoosingAttachments = true
                        }
                    }
                } header: {
                    Text(L("들여올 것", "What to Import"))
                } footer: {
                    Text(L(
                        """
                        Bookends에서 File ▸ Export를 골라 BibTeX을 고른 다음, Paper Time에 내보낸 파일과 \
                        Attachments 폴더를 가리켜 준다.
                        """,
                        """
                        In Bookends choose File ▸ Export and pick BibTeX, then point Paper Time \
                        at the exported file and at your Attachments folder.
                        """
                    ))
                }

                if let plan {
                    Section(L("미리 보기", "Preview")) {
                        LabeledContent(L("찾은 항목", "Records found"), value: "\(plan.totalRecords)")
                        LabeledContent(L("짝지은 PDF", "PDFs matched"), value: "\(plan.matched.count)")
                        LabeledContent(
                            L("PDF 없는 항목", "Records without a PDF"),
                            value: "\(plan.withoutDocuments.count)"
                        )
                        LabeledContent(
                            L("어느 항목도 가리키지 않는 PDF", "PDFs no record mentions"),
                            value: "\(plan.orphanedDocuments.count)"
                        )
                    }

                    if !plan.matched.isEmpty {
                        Section(L("짝지은 것", "Matches")) {
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
                                Text(L("그리고 \(plan.matched.count - 50)개 더", "and \(plan.matched.count - 50) more"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if !plan.warnings.isEmpty {
                        Section(L("경고", "Warnings")) {
                            ForEach(plan.warnings.prefix(20), id: \.self) { warning in
                                Label(warning, systemImage: "exclamationmark.triangle")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Section {
                        Text(L(
                            """
                            들여온 항목은 "Needs Review"로 시작한다. Paper Time이 하나하나 DOI·arXiv·OpenAlex \
                            기록과 다시 맞춰 보고 증명할 수 있는 것만 확인하므로, 옛 라이브러리의 실수가 \
                            따라오지 않는다.
                            """,
                            """
                            Imported records start as "needs review". Paper Time re-checks each \
                            one against the DOI, arXiv and OpenAlex records and confirms the ones \
                            it can prove, so mistakes in the old library do not carry over.
                            """
                        ))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }

                if let result {
                    Section(L("끝", "Done")) {
                        LabeledContent(L("더한 논문", "Papers added"), value: "\(result.imported)")
                        if result.failed > 0 {
                            LabeledContent(L("실패", "Failed"), value: "\(result.failed)")
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
            .navigationTitle(L("있던 라이브러리 들여오기", "Import Existing Library"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("닫기", "Close")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isImporting ? L("들여오는 중…", "Importing…") : L("들여오기", "Import")) {
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
