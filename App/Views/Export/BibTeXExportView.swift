import Bibliography
import LibraryStore
import PaperCore
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Turns a selection of papers into a `.bib` file, previewed before it leaves
/// the app.
///
/// Presented as a sheet from the library toolbar. It never writes back into
/// the library itself — export is a one-way read of whatever the model
/// already holds.
struct BibTeXExportView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    /// What set of papers to export. `.collection` needs a second picker for
    /// which one, so it is kept separate from the id it names.
    enum ScopeKind: String, CaseIterable, Identifiable {
        case selectedPaper, currentView, wholeLibrary, collection
        var id: String { rawValue }

        var label: String {
            switch self {
            case .selectedPaper: L("고른 논문", "Selected Paper")
            case .currentView: L("지금 보이는 목록", "Current View")
            case .wholeLibrary: L("라이브러리 전체", "Whole Library")
            case .collection: L("컬렉션", "Collection")
            }
        }
    }

    @State private var scopeKind: ScopeKind = .currentView
    @State private var selectedCollectionID: UUID?
    @State private var options = BibTeXExportOptions()
    @State private var previewText = ""
    @State private var isExporting = false
    @State private var exportDocument = BibTeXDocument(text: "")

    private var model: LibraryModel? { app.library }

    var body: some View {
        NavigationStack {
            Form {
                scopeSection
                optionsSection
                if reviewCount > 0 {
                    warningSection
                }
                previewSection
            }
            .formStyle(.grouped)
            .navigationTitle(L("BibTeX 내보내기", "Export BibTeX"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("취소", "Cancel")) { dismiss() }
                }
                ToolbarItemGroup(placement: .confirmationAction) {
                    Button(L("복사", "Copy")) { copyToClipboard() }
                        .disabled(papersInScope.isEmpty)
                    Button(L("저장…", "Save…")) {
                        exportDocument = BibTeXDocument(text: makeBibTeX())
                        isExporting = true
                    }
                    .disabled(papersInScope.isEmpty)
                    Button(L("완료", "Done")) { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .task { regeneratePreview() }
        .onChange(of: scopeKind) { regeneratePreview() }
        .onChange(of: selectedCollectionID) { regeneratePreview() }
        .onChange(of: options) { regeneratePreview() }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .plainText,
            defaultFilename: "references.bib"
        ) { _ in }
    }

    // MARK: - Sections

    private var scopeSection: some View {
        Section(L("내보내기", "Export")) {
            Picker(L("범위", "Scope"), selection: $scopeKind) {
                ForEach(ScopeKind.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            if scopeKind == .collection {
                Picker(L("컬렉션", "Collection"), selection: $selectedCollectionID) {
                    Text(L("컬렉션 고르기", "Choose a Collection")).tag(UUID?.none)
                    ForEach(model?.collections.collections ?? []) { collection in
                        Text(collection.name).tag(Optional(collection.id))
                    }
                }
            }
        }
    }

    private var optionsSection: some View {
        Section(L("옵션", "Options")) {
            Picker(L("프리프린트 양식", "Preprint Style"), selection: $options.preprintStyle) {
                ForEach(BibTeXExportOptions.PreprintStyle.allCases, id: \.self) { style in
                    Text(style.displayName).tag(style)
                }
            }
            Toggle(L("제목 대소문자 지키기", "Protect Case in Titles"), isOn: $options.protectCase)
            Toggle(L("학술지 이름 줄이기", "Abbreviate Journal Names"), isOn: $options.abbreviateJournals)
            Toggle(L("초록 넣기", "Include Abstract"), isOn: $options.includeAbstract)
            Toggle(L("키워드 넣기", "Include Keywords"), isOn: $options.includeKeywords)
            Toggle(L("URL 넣기", "Include URL"), isOn: $options.includeURL)
            Toggle(L("확인 안 된 항목도 넣기", "Include Unverified Records"), isOn: $options.includeUnverified)
        }
    }

    private var warningSection: some View {
        Section {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel(L("경고", "Warning"))
                Text(warningText)
                    .font(.callout)
            }
        }
    }

    private var previewSection: some View {
        Section(L("미리 보기", "Preview")) {
            ScrollView {
                Text(previewText.isEmpty ? L("아직 내보낼 것이 없어요.", "Nothing to export yet.") : previewText)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 220, maxHeight: 420)

            ExportInstructionsView()
        }
    }

    // MARK: - Scope resolution

    /// The papers named by the current scope, before the verified/manual
    /// filter that decides what actually gets written.
    private var papersInScope: [LoadedPaper] {
        guard let model else { return [] }
        switch scopeKind {
        case .selectedPaper:
            return model.selectedPaper.map { [$0] } ?? []
        case .currentView:
            return model.visiblePapers
        case .wholeLibrary:
            return model.papers
        case .collection:
            guard let selectedCollectionID,
                  let collection = model.collections.collections.first(where: { $0.id == selectedCollectionID })
            else { return [] }
            guard let rule = collection.rule else {
                return model.papers.filter { $0.meta.collectionIDs.contains(selectedCollectionID) }
            }
            return model.papers.filter { SmartRuleEvaluator.matches(rule, paper: $0, tags: model.manifest.tags) }
        }
    }

    /// Only papers are counted here. Neither a document nor a book is ever
    /// "unverified" — neither has a registrar to be verified against — and
    /// counting manuals as unfinished business made the warning cry wolf.
    private var reviewCount: Int {
        papersInScope.filter {
            $0.meta.effectiveKind.isLookedUp
                && ($0.meta.confidence == .needsReview || $0.meta.confidence == .unparsed)
        }.count
    }

    private var warningText: String {
        let noun = reviewCount == 1 ? "paper hasn't" : "papers haven't"
        let verb = options.includeUnverified ? "will still be included" : "will be left out of this export"
        return L(
            "\(reviewCount)편은 아직 확인하지 못했어요. \(options.includeUnverified ? "그래도 들어가요" : "이번 내보내기에서는 빠져요"). 바꾸려면 “확인 안 된 항목도 넣기”를 켜면 돼요.",
            else: "\(reviewCount) \(noun) been verified and \(verb). Turn on “Include Unverified Records” to change that."
        )
    }

    // MARK: - Generation

    /// Builds the `.bib` file for the current scope and options.
    ///
    /// Candidates are sorted by citation key before writing so that exporting
    /// the same library twice produces byte-identical output — the property
    /// that makes it safe to overwrite the same file in Overleaf repeatedly.
    private func makeBibTeX() -> String {
        let candidates = papersInScope.filter {
            options.includeUnverified || $0.meta.confidence == .verified || $0.meta.confidence == .manual
        }
        let keys = CitationKey.assignKeys(to: candidates.map {
            (id: $0.id, item: $0.meta.csl, preferred: $0.meta.bibKey.isEmpty ? nil : $0.meta.bibKey)
        })
        let sorted = candidates.sorted { (keys[$0.id] ?? "") < (keys[$1.id] ?? "") }
        let entries = sorted.map {
            BibTeXWriter.entry(
                for: $0.meta.csl,
                key: keys[$0.id] ?? $0.meta.bibKey,
                identifiers: $0.meta.identifiers,
                options: options
            )
        }
        return BibTeXWriter.write(entries, options: options)
    }

    /// Regenerates the preview, capped so a large library cannot stall the
    /// sheet while the user is still adjusting options.
    private func regeneratePreview() {
        let full = makeBibTeX()
        let lines = full.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 200 else {
            previewText = full
            return
        }
        let shown = lines.prefix(200).joined(separator: "\n")
        previewText = L("\(shown)\n… 그리고 \(lines.count - 200)줄 더", "\(shown)\n… and \(lines.count - 200) more lines")
    }

    private func copyToClipboard() {
        let text = makeBibTeX()
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

/// A plain-text `.bib` file for `.fileExporter`.
struct BibTeXDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    static var writableContentTypes: [UTType] { [.plainText] }

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let string = String(data: data, encoding: .utf8)
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        text = string
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
