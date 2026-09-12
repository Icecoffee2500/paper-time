import PaperCore
import SwiftUI

/// The source list: built-in scopes, collections, and tags.
///
/// Not a `List(selection:)`. The system paints a selected sidebar row in the
/// accent while the list has keyboard focus and in grey the moment focus
/// moves to the papers — which, on a panel, read as "inactive" and, on the
/// window's glass, read as a smudge. Which shelf you are on is not a fact
/// about where the keyboard is pointing, so each row marks itself: the
/// accent for its words on a pale tint of the accent behind them, the shape
/// the folder's name takes in the header and a passage takes in a note.
struct LibrarySidebar: View {
    @State private var showsAllAuthors = false
    @State private var authorsAreShown = true
    @Bindable var model: LibraryModel

    @State private var isPresentingNewCollection = false
    @State private var newCollectionName = ""

    var body: some View {
        List {
            if !model.searchQuery.isEmpty {
                // A search is somewhere you can be, not a filter left switched
                // on somewhere off-screen — so it gets a row of its own, at the
                // top, and it can be dismissed from there.
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Search Results")
                            Text(model.searchQuery)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    } icon: {
                        Image(systemName: "magnifyingglass")
                    }
                    .count(model.searchResultCount, current: model.scope == .searchResults)
                    .scopeRow(.searchResults, in: model)
                    .contextMenu {
                        Button("Clear Search") { model.clearSearchResults() }
                    }
                }
            }

            Section {
                Label("All Papers", systemImage: "tray.full")
                    .count(model.counts.all, current: model.scope == .all)
                    .scopeRow(.all, in: model)
                Label("Unread", systemImage: "circle")
                    .count(model.counts.unread, current: model.scope == .unread)
                    .scopeRow(.unread, in: model)
                    .dropTarget(in: model) { await model.setReadingStatus(.unread, for: $0) }
                Label("Reading", systemImage: "circle.lefthalf.filled")
                    .count(model.counts.reading, current: model.scope == .reading)
                    .scopeRow(.reading, in: model)
                    .dropTarget(in: model) { await model.setReadingStatus(.reading, for: $0) }
                Label("Read", systemImage: "checkmark.circle")
                    .count(model.counts.read, current: model.scope == .read)
                    .scopeRow(.read, in: model)
                    .dropTarget(in: model) { await model.setReadingStatus(.read, for: $0) }
                Label("Favorites", systemImage: "star")
                    .count(model.counts.favorites, current: model.scope == .favorites)
                    .scopeRow(.favorites, in: model)
                    .dropTarget(in: model) { await model.setFavorite(true, for: $0) }
                Label("Needs Review", systemImage: "exclamationmark.triangle")
                    .count(model.counts.needsReview, current: model.scope == .needsReview)
                    .scopeRow(.needsReview, in: model)
            } header: {
                // The folder's name, small, where a headline used to sit
                // over the whole list saying the same thing louder.
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("Library")
                    // The folder as a chip — the same shape a passage from a
                    // paper takes in a note, and for the same reason: it
                    // names where something came from. Plain accent type
                    // beside a grey header shouted; on its own pale tint it
                    // is a label.
                    Text(model.displayName)
                        .foregroundStyle(.tint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(
                            RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                                .fill(Color.accentColor.opacity(0.12))
                        )
                }
                // Lines the first row up with the first paper across the way:
                // the list column's header is taller than this one, and the
                // two rows underneath should sit level.
                .padding(.bottom, 13)
            }

            Section("Slip-Box") {
                Label("Notes", systemImage: "tray.full")
                    .count(model.notes.notes.count, current: model.scope == .notes)
                    .scopeRow(.notes, in: model)
            }

            Section("Collections") {
                ForEach(model.collections.collections) { collection in
                    Label(collection.name, systemImage: symbolName(for: collection))
                        .count(model.counts.collections[collection.id] ?? 0, current: model.scope == .collection(collection.id))
                        .scopeRow(.collection(collection.id), in: model)
                        .dropTarget(in: model, isEnabled: !collection.isSmart) { paperID in
                            await model.addToCollection(collection.id, paperID: paperID)
                        }
                }
                Button {
                    newCollectionName = ""
                    isPresentingNewCollection = true
                } label: {
                    Label("New Collection…", systemImage: "plus.circle")
                        .foregroundStyle(.secondary)
                        .contentShape(.rect)
                }
                // Plain, or SwiftUI gives it a bezel and it sits in the source
                // list looking like the one thing that is not a row.
                .buttonStyle(.plain)
            }

