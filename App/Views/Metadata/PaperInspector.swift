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
                L("고른 논문이 없어요", "No Paper Selected"),
                systemImage: "doc.text.magnifyingglass",
                description: Text(L("논문을 고르면 서지를 보고 고칠 수 있어요.", "Choose a paper to see its details."))
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

                // Before anything else: what is this? A form that asks a car
                // manual for its journal is a form that makes the reader
                // wrong, so the question comes before the fields it decides —
                // and stays afterwards, because the wrong button is pressed
                // sometimes and an answer with no way back is a trap.
                kindQuestion(for: paper)

                let kind = paper.meta.effectiveKind
                if kind == .paper, paper.meta.confidence == .needsReview, !paper.meta.candidates.isEmpty {
                    candidatesSection(for: paper)
                }

                supplementsSection(for: paper)
                if kind == .paper {
                    detailsSection
                    AuthorListEditor(authors: $draft.author)
                } else {
                    documentSection
                    AuthorListEditor(authors: $draft.author, title: L("쓴 사람", "Written by"))
                }
                saveRevertSection
                readingStateSection
                if kind == .paper {
                    identifiersSection(for: paper)
                } else {
                    fileSection(for: paper)
                }
                provenanceFooter(for: paper)
            }
        }
        .formStyle(.grouped)
        // A grouped form brings its own opaque background, which filled the
        // whole inspector panel white and left no glass to see.
        .scrollContentBackground(.hidden)
        // And its own scroller. The sweep is window-wide, but it runs off the
        // probes, and until this one there was none in the inspector: the
        // form's bar was only ever taken away when some other panel happened
        // to update after it appeared.
        .hiddenScrollers()
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
            Label(L("확인됨", "Confirmed"), systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
        case .needsReview:
            Label(L("살펴볼 것", "Needs Review"), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .manual:
            Label(L("직접 고침", "Edited by You"), systemImage: "person.fill.checkmark")
                .foregroundStyle(.blue)
        case .unparsed:
            Label(L("아직 모름", "Unresolved"), systemImage: "questionmark.circle")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - What is this?

    /// One question, asked once, with the app's own guess offered.
    ///
    /// Everything downstream hangs on the answer — which fields the form has,
    /// whether the record is looked up online at all, whether it turns up in
    /// a BibTeX export — so it is asked plainly rather than inferred and
    /// quietly acted on.
    @ViewBuilder
    private func kindQuestion(for paper: LoadedPaper) -> some View {
        let answered = !paper.meta.kindIsUnanswered
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(answered
                     ? L("이 PDF는", "This PDF is")
                     : L("이 PDF는 무엇인가요?", "What is this PDF?"))
                    .font(answered ? .subheadline.weight(.medium) : .headline)
                Picker("", selection: kindBinding(for: paper)) {
                    Text(L("논문", "A paper")).tag(DocumentKind.paper)
                    Text(L("일반 문서", "A document")).tag(DocumentKind.document)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if !answered {
                    Text(hint(for: paper.meta.guessedKind))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// The answer, and the way back from it.
    ///
    /// Before there is an answer the control still shows the app's guess, so
    /// pressing the one already marked is an answer too — "yes, that one" —
    /// rather than a press that appears to do nothing.
    private func kindBinding(for paper: LoadedPaper) -> Binding<DocumentKind> {
        Binding(
            get: { paper.meta.effectiveKind },
            set: { kind in Task { await model.setKind(kind, for: paper.id) } }
        )
    }

    private func hint(for guess: DocumentKind?) -> String {
        switch guess {
        case .paper:
            L("논문 같아요 — 안에 DOI나 참고문헌이 보여요. 맞으면 그대로 눌러주세요.",
              "It looks like a paper — there is a DOI or a reference list in it. Press it again to agree.")
        case .document:
            L("논문은 아닌 것 같아요. 일반 문서면 학술지 같은 칸은 숨길게요.",
              "It doesn't look like a paper. As a document, the journal fields go away.")
        case nil:
            L("고르면 이 칸들이 그에 맞게 바뀌어요.", "The fields below follow your answer.")
        }
    }

    // MARK: - Candidates

    @ViewBuilder
    private func candidatesSection(for paper: LoadedPaper) -> some View {
        Section(L("이 논문이 맞나요?", "Is this the right paper?")) {
            ForEach(paper.meta.candidates) { candidate in
                Button {
                    Task { await model.acceptCandidate(candidate, for: paperID) }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(candidate.csl.fullTitle ?? L("제목 없음", "Untitled"))
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
                        Text(L("\(Int((candidate.score * 100).rounded()))% 일치", "\(Int((candidate.score * 100).rounded()))% match"))
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
            Section(L("붙어 있는 논문", "Belongs To")) {
                Button {
                    model.selectedPaperID = parent.id
                } label: {
                    Label(parent.meta.displayTitle, systemImage: "doc.text")
                }
                .buttonStyle(.plain)
                Button(L("따로 논문으로 두기", "Make a Paper of Its Own")) {
                    Task { await model.detach(paperID) }
                }
            }
        } else {
            let attachments = model.attachments(of: paperID)
            if !attachments.isEmpty {
                Section(L("보충 자료", "Supplementary Material")) {
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
                            Button(L("떼기", "Detach")) {
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
                        Text(L("보충 자료 같아 보여요.", "This looks like supplementary material."))
                            .font(.subheadline)
                        Text(suggested.meta.displayTitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button(L("이 논문에 붙이기", "Attach to This Paper")) {
                            Task { await model.attach(paperID, to: suggested.id) }
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: - Editable fields

    private var detailsSection: some View {
        Section(L("서지 정보", "Details")) {
            TextField(L("제목", "Title"), text: stringBinding(\.title))
            TextField(L("부제", "Subtitle"), text: stringBinding(\.subtitle))
            TextField(L("해", "Year"), text: yearBinding)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
            TextField(L("학술지·학회", "Venue"), text: stringBinding(\.containerTitle))
            TextField(L("권", "Volume"), text: stringBinding(\.volume))
            TextField(L("호", "Issue"), text: stringBinding(\.issue))
            TextField(L("쪽", "Pages"), text: stringBinding(\.page))
            TextField(L("출판사", "Publisher"), text: stringBinding(\.publisher))
            TextField("DOI", text: stringBinding(\.doi))
            TextField("URL", text: stringBinding(\.url))
            Picker(L("종류", "Type"), selection: $draft.type) {
                ForEach(CSLType.allCases, id: \.self) { type in
                    Text(displayName(for: type)).tag(type)
                }
            }
        }
    }

    /// The form a document gets: what it is, who made it, when — and nothing
    /// about journals, volumes or DOIs, which it does not have.
    private var documentSection: some View {
        Section(L("문서 정보", "Details")) {
            TextField(L("제목", "Title"), text: stringBinding(\.title))
            TextField(L("부제", "Subtitle"), text: stringBinding(\.subtitle))
            TextField(L("펴낸 곳", "From"), text: stringBinding(\.publisher))
            TextField(L("해", "Year"), text: yearBinding)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
            TextField("URL", text: stringBinding(\.url))
            Picker(L("종류", "Kind"), selection: $draft.type) {
                ForEach(Self.documentTypes, id: \.self) { type in
                    Text(displayName(for: type)).tag(type)
                }
            }
        }
    }

    /// The kinds a document can be. The bibliography's own list, minus the
    /// half of it that only a paper is.
    private static let documentTypes: [CSLType] = [
        .report, .book, .chapter, .manuscript, .webpage, .speech, .dataset, .software, .patent, .other,
    ]

    /// What a document has instead of identifiers: the file it came from.
    @ViewBuilder
    private func fileSection(for paper: LoadedPaper) -> some View {
        Section(L("파일", "File")) {
            LabeledContent(L("이름", "Name"), value: paper.meta.file.originalName)
            LabeledContent(L("쪽", "Pages"), value: "\(paper.meta.file.pageCount)")
            Button(L("폴더에서 보기", "Show in Finder")) {
                #if os(macOS)
                NSWorkspace.shared.activateFileViewerSelecting([paper.documentURL])
                #endif
            }
        }
    }

    private var saveRevertSection: some View {
        Section {
            HStack {
                Button(L("되돌리기", "Revert")) {
                    if let paper { draft = paper.meta.csl }
                }
                .disabled(!isDirty)

                Spacer()

                Button(L("저장", "Save")) {
                    guard var meta = paper?.meta else { return }
                    meta.csl = draft
                    Task { await model.update(meta: meta, for: paperID) }
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
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
        case .articleJournal: L("학술지 논문", "Journal Article")
        case .paperConference: L("학회 논문", "Conference Paper")
        case .book: L("책", "Book")
        case .chapter: L("책의 장", "Book Chapter")
        case .thesis: L("학위 논문", "Thesis")
        case .report: L("보고서", "Report")
        case .dataset: L("데이터셋", "Dataset")
        case .software: L("소프트웨어", "Software")
        case .webpage: L("웹 페이지", "Web Page")
        case .patent: L("특허", "Patent")
        case .speech: L("발표", "Speech")
        case .manuscript: L("프리프린트 / 원고", "Preprint / Manuscript")
        case .other: L("그 밖", "Other")
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
        Section(L("읽기", "Reading")) {
            Picker(L("상태", "Status"), selection: readingStatusBinding) {
                ForEach(PaperState.ReadingStatus.allCases, id: \.self) { status in
                    Label(readingStatusLabel(status), systemImage: status.symbolName)
                        .tag(status)
                }
            }

            Toggle(L("즐겨찾기", "Favorite"), isOn: favoriteBinding)

            ratingControl

            TextField(L("메모", "Note"), text: $noteDraft, axis: .vertical)
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
            Text(L("별점", "Rating"))
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
                    .accessibilityLabel(L("별 \(value)개", "\(value) star\(value == 1 ? "" : "s")"))
                    .accessibilityAddTraits(rating >= value ? [.isSelected] : [])
                }
            }
        }
    }

    private func readingStatusLabel(_ status: PaperState.ReadingStatus) -> String {
        switch status {
        case .unread: L("안 읽음", "Unread")
        case .reading: L("읽는 중", "Reading")
        case .read: L("읽음", "Read")
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
        Section(L("식별자", "Identifiers")) {
            identifierRow(label: "DOI", value: paper.meta.identifiers.doi)
            identifierRow(label: "arXiv", value: paper.meta.identifiers.arxiv)
            identifierRow(label: "PMID", value: paper.meta.identifiers.pmid)
            identifierRow(label: L("BibTeX 키", "BibTeX Key"), value: paper.meta.bibKey)
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
                .accessibilityLabel(L("\(label) 복사", "Copy \(label)"))
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
                Text(L("출처: \(humanized(paper.meta.provenance.source))", "Source: \(humanized(paper.meta.provenance.source))"))
                Text(
                    L(
                        "\(paper.meta.provenance.fetchedAt.formatted(date: .abbreviated, time: .shortened))에 가져옴",
                        "Fetched \(paper.meta.provenance.fetchedAt.formatted(date: .abbreviated, time: .shortened))"
                    )
                )
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func humanized(_ source: Provenance.Source) -> String {
        switch source {
        case .doiContentNegotiation: L("DOI 콘텐츠 협상", "DOI Content Negotiation")
        case .crossref: "Crossref"
        case .openAlex: "OpenAlex"
        case .arxiv: "arXiv"
        case .semanticScholar: "Semantic Scholar"
        case .pdfDocumentInfo: L("PDF 문서 정보", "PDF Document Info")
        case .onDeviceModel: L("온디바이스 모델", "On-Device Model")
        case .heuristic: L("조판 규칙으로 읽음", "Heuristic Extraction")
        case .importedBibTeX: L("BibTeX에서 들여옴", "Imported BibTeX")
        case .importedRIS: L("RIS에서 들여옴", "Imported RIS")
        case .manual: L("직접 적음", "Entered by You")
        }
    }
}
