import Foundation
import LibraryStore
import PaperCore
import SwiftUI

/// Top-level application state: which library folder is open, and the model
/// that reads it.
///
/// The app deliberately has no account and no server. A library is a folder the
/// user chose, so "signing in" is picking that folder once per device.
@MainActor
@Observable
public final class AppModel {
    public enum Phase: Equatable {
        case launching
        case needsLibraryFolder
        case ready
        case failed(String)
    }

    public private(set) var phase: Phase = .launching
    public private(set) var library: LibraryModel?
    public var settings = AppSettings()

    /// Panel visibility lives here so the View menu can toggle it. A window's
    /// own `@State` is unreachable from `Commands`.
    public var columnVisibility = NavigationSplitViewVisibility.all
    #if os(macOS)
    public var showsInspector = true
    #else
    public var showsInspector = false
    #endif
    /// The Spotlight-style search overlay.
    public var showsSearchPalette = false

    /// Hides everything except the paper.
    public private(set) var isFocusMode = false
    /// In focus mode the paper list is summoned as a floating panel instead of
    /// occupying a column, so the page keeps the whole window.
    public var showsFloatingList = false

    private var restoredColumnVisibility = NavigationSplitViewVisibility.all
    private var restoredInspector = false

    public func toggleFocusMode() {
        withAnimation(.snappy(duration: 0.28)) {
            if isFocusMode {
                columnVisibility = restoredColumnVisibility
                showsInspector = restoredInspector
                showsFloatingList = false
                isFocusMode = false
            } else {
                restoredColumnVisibility = columnVisibility
                restoredInspector = showsInspector
                columnVisibility = .detailOnly
                showsInspector = false
                isFocusMode = true
            }
        }
    }

    public func toggleFloatingList() {
        guard isFocusMode else { return }
        withAnimation(.snappy(duration: 0.22)) {
            showsFloatingList.toggle()
        }
    }

    /// Hides the scope sidebar only. The paper list stays put: collapsing both
    /// columns at once is a different, rarer intent than "give me more room".
    public func toggleSidebar() {
        // The inspector animates because `.inspector` animates its own
        // presentation; a column-visibility change does not, so it has to be
        // asked for explicitly or the sidebar snaps in and out.
        withAnimation(.snappy(duration: 0.25)) {
            columnVisibility = columnVisibility == .all ? .doubleColumn : .all
        }
    }

    public func toggleInspector() {
        withAnimation(.snappy(duration: 0.25)) {
            showsInspector.toggle()
        }
    }

    public var isSidebarVisible: Bool { columnVisibility == .all }

    private let preference = LibraryLocationPreference()

    public init() {}

    /// Reopens the folder chosen on this device, if there is one.
    public func restore() async {
        guard let result = preference.load() else {
            phase = .needsLibraryFolder
            return
        }
        switch result {
        case let .resolved(location), let .resolvedStale(location, _):
            await open(location)
        case let .unavailable(error):
            // The folder may simply not be mounted yet, so this is a prompt to
            // reconnect rather than a reason to forget the choice.
            phase = .failed(
                """
                Paper Time can't reach its library folder\
                \(preference.pathHint.map { " at \($0)" } ?? "").
                \(error.localizedDescription)
                """
            )
        }
    }

    /// Adopts a folder the user just picked.
    public func adopt(folderAt url: URL) async {
        let location = LibraryLocation.adopting(url)
        do {
            try preference.store(location)
        } catch {
            phase = .failed("That folder could not be remembered: \(error.localizedDescription)")
            return
        }
        await open(location)
    }

    public func forgetLibrary() {
        preference.clear()
        library = nil
        phase = .needsLibraryFolder
    }

    private func open(_ location: LibraryLocation) async {
        let store = LibraryStore(location: location)
        do {
            let manifest = try await store.bootstrap()
            let model = LibraryModel(store: store, location: location, manifest: manifest)
            library = model
            phase = .ready
            await model.refresh()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

/// User preferences that are per-device rather than per-library.
@Observable
public final class AppSettings {
    @ObservationIgnored
    @AppStorage("resolveMetadataOnImport") public var resolvesMetadataOnImport = true
    /// Optional address sent to Crossref and OpenAlex.
    ///
    /// Both services route requests that identify a contact into a faster,
    /// more forgiving pool. Empty by default: the app must work without ever
    /// disclosing who is using it.
    @ObservationIgnored
    @AppStorage("metadataContactEmail") public var metadataContactEmail = ""
    @ObservationIgnored
    @AppStorage("preferredPreprintStyle") public var preferredPreprintStyle = "eprint"
    @ObservationIgnored
    @AppStorage("protectCaseInBibTeX") public var protectsCase = true
    @ObservationIgnored
    @AppStorage("includeUnverifiedInExport") public var includesUnverifiedInExport = false
    @ObservationIgnored
    @AppStorage("readerPageMode") public var readerPageMode = "continuous"
    @ObservationIgnored
    @AppStorage("readerTint") public var readerTint = "none"

    public init() {}
}
