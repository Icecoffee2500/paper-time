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
            case .selectedPaper: "Selected Paper"
            case .currentView: "Current View"
            case .wholeLibrary: "Whole Library"
            case .collection: "Collection"
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
            .navigationTitle("Export BibTeX")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItemGroup(placement: .confirmationAction) {
                    Button("Copy") { copyToClipboard() }
                        .disabled(papersInScope.isEmpty)
                    Button("Save…") {
                        exportDocument = BibTeXDocument(text: makeBibTeX())
                        isExporting = true
                    }
                    .disabled(papersInScope.isEmpty)
                    Button("Done") { dismiss() }
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
        Section("Export") {
            Picker("Scope", selection: $scopeKind) {
                ForEach(ScopeKind.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            if scopeKind == .collection {
                Picker("Collection", selection: $selectedCollectionID) {
                    Text("Choose a Collection").tag(UUID?.none)
                    ForEach(model?.collections.collections ?? []) { collection in
                        Text(collection.name).tag(Optional(collection.id))
                    }
                }
            }
        }
    }

    private var optionsSection: some View {
        Section("Options") {
            Picker("Preprint Style", selection: $options.preprintStyle) {
                ForEach(BibTeXExportOptions.PreprintStyle.allCases, id: \.self) { style in
                    Text(style.displayName).tag(style)
                }
            }
            Toggle("Protect Case in Titles", isOn: $options.protectCase)
            Toggle("Abbreviate Journal Names", isOn: $options.abbreviateJournals)
            Toggle("Include Abstract", isOn: $options.includeAbstract)
            Toggle("Include Keywords", isOn: $options.includeKeywords)
            Toggle("Include URL", isOn: $options.includeURL)
            Toggle("Include Unverified Records", isOn: $options.includeUnverified)
        }
    }

    private var warningSection: some View {
        Section {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Warning")
                Text(warningText)
                    .font(.callout)
            }
        }
    }

    private var previewSection: some View {
        Section("Preview") {
            ScrollView {
                Text(previewText.isEmpty ? "Nothing to export yet." : previewText)
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

    private var reviewCount: Int {
        papersInScope.filter { $0.meta.confidence == .needsReview || $0.meta.confidence == .unparsed }.count
    }

    private var warningText: String {
        let noun = reviewCount == 1 ? "paper hasn't" : "papers haven't"
        let verb = options.includeUnverified ? "will still be included" : "will be left out of this export"
        return "\(reviewCount) \(noun) been verified and \(verb). Turn on “Include Unverified Records” to change that."
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
        previewText = "\(shown)\n… and \(lines.count - 200) more lines"
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
