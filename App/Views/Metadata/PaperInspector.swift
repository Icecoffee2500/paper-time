import LibraryStore
import PaperCore
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Bibliographic and reading-state editor for the selected paper.
struct PaperInspector: View {
    let model: LibraryModel

    var body: some View {
        if let paper = model.selectedPaper {
            // `.id` forces a fresh `PaperInspectorForm` (and fresh local
            // `@State`) whenever the selection changes, instead of trying to
            // reset in-place drafts by hand.
            PaperInspectorForm(model: model, paperID: paper.id)
                .id(paper.id)
        } else {
            ContentUnavailableView(
                "No Paper Selected",
                systemImage: "doc.text.magnifyingglass",
                description: Text("Select a paper to see and edit its details.")
            )
        }
    }
}

/// The editor form for one specific paper.
private struct PaperInspectorForm: View {
    let model: LibraryModel
    let paperID: UUID

    @State private var draft: CSLItem
    @State private var stateDraft: PaperState

    init(model: LibraryModel, paperID: UUID) {
        self.model = model
        self.paperID = paperID
        let paper = model.papers.first { $0.id == paperID }
        _draft = State(initialValue: paper?.meta.csl ?? CSLItem())
        _stateDraft = State(initialValue: paper?.state ?? PaperState())
    }

    private var paper: LoadedPaper? {
        model.papers.first { $0.id == paperID }
    }

    private var isDirty: Bool {
        guard let paper else { return false }
        return draft != paper.meta.csl
    }

    var body: some View {
        Form {
            if let paper {
                header(for: paper)

                if paper.meta.confidence == .needsReview, !paper.meta.candidates.isEmpty {
                    candidatesSection(for: paper)
                }

                detailsSection
                AuthorListEditor(authors: $draft.author)
                saveRevertSection
                readingStateSection
                identifiersSection(for: paper)
                provenanceFooter(for: paper)
            }
        }
        .formStyle(.grouped)
        .onDisappear { saveNoteIfNeeded() }
    }

    // MARK: - Header

