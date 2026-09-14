import SwiftUI

/// A Spotlight-like search overlay for jumping to a paper, a collection, a
/// tag, or a library-wide action without leaving the keyboard.
///
/// The caller owns presentation (`isPresented`) and the handful of actions
/// that need UI the palette itself has no business showing, such as a file
/// importer or the Settings window.
struct SearchPalette: View {
    let model: LibraryModel
    /// The open paper, so a passage found in another one can send the reader
    /// to the line it was found on.
    let link: ReaderLink
    @Binding var isPresented: Bool
    /// Called for the action results the palette cannot perform itself.
    var perform: (SearchResult.Action) -> Void

    // Typing into this field from a script means posting keys to whatever is
    // frontmost, which is how a ⌘K once ended up in somebody's browser. The
    // same variable that opens the palette for a check can carry what to look
    // for, and then the check needs no keyboard at all.
    @State private var query = Boot.setting("PAPERTIME_SHOW_SEARCH") ?? ""
    @State private var highlightedIndex = 0
    /// What the words themselves turned up, as the papers are read.
    @State private var passages: [SearchResult] = []
    @State private var isScanning = false
    @State private var warming: Task<Void, Never>?
    /// What the library offers when nothing has been typed, and what the
    /// typing matches. Worked out once each, not once per pass over the body.
    @State private var offered: [SearchSuggestions.Group] = []
    @State private var typed: [SearchResult] = []
    @FocusState private var isFieldFocused: Bool
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private enum ResultGroup: String, CaseIterable {
        case library = "Library"
        case papers = "Papers"
        case notes = "Notes"
        case collections = "Collections"
        case tags = "Tags"
        case actions = "Actions"
        /// Last on purpose: a title match is a surer thing than a word in
        /// the middle of page nine, and these arrive a moment later anyway.
        case passages = "In the Papers"
    }

    private let rowHeight: CGFloat = 44
    private let maxDisplayedResults = 8

    private var paletteWidth: CGFloat {
        #if os(macOS)
        680
        #else
        horizontalSizeClass == .compact ? 560 : 680
        #endif
    }

