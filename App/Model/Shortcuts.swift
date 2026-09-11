import SwiftUI

/// A key and the modifiers held with it.
///
/// Kept as a value rather than reached for through `keyboardShortcut`
/// directly, because a reader can change these and both the menu and the
/// settings sheet have to be able to show what they chose.
public struct Shortcut: Equatable, Sendable {
    /// Most shortcuts are a character. A few are a key that has no character.
    public enum Key: Equatable, Sendable {
        case character(Character)
        case up, down, left, right

        var equivalent: KeyEquivalent {
            switch self {
            case .character(let character): KeyEquivalent(character)
            case .up: .upArrow
            case .down: .downArrow
            case .left: .leftArrow
            case .right: .rightArrow
            }
        }

        var display: String {
            switch self {
            case .character(let character): String(character).uppercased()
            case .up: "↑"
            case .down: "↓"
            case .left: "←"
            case .right: "→"
            }
        }

        var stored: String {
            switch self {
            case .character(let character): String(character)
            case .up: "«up»"
            case .down: "«down»"
            case .left: "«left»"
            case .right: "«right»"
            }
        }

        init?(stored: String) {
            switch stored {
            case "«up»": self = .up
            case "«down»": self = .down
            case "«left»": self = .left
            case "«right»": self = .right
            default:
                guard stored.count == 1, let character = stored.first else { return nil }
                self = .character(character)
            }
        }
    }

    public var key: Key
    public var modifiers: SwiftUI.EventModifiers

    public init(_ key: Key, _ modifiers: SwiftUI.EventModifiers = .command) {
        self.key = key
        self.modifiers = modifiers
    }

    public init(_ character: Character, _ modifiers: SwiftUI.EventModifiers = .command) {
        self.init(.character(character), modifiers)
    }

    public var keyboardShortcut: KeyboardShortcut {
        KeyboardShortcut(key.equivalent, modifiers: modifiers)
    }

    /// The shortcut as a Mac writes it: ⌃⌥⇧⌘ in that order, then the key.
    public var display: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + key.display
    }

    // MARK: - Keeping it

    public var stored: String {
        var parts: [String] = []
        if modifiers.contains(.command) { parts.append("cmd") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.option) { parts.append("opt") }
        if modifiers.contains(.control) { parts.append("ctrl") }
        parts.append(key.stored)
        return parts.joined(separator: "+")
    }

    public init?(stored: String) {
        var modifiers = SwiftUI.EventModifiers()
        var key: Key?
        for part in stored.split(separator: "+") {
            switch part {
            case "cmd": modifiers.insert(.command)
            case "shift": modifiers.insert(.shift)
            case "opt": modifiers.insert(.option)
            case "ctrl": modifiers.insert(.control)
            default: key = Key(stored: String(part))
            }
        }
        guard let key else { return nil }
        self.init(key, modifiers)
    }
}

/// Everything the app can be told to do from the keyboard.
///
/// One list, so the settings sheet can show every shortcut the app has rather
/// than the handful someone remembered to add, and so no two can quietly end
/// up on the same key.
public enum ShortcutAction: String, CaseIterable, Identifiable, Sendable {
    // Library
    case addPapers, exportBibTeX, copyCitationKey, resolveMetadata, refreshFolder
    // Reading
    case searchEverything, findInDocument, ultracopy, linkToNote
    case layoutContinuous, layoutSinglePage, layoutBook
    // Marking
    case highlight, underline, newNote
    // Panes
    case sidebar, paperList, reader, inspector, focus, floatingList
    // Moving about
    case zoomIn, zoomOut, actualSize
    case nextPage, previousPage, nextPaper, previousPaper, back, forward
    // The app itself
    case settings

    public var id: String { rawValue }

    public enum Group: String, CaseIterable, Identifiable, Sendable {
        case library = "Library"
        case reading = "Reading"
        case marking = "Marking"
        case panes = "Window"
        case moving = "Navigation"
        case app = "Application"

        public var id: String { rawValue }
    }

