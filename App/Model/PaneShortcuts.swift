import SwiftUI

/// A key and the modifiers held with it.
///
/// Kept as a value rather than reached for through `keyboardShortcut` directly,
/// because a reader can change these and the menu has to be able to show what
/// they chose.
public struct Shortcut: Equatable, Sendable {
    public var key: Character
    public var modifiers: EventModifiers

    public init(_ key: Character, _ modifiers: EventModifiers = .command) {
        self.key = key
        self.modifiers = modifiers
    }

    public var keyEquivalent: KeyEquivalent { KeyEquivalent(key) }

    /// The shortcut as a Mac writes it: ⌃⌥⇧⌘ in that order, then the key.
    public var display: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + String(key).uppercased()
    }

    // MARK: - Keeping it

    public var stored: String {
        var parts: [String] = []
        if modifiers.contains(.command) { parts.append("cmd") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.option) { parts.append("opt") }
        if modifiers.contains(.control) { parts.append("ctrl") }
        parts.append(String(key))
        return parts.joined(separator: "+")
    }

    public init?(stored: String) {
        var modifiers = EventModifiers()
        var key: Character?
        for part in stored.split(separator: "+") {
            switch part {
            case "cmd": modifiers.insert(.command)
            case "shift": modifiers.insert(.shift)
            case "opt": modifiers.insert(.option)
            case "ctrl": modifiers.insert(.control)
            default:
                guard part.count == 1, let first = part.first else { return nil }
                key = first
            }
        }
        guard let key else { return nil }
        self.init(key, modifiers)
    }
}

/// The shortcuts that open and close the parts of the window.
///
/// These are the ones worth letting a reader change: which pane a key opens is
/// a matter of habit, and habits come from whatever they used before this.
public enum PaneShortcut: String, CaseIterable, Identifiable, Sendable {
    case sidebar
    case paperList
    case reader
    case inspector
    case focus

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .sidebar: "Sidebar"
        case .paperList: "Paper List"
        case .reader: "Paper"
        case .inspector: "Inspector"
        case .focus: "Focus on the Paper"
        }
    }

    /// What it is when nobody has said otherwise.
    public var fallback: Shortcut {
        switch self {
        case .sidebar: Shortcut("[")
        case .paperList: Shortcut("p")
        case .reader: Shortcut("\\")
        case .inspector: Shortcut("]")
        case .focus: Shortcut("f", [.command, .control])
        }
    }
}
