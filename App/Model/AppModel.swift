import Foundation
import LibraryStore
import PaperCore
import PDFReader
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

    /// Whether a window has begun the launch. `phase` stays `.launching`
    /// until the library is open, so two windows that appear together — a
    /// launch that brings back two, or a probe's own window beside one
    /// SwiftUI made late — both saw it and opened the library twice.
    @ObservationIgnored public private(set) var launchBegan = false

    /// True the first time it is asked, and never again.
    public func beginLaunch() -> Bool {
        guard !launchBegan else { return false }
        launchBegan = true
        return true
    }

    public var settings = AppSettings()

    /// Panel visibility lives here so the View menu can toggle it. A window's
    /// own `@State` is unreachable from `Commands`.
    /// `.doubleColumn` rather than `.all`: this is a two-column split view, and
    /// `.all` is not one of the states it understands — starting there left
    /// every later change to the binding being ignored.
    public var columnVisibility = NavigationSplitViewVisibility.doubleColumn
    /// Which column an iPhone shows. Tapping a shelf pushes the list; tapping
    /// a paper pushes the page. The system moves it back on its own.
    public var compactColumn = NavigationSplitViewColumn.sidebar
    /// The iPad's source list: not a column, which the screen has no room
    /// for, but a panel summoned over the window, the way Spotlight comes.
    public var showsScopePanel = false
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

    /// Papers shown side by side, when they are: up to four, in the two
    /// halves and the four quarters of the page area — the way a Mac tiles
    /// windows when one is dragged to an edge of the screen.
    public var split: SplitArrangement?

    /// A reader handle for each pane. The pane showing the current paper
    /// borrows the window's own, so the toolbar and the inspector act on it;
    /// the others each keep one of these.
    private var paneLinks: [UUID: ReaderLink] = [:]

    func paneLink(for paperID: UUID) -> ReaderLink {
        if let link = paneLinks[paperID] { return link }
        let link = ReaderLink()
        paneLinks[paperID] = link
        return link
    }

    /// Puts a paper into a zone of the page area. With nothing side by side
    /// yet, the paper already showing takes the other half.
    func dock(_ id: UUID, at zone: DockZone, in model: LibraryModel) {
        let current = model.selectedPaperID
        var arrangement = split ?? current.map { SplitArrangement(left: .init(top: $0)) }
            ?? SplitArrangement(left: .init(top: id))
        arrangement.dock(id, at: zone)
        // Put beside another by hand: that is a pin, and it stays until it
        // is closed.
        for paper in arrangement.papers { model.keepOpen(paper, byHand: true) }
        withAnimation(AppModel.paneMotion) {
            split = arrangement.papers.count > 1 ? arrangement : nil
            showsReader = true
            if current == nil { model.selectedPaperID = id }
        }
    }

    /// Takes a paper out of the side-by-side arrangement. One pane left is
    /// no arrangement at all; that paper is simply the one showing.
    func undock(_ id: UUID, model: LibraryModel) {
        guard var arrangement = split else { return }
        arrangement.remove(id)
        withAnimation(AppModel.paneMotion) {
            if arrangement.papers.count <= 1 {
                split = nil
                if let last = arrangement.papers.first, model.selectedPaperID == id || model.selectedPaperID == nil {
                    model.selectedPaperID = last
                }
            } else {
                split = arrangement
                if model.selectedPaperID == id, let first = arrangement.papers.first { model.selectedPaperID = first }
            }
        }
    }

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

    /// Which paper a row has asked to attach to another one.
    ///
    /// A `let` to an object of its own, not a property of this model: the
    /// context menu that starts this is torn down the moment it is clicked, so
    /// the sheet has to be presented by something that outlives it, and
    /// everything in the window reads this model. Writing into the object
    /// invalidates only whoever reads the object's own property — the same
    /// reason `PullProgress` is an object.
    public let attaching = AttachRequest()

    // MARK: - What's new

    /// Whether the introduction is on screen.
    public var showsReleaseNotes = false
    /// The one sheet anybody can reach from anywhere, with ⌥⌘/.
    public var showsFeedback = false
    /// Held here rather than inside the sheet, so the screenshot can be taken
    /// before the sheet exists. It lasts as long as the sheet does: opening
    /// the report again starts a blank one.
    public var feedbackDraft = FeedbackDraft()
    /// Whether the last run ended badly. Read once at launch; the moment
    /// somebody is most willing to say what happened is the moment after it
    /// happened to them.
    public private(set) var cameBackFromCrash = false

    /// Opens the report sheet, blank. The screenshot is taken inside the
    /// sheet's own `task`, one runloop later, so the sheet is not in its own
    /// picture.
    ///
    /// A new draft every time. The old one used to be kept in case the sheet
    /// was dismissed by accident, and what that actually did was open the
    /// next report on top of the last one — yesterday's sentence and
    /// yesterday's screenshot, with its pen marks still on it. A report is
    /// about the moment it is written in. The name and the reply address are
    /// the exception: they live in defaults and the new draft reads them
    /// back.
    public func askForFeedback() {
        feedbackDraft = FeedbackDraft()
        showsFeedback = true
    }

    public func noteLaunch() {
        cameBackFromCrash = Feedback.Crash.markLaunched()
        #if os(macOS)
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { Feedback.Crash.markCleanExit() }
        }
        #endif
    }

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
            #if os(iOS)
            // The split view owns the columns here; focus is its detail-only
            // state, and leaving focus gives back the columns it had.
            if isOn {
                restoredColumnVisibility = columnVisibility
                restoredInspector = showsInspector
                columnVisibility = .detailOnly
                showsInspector = false
                isFocusMode = true
            } else {
                columnVisibility = restoredColumnVisibility == .detailOnly ? .doubleColumn : restoredColumnVisibility
                showsInspector = restoredInspector
                showsFloatingList = false
                isFocusMode = false
            }
            return
            #endif
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

    /// Says again what focus mode already said. The split view on the iPad
    /// settles its columns a moment after it appears, over whatever was set
    /// before it did; a book opened at launch was left with its list showing.
    public func reassertFocusMode() {
        #if os(iOS)
        guard isFocusMode else { return }
        withAnimation(AppModel.paneMotion) { columnVisibility = .detailOnly }
        #endif
    }

    /// Summons the paper's table of contents over the page, or puts it away.
    public func toggleFloatingList() {
        withAnimation(AppModel.paneMotion) {
            showsFloatingList.toggle()
            if showsFloatingList { showsOpenPapers = false }
        }
    }

    /// The open papers, summoned over the page the way the contents are —
    /// a key, a list, a choice.
    public var showsOpenPapers = false

    public func toggleOpenPapers() {
        withAnimation(AppModel.paneMotion) {
            showsOpenPapers.toggle()
            if showsOpenPapers { showsFloatingList = false }
        }
    }

    /// How a pane opens and closes.
    ///
    /// One curve, in one place. There were three — 0.22 declared on the
    /// columns, 0.25 here, 0.28 for focus mode — and they were all animating
    /// the same widths, so a toggle was interpolated two ways at once and the
    /// motion came out stepped. A pane is a surface, so it moves at a
    /// surface's speed (`Motion`).
    public static var paneMotion: Animation { Motion.surface }

    /// Hides the scope sidebar only. The paper list stays put: collapsing both
    /// columns at once is a different, rarer intent than "give me more room".
    public func toggleSidebar() {
        withAnimation(AppModel.paneMotion) {
            #if os(iOS)
            showsScopePanel.toggle()
            #else
            sidebarHidden.toggle()
            #endif
        }
    }

    /// Hides the paper list, leaving the source list and the reader.
    public func togglePaperList() {
        withAnimation(AppModel.paneMotion) {
            #if os(iOS)
            columnVisibility = columnVisibility == .detailOnly ? .doubleColumn : .detailOnly
            if columnVisibility != .detailOnly { isFocusMode = false }
            return
            #endif
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
        showsScopePanel
        #endif
    }

    private let preference = LibraryLocationPreference()

    public init() {}

    /// Reopens the folder chosen on this device, if there is one.
    public func restore() async {
        // For driving a simulator: `PAPERTIME_LIBRARY=<folder>` opens that
        // folder as the library, and `PAPERTIME_SKIP_WELCOME=1` keeps the
        // introduction down.
        if Boot.isSet("PAPERTIME_SKIP_WELCOME") { markReleaseNotesSeen() }
        if let path = Boot.setting("PAPERTIME_LIBRARY") {
            // A relative path is inside the app's own Documents, which on a
            // simulator moves with every install.
            let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: "/")
            let url = path.hasPrefix("/") ? URL(fileURLWithPath: path, isDirectory: true) : base.appendingPathComponent(path, isDirectory: true)
            // The words of a probe's papers are kept beside its library, not
            // in the caches folder the reader's copy keeps its own in —
            // `--papertime-text-cache=<path>` names another place.
            let beside = url.standardizedFileURL
            PaperTextIndex.probeDirectory = Boot.setting("PAPERTIME_TEXT_CACHE").map(Self.probeURL)
                ?? beside.deletingLastPathComponent()
                    .appending(path: beside.lastPathComponent + "-text-cache", directoryHint: .isDirectory)
            // Opened, not adopted: a run driven by a probe must leave no trace
            // on the Mac it ran on. The app is sandboxed per bundle
            // identifier, so a probe and the copy somebody actually reads with
            // share one preferences domain — and a probe that stored its test
            // folder replaced a real library with it. Twice.
            await open(LibraryLocation.adopting(url))
            return
        }
        // `--papertime-force-setup=1` shows the first-run screen without
        // forgetting the library, so that screen can be looked at on a machine
        // that already has one. It stores nothing and clears nothing.
        guard !Boot.isSet("PAPERTIME_FORCE_SETUP") else {
            phase = .needsLibraryFolder
            return
        }
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

    /// Shows the folder picker; the library stays until a folder is chosen.
    /// Only the phone and the iPad still use it — see `chooseLibraryFolder`.
    public var isChoosingLibraryFolder = false

    /// Asks for the library folder.
    ///
    /// AppKit's own open panel on the Mac. SwiftUI's `fileImporter` is what
    /// this used to be, and it did not open at all from the first-run screen —
    /// the same failure the toolbar's ＋ had in 0.4.x, where an importer
    /// presented from a view that is itself being replaced never appears. A
    /// button that does nothing is the worst thing on a first-run screen,
    /// because there is nothing else on it to try.
    public func chooseLibraryFolder() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = L("이 폴더 쓰기", "Use This Folder")
        panel.message = L(
            "논문을 둘 폴더를 골라주세요. iCloud Drive나 Google Drive 폴더도 괜찮아요.",
            "Choose the folder your papers live in. A folder in iCloud Drive or Google Drive is fine."
        )
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in await self?.adopt(folderAt: url) }
        }
        #else
        isChoosingLibraryFolder = true
        #endif
    }

    /// Opens another folder beside the ones already open, and remembers it.
    public func addLibraryFolder() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = L("이 폴더도 열기", "Open This Folder Too")
        panel.message = L(
            "옆에 둘 폴더를 골라주세요. 그 폴더의 논문이 같은 목록에 함께 보여요. 파일은 그대로 있어요.",
            "Choose another folder to read beside this one. Its papers join the same list, and nothing is moved."
        )
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in await self?.adoptExtraFolder(at: url) }
        }
        #endif
    }

    @MainActor
    public func adoptExtraFolder(at url: URL) async {
        guard let model = library else { return }
        guard !model.sources.contains(where: { $0.url == url }) else { return }
        let location = LibraryLocation.adopting(url)
        let store = LibraryStore(location: location)
        _ = try? await store.bootstrap()
        await model.addSource(location, store: store)
        rememberExtras(of: model)
    }

    /// Stops reading a folder. Its files and its records stay where they are.
    @MainActor
    public func disconnectFolder(at url: URL) async {
        guard let model = library else { return }
        await model.removeSource(url)
        rememberExtras(of: model)
    }

    /// Which folder was the library on this Mac, and which were beside it —
    /// unless this run was told which folder to open, in which case it is a
    /// probe and remembers nothing.
    private var isProbeLibrary: Bool { Boot.setting("PAPERTIME_LIBRARY") != nil }

    private func rememberExtras(of model: LibraryModel) {
        guard !isProbeLibrary else { return }
        preference.storeExtras(model.extraSources)
    }

    public func forgetLibrary() {
        preference.clear()
        library = nil
        phase = .needsLibraryFolder
    }

    // MARK: - Where the notes about no paper live

    /// Where the notes that are about no paper are, as the settings say it.
    public enum NotesFolder: Equatable {
        /// In the app's own folder, and nothing else was chosen.
        case app
        /// In the folder the reader chose.
        case chosen
        /// A folder was chosen and cannot be reached — an unplugged disk, a
        /// cloud drive signed out of, a folder in the Trash. The choice is
        /// kept; the notes are in the app's own folder until it is back. The
        /// path is the last place it was seen.
        case away(String?)
    }

    public private(set) var notesFolder: NotesFolder = .app

    /// What the last move of the notes did, for the line under the row.
    public struct NotesMove: Equatable {
        public enum Occasion: Equatable {
            /// The reader chose a folder.
            case chose
            /// The chosen folder was back, and what was written while it was
            /// away went across.
            case cameBack
            /// The reader went back to the app's own folder.
            case wentBack
        }
        public var occasion: Occasion
        public var moved: Int
        public var kept: Int
        /// Where the ones that did not move still are.
        public var keptIn: URL
    }

    public private(set) var lastNotesMove: NotesMove?
    /// One sentence that stands in for the rest of the row's footer: why a
    /// folder was not taken, why nothing came back, that it still is not there.
    public private(set) var notesNotice: String?

    /// The app's own folder for the notes about no paper — unless this run
    /// is a probe's, in which case it is a folder of the probe's own.
    ///
    /// A probe and the copy the reader uses are one sandbox, so the app's
    /// folder of a probe run *is* the reader's notes: a probe that seeded or
    /// moved notes there would be moving theirs. `--papertime-notes-box=<path>`
    /// names the probe's box, and without it the box is a folder beside the
    /// probe's library.
    private func appNotesFolder() -> LooseNotes {
        guard let library = Boot.setting("PAPERTIME_LIBRARY") else { return .inApplicationSupport() }
        if let box = Boot.setting("PAPERTIME_NOTES_BOX") { return LooseNotes(directory: Self.probeURL(box)) }
        let beside = Self.probeURL(library).standardizedFileURL
        return LooseNotes(directory: beside.deletingLastPathComponent()
            .appending(path: beside.lastPathComponent + "-loose-notes", directoryHint: .isDirectory))
    }

    /// A path given on the command line. A relative one is inside the app's
    /// own Documents, as it is for `--papertime-library`.
    private static func probeURL(_ path: String) -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: "/")
        return path.hasPrefix("/")
            ? URL(fileURLWithPath: path, isDirectory: true)
            : base.appendingPathComponent(path, isDirectory: true)
    }

    /// Decides where the notes about no paper are, before any of them is read.
    ///
    /// The folder the reader chose, if there is one and it is there — and
    /// then whatever is in the app's own folder goes across first: those are
    /// the notes written while it was away. A chosen folder that is not there
    /// is not forgotten; this run keeps its notes in the app's folder and
    /// the settings say so.
    ///
    /// A probe reads no choice and stores none. `--papertime-notes-chosen=<path>`
    /// stands in for the stored choice, so the way a launch finds the chosen
    /// folder — and what it does when it is missing — can be run.
    private func openNotes() async -> NotesModel {
        // A library opened again in the same run starts its account afresh:
        // what the last one moved is not what this one did.
        lastNotesMove = nil
        notesNotice = nil
        let own = appNotesFolder()
        let chosen: LibraryLocation?
        let hint: String?
        if isProbeLibrary {
            guard let path = Boot.setting("PAPERTIME_NOTES_CHOSEN") else {
                notesFolder = .app
                return NotesModel(appFolder: own)
            }
            chosen = LibraryLocation.adopting(Self.probeURL(path))
            hint = chosen?.url.path(percentEncoded: false)
        } else {
            guard preference.hasStoredNotesFolder else {
                notesFolder = .app
                return NotesModel(appFolder: own)
            }
            chosen = preference.loadNotesFolder()
            hint = preference.notesPathHint
        }
        guard let chosen, LooseNotes(at: chosen).isReachable else {
            notesFolder = .away(hint)
            return NotesModel(appFolder: own)
        }
        let box = LooseNotes(at: chosen)
        let model = NotesModel(appFolder: own, chosen: box)
        notesFolder = .chosen
        let caught = await Trace.time("notes: carry what was written while away") { await model.catchUp() }
        if caught.moved + caught.kept > 0 {
            lastNotesMove = NotesMove(occasion: .cameBack, moved: caught.moved, kept: caught.kept, keptIn: own.directory)
        }
        return model
    }

    /// Asks for a folder to keep the notes about no paper in, and moves them
    /// there.
    public func chooseNotesFolder() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = L("여기에 두기", "Keep Notes Here")
        panel.message = L(
            "논문 없는 노트를 둘 폴더를 골라주세요. 지금 있는 노트도 그리로 옮겨요.",
            "Choose a folder for notes that aren't about a paper. The ones you have move there too."
        )
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in await self?.moveNotes(toFolderAt: url) }
        }
        #endif
    }

    /// Makes a folder the home of the notes about no paper, and carries them
    /// into it.
    ///
    /// The choice is remembered before anything moves. Stopped halfway — the
    /// app quit, the machine slept for good — the next launch finds the new
    /// folder and carries the rest of the app's folder into it, which is the
    /// same move finished. The other way round, the moved half would sit in
    /// a folder nobody remembers.
    public func moveNotes(toFolderAt url: URL) async {
        guard let model = library else { return }
        notesNotice = nil
        // A library's own records. Its slip-box is in there, and a second
        // box over the same files moves every note about a paper out of it
        // and deletes it on the way.
        if url.pathComponents.contains(LibraryLayout.supportDirectoryName) {
            notesNotice = L(
                "이 폴더에는 라이브러리의 기록이 있어요. 다른 폴더를 골라주세요.",
                "That folder holds a library's records. Choose another one."
            )
            return
        }
        if url.standardizedFileURL == model.notes.appFolderURL.standardizedFileURL {
            await keepNotesInAppFolder()
            return
        }
        let location = LibraryLocation.adopting(url)
        // Gone between the panel and here — a disk ejected while it was
        // open. Taken anyway, every note would count as one that could not
        // move, and the settings would give the wrong reason for it.
        guard LooseNotes(at: location).isReachable else {
            notesNotice = L(
                "이 폴더에 닿을 수 없어요. 다른 폴더를 골라주세요.",
                "Paper Time can't reach that folder. Choose another one."
            )
            return
        }
        if !isProbeLibrary {
            do {
                try preference.storeNotesFolder(location)
            } catch {
                notesNotice = L(
                    "이 폴더를 기억하지 못했어요. 다른 폴더를 골라주세요.",
                    "Paper Time can't remember that folder. Choose another one."
                )
                return
            }
        }
        let from = model.notes.looseBox
        let result = await model.notes.relocate(to: LooseNotes(at: location))
        notesFolder = .chosen
        lastNotesMove = NotesMove(occasion: .chose, moved: result.moved, kept: result.kept, keptIn: from)
    }

    /// The way back: the notes about no paper return to the app's own folder
    /// and the choice is forgotten.
    ///
    /// With the chosen folder away there is nothing to carry back, and its
    /// notes stay in it — they are files in a folder the reader picked, and
    /// choosing it again brings them back.
    public func keepNotesInAppFolder() async {
        guard let model = library else { return }
        notesNotice = nil
        if !isProbeLibrary { preference.clearNotesFolder() }
        let from = model.notes.looseBox
        let wasAway = notesFolder != .chosen || model.notes.chosenFolderWentAway
        let result = await model.notes.returnToAppFolder()
        notesFolder = .app
        if wasAway, result == (0, 0) {
            // Nothing could come back from a folder that is not there, and
            // "no notes to move" would read as "there were none".
            lastNotesMove = nil
            notesNotice = L(
                "이제 노트를 앱 폴더에 둬요. 고른 폴더에 있던 노트는 그 폴더에 그대로 있어요.",
                "Notes stay on this Mac now. The ones in the folder you chose are still there."
            )
        } else {
            lastNotesMove = NotesMove(occasion: .wentBack, moved: result.moved, kept: result.kept, keptIn: from)
        }
    }

    /// Looks for the chosen folder again, for the moment the disk is plugged
    /// back in, without quitting to find out.
    public func reconnectNotesFolder() async {
        guard let model = library else { return }
        notesNotice = nil
        if model.notes.chosenFolderWentAway {
            if let result = await model.notes.comeBack() {
                lastNotesMove = NotesMove(occasion: .cameBack, moved: result.moved, kept: result.kept, keptIn: model.notes.appFolderURL)
            } else {
                notesNotice = L("아직 폴더에 닿을 수 없어요.", "The folder still isn't there.")
            }
            return
        }
        guard case .away = notesFolder else { return }
        let location = isProbeLibrary
            ? Boot.setting("PAPERTIME_NOTES_CHOSEN").map { LibraryLocation.adopting(Self.probeURL($0)) }
            : preference.loadNotesFolder()
        guard let location, LooseNotes(at: location).isReachable else {
            notesNotice = L("아직 폴더에 닿을 수 없어요.", "The folder still isn't there.")
            return
        }
        let result = await model.notes.relocate(to: LooseNotes(at: location))
        notesFolder = .chosen
        lastNotesMove = NotesMove(occasion: .cameBack, moved: result.moved, kept: result.kept, keptIn: model.notes.appFolderURL)
    }

    private func open(_ location: LibraryLocation) async {
        Trace.mark("opening the library")
        let store = LibraryStore(location: location)
        do {
            let manifest = try await Trace.time("library: bootstrap") { try await store.bootstrap() }
            let notes = await Trace.time("notes: find the loose box") { await openNotes() }
            let model = LibraryModel(store: store, location: location, manifest: manifest, notes: notes)
            // The folders opened beside the first one, reopened from their own
            // bookmarks. One that will not resolve — an unplugged disk — is
            // left out rather than stopping the library; it comes back when
            // the disk does.
            //
            // All of them at once, and not one of them read yet: opening a
            // folder waits for the cloud to hand over its manifest, and three
            // folders waited one after another for that. Then each was added
            // with `addSource`, which reads the whole library — so a library
            // of three folders read itself three times before the window had
            // anything in it. It is taken in here and read once, below.
            let extras = isProbeLibrary ? [] : preference.loadExtras().filter { $0.url != location.url }
            if !extras.isEmpty {
                let opened = await Trace.time("library: open \(extras.count) more folder(s)") {
                    await withTaskGroup(of: (Int, LibraryStore).self) { group in
                        for (position, extra) in extras.enumerated() {
                            group.addTask {
                                let extraStore = LibraryStore(location: extra)
                                _ = try? await extraStore.bootstrap()
                                return (position, extraStore)
                            }
                        }
                        var stores = [LibraryStore?](repeating: nil, count: extras.count)
                        for await (position, extraStore) in group { stores[position] = extraStore }
                        return stores
                    }
                }
                // In the order they were remembered, whatever order they woke
                // up in: this is the order of the sidebar's library list.
                for (extra, extraStore) in zip(extras, opened) {
                    guard let extraStore else { continue }
                    model.attachSource(extra, store: extraStore)
                }
            }
            library = model
            phase = .ready
            await model.refresh()
            Trace.mark("library ready — \(model.papers.count) papers")
            #if os(macOS)
            // The passages by meaning, a few seconds after the window has
            // its list — never in the same instant. A probe that asked for
            // the index (`--papertime-semantic-index=1`) waits for it below.
            if !Boot.isSet("PAPERTIME_SEMANTIC_INDEX"), !Boot.isSet("PAPERTIME_SEMANTIC_QUERY") {
                SemanticIndex.shared.schedule(model.semanticSources)
            }
            #endif
            // `--papertime-import=<경로>`가 드롭·«PDF 더하기» 패널이 지나는 그
            // 길로 파일을 하나 들여온다. 라이브러리 폴더 안에 이미 있는 파일을
            // 이 길로 들이면 «남은 PDF» 목록이 낡은 채로 남고, 그 다음 줄을
            // 누르면 같은 파일에 기록이 둘 생겼다 — 손 없이 그 순서를 밟는
            // 유일한 길이다. `--papertime-adopt-loose`보다 먼저 온다.
            if let wanted = Boot.setting("PAPERTIME_IMPORT") {
                let url = wanted.hasPrefix("/")
                    ? URL(fileURLWithPath: wanted)
                    : model.location.url.appending(path: wanted)
                let (added, duplicates) = await model.importDocuments(at: [url])
                FileHandle.standardError.write(
                    Data("import: added=\(added) duplicates=\(duplicates)\n".utf8)
                )
            }
            // Driving a simulator: take in the folder's loose PDFs and open
            // the first paper, since nothing there can be tapped from here.
            if Boot.isSet("PAPERTIME_ADOPT_LOOSE") {
                _ = await model.adoptLooseDocuments()
                await model.refresh()
            }
            // `--papertime-add-folder=<path>` opens another folder beside the
            // first, the way the panel does — for checking a library of
            // several folders without a hand on the machine.
            if let extra = Boot.setting("PAPERTIME_ADD_FOLDER") {
                let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                    ?? URL(fileURLWithPath: "/")
                let url = extra.hasPrefix("/")
                    ? URL(fileURLWithPath: extra, isDirectory: true)
                    : base.appendingPathComponent(extra, isDirectory: true)
                await adoptExtraFolder(at: url)
            }
            // …and `--papertime-remove-folder=<path>` disconnects one, which
            // is the other half of the pair and the half that has to leave
            // the folder untouched.
            if let gone = Boot.setting("PAPERTIME_REMOVE_FOLDER") {
                let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                    ?? URL(fileURLWithPath: "/")
                let url = gone.hasPrefix("/")
                    ? URL(fileURLWithPath: gone, isDirectory: true)
                    : base.appendingPathComponent(gone, isDirectory: true)
                await disconnectFolder(at: url)
            }
            // `--papertime-notes-folder=<path>` chooses a folder for the notes
            // about no paper and carries them there, as the panel would — in a
            // probe only, and remembering nothing. The folder is made first,
            // the way the panel's New Folder would have made it.
            if isProbeLibrary, let wanted = Boot.setting("PAPERTIME_NOTES_FOLDER") {
                let url = Self.probeURL(wanted)
                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                // With `--papertime-open-note=<id>` that note is open in the
                // slip-box while its file moves, and `--papertime-notes-edit=<id>`
                // leaves an edit to a note waiting for the pause in typing —
                // the two things a move must not lose track of.
                if let id = Boot.setting("PAPERTIME_OPEN_NOTE") {
                    model.scope = .notes
                    model.notes.openNoteID = id
                    try? await Task.sleep(for: .seconds(1))
                }
                if let id = Boot.setting("PAPERTIME_NOTES_EDIT"), var note = model.notes.note(id) {
                    note.body += "\nEdited while waiting to be written."
                    model.notes.update(note)
                }
                await moveNotes(toFolderAt: url)
                let move = lastNotesMove
                var said = "notes folder: \(model.notes.looseBox.path(percentEncoded: false))"
                said += " moved=\(move?.moved ?? 0) kept=\(move?.kept ?? 0)"
                if let notice = notesNotice { said += " refused: \(notice)" }
                if let id = model.notes.openNoteID {
                    let shown = model.notes.note(id)
                    said += "\nnotes folder: open note \(id) still there=\(shown != nil) title=\(shown?.title ?? "—")"
                }
                FileHandle.standardError.write(Data((said + "\n").utf8))
            }
            // …and `--papertime-notes-back=1` is the way back.
            if isProbeLibrary, Boot.isSet("PAPERTIME_NOTES_BACK") {
                await keepNotesInAppFolder()
                let move = lastNotesMove
                FileHandle.standardError.write(Data((
                    "notes folder: back to \(model.notes.looseBox.path(percentEncoded: false))"
                        + " moved=\(move?.moved ?? 0) kept=\(move?.kept ?? 0)\n"
                ).utf8))
            }
            // The chosen folder going away while the app is open, and coming
            // back — the one way a note could have nowhere to go.
            // `--papertime-notes-unplug=1` renames the probe's chosen folder
            // out of the way, `--papertime-new-loose-note=<title>` writes a
            // note about no paper as the slip-box's ＋ would, and
            // `--papertime-notes-replug=1` puts the folder back and presses
            // Reconnect. Probe folders only.
            let unplugged = model.notes.looseBox.deletingLastPathComponent()
                .appending(path: model.notes.looseBox.lastPathComponent + "-unplugged", directoryHint: .isDirectory)
            let plugged = model.notes.looseBox
            if isProbeLibrary, Boot.isSet("PAPERTIME_NOTES_UNPLUG"), model.notes.looseBoxIsChosen {
                try? FileManager.default.moveItem(at: plugged, to: unplugged)
                FileHandle.standardError.write(Data("notes folder: unplugged \(plugged.path(percentEncoded: false))\n".utf8))
            }
            if isProbeLibrary, let title = Boot.setting("PAPERTIME_NEW_LOOSE_NOTE") {
                var note = model.notes.create(paperID: nil)
                note.title = title
                note.body = "Written by a probe."
                model.notes.update(note)
                await model.notes.flush(note)
                let wentTo = model.notes.chosenFolderWentAway ? "the app folder (chosen one away)" : model.notes.looseBox.lastPathComponent
                FileHandle.standardError.write(Data("new loose note: \(note.id) went to \(wentTo)\n".utf8))
            }
            // `--papertime-edit-loose-note=<id>` changes a note that is
            // already in the chosen folder, as typing into it would — with
            // the folder unplugged, the case where one note becomes two.
            if isProbeLibrary, let id = Boot.setting("PAPERTIME_EDIT_LOOSE_NOTE"), var note = model.notes.note(id) {
                note.body += "\nChanged by a probe."
                model.notes.update(note)
                await model.notes.flush(note)
                let wentTo = model.notes.chosenFolderWentAway ? "the app folder (chosen one away)" : model.notes.looseBox.lastPathComponent
                FileHandle.standardError.write(Data("edited loose note: \(id) went to \(wentTo)\n".utf8))
            }
            if isProbeLibrary, Boot.isSet("PAPERTIME_NOTES_REPLUG") {
                if FileManager.default.fileExists(atPath: unplugged.path(percentEncoded: false)) {
                    try? FileManager.default.moveItem(at: unplugged, to: plugged)
                } else if case let .away(hint) = notesFolder, let hint {
                    // Away since launch: the disk arriving is the folder
                    // appearing where it was.
                    try? FileManager.default.createDirectory(
                        at: URL(fileURLWithPath: hint, isDirectory: true), withIntermediateDirectories: true
                    )
                }
                await reconnectNotesFolder()
                let move = lastNotesMove
                var said = "notes folder: replugged, moved=\(move?.moved ?? 0) kept=\(move?.kept ?? 0)"
                if let notice = notesNotice { said += " notice: \(notice)" }
                FileHandle.standardError.write(Data((said + "\n").utf8))
            }
            // `--papertime-folders=1` says what each folder holds, which is
            // how a library of several folders is checked from here.
            if Boot.isSet("PAPERTIME_FOLDERS") {
                let place: String = switch notesFolder {
                case .app: "app folder"
                case .chosen: "chosen"
                case let .away(hint): "chosen one away (\(hint ?? "?")), using the app folder"
                }
                var said = "loose notes: \(place)"
                if let move = lastNotesMove {
                    said += " — last move \(move.occasion) moved=\(move.moved) kept=\(move.kept)"
                        + " kept in \(move.keptIn.path(percentEncoded: false))"
                }
                FileHandle.standardError.write(Data((said + "\n").utf8))
                await model.reportFolders()
            }
            if Boot.isSet("PAPERTIME_OPEN_FIRST"), let first = model.visiblePapers.first {
                model.selection = [first.id]
            }
            // A particular paper rather than whichever is first: the pictures
            // on the landing page want the one with marks on it.
            if let wanted = Boot.setting("PAPERTIME_OPEN_TITLE"),
               let paper = model.visiblePapers.first(where: {
                   $0.meta.displayTitle.localizedCaseInsensitiveContains(wanted)
               }) {
                model.selection = [paper.id]
            }
            // `--papertime-rename=<name>` renames the chosen paper's file,
            // which is worth doing from here because the risky case is a
            // rename while the reader has the file open.
            if let name = Boot.setting("PAPERTIME_RENAME"),
               let paper = model.selectedPaper ?? model.visiblePapers.first {
                // A moment first, so the reader has the file open: that is
                // the case worth checking, and the session is made by the
                // view rather than here.
                try? await Task.sleep(for: .seconds(2))
                do {
                    try await model.rename(paperID: paper.id, to: name)
                    let now = model.paper(paper.id)?.documentURL.lastPathComponent ?? "?"
                    let told = DocumentSession.open(forPaper: paper.id)
                    let says = told.map { $0.paper.documentURL.lastPathComponent }.joined(separator: ",")
                    FileHandle.standardError.write(
                        Data("rename: \(now) — sessions told: \(told.count) [\(says)]\n".utf8)
                    )
                } catch {
                    FileHandle.standardError.write(Data("rename refused: \(error)\n".utf8))
                }
            }
            // `--papertime-kind=<paper|book|document>` answers "what is this?"
            // for the chosen paper and says what the shelves now hold — the
            // one way to see a kind change without a hand on the machine.
            if let raw = Boot.setting("PAPERTIME_KIND"),
               let kind = DocumentKind(rawValue: raw),
               let paper = model.selectedPaper ?? model.visiblePapers.first {
                await model.setKind(kind, for: paper.id)
                let now = model.paper(paper.id)?.meta
                let counts = model.counts
                FileHandle.standardError.write(Data("""
                kind: \(now?.effectiveKind.rawValue ?? "?")                 csl=\(now?.csl.type.rawValue ?? "?")                 venue=\(now?.csl.containerTitle ?? "—")                 volume=\(now?.csl.volume ?? "—")                 shelves: papers=\(counts.papers) books=\(counts.books) documents=\(counts.documents)                 review=\(counts.needsReview)

                """.utf8))
            }
            switch Boot.setting("PAPERTIME_SCOPE") {
            case "notes": model.scope = .notes
            case "papers": model.scope = .papers
            case "books": model.scope = .books
            case "lectures": model.scope = .lectures
            case "documents": model.scope = .documents
            default: break
            }
            // A folder inside the library, by its path under the root:
            // `--papertime-scope=folder:2026-2학기/week 1`. The tree only
            // exists once you are inside one, and a synthetic click cannot
            // get you there — SwiftUI's rows are not reachable that way, and
            // keys sent at the window land in whatever is in front.
            if let inside = Boot.setting("PAPERTIME_SCOPE")?.stripPrefix("folder:") {
                model.scope = .folder(model.location.url.appending(path: inside, directoryHint: .isDirectory))
            }
            // The results of a search, without anybody having to type one.
            if let query = Boot.setting("PAPERTIME_SEARCH_RESULTS") {
                model.showSearchResults(for: query)
            }
            // `--papertime-attach=<말>` opens the attach picker on the chosen
            // paper and says what it would offer for that query. The list it
            // shows cannot be reached by a synthetic click, and the answer —
            // which papers, in which order — is the whole of what there is to
            // check.
            if let query = Boot.setting("PAPERTIME_ATTACH"),
               let child = model.selectedPaper ?? model.visiblePapers.first {
                let shelf = model.attachmentCandidates(for: child.id).map {
                    AttachmentSearch.Candidate(
                        id: $0.id,
                        title: $0.meta.displayTitle,
                        fileName: $0.meta.file.originalName
                    )
                }
                let me = AttachmentSearch.Candidate(
                    id: child.id,
                    title: child.meta.csl.fullTitle ?? "",
                    fileName: child.meta.file.originalName
                )
                let suggested = AttachmentSearch.suggestion(for: me, among: shelf)
                let found = AttachmentSearch.ranked(shelf, matching: query)
                var said = "attach: \(child.meta.displayTitle) — \(shelf.count) candidates"
                said += ", query \"\(query)\" → \(found.count)\n"
                if let suggested, let paper = model.paper(suggested) {
                    said += "attach: suggested \(paper.meta.displayTitle)\n"
                } else {
                    said += "attach: nothing suggested\n"
                }
                for (rank, candidate) in found.prefix(10).enumerated() {
                    said += "attach: \(rank + 1). \(candidate.title)  [\(candidate.fileName)]\n"
                }
                FileHandle.standardError.write(Data(said.utf8))
                attaching.child = child
                // `--papertime-attach-close=<초>`가 그 뒤에 시트를 닫는다. 취소와
                // Escape와 «붙이기»가 전부 같은 곳을 부르므로, 이 하나가 셋을 다
                // 확인한다 — 한때 그 셋이 모두 아무 일도 하지 않았고, 사용자는
                // 닫을 수 없는 창을 받았다.
                if let after = Double(Boot.setting("PAPERTIME_ATTACH_CLOSE") ?? "") {
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(after))
                        guard let self else { return }
                        let sheets = NSApp.windows.compactMap(\.attachedSheet).count
                        attaching.child = nil
                        try? await Task.sleep(for: .seconds(1.5))
                        let left = NSApp.windows.compactMap(\.attachedSheet).count
                        FileHandle.standardError.write(
                            Data("attach: sheets \(sheets) → \(left) after closing\n".utf8)
                        )
                    }
                }
            }
            if let noteID = Boot.setting("PAPERTIME_OPEN_NOTE") { model.notes.openNoteID = noteID }
            // `--papertime-search-bench=1` times Search Everything and writes
            // down every answer it gives, then quits — see `SearchBench`.
            #if os(macOS)
            if isProbeLibrary, let spec = Boot.setting("PAPERTIME_SEARCH_BENCH") {
                await SearchBench.run(in: model, spec: spec)
                Trace.summary()
                NSApp.terminate(nil)
            }
            // `--papertime-semantic-index=1` builds the passages-by-meaning
            // index for this library now and says what it did;
            // `--papertime-semantic-query=<text>` then prints the passages
            // closest to the text. Without `PAPERTIME_SHOW_SEARCH` the run
            // quits afterwards, so the trace can add up.
            if isProbeLibrary, Boot.isSet("PAPERTIME_SEMANTIC_INDEX") || Boot.isSet("PAPERTIME_SEMANTIC_QUERY") {
                await SemanticIndexProbe.run(in: model)
            }
            // `--papertime-quit-after=<초>` ends a probe's run on its own, the
            // way a person quits, so the trace adds up what the time went on.
            // Killed from outside, it never gets to say.
            if isProbeLibrary, let after = Double(Boot.setting("PAPERTIME_QUIT_AFTER") ?? "") {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(after))
                    Trace.summary()
                    NSApp.terminate(nil)
                }
            }
            #endif
            if Boot.isSet("PAPERTIME_SHOW_SEARCH") {
                try? await Task.sleep(for: .seconds(2))
                showsSearchPalette = true
            }
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
    /// Latex Suite's snippets in the note and in text cards: `//` into a
    /// fraction, Tab to the next placeholder. On unless turned off; the text
    /// views read the same key (`LatexSuiteTyping.isEnabled`).
    @ObservationIgnored
    @AppStorage(AppSettings.latexShortcutsKey) public var latexShortcuts = true
    public static let latexShortcutsKey = "latexShortcuts"
    /// Passages found by what they mean, under the exact matches in Search
    /// Everything. On unless turned off: it is a 45 MB model running in the
    /// background, and not everybody wants one. `SemanticIndex` reads the
    /// same key.
    @ObservationIgnored
    @AppStorage(AppSettings.searchByMeaningKey) public var searchByMeaning = true
    public static let searchByMeaningKey = "searchByMeaning"
    /// How wide the paper list is, remembered so hiding and showing it gives
    /// back the column you had rather than a default.

    public init() {}
}


