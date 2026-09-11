import Foundation
import LibraryStore
import PaperCore
import SwiftUI
#if os(macOS)
import AppKit
#endif

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
    /// `.doubleColumn` rather than `.all`: this is a two-column split view, and
    /// `.all` is not one of the states it understands — starting there left
    /// every later change to the binding being ignored.
    public var columnVisibility = NavigationSplitViewVisibility.doubleColumn
    #if os(macOS)
    public var showsInspector = true
    #else
    public var showsInspector = false
    #endif
    /// Whether the paper list — the column between the source list and the
    /// reader — is showing.
    public var showsPaperList = true
    /// Whether the paper itself is showing.
    ///
    /// Closing it leaves the library: the source list and the titles, with the
    /// width the page was using. Worth having when you are sorting a shelf
    /// rather than reading from it.
    public var showsReader = true

    /// How wide the two columns are.
    ///
    /// Observed properties rather than `@AppStorage`: an `@ObservationIgnored`
    /// property tells nobody when it changes, so dragging a divider wrote the
    /// new width and the layout, which had never been asked to watch it, went
    /// on drawing the old one. They persist themselves on the way past.
    public var sidebarWidth: Double = AppModel.storedWidth("sidebarWidth", default: 232) {
        didSet { UserDefaults.standard.set(sidebarWidth, forKey: "sidebarWidth") }
    }
    public var paperListWidth: Double = AppModel.storedWidth("paperListWidth", default: 320) {
        didSet { UserDefaults.standard.set(paperListWidth, forKey: "paperListWidth") }
    }
    /// The inspector's, for the same reason the other two are here: it is a
    /// column of ours now rather than SwiftUI's. `.inspector` brought its own
    /// background with a square corner on it, which no amount of clipping from
    /// outside would round off.
    public var inspectorWidth: Double = AppModel.storedWidth("inspectorWidth", default: 360) {
        didSet { UserDefaults.standard.set(inspectorWidth, forKey: "inspectorWidth") }
    }

    /// The keys that open and close the panes.
    ///
    /// Persists itself on the way past, the same as the column widths: an
    /// `@AppStorage` property that nothing observes would change the defaults
    /// without the menu ever hearing about it, and the menu is where these are
    /// actually used.
    public var paneShortcuts: [String: String] =
        UserDefaults.standard.dictionary(forKey: "paneShortcuts") as? [String: String] ?? [:] {
        didSet { UserDefaults.standard.set(paneShortcuts, forKey: "paneShortcuts") }
    }

    public func shortcut(for action: ShortcutAction) -> Shortcut {
        paneShortcuts[action.rawValue].flatMap(Shortcut.init(stored:)) ?? action.fallback
    }

    /// What the menu asks for: the shortcut, or nothing when another action
    /// has taken the key this one had.
    ///
    /// Optional on purpose. Choosing between a button with a shortcut and one
    /// without produced two different view types in the same place, and
    /// SwiftUI handed the keys to the wrong menu items — ⌘[ opened the paper
    /// list and ⌘P the sidebar. One view, one optional shortcut.
    public func keyboardShortcut(for action: ShortcutAction) -> KeyboardShortcut? {
        guard hasShortcut(action) else { return nil }
        return shortcut(for: action).keyboardShortcut
    }

    public func setShortcut(_ shortcut: Shortcut, for action: ShortcutAction) {
        // One key, one action: whoever else had it gives it up.
        for other in ShortcutAction.allCases where other != action {
            if hasShortcut(other), self.shortcut(for: other) == shortcut {
                paneShortcuts[other.rawValue] = ""
            }
        }
        paneShortcuts[action.rawValue] = shortcut.stored
    }

    public func resetShortcuts() {
        paneShortcuts = [:]
    }

    /// True when an action has been left with no key at all, because another
    /// took the one it had.
    public func hasShortcut(_ action: ShortcutAction) -> Bool {
        guard let stored = paneShortcuts[action.rawValue] else { return true }
        return Shortcut(stored: stored) != nil
    }

    private static func storedWidth(_ key: String, default fallback: Double) -> Double {
        let stored = UserDefaults.standard.double(forKey: key)
        return stored > 0 ? stored : fallback
    }
    /// The Spotlight-style search overlay.
    public var showsSearchPalette = false

    // MARK: - What's new

    /// Whether the introduction is on screen.
    public var showsReleaseNotes = false

    /// The version whose notes have been read.
    ///
    /// Stored rather than a plain "has launched before" flag, so the same
    /// sheet can introduce the next version too without anyone having to
    /// remember to reset anything.
    @ObservationIgnored
    @AppStorage("seenReleaseNotesVersion") private var seenVersion = ""

    /// True on the first run of a version the reader has not been shown.
    public var hasUnseenReleaseNotes: Bool { seenVersion != ReleaseNotes.version }

    public func showReleaseNotesIfNew() {
        guard hasUnseenReleaseNotes else { return }
        showsReleaseNotes = true
    }

    public func markReleaseNotesSeen() {
        seenVersion = ReleaseNotes.version
    }

    /// Hides everything except the paper.
    public private(set) var isFocusMode = false
    /// In focus mode the paper list is summoned as a floating panel instead of
    /// occupying a column, so the page keeps the whole window.
    public var showsFloatingList = false

    private var restoredColumnVisibility = NavigationSplitViewVisibility.doubleColumn
    private var restoredInspector = false
    private var restoredPaperList = true

    public func toggleFocusMode() {
        setFocusMode(!isFocusMode)
    }

    /// Puts the window into, or takes it out of, the paper-only mode.
    ///
    /// What was open before is remembered, because leaving focus should give
    /// back the window the reader had rather than some default.
    public func setFocusMode(_ isOn: Bool) {
        guard isOn != isFocusMode else { return }
        withAnimation(AppModel.paneMotion) {
            if isOn {
                restoredColumnVisibility = columnVisibility
                restoredInspector = showsInspector
                restoredPaperList = showsPaperList
                // Set directly rather than through `toggleSidebar`, which
                // would open a second transaction inside this one.
                if isSidebarVisible { sidebarHidden = true }
                showsPaperList = false
                showsInspector = false
                showsReader = true
                isFocusMode = true
            } else {
                if !isSidebarVisible { sidebarHidden = false }
                showsInspector = restoredInspector
                showsPaperList = restoredPaperList
                showsFloatingList = false
                isFocusMode = false
            }
        }
    }

    public func toggleFloatingList() {
        guard isFocusMode else { return }
        withAnimation(AppModel.paneMotion) {
            showsFloatingList.toggle()
        }
    }

    /// How a pane opens and closes.
    ///
    /// One curve, in one place. There were three — 0.22 declared on the
    /// columns, 0.25 here, 0.28 for focus mode — and they were all animating
    /// the same widths, so a toggle was interpolated two ways at once and the
    /// motion came out stepped.
    public static let paneMotion: Animation = .snappy(duration: 0.25)

    /// Hides the scope sidebar only. The paper list stays put: collapsing both
    /// columns at once is a different, rarer intent than "give me more room".
    public func toggleSidebar() {
        withAnimation(AppModel.paneMotion) { sidebarHidden.toggle() }
    }

    /// Hides the paper list, leaving the source list and the reader.
    public func togglePaperList() {
        withAnimation(AppModel.paneMotion) {
            showsPaperList.toggle()
            // Something has to be left to look at.
            if !showsPaperList, !showsReader, !isSidebarVisible { showsReader = true }
        }
    }

    /// Hides the paper, leaving the library around it.
    ///
    /// Focus mode is the paper and nothing else, so the two cannot both be on:
    /// asking for one leaves the other.
    public func toggleReader() {
        withAnimation(AppModel.paneMotion) {
            if isFocusMode {
                setFocusMode(false)
                return
            }
            showsReader.toggle()
            // A window with every column closed is a window with nothing in
            // it, so the last one to be closed opens the list instead.
            if !showsReader, !showsPaperList, !isSidebarVisible { showsPaperList = true }
        }
    }

    public func toggleInspector() {
        withAnimation(AppModel.paneMotion) {
            showsInspector.toggle()
        }
    }

    /// Whether the source list is showing. On the Mac the split view owns the
    /// truth, so this follows our own toggling.
    public private(set) var sidebarHidden = false

    public var isSidebarVisible: Bool {
        #if os(macOS)
        !sidebarHidden
        #else
        columnVisibility != .detailOnly
        #endif
    }

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
    /// Which fields appear under a paper's title in the list, in order.
    @ObservationIgnored
    @AppStorage("listSubtitleFields") public var listSubtitleFields = "authors,year,venue"
    /// How wide the paper list is, remembered so hiding and showing it gives
    /// back the column you had rather than a default.

    public init() {}
}
