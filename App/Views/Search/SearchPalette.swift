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
        case papers = "Papers"
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

    private var results: [SearchResult] {
        Array(SearchIndex.results(for: query, in: model).prefix(maxDisplayedResults))
    }

    /// Results split into their display groups, each row carrying the index it
    /// has in the flat list so keyboard highlighting stays in one coordinate
    /// space.
    private var groups: [SearchResultGroup] {
        var byGroup: [ResultGroup: [SearchResultRow]] = [:]
        for (offset, result) in results.enumerated() {
            let group = sectionForKind(result.kind)
            byGroup[group, default: []].append(SearchResultRow(offset: offset, result: result))
        }
        var ordered: [SearchResultGroup] = []
        for group in ResultGroup.allCases {
            guard let rows = byGroup[group], !rows.isEmpty else { continue }
            ordered.append(SearchResultGroup(group: group, rows: rows))
        }
        return ordered
    }

    private struct SearchResultRow: Identifiable {
        var offset: Int
        var result: SearchResult
        var id: Int { offset }
    }

    private struct SearchResultGroup: Identifiable {
        var group: ResultGroup
        var rows: [SearchResultRow]
        var id: String { group.rawValue }
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
        .onAppear { isFieldFocused = true }
    }

    private var paletteCard: some View {
        VStack(spacing: 0) {
            searchField
            if !results.isEmpty {
                Divider()
                resultsList
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
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

            TextField("Paper Time Search", text: $query)
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
                        Text(group.group.rawValue.uppercased())
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
            .frame(maxHeight: CGFloat(maxDisplayedResults) * rowHeight + 40)
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
                if !result.subtitle.isEmpty {
                    Text(result.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
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
        case .paper: .papers
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
        case let .paper(id):
            model.selectedPaperID = id
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