/// Where a paper is put when it is dragged to the page area's edge: a half,
/// or a quarter.
public enum DockZone: Equatable, Sendable {
    case left, right, topLeft, topRight, bottomLeft, bottomRight
}

/// Up to four papers in the page area: a left column and, when there is
/// one, a right column, each of one or two panes.
public struct SplitArrangement: Equatable, Sendable {
    public struct Column: Equatable, Sendable {
        public var top: UUID
        public var bottom: UUID?
        public init(top: UUID, bottom: UUID? = nil) {
            self.top = top
            self.bottom = bottom
        }
        var papers: [UUID] { [top] + (bottom.map { [$0] } ?? []) }
    }

    public var left: Column
    public var right: Column?

    public init(left: Column, right: Column? = nil) {
        self.left = left
        self.right = right
    }

    /// Every paper in the arrangement, left column first, top before bottom.
    public var papers: [UUID] { left.papers + (right?.papers ?? []) }

    public func contains(_ id: UUID) -> Bool { papers.contains(id) }

    /// Takes a paper out, closing up the space it leaves.
    public mutating func remove(_ id: UUID) {
        var columns = [left, right].compactMap { $0 }.compactMap { column -> Column? in
            let kept = column.papers.filter { $0 != id }
            guard let first = kept.first else { return nil }
            return Column(top: first, bottom: kept.count > 1 ? kept[1] : nil)
        }
        if columns.isEmpty { return }
        left = columns.removeFirst()
        right = columns.first
    }