    @ViewBuilder
    private func header(for paper: LoadedPaper) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(paper.meta.displayTitle)
                    .font(.title3.weight(.semibold))
                if !paper.meta.displayAuthors.isEmpty {
                    Text(paper.meta.displayAuthors)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                confidenceBadge(for: paper.meta.confidence)
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func confidenceBadge(for confidence: MetadataConfidence) -> some View {
        switch confidence {
        case .verified:
            Label("Confirmed", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
        case .needsReview:
            Label("Needs Review", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .manual:
            Label("Edited by You", systemImage: "person.fill.checkmark")
                .foregroundStyle(.blue)
        case .unparsed:
            Label("Unresolved", systemImage: "questionmark.circle")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Candidates

    @ViewBuilder
    private func candidatesSection(for paper: LoadedPaper) -> some View {
        Section("Is this the right paper?") {
            ForEach(paper.meta.candidates) { candidate in
                Button {
                    Task { await model.acceptCandidate(candidate, for: paperID) }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(candidate.csl.fullTitle ?? "Untitled")
                            .font(.headline)
                        if !candidate.csl.author.isEmpty {
                            Text(candidate.csl.author.map(\.displayName).joined(separator: ", "))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 8) {
                            if let year = candidate.csl.year {
                                Text(String(year))
                            }
                            if let venue = candidate.csl.containerTitle, !venue.isEmpty {
                                Text(venue)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        if !candidate.matchExplanation.isEmpty {
                            Text(candidate.matchExplanation)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text("\(Int((candidate.score * 100).rounded()))% match")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.blue)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Editable fields

    private var detailsSection: some View {
        Section("Details") {
            TextField("Title", text: stringBinding(\.title))
            TextField("Subtitle", text: stringBinding(\.subtitle))
            TextField("Year", text: yearBinding)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
            TextField("Venue", text: stringBinding(\.containerTitle))
            TextField("Volume", text: stringBinding(\.volume))
            TextField("Issue", text: stringBinding(\.issue))
            TextField("Pages", text: stringBinding(\.page))
            TextField("Publisher", text: stringBinding(\.publisher))
            TextField("DOI", text: stringBinding(\.doi))
            TextField("URL", text: stringBinding(\.url))
            Picker("Type", selection: $draft.type) {
                ForEach(CSLType.allCases, id: \.self) { type in
                    Text(displayName(for: type)).tag(type)
                }
            }
        }
    }

    private var saveRevertSection: some View {
        Section {
            HStack {
                Button("Revert") {
                    if let paper { draft = paper.meta.csl }
                }
                .disabled(!isDirty)

                Spacer()

                Button("Save") {
                    guard var meta = paper?.meta else { return }
                    meta.csl = draft
                    Task { await model.update(meta: meta, for: paperID) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isDirty)
            }
        }
    }

    private func stringBinding(_ keyPath: WritableKeyPath<CSLItem, String?>) -> Binding<String> {
        Binding(
            get: { draft[keyPath: keyPath] ?? "" },
            set: { draft[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }

    /// `CSLItem` stores the year inside `issued.dateParts`, so the plain-text
    /// field just reads/writes that first component.
    private var yearBinding: Binding<String> {
        Binding(
            get: { draft.issued?.year.map(String.init) ?? "" },
            set: { text in
                let digits = text.filter(\.isNumber)
                if digits.isEmpty {
                    draft.issued = nil
                } else if let year = Int(digits) {
                    draft.issued = CSLDate(year: year)
                }
            }
        )
    }

    private func displayName(for type: CSLType) -> String {
        switch type {
        case .articleJournal: "Journal Article"
        case .paperConference: "Conference Paper"
        case .book: "Book"
        case .chapter: "Book Chapter"
        case .thesis: "Thesis"
        case .report: "Report"
        case .dataset: "Dataset"
        case .software: "Software"
        case .webpage: "Web Page"
        case .patent: "Patent"
        case .speech: "Speech"
        case .manuscript: "Preprint / Manuscript"
        case .other: "Other"
        }
    }

    // MARK: - Reading state

    private var readingStateSection: some View {
        Section("Reading") {
            Picker("Status", selection: $stateDraft.readingStatus) {
                ForEach(PaperState.ReadingStatus.allCases, id: \.self) { status in
                    Label(readingStatusLabel(status), systemImage: status.symbolName)
                        .tag(status)
                }
            }
            .onChange(of: stateDraft.readingStatus) { saveState() }

            Toggle("Favorite", isOn: $stateDraft.isFavorite)
                .onChange(of: stateDraft.isFavorite) { saveState() }

            ratingControl

            TextField("Notes", text: $stateDraft.summaryNote, axis: .vertical)
                .lineLimit(3 ... 8)
                .onSubmit { saveState() }
        }
    }

    private var ratingControl: some View {
        HStack {
            Text("Rating")
            Spacer()
            HStack(spacing: 2) {
                ForEach(1 ... 5, id: \.self) { value in
                    Button {
                        stateDraft.rating = (stateDraft.rating == value) ? nil : value
                        saveState()
                    } label: {
                        Image(systemName: (stateDraft.rating ?? 0) >= value ? "star.fill" : "star")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle((stateDraft.rating ?? 0) >= value ? .yellow : .secondary)
                    .accessibilityLabel("\(value) star\(value == 1 ? "" : "s")")
                }
            }
        }
    }

    private func readingStatusLabel(_ status: PaperState.ReadingStatus) -> String {
        switch status {
        case .unread: "Unread"
        case .reading: "Reading"
        case .read: "Read"
        }
    }

    private func saveState() {
        Task { await model.update(state: stateDraft, for: paperID) }
    }

    /// The note is the one field that must not save on every keystroke, so it
    /// only flushes on submit and when the inspector goes away.
    private func saveNoteIfNeeded() {
        guard let paper, stateDraft.summaryNote != paper.state.summaryNote else { return }
        saveState()
    }

    // MARK: - Identifiers

    @ViewBuilder
    private func identifiersSection(for paper: LoadedPaper) -> some View {
        Section("Identifiers") {
            identifierRow(label: "DOI", value: paper.meta.identifiers.doi)
            identifierRow(label: "arXiv", value: paper.meta.identifiers.arxiv)
            identifierRow(label: "PMID", value: paper.meta.identifiers.pmid)
            identifierRow(label: "BibTeX Key", value: paper.meta.bibKey)
        }
    }

    @ViewBuilder
    private func identifierRow(label: String, value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack {
                Text(label)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(value)
                    .textSelection(.enabled)
                Button {
                    copyToPasteboard(value)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy \(label)")
            }
        }
    }

    private func copyToPasteboard(_ string: String) {
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
        #else
        UIPasteboard.general.string = string
        #endif
    }

    // MARK: - Provenance

    @ViewBuilder
    private func provenanceFooter(for paper: LoadedPaper) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 2) {
                Text("Source: \(humanized(paper.meta.provenance.source))")
                Text(
                    "Fetched \(paper.meta.provenance.fetchedAt.formatted(date: .abbreviated, time: .shortened))"
                )
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func humanized(_ source: Provenance.Source) -> String {
        switch source {
        case .doiContentNegotiation: "DOI Content Negotiation"
        case .crossref: "Crossref"
        case .openAlex: "OpenAlex"
        case .arxiv: "arXiv"
        case .semanticScholar: "Semantic Scholar"
        case .pdfDocumentInfo: "PDF Document Info"
        case .onDeviceModel: "On-Device Model"
        case .heuristic: "Heuristic Extraction"
        case .importedBibTeX: "Imported BibTeX"
        case .importedRIS: "Imported RIS"
        case .manual: "Entered by You"
        }
    }
}
