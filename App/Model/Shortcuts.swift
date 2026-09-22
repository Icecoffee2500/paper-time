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
    case highlight, underline, newNote, draw
    // Panes
    case sidebar, paperList, reader, inspector, focus, floatingList, openPapers
    // Moving about
    case zoomIn, zoomOut, actualSize
    case nextPage, previousPage, nextPaper, previousPaper, back, forward
    // The app itself
    case settings
    case feedback

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
        case .highlight, .underline, .newNote, .draw:
            .marking
        case .sidebar, .paperList, .reader, .inspector, .focus, .floatingList, .openPapers:
            .panes
        case .zoomIn, .zoomOut, .actualSize, .nextPage, .previousPage,
             .nextPaper, .previousPaper, .back, .forward:
            .moving
        case .settings:
            .app
        case .feedback:
            .app
        }
    }

    public var title: String {
        switch self {
        case .addPapers: L("논문 더하기", "Add Papers")
        case .exportBibTeX: L("BibTeX 내보내기", "Export BibTeX")
        case .copyCitationKey: L("인용 키 복사", "Copy Citation Key")
        case .resolveMetadata: L("빠진 서지 채우기", "Resolve Missing Metadata")
        case .refreshFolder: L("지금 맞추기", "Sync Now")
        case .searchEverything: L("전부 찾기", "Search Everything")
        case .findInDocument: L("이 논문에서 찾기", "Find in Document")
        case .ultracopy: "Ultracopy"
        case .linkToNote: L("고른 곳을 노트로", "Link Selection to Note")
        case .layoutContinuous: L("이어서 보기", "Continuous Layout")
        case .layoutSinglePage: L("한 쪽씩 보기", "Single Page Layout")
        case .layoutBook: L("책처럼 보기", "Book Layout")
        case .highlight: L("고른 곳에 형광펜", "Highlight Selection")
        case .underline: L("고른 곳에 밑줄", "Underline Selection")
        case .newNote: L("새 노트", "New Note")
        case .draw: L("쪽에 그리기", "Draw on the Page")
        case .sidebar: L("옆 목록", "Sidebar")
        case .paperList: L("논문 목록", "Paper List")
        case .reader: L("논문", "Paper")
        case .inspector: L("정보 패널", "Inspector")
        case .focus: L("논문에 집중", "Focus on the Paper")
        case .floatingList: L("차례", "Table of Contents")
        case .openPapers: L("열린 문서", "Open Documents")
        case .zoomIn: L("크게", "Zoom In")
        case .zoomOut: L("작게", "Zoom Out")
        case .actualSize: L("실제 크기", "Actual Size")
        case .nextPage: L("다음 쪽", "Next Page")
        case .previousPage: L("이전 쪽", "Previous Page")
        case .nextPaper: L("다음 논문", "Next Paper")
        case .previousPaper: L("이전 논문", "Previous Paper")
        case .back: L("뒤로", "Back")
        case .forward: L("앞으로", "Forward")
        case .settings: L("설정", "Settings")
        case .feedback: L("한마디 보내기", "Send Feedback")
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
        case .draw: Shortcut("d", [.command, .shift])
        case .sidebar: Shortcut("[")
        case .paperList: Shortcut("p")
        case .reader: Shortcut("\\")
        case .inspector: Shortcut("]")
        // Not ⌃⌘F, which is the system's own key for full screen: pressed
        // in this app it went to the window and never reached the command,
        // which is what made Focus look broken.
        case .focus: Shortcut("f", [.command, .shift])
        case .floatingList: Shortcut("l", [.command, .shift])
        case .openPapers: Shortcut("o", [.command, .shift])
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
        case .feedback: Shortcut("/", [.command, .option])
        }
    }
}
