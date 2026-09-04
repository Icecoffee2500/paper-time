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
            Section("Library") {
                Label("All Papers", systemImage: "tray.full")
                    .tag(LibraryModel.Scope.all)
                Label("Unread", systemImage: "circle")
                    .tag(LibraryModel.Scope.unread)
                Label("Favorites", systemImage: "star")
                    .tag(LibraryModel.Scope.favorites)
                if model.reviewCount > 0 {
                    Label("Needs Review", systemImage: "exclamationmark.triangle")
                        .badge(model.reviewCount)
                        .tag(LibraryModel.Scope.needsReview)
                }
            }

            Section("Collections") {
                ForEach(model.collections.collections) { collection in
                    Label(collection.name, systemImage: symbolName(for: collection))
                        .tag(LibraryModel.Scope.collection(collection.id))
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
                    .tag(LibraryModel.Scope.tag(tag.id))
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
