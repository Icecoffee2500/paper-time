import PaperCore
import SwiftUI

/// The source list: built-in scopes, collections, and tags.
///
/// `LibraryModel.Scope` is not optional (there is always something selected),
/// while `List(selection:)` wants `Binding<Scope?>`, so this view bridges the
/// two with a small computed binding rather than adding an optional to the
/// model just for this view.
struct LibrarySidebar: View {
    @State private var showsAllAuthors = false
    @State private var authorsAreShown = true
    @Bindable var model: LibraryModel

    @State private var isPresentingNewCollection = false
    @State private var newCollectionName = ""

    private var scopeSelection: Binding<LibraryModel.Scope?> {
        Binding(
            get: { model.scope },
            set: { newValue in
                if let newValue { model.scope = newValue }
            }
        )
    }

    var body: some View {
        List(selection: scopeSelection) {
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
                    .count(model.searchResultCount)
                    .tag(LibraryModel.Scope.searchResults)
                    .contextMenu {
                        Button("Clear Search") { model.clearSearchResults() }
                    }
                }
            }

            Section("Library") {
                Label("All Papers", systemImage: "tray.full")
                    .count(model.counts.all)
                    .tag(LibraryModel.Scope.all)
                Label("Unread", systemImage: "circle")
                    .count(model.counts.unread)
                    .tag(LibraryModel.Scope.unread)
                    .dropTarget(in: model) { await model.setReadingStatus(.unread, for: $0) }
                Label("Reading", systemImage: "circle.lefthalf.filled")
                    .count(model.counts.reading)
                    .tag(LibraryModel.Scope.reading)
                    .dropTarget(in: model) { await model.setReadingStatus(.reading, for: $0) }
                Label("Read", systemImage: "checkmark.circle")
                    .count(model.counts.read)
                    .tag(LibraryModel.Scope.read)
                    .dropTarget(in: model) { await model.setReadingStatus(.read, for: $0) }
                Label("Favorites", systemImage: "star")
                    .count(model.counts.favorites)
                    .tag(LibraryModel.Scope.favorites)
                    .dropTarget(in: model) { await model.setFavorite(true, for: $0) }
                Label("Needs Review", systemImage: "exclamationmark.triangle")
                    .count(model.counts.needsReview)
                    .tag(LibraryModel.Scope.needsReview)
            }

            Section("Slip-Box") {
                Label("Notes", systemImage: "tray.full")
                    .count(model.notes.notes.count)
                    .tag(LibraryModel.Scope.notes)
            }

            Section("Collections") {
                ForEach(model.collections.collections) { collection in
                    Label(collection.name, systemImage: symbolName(for: collection))
                        .count(model.counts.collections[collection.id] ?? 0)
                        .tag(LibraryModel.Scope.collection(collection.id))
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
                    .count(model.counts.tags[tag.id] ?? 0)
                    .tag(LibraryModel.Scope.tag(tag.id))
                    .dropTarget(in: model) { await model.addTag(tag.id, to: $0) }
                }
            }

            authorsSection

            Section {
                Label("Graph", systemImage: "point.3.connected.trianglepath.dotted")
                    .tag(LibraryModel.Scope.graph)
            }
        }
        .thinScrollers()
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
                        .count(author.count)
                        .tag(LibraryModel.Scope.author(author.key))
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
            .listRowBackground(
                isTargeted
                    ? RoundedRectangle(cornerRadius: Corner.row, style: .continuous)
                        .fill(Color.accentColor.opacity(0.2))
                    : nil
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


private extension View {
    /// A count beside a source-list row, shown even when it is zero.
    ///
    /// `.badge(0)` draws nothing at all, so a row would lose its number exactly
    /// when the number is worth knowing — an empty collection reads as broken
    /// rather than empty.
    func count(_ value: Int) -> some View {
        badge(
            Text(value, format: .number)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        )
    }
}
