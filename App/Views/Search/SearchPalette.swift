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
    /// What says the same thing in other words, when the library's passages
    /// have been embedded. Never waited for by anything above it.
    @State private var meanings: [SearchResult] = []
    @State private var isScanning = false
    /// The query the words inside the papers were last read to the end for.
    @State private var settled: String?
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
        /// Late on purpose: a title match is a surer thing than a word in
        /// the middle of page nine, and these arrive a moment later anyway.
        case passages = "In the Papers"
        /// Last: passages that say it without saying it. Under the exact
        /// matches, because a passage with the word in it is the surer
        /// answer, and only once every passage in the library has a vector.
        case meanings = "Similar in Meaning"

        var title: String {
            switch self {
            case .library: L("라이브러리", "Library")
            case .papers: L("논문", "Papers")
            case .notes: L("노트", "Notes")
            case .collections: L("컬렉션", "Collections")
            case .tags: L("태그", "Tags")
            case .actions: L("동작", "Actions")
            case .passages: L("논문 본문", "In the Papers")
            case .meanings: L("뜻이 비슷한 구절", "Similar in Meaning")
            }
        }
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
        return Array(typed.prefix(room)) + passages + meanings
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
            ordered.append(SearchResultGroup(group: group, title: group.title, rows: rows))
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
            #if os(macOS)
            // And the passages by meaning catch up with whatever came or
            // went since the library opened. Nothing to do when nothing
            // did: every paper's stamp is compared and no vector is made.
            SemanticIndex.shared.schedule(sources(excluding: []), after: .seconds(2))
            #endif
            // And what is kept of papers the library no longer has goes,
            // once a session. Every paper counts here, supplements too: the
            // echoes read those.
            await PaperTextIndex.shared.sweep(keeping: Set(model.papers.map(\.id)))
        }
        .onDisappear { warming?.cancel() }
        // What the ranking compares with, folded while the reader is still
        // deciding what to type: the notes off the main thread first, then
        // the library once they are done. Made at the first keystroke
        // instead, it was that keystroke — 50 ms of it at six hundred papers
        // and a thousand notes — and made before the notes were ready, it
        // would fold all thousand of them here, on the main thread.
        .task {
            await model.notes.prepareSearch()
            guard !Task.isCancelled else { return }
            _ = SearchIndex.prepared(for: model)
        }
        .task(id: query) { await scan() }
        #if os(macOS)
        .task(id: query) { await mean() }
        #endif
        // `--papertime-search-script=<q1|q2|…>` types each query into the
        // field a letter at a time, the way a hand would, and says what came
        // back and when. A key posted from outside goes to whatever is in
        // front; this goes nowhere but the field.
        .task {
            guard let script = Boot.setting("PAPERTIME_SEARCH_SCRIPT") else { return }
            await type(script.split(separator: "|").map(String.init))
        }
    }

    /// The offers, once. They are about the library rather than the query,
    /// so they do not change while the palette is open.
    private func gather() {
        Trace.mark("palette: open")
        Trace.time("palette: get ready") {
            offered = SearchSuggestions.groups(in: model)
            match()
        }
    }

    /// What the typing matches, once per change of it.
    private func match() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        typed = text.isEmpty ? [] : Trace.time("palette: rank one keystroke") {
            SearchIndex.results(for: text, in: model)
        }
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

            TextField(offered.isEmpty ? L("Paper Time 찾기", "Paper Time Search") : L("찾기 — 또는 읽던 자리로", "Search — or pick up where you were"), text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 26, weight: .regular))
                .focused($isFieldFocused)
                .accessibilityLabel(L("Paper Time 찾기", "Paper Time Search"))
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
                    #if os(macOS)
                    if let progress = semantic.progress, !query.trimmingCharacters(in: .whitespaces).isEmpty {
                        preparing(progress)
                    }
                    #endif
                }
                .padding(.bottom, 8)
            }
            // As tall as its rows and no taller: two offers under an empty
            // field are two rows, not a panel with two rows at the top.
            .frame(height: min(CGFloat(results.count) * rowHeight
                                   + CGFloat(groups.count) * 30 + (isScanning ? 30 : 0)
                                   + (footerShown ? 26 : 0) + 8,
                               CGFloat(maxDisplayedResults + 2) * rowHeight + 70))
            .onChange(of: highlightedIndex) { _, newValue in
                guard results.indices.contains(newValue) else { return }
                let target = results[newValue].kind
                withAnimation(Motion.tap) {
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

    #if os(macOS)
    private var semantic: SemanticIndexStatus { SemanticIndex.shared.status }

    private var footerShown: Bool {
        semantic.progress != nil && !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Said quietly, once, under the results: the passages are still being
    /// embedded, and until every one of them is the section stays away — a
    /// list ranked over half the library would name the wrong half.
    private func preparing(_ progress: (done: Int, total: Int)) -> some View {
        Text(L("뜻으로 찾기 준비 중 · \(progress.done)/\(progress.total)",
               "Getting ready to search by meaning · \(progress.done)/\(progress.total)"))
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }
    #else
    private var footerShown: Bool { false }
    #endif

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
        case .meaning: .meanings
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
        case let .passage(passage), let .meaning(passage):
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
            settled = text
            return
        }
        // Not on every keystroke: "un", "unl", "unle" are three searches of
        // the whole library that nobody asked for.
        try? await Task.sleep(for: .milliseconds(220))
        guard !Task.isCancelled else { return }
        isScanning = true
        let started = DispatchTime.now().uptimeNanoseconds
        func since() -> Double { Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6 }
        // The papers already named by title are the ones just matched; there
        // is no reason to match them a second time.
        let named = Set(typed.compactMap { result in
            if case let .paper(id) = result.kind { id } else { nil }
        })
        for await hit in PaperTextIndex.shared.hits(for: text, in: sources(excluding: named)) {
            passages.append(SearchResult(hit: hit))
            if passages.count == 1 {
                Trace.mark(String(format: "palette: “%@” first passage after %.1f ms", text, since()))
            }
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
        Trace.mark(String(format: "palette: “%@” read to the end after %.1f ms — %d passages",
                          text, since(), passages.count))
        isScanning = false
        if !Task.isCancelled { settled = text }
    }

    #if os(macOS)
    /// Asks the passages what says the same thing, a beat after the typing
    /// stops. Off the main thread: the query is embedded by the model
    /// (about a millisecond, once it is loaded) and scored against every
    /// passage, and none of it holds up the rows above. While the library
    /// is still being embedded there is nothing to ask, and nothing is
    /// shown — the index brings the library up to date each time the
    /// palette opens.
    private func mean() async {
        meanings = []
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > 2, SemanticIndex.isEnabled else { return }
        try? await Task.sleep(for: .milliseconds(320))
        guard !Task.isCancelled, await SemanticIndex.shared.isReady else { return }
        let started = DispatchTime.now().uptimeNanoseconds
        let hits = await SemanticIndex.shared.hits(for: text, k: 8)
        guard !Task.isCancelled else { return }
        // A passage already named above, word for word, is not news twice.
        let shown = Set(passages.compactMap { result -> PaperTextIndex.Passage? in
            if case let .passage(passage) = result.kind { passage } else { nil }
        })
        meanings = hits.filter { !shown.contains($0.passage) }.map(SearchResult.init(meaning:))
        Trace.mark(String(format: "palette: “%@” %d by meaning after %.1f ms", text, meanings.count,
                          Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6))
    }
    #endif

    /// Types each query in, a letter every ninety milliseconds, waits for
    /// the words inside the papers to come back, and writes down what the
    /// palette is showing. Then quits, so the trace can add it up.
    private func type(_ queries: [String]) async {
        try? await Task.sleep(for: .seconds(1))
        Trace.mark("palette: script begins · \(Trace.memory())")
        for wanted in queries {
            let letters = Array(wanted)
            for count in 1...max(letters.count, 1) {
                query = String(letters.prefix(count))
                try? await Task.sleep(for: .milliseconds(90))
            }
            let deadline = Date.now.addingTimeInterval(20)
            while settled != wanted, Date.now < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            var said = "palette: “\(wanted)” shows \(typed.count) typed · \(passages.count) passages · \(meanings.count) by meaning · \(Trace.memory())\n"
            for row in results {
                said += "palette:   \(row.title.prefix(70)) — \(row.subtitle.prefix(70))\n"
            }
            FileHandle.standardError.write(Data(said.utf8))
            query = ""
            try? await Task.sleep(for: .milliseconds(400))
        }
        Trace.summary()
        #if os(macOS)
        NSApp.terminate(nil)
        #endif
    }

    private func dismiss() {
        isPresented = false
    }
}