    public var group: Group {
        switch self {
        case .addPapers, .exportBibTeX, .copyCitationKey, .resolveMetadata, .refreshFolder:
            .library
        case .searchEverything, .findInDocument, .ultracopy, .linkToNote,
             .layoutContinuous, .layoutSinglePage, .layoutBook:
            .reading
        case .highlight, .underline, .newNote:
            .marking
        case .sidebar, .paperList, .reader, .inspector, .focus, .floatingList:
            .panes
        case .zoomIn, .zoomOut, .actualSize, .nextPage, .previousPage,
             .nextPaper, .previousPaper, .back, .forward:
            .moving
        case .settings:
            .app
        }
    }

    public var title: String {
        switch self {
        case .addPapers: "Add Papers"
        case .exportBibTeX: "Export BibTeX"
        case .copyCitationKey: "Copy Citation Key"
        case .resolveMetadata: "Resolve Missing Metadata"
        case .refreshFolder: "Refresh from Folder"
        case .searchEverything: "Search Everything"
        case .findInDocument: "Find in Document"
        case .ultracopy: "Ultracopy"
        case .linkToNote: "Link Selection to Note"
        case .layoutContinuous: "Continuous Layout"
        case .layoutSinglePage: "Single Page Layout"
        case .layoutBook: "Book Layout"
        case .highlight: "Highlight Selection"
        case .underline: "Underline Selection"
        case .newNote: "New Note"
        case .sidebar: "Sidebar"
        case .paperList: "Paper List"
        case .reader: "Paper"
        case .inspector: "Inspector"
        case .focus: "Focus on the Paper"
        case .floatingList: "Table of Contents"
        case .zoomIn: "Zoom In"
        case .zoomOut: "Zoom Out"
        case .actualSize: "Actual Size"
        case .nextPage: "Next Page"
        case .previousPage: "Previous Page"
        case .nextPaper: "Next Paper"
        case .previousPaper: "Previous Paper"
        case .back: "Back"
        case .forward: "Forward"
        case .settings: "Settings"
        }
    }

    /// Whether the system owns this one.
    ///
    /// SwiftUI's `Settings` scene puts its own item in the app menu and keeps
    /// ⌘, for it. Adding a second one only got the app two Settings items, so
    /// this is listed to say where the key went, and left alone.
    public var isFixed: Bool { self == .settings }

    /// What it is when nobody has said otherwise.
    public var fallback: Shortcut {
        switch self {
        case .addPapers: Shortcut("o")
        case .exportBibTeX: Shortcut("e", [.command, .shift])
        case .copyCitationKey: Shortcut("k", [.command, .shift])
        case .resolveMetadata: Shortcut("r", [.command, .shift])
        case .refreshFolder: Shortcut("r")
        case .searchEverything: Shortcut("k")
        case .findInDocument: Shortcut("f")
        case .ultracopy: Shortcut("c", [.command, .shift])
        case .linkToNote: Shortcut("l")
        case .layoutContinuous: Shortcut("1")
        case .layoutSinglePage: Shortcut("2")
        case .layoutBook: Shortcut("3")
        case .highlight: Shortcut("h", [.command, .shift])
        case .underline: Shortcut("u", [.command, .shift])
        case .newNote: Shortcut("n")
        case .sidebar: Shortcut("[")
        case .paperList: Shortcut("p")
        case .reader: Shortcut("\\")
        case .inspector: Shortcut("]")
        // Not ⌃⌘F, which is the system's own key for full screen: pressed
        // in this app it went to the window and never reached the command,
        // which is what made Focus look broken.
        case .focus: Shortcut("f", [.command, .shift])
        case .floatingList: Shortcut("l", [.command, .option])
        case .zoomIn: Shortcut("+")
        case .zoomOut: Shortcut("-")
        case .actualSize: Shortcut("0")
        case .nextPage: Shortcut(.down, .command)
        case .previousPage: Shortcut(.up, .command)
        case .nextPaper: Shortcut(.down, [.command, .option])
        case .previousPaper: Shortcut(.up, [.command, .option])
        case .back: Shortcut("[", [.command, .option])
        case .forward: Shortcut("]", [.command, .option])
        case .settings: Shortcut(",")
        }
    }
}
