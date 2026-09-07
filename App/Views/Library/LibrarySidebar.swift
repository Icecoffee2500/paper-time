import PaperCore
import SwiftUI

/// The source list: built-in scopes, collections, and tags.
///
/// `LibraryModel.Scope` is not optional (there is always something selected),
/// while `List(selection:)` wants `Binding<Scope?>`, so this view bridges the
/// two with a small computed binding rather than adding an optional to the
/// model just for this view.
struct LibrarySidebar: View {
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
                    .badge(model.searchResultCount)
                    .tag(LibraryModel.Scope.searchResults)
                    .contextMenu {
                        Button("Clear Search") { model.clearSearchResults() }
                    }
                }
            }

            Section("Library") {
                Label("All Papers", systemImage: "tray.full")
                    .badge(model.counts.all)
                    .tag(LibraryModel.Scope.all)
                Label("Unread", systemImage: "circle")
                    .badge(model.counts.unread)
                    .tag(LibraryModel.Scope.unread)
                    .dropTarget { await model.setReadingStatus(.unread, for: $0) }
                Label("Reading", systemImage: "circle.lefthalf.filled")
                    .badge(model.counts.reading)
                    .tag(LibraryModel.Scope.reading)
                    .dropTarget { await model.setReadingStatus(.reading, for: $0) }
                Label("Read", systemImage: "checkmark.circle")
                    .badge(model.counts.read)
                    .tag(LibraryModel.Scope.read)
                    .dropTarget { await model.setReadingStatus(.read, for: $0) }
                Label("Favorites", systemImage: "star")
                    .badge(model.counts.favorites)
                    .tag(LibraryModel.Scope.favorites)
                    .dropTarget { await model.setFavorite(true, for: $0) }
                Label("Needs Review", systemImage: "exclamationmark.triangle")
                    .badge(model.counts.needsReview)
                    .tag(LibraryModel.Scope.needsReview)
            }

            Section("Collections") {
                ForEach(model.collections.collections) { collection in
                    Label(collection.name, systemImage: symbolName(for: collection))
                        .badge(model.counts.collections[collection.id] ?? 0)
                        .tag(LibraryModel.Scope.collection(collection.id))
                        .dropTarget(isEnabled: !collection.isSmart) { paperID in
                            await model.addToCollection(collection.id, paperID: paperID)
                        }
                }
                Button {
                    newCollectionName = ""
                    isPresentingNewCollection = true
                } label: {
                    Label("New Collection…", systemImage: "plus.circle")
                }
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
                    .badge(model.counts.tags[tag.id] ?? 0)
                    .tag(LibraryModel.Scope.tag(tag.id))
                    .dropTarget { await model.addTag(tag.id, to: $0) }
                }
            }
        }
        .navigationTitle(model.manifest.displayName)
        .sheet(isPresented: $isPresentingNewCollection) {
            NewCollectionSheet(
                name: $newCollectionName,
                onCreate: { name in
                    Task { await model.addCollection(named: name) }
                }
            )
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
    let isEnabled: Bool
    let handle: (UUID) async -> Void

    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .listRowBackground(
                isTargeted
                    ? RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.accentColor.opacity(0.2))
                    : nil
            )
            .dropDestination(for: PaperTransfer.self) { items, _ in
                guard isEnabled, !items.isEmpty else { return false }
                Task {
                    for item in items { await handle(item.id) }
                }
                return true
            } isTargeted: { targeted in
                isTargeted = isEnabled && targeted
            }
    }
}

extension View {
    func dropTarget(
        isEnabled: Bool = true,
        handle: @escaping (UUID) async -> Void
    ) -> some View {
        modifier(PaperDropTarget(isEnabled: isEnabled, handle: handle))
    }
}