            Section("Tags") {
                ForEach(model.manifest.tags) { tag in
                    Label {
                        Text(tag.name)
                    } icon: {
                        Circle()
                            .fill(tag.color.swiftUIColor)
                            .frame(width: 10, height: 10)
                            .accessibilityHidden(true)
                    }
                    .count(model.counts.tags[tag.id] ?? 0, current: model.scope == .tag(tag.id))
                    .scopeRow(.tag(tag.id), in: model)
                    .dropTarget(in: model) { await model.addTag(tag.id, to: $0) }
                }
            }

            authorsSection

            Section {
                Label {
                    Text("Graph")
                } icon: {
                    GraphSymbol(colored: model.scope == .graph)
                }
                .scopeRow(.graph, in: model)
            }
        }
        .hiddenScrollers()
        // The source list used to get this from being a split view's sidebar.
        // Laying the columns out ourselves means asking for it: without it the
        // rows come back with separator lines under them.
        #if os(macOS)
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        #endif
        .navigationTitle(model.displayName)
        .sheet(isPresented: $isPresentingNewCollection) {
            NewCollectionSheet(
                name: $newCollectionName,
                onCreate: { name in
                    Task { await model.addCollection(named: name) }
                }
            )
        }
    }

    /// Who is on the most papers here.
    ///
    /// A shelf has a shape, and this is it: the names that keep coming back.
    /// Ten of them fit without turning the source list into a directory; the
    /// rest are one click away.
    @ViewBuilder
    private var authorsSection: some View {
        let ranking = model.authorRanking
        if !ranking.isEmpty {
            Section("Authors", isExpanded: $authorsAreShown) {
                ForEach(showsAllAuthors ? ranking : Array(ranking.prefix(10))) { author in
                    Label(author.name, systemImage: "person")
                        .count(author.count, current: model.scope == .author(author.key))
                        .scopeRow(.author(author.key), in: model)
                }
                if ranking.count > 10 {
                    Button(showsAllAuthors ? "Show Fewer" : "Show All \(ranking.count)") {
                        withAnimation(.snappy(duration: 0.2)) { showsAllAuthors.toggle() }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.callout)
                }
            }
        }
    }

    private func symbolName(for collection: Collection) -> String {
        collection.isSmart ? "folder.badge.gearshape" : collection.symbolName
    }
}

/// Small name-only sheet for creating a manual collection.
private struct NewCollectionSheet: View {
    @Binding var name: String
    let onCreate: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField("Collection Name", text: $name)
            }
            .formStyle(.grouped)
            .navigationTitle("New Collection")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        onCreate(trimmed)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 320, minHeight: 140)
        #endif
    }
}

extension Tag.Color {
    /// Maps the library's persisted tag palette onto system colors, so tag
    /// swatches always match the platform's semantic palette.
    var swiftUIColor: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .mint: .mint
        case .teal: .teal
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .gray: .gray
        }
    }
}

/// Makes a sidebar row accept a dragged paper.
///
/// Filing a paper by dragging it onto the thing you want it filed under is the
/// gesture people already know from Finder and Mail, and it is faster than
/// finding the same action in a menu.
private struct PaperDropTarget: ViewModifier {
    let model: LibraryModel
    let isEnabled: Bool
    let handle: (UUID) async -> Void

    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            // A ring, not the row's background — the background belongs to
            // whichever row is chosen, and a drop can land on any of them.
            .overlay(
                RoundedRectangle(cornerRadius: Corner.row, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(isTargeted ? 0.6 : 0), lineWidth: 1.5)
                    .padding(.horizontal, -8)
                    .padding(.vertical, -3)
            )
            .dropDestination(for: PaperTransfer.self) { items, _ in
                guard isEnabled, !items.isEmpty else { return false }
                // A drag that started on one of several selected rows brings
                // all of them.
                Task {
                    var seen: Set<UUID> = []
                    for item in items {
                        for id in model.draggedPapers(startingAt: item.id)
                        where seen.insert(id).inserted {
                            await handle(id)
                        }
                    }
                }
                return true
            } isTargeted: { targeted in
                isTargeted = isEnabled && targeted
            }
    }
}

extension View {
    func dropTarget(
        in model: LibraryModel,
        isEnabled: Bool = true,
        handle: @escaping (UUID) async -> Void
    ) -> some View {
        modifier(PaperDropTarget(model: model, isEnabled: isEnabled, handle: handle))
    }
}


/// A row of the source list that stands for a scope: pressed, it becomes the
/// scope; when it is the scope, it says so in the accent.
private struct ScopeRow: ViewModifier {
    let scope: LibraryModel.Scope
    let model: LibraryModel

    private var isCurrent: Bool { model.scope == scope }

