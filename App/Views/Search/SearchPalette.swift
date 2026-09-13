import SwiftUI

/// A Spotlight-like search overlay for jumping to a paper, a collection, a
/// tag, or a library-wide action without leaving the keyboard.
///
/// The caller owns presentation (`isPresented`) and the handful of actions
/// that need UI the palette itself has no business showing, such as a file
/// importer or the Settings window.
struct SearchPalette: View {
    let model: LibraryModel
    @Binding var isPresented: Bool
    /// Called for the action results the palette cannot perform itself.
    var perform: (SearchResult.Action) -> Void

    @State private var query = ""
    @State private var highlightedIndex = 0
    @FocusState private var isFieldFocused: Bool
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private enum ResultGroup: String, CaseIterable {
        case library = "Library"
        case papers = "Papers"
        case notes = "Notes"
        case collections = "Collections"
        case tags = "Tags"
        case actions = "Actions"
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
    private var results: [SearchResult] {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            return offered.flatMap(\.results)
        }
        return Array(SearchIndex.results(for: query, in: model).prefix(maxDisplayedResults))
    }

    private var offered: [SearchSuggestions.Group] { SearchSuggestions.groups(in: model) }

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
        var id: Int { offset }
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
        #if os(macOS)
        .onAppear { isFieldFocused = true }
        #endif
    }

    private var paletteCard: some View {
        VStack(spacing: 0) {
            searchField
            if !results.isEmpty {
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
                                .id(row.offset)
                                .onTapGesture { activate(row.result) }
                                .onHover { isHovering in
                                    if isHovering { highlightedIndex = row.offset }
                                }
                        }
                    }
                }
                .padding(.bottom, 8)
            }
            // As tall as its rows and no taller: two offers under an empty
            // field are two rows, not a panel with two rows at the top.
            .frame(height: min(CGFloat(results.count) * rowHeight + CGFloat(groups.count) * 30 + 8,
                               CGFloat(maxDisplayedResults) * rowHeight + 40))
            .onChange(of: highlightedIndex) { _, newValue in
                withAnimation(.easeOut(duration: 0.12)) {
                    scrollProxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
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

    private func dismiss() {
        isPresented = false
    }
}
