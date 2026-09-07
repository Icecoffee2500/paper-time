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
    @State private var noteDraft: String

    init(model: LibraryModel, paperID: UUID) {
        self.model = model
        self.paperID = paperID
        let paper = model.papers.first { $0.id == paperID }
        _draft = State(initialValue: paper?.meta.csl ?? CSLItem())
        _noteDraft = State(initialValue: paper?.state.summaryNote ?? "")
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

                supplementsSection(for: paper)
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

    // MARK: - Supplements

    @ViewBuilder
    private func supplementsSection(for paper: LoadedPaper) -> some View {
        if let parent = model.parent(of: paperID) {
            Section("Belongs To") {
                Button {
                    model.selectedPaperID = parent.id
                } label: {
                    Label(parent.meta.displayTitle, systemImage: "doc.text")
                }
                .buttonStyle(.plain)
                Button("Make a Paper of Its Own") {
                    Task { await model.detach(paperID) }
                }
            }
        } else {
            let attachments = model.attachments(of: paperID)
            if !attachments.isEmpty {
                Section("Supplementary Material") {
                    ForEach(attachments) { attachment in
                        HStack {
                            Button {
                                model.selectedPaperID = attachment.id
                            } label: {
                                Label(
                                    attachment.meta.displayTitle,
                                    systemImage: "paperclip"
                                )
                            }
                            .buttonStyle(.plain)
                            Spacer()
                            Button("Detach") {
                                Task { await model.detach(attachment.id) }
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }

            if let suggested = model.suggestedParent(for: paperID) {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("This looks like supplementary material.")
                            .font(.subheadline)
                        Text(suggested.meta.displayTitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("Attach to This Paper") {
                            Task { await model.attach(paperID, to: suggested.id) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(.vertical, 2)
                }
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

    /// Reading state binds straight through to the model.
    ///
    /// It used to be edited in a local copy taken when the inspector appeared,
    /// which meant a change made anywhere else — the list, a drag onto the
    /// sidebar — never showed here, and a change made here was written from a
    /// snapshot that had since gone stale.
    private var readingStateSection: some View {
        Section("Reading") {
            Picker("Status", selection: readingStatusBinding) {
                ForEach(PaperState.ReadingStatus.allCases, id: \.self) { status in
                    Label(readingStatusLabel(status), systemImage: status.symbolName)
                        .tag(status)
                }
            }

            Toggle("Favorite", isOn: favoriteBinding)

            ratingControl

            TextField("Notes", text: $noteDraft, axis: .vertical)
                .lineLimit(3 ... 8)
                .onSubmit { saveNoteIfNeeded() }
        }
    }

    private var readingStatusBinding: Binding<PaperState.ReadingStatus> {
        Binding(
            get: { paper?.state.readingStatus ?? .unread },
            set: { newValue in
                Task { await model.setReadingStatus(newValue, for: paperID) }
            }
        )
    }

    private var favoriteBinding: Binding<Bool> {
        Binding(
            get: { paper?.state.isFavorite ?? false },
            set: { newValue in
                Task { await model.setFavorite(newValue, for: paperID) }
            }
        )
    }

    private var ratingControl: some View {
        let rating = paper?.state.rating ?? 0
        return HStack {
            Text("Rating")
            Spacer()
            HStack(spacing: 2) {
                ForEach(1 ... 5, id: \.self) { value in
                    Button {
                        // Tapping the current rating clears it, which is the
                        // only way to get back to "no rating".
                        let newValue = rating == value ? nil : value
                        Task { await model.setRating(newValue, for: paperID) }
                    } label: {
                        Image(systemName: rating >= value ? "star.fill" : "star")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(rating >= value ? .yellow : .secondary)
                    .accessibilityLabel("\(value) star\(value == 1 ? "" : "s")")
                    .accessibilityAddTraits(rating >= value ? [.isSelected] : [])
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

    /// The note is the one field that must not save on every keystroke, so it
    /// only flushes on submit and when the inspector goes away.
    private func saveNoteIfNeeded() {
        guard let paper, noteDraft != paper.state.summaryNote else { return }
        Task { await model.setSummaryNote(noteDraft, for: paperID) }
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