    /// Puts a paper into a zone. What was there slides to the other half of
    /// its column; what there is no room for leaves the arrangement (and
    /// stays open in the list).
    public mutating func dock(_ id: UUID, at zone: DockZone) {
        let leftIDs = left.papers.filter { $0 != id }
        let rightIDs = right?.papers.filter { $0 != id } ?? []
        let others = leftIDs + rightIDs
        func column(_ ids: [UUID]) -> Column? {
            guard let first = ids.first else { return nil }
            return Column(top: first, bottom: ids.count > 1 ? ids[1] : nil)
        }
        switch zone {
        case .left:
            left = Column(top: id)
            right = column(Array(others.prefix(2)))
        case .right:
            if let rest = column(Array(others.prefix(2))) {
                left = rest
                right = Column(top: id)
            } else {
                left = Column(top: id)
                right = nil
            }
        case .topLeft, .bottomLeft:
            let top = zone == .topLeft
            let kept = Array(leftIDs.prefix(1))
            let spill = Array(leftIDs.dropFirst(1))
            left = column(top ? [id] + kept : kept + [id])!
            right = column(Array((rightIDs + spill).prefix(2)))
        case .topRight, .bottomRight:
            let top = zone == .topRight
            let kept = Array(rightIDs.prefix(1))
            let spill = Array(rightIDs.dropFirst(1))
            let placed = column(top ? [id] + kept : kept + [id])!
            if let rest = column(Array((leftIDs + spill).prefix(2))) {
                left = rest
                right = placed
            } else {
                left = placed
                right = nil
            }
        }
    }
}