    /// The colour the chosen row's symbol takes. The source list's own icon
    /// colouring ignores the row's foreground style, so the label is drawn
    /// here, symbol first. States get the system's colours for states —
    /// reading is under way, read is done, review is wanted — and places
    /// take the accent, so the strip reads as one thing with a few meanings.
    private var symbolColor: Color {
        switch scope {
        case .reading: .orange
        case .read: .green
        case .favorites: .yellow
        case .needsReview: .red
        default: .accentColor
        }
    }

    /// The three colours the graph draws its connections in, for its row.
    static let graphColors: [Color] = [.blue, .purple, .pink]
    @Environment(\.colorScheme) private var colorScheme

    /// The row's colour made fit for words: a yellow star reads, yellow
    /// type on a pale wash over a blue desktop does not. Deepened toward
    /// black in the light, lifted toward white in the dark.
    private var textColor: Color {
        symbolColor.mix(with: colorScheme == .dark ? .white : .black, by: colorScheme == .dark ? 0.25 : 0.4)
    }

    /// A pale wash of the row's colour; for the graph, the three colours of
    /// its connections running into one another.
    private var ground: AnyShapeStyle {
        guard isCurrent else { return AnyShapeStyle(Color.clear) }
        if scope == .graph {
            return AnyShapeStyle(LinearGradient(
                colors: Self.graphColors.map { $0.opacity(0.24) },
                startPoint: .leading, endPoint: .trailing
            ))
        }
        return AnyShapeStyle(symbolColor.opacity(0.2))
    }

    func body(content: Content) -> some View {
        content
            .labelStyle(SidebarLabelStyle(symbolColor: isCurrent ? symbolColor : nil))
            // The row's colour is the symbol's: name, count and ground
            // agree, rather than an orange symbol on a blue wash.
            .tint(textColor)
            .foregroundStyle(isCurrent ? AnyShapeStyle(textColor) : AnyShapeStyle(.primary))
            .fontWeight(isCurrent ? .medium : .regular)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .onTapGesture { model.scope = scope }
            .listRowBackground(
                RoundedRectangle(cornerRadius: Corner.row, style: .continuous)
                    .fill(ground)
                    .padding(.horizontal, 6)
            )
    }
}

/// The graph's symbol: three nodes joined by dotted edges, each node in one
/// of the colours the graph draws its connections in when the row is the
/// one chosen, and plain otherwise.
private struct GraphSymbol: View {
    let colored: Bool

    var body: some View {
        Canvas { context, size in
            let points = [
                CGPoint(x: size.width * 0.5, y: size.height * 0.16),
                CGPoint(x: size.width * 0.14, y: size.height * 0.84),
                CGPoint(x: size.width * 0.86, y: size.height * 0.84),
            ]
            var edges = Path()
            for index in 0..<3 {
                edges.move(to: points[index])
                edges.addLine(to: points[(index + 1) % 3])
            }
            context.stroke(edges, with: .color(.secondary.opacity(0.7)),
                           style: StrokeStyle(lineWidth: 1, dash: [1.5, 2]))
            // Filled in colour when chosen; outlined, like the other rows'
            // symbols, when not.
            for (index, point) in points.enumerated() {
                let dot = CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)
                if colored {
                    context.fill(Path(ellipseIn: dot), with: .color(ScopeRow.graphColors[index]))
                } else {
                    context.fill(Path(ellipseIn: dot), with: .color(.clear))
                    context.stroke(Path(ellipseIn: dot.insetBy(dx: 0.5, dy: 0.5)), with: .color(.primary), lineWidth: 1)
                }
            }
        }
        .frame(width: 15, height: 15)
        .accessibilityHidden(true)
    }
}

/// A source-list label whose symbol can be given a colour of its own.
private struct SidebarLabelStyle: LabelStyle {
    let symbolColor: Color?

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 7) {
            configuration.icon
                .foregroundStyle(symbolColor.map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary))
                .frame(width: 20, alignment: .center)
            configuration.title
        }
    }
}

private extension View {
    func scopeRow(_ scope: LibraryModel.Scope, in model: LibraryModel) -> some View {
        modifier(ScopeRow(scope: scope, model: model))
    }

    /// A count beside a source-list row, shown even when it is zero.
    ///
    /// `.badge(0)` draws nothing at all, so a row would lose its number exactly
    /// when the number is worth knowing — an empty collection reads as broken
    /// rather than empty.
    func count(_ value: Int, current: Bool = false) -> some View {
        // On the row you are on, the same accent as the words: a pale number
        // beside a blue name looked like it belonged to a different row.
        badge(
            Text(value, format: .number)
                .monospacedDigit()
                .foregroundStyle(current ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        )
    }
}