    /// Typed: what matches. Empty: what is offered, in its groups.
    ///
    /// Both are read out of state rather than worked out here. They used to
    /// be computed properties, which meant SwiftUI asked for them again on
    /// every pass over the body — and it makes many passes while a palette is
    /// opening. Measured on a library of sixty-two papers: the offers cost
    /// 36 ms and were asked for twelve times, the matches 13 ms and
    /// forty-eight times. That is a second of the main thread spent working
    /// out the same two answers sixty times, which is why the window took a
    /// moment to appear and why the first letters typed into it were dropped.
    /// Each is now worked out once, when the thing it depends on changes.
    private var results: [SearchResult] {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            return offered.flatMap(\.results)
        }
        // Room is made for the words inside the papers as soon as they are
        // being looked for. Eight title matches and then a scroll bar is the
        // same as not having searched the text at all: what is below the fold
        // of a palette does not exist.
        let room = isScanning || !passages.isEmpty ? maxDisplayedResults - 4 : maxDisplayedResults
        return Array(typed.prefix(room)) + passages
    }

    /// Results split into their display groups, each row carrying the index it
    /// has in the flat list so keyboard highlighting stays in one coordinate
    /// space.
    private var groups: [SearchResultGroup] {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            var offset = 0
            return offered.map { group in
                let rows = group.results.map { result in
                    defer { offset += 1 }
                    return SearchResultRow(offset: offset, result: result)
                }
                return SearchResultGroup(group: nil, title: group.title, rows: rows)
            }
        }
        var byGroup: [ResultGroup: [SearchResultRow]] = [:]
        for (offset, result) in results.enumerated() {
            let group = sectionForKind(result.kind)
            byGroup[group, default: []].append(SearchResultRow(offset: offset, result: result))
        }
        var ordered: [SearchResultGroup] = []
        for group in ResultGroup.allCases {
            guard let rows = byGroup[group], !rows.isEmpty else { continue }
            ordered.append(SearchResultGroup(group: group, title: group.rawValue, rows: rows))
        }
        return ordered
    }

    private struct SearchResultRow: Identifiable {
        var offset: Int
        var result: SearchResult
        /// What the row is, not where it is. Numbering the rows meant that
        /// when the passages arrived and the titles above them made room,
        /// rows four to eight kept the views — and the words — they had when
        /// they were still titles: the palette went on showing papers under
        /// a heading that said the words had been found inside them.
        var id: SearchResult.Kind { result.kind }
    }

    private struct SearchResultGroup: Identifiable {
        var group: ResultGroup?
        var title: String
        var rows: [SearchResultRow]
        var id: String { title }
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .onTapGesture { dismiss() }

                paletteCard
                    .frame(width: min(paletteWidth, proxy.size.width - 32))
                    .padding(.top, proxy.size.height * 0.28)
            }
        }
        // The Mac opens with the caret in the field: the keyboard is already
        // there, and ⌘K is a key you press in order to type. A touch screen
        // has no keyboard until one is asked for, and raising it covers the
        // half of the palette that offers what to read next — which is the
        // part worth seeing before typing anything. Tap the field and it
        // comes, as it does everywhere else.
        // Everything the palette knows, before it is looked at.
        .onAppear { gather() }
        .onChange(of: query) { _, _ in match() }
        #if os(macOS)
        // The caret, in the field, from the moment it opens — ⌘K is a key
        // you press in order to type. Set once as the view appears and again
        // a beat later: the first is for the usual case, the second for the
        // one where the field is not yet in the window to take it.
        .onAppear { isFieldFocused = true }
        .task {
            try? await Task.sleep(for: .milliseconds(60))
            isFieldFocused = true
        }
        #endif
        // Reading the library starts a moment after the field opens rather
        // than with it. Sixty PDFs is real work, and having it start in the
        // same instant as the window was making the window wait for it.
        .task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            warming = PaperTextIndex.shared.warm(sources(excluding: []))
        }
        .onDisappear { warming?.cancel() }
        .task(id: query) { await scan() }
    }

    /// The offers, once. They are about the library rather than the query,
    /// so they do not change while the palette is open.
    private func gather() {
        offered = SearchSuggestions.groups(in: model)
        match()
    }

    /// What the typing matches, once per change of it.
    private func match() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        typed = text.isEmpty ? [] : SearchIndex.results(for: text, in: model)
    }

    private var paletteCard: some View {
        VStack(spacing: 0) {
            searchField
            if !results.isEmpty || isScanning {
                Divider()
                resultsList
            }
        }
        .liquidGlass(.floating, in: RoundedRectangle(cornerRadius: Corner.panel, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: Corner.panel, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 12)
        .onKeyPress(.upArrow) {
            moveHighlight(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveHighlight(by: 1)
            return .handled
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
        // Escape, from inside the field. A text field takes the key as its
        // own cancel and never passes it on, so `onKeyPress` — which only
        // ever saw the keys the field let through — was deaf to the one key
        // everybody presses to put a palette away. This is the cancel itself.
        #if os(macOS)
        .onExitCommand { dismiss() }
        #endif
        .onChange(of: query) { _, _ in highlightedIndex = 0 }
    }

    private var searchField: some View {
        HStack(spacing: 14) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField(offered.isEmpty ? "Paper Time Search" : "Search — or pick up where you were", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 26, weight: .regular))
                .focused($isFieldFocused)
                .accessibilityLabel("Paper Time Search")
                .onSubmit { activateHighlighted() }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var resultsList: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(groups) { group in
                        Text(group.title.uppercased())
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 20)
                            .padding(.top, 12)
                            .padding(.bottom, 4)

                        ForEach(group.rows) { row in
                            resultRow(row.result, isHighlighted: row.offset == highlightedIndex)
                                .id(row.result.kind)
                                .onTapGesture { activate(row.result) }
                                .onHover { isHovering in
                                    if isHovering { highlightedIndex = row.offset }
                                }
                        }
                    }
                    if isScanning { scanning }
                }
                .padding(.bottom, 8)
            }
            // As tall as its rows and no taller: two offers under an empty
            // field are two rows, not a panel with two rows at the top.
            .frame(height: min(CGFloat(results.count) * rowHeight
                                   + CGFloat(groups.count) * 30 + (isScanning ? 30 : 0) + 8,
                               CGFloat(maxDisplayedResults + 2) * rowHeight + 70))
            .onChange(of: highlightedIndex) { _, newValue in
                guard results.indices.contains(newValue) else { return }
                let target = results[newValue].kind
                withAnimation(.easeOut(duration: 0.12)) {
                    scrollProxy.scrollTo(target, anchor: .center)
                }
            }
        }
    }

    /// Said rather than spun silently: the first search of a session reads
    /// every paper in the library, and a palette that simply sat there for a
    /// few seconds would look broken rather than busy.
    private var scanning: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(ReleaseNotes.string("논문 본문을 읽는 중…", "Reading the papers…"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    private func resultRow(_ result: SearchResult, isHighlighted: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: result.symbolName)
                .font(.system(size: 16))
                .frame(width: 22)
                .foregroundStyle(isHighlighted ? Color.accentColor : Color.secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(result.title)
                    .font(.body)
                    .lineLimit(1)
                if let reason = result.reason {
                    // Why it is offered — the reason is the invitation.
                    Text(reason.text)
                        .font(.caption)
                        .foregroundStyle(.tint)
                        .lineLimit(1)
                } else if !result.subtitle.isEmpty {
                    Text(result.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if let progress = result.reason?.progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(.secondary.opacity(0.6))
                    .frame(width: 64)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: rowHeight)
        .background(
            RoundedRectangle(cornerRadius: Corner.row, style: .continuous)
                .fill(isHighlighted ? Color.accentColor.opacity(0.15) : Color.clear)
        )
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            result.subtitle.isEmpty ? result.title : "\(result.title), \(result.subtitle)"
        )
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    }

    private func sectionForKind(_ kind: SearchResult.Kind) -> ResultGroup {
        switch kind {
        case .showAll: .library
        case .paper: .papers
        case .passage: .passages
        case .note: .notes
        case .collection: .collections
        case .tag: .tags
        case .action: .actions
        }
    }

    private func moveHighlight(by delta: Int) {
        guard !results.isEmpty else { return }
        let count = results.count
        highlightedIndex = ((highlightedIndex + delta) % count + count) % count
    }

    private func activateHighlighted() {
        guard results.indices.contains(highlightedIndex) else { return }
        activate(results[highlightedIndex])
    }

    private func activate(_ result: SearchResult) {
        switch result.kind {
        case let .showAll(query):
            model.showSearchResults(for: query)
        case let .paper(id):
            model.selectedPaperID = id
        case let .passage(passage):
            openPassage(passage, in: model, link: link)
        case let .note(id):
            model.scope = .notes
            model.notes.openNoteID = id
        case let .collection(id):
            model.scope = .collection(id)
        case let .tag(id):
            model.scope = .tag(id)
        case let .action(action):
            perform(action)
        }
        dismiss()
    }

    // MARK: - The words inside the papers

    /// The papers to read, the one opened most recently first — which is
    /// nearly always the one the answer is in.
    ///
    /// Papers already named above by their title are left out. A paper about
    /// unlearning has the word on its first page, so searching for it would
    /// otherwise say the same twelve papers twice: once as titles, once as
    /// their own titles quoted back. What this group is for is the paper that
    /// says the word on page nine and never says it again.
    private func sources(excluding shown: Set<UUID>) -> [PaperTextIndex.Source] {
        model.papers
            .filter { $0.meta.parentID == nil && !shown.contains($0.id) }
            .sorted {
                ($0.state.lastOpenedAt ?? .distantPast) > ($1.state.lastOpenedAt ?? .distantPast)
            }
            .map {
                PaperTextIndex.Source(id: $0.id, url: $0.documentURL,
                                      title: $0.meta.displayTitle)
            }
    }

    /// Searches the text of the library for what has been typed.
    ///
    /// Results are taken as they arrive rather than waited for: reading sixty
    /// PDFs takes seconds the first time and nothing afterwards, and a list
    /// that fills in front of you is the honest way to show the difference.
    private func scan() async {
        passages = []
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > 1 else {
            isScanning = false
            return
        }
        // Not on every keystroke: "un", "unl", "unle" are three searches of
        // the whole library that nobody asked for.
        try? await Task.sleep(for: .milliseconds(220))
        guard !Task.isCancelled else { return }
        isScanning = true
        // The papers already named by title are the ones just matched; there
        // is no reason to match them a second time.
        let named = Set(typed.compactMap { result in
            if case let .paper(id) = result.kind { id } else { nil }
        })
        for await hit in PaperTextIndex.shared.hits(for: text, in: sources(excluding: named)) {
            passages.append(SearchResult(hit: hit))
            // Pressing the first row from a script, so that "does it land on
            // the word?" can be seen in a screenshot without a click being
            // posted to whatever happens to be frontmost.
            if Boot.isSet("PAPERTIME_SEARCH_JUMP"),
               passages.count == 1 {
                activate(passages[0])
                return
            }
            if passages.count >= 4 { break }
        }
        isScanning = false
    }

    private func dismiss() {
        isPresented = false
    }
}
