import Foundation

/// The text engine of Latex Suite (Obsidian, by artisticat1), with its default
/// snippets and settings, for the note editors on both builds.
///
/// Latex Suite is why people can take math notes at the speed they write:
/// `@a` becomes `\alpha`, `x/` becomes `\frac{x}{}` with the caret in the
/// denominator, Tab walks through placeholders and out of the equation. What
/// makes it feel right is a thousand small decisions — which snippet wins,
/// where the caret lands, when a key is left alone — so this reproduces the
/// plugin's 1.13.1 behaviour exactly rather than approximately, down to the
/// quirks its users have learned (`dm` after a word, `\xii` never firing).
/// The fixtures it is tested against were produced by running the plugin's
/// own code, not by reading it.
///
/// It is pure: text in, edit out, Foundation only — no editor, no view. The
/// Mac note editor and the Portable one each adapt their own text view to it,
/// and the snippet data (`LatexSuiteSnippets.json`) is the same file in both.
///
/// **When to call it.** Before the editor acts on a key, exactly like Latex
/// Suite's `keydown` handler: the typed character is *not* yet in `text`. If
/// the result is nil, let the editor do what it normally does (insert the
/// character, indent, break the line, delete) and then move the tabstops with
/// `Tabstops.afterEdit(_:selection:)`. If there is an `Edit`, apply it instead
/// and do not insert the key. Call it only for plain keystrokes — not while an
/// input method is composing, not with Command or Control held (Option-made
/// characters are fine) — because Latex Suite does not run then either.
///
/// **The selection.** Ranges in any order; they are sorted and merged, and
/// the first one after that is the main one — the caret whose place decides
/// the mode for all of them, as in the plugin. A range's end stands for the
/// caret (its head): the engine has no direction for a selection.
///
/// **Tabstops.** Keep the `Edit.tabstops` the engine returns and pass them
/// back with the next key. Whenever the text or selection changes any other
/// way — the editor's own typing, a click, an arrow key, a paste — run them
/// through `afterEdit` (or `selecting` for a selection change alone), which
/// is what Latex Suite does on every transaction: that is how a placeholder
/// grows as it is typed into, and how leaving every placeholder ends the
/// snippet. Undo drops them (`Tabstops.none`).
///
/// Where the engine does not follow the plugin — one case on purpose, and
/// some half-typed LaTeX whose reading comes from lezer's error recovery —
/// the tests and the fixtures' headers say so.
public enum LatexSuite {
    /// One keystroke, and what Latex Suite may do with it.
    public enum Input: Equatable, Sendable {
        /// The characters one keypress produces: automatic snippets; with a
        /// selection, the visual ones (`U O B C K S ( [ {`); `/` makes a
        /// fraction; `)` `]` `}` step over the same character. Only a single
        /// UTF-16 code unit counts; anything longer (an emoji, a paste) is the
        /// editor's.
        case text(String)
        /// Tab-triggered snippets, then the next tabstop, then the matrix
        /// shortcuts (past a closing bracket, or ` & `), then out of the
        /// equation.
        case tab
        /// The previous tabstop.
        case shiftTab
        /// A new matrix row, inside a matrix environment.
        case enter
        /// Out of the matrix row or environment.
        case shiftEnter
        /// Both dollars of an empty `$$` at once.
        case backspace
    }

    /// One replacement: `range` (UTF-16) in the document it applies to becomes `text`.
    public struct Change: Equatable, Sendable {
        public var range: NSRange
        public var text: String

        public init(range: NSRange, text: String) {
            self.range = range
            self.text = text
        }
    }

    /// The placeholders of the snippets being filled in.
    ///
    /// A snippet's tabstops form **groups** visited in order; `$0` is the
    /// *first* stop (not the last, as in VS Code). Ranges of one group mirror
    /// each other and are selected together. `index` is the group the caret is
    /// in. Reaching the last group — or leaving every group — ends the snippet,
    /// and then there are no groups at all. A snippet expanded inside a group
    /// replaces that group with its own groups, so Tab continues with the outer
    /// snippet afterwards.
    public struct Tabstops: Equatable, Sendable {
        public struct Group: Equatable, Sendable {
            /// In document order; a range may be empty (a caret position).
            public var ranges: [NSRange]
            /// 0, 1 or 2, cycling per expansion: Latex Suite's
            /// `latex-suite-snippet-placeholder-N` class. Styling only.
            public var color: Int

            public init(ranges: [NSRange], color: Int = 0) {
                self.ranges = ranges
                self.color = color
            }
        }

        public var groups: [Group]
        public var index: Int
        /// The next expansion's colour (styling only).
        public var nextColor: Int

        public static let none = Tabstops(groups: [], index: 0, nextColor: 0)

        public init(groups: [Group], index: Int, nextColor: Int = 0) {
            self.groups = groups
            self.index = index
            self.nextColor = nextColor
        }

        public var isActive: Bool { !groups.isEmpty }
        public var current: Group? { groups.indices.contains(index) ? groups[index] : nil }

        /// Every range moved through an edit — the editor's own typing inside
        /// a placeholder, or anything else. Ranges grow at both ends (text typed
        /// at a placeholder's edge becomes part of it); an empty tabstop inside
        /// text that was replaced disappears. `changes` are simultaneous and
        /// refer to the document before them.
        public func mapped(through changes: [Change]) -> Tabstops {
            var state = LSTabstopState(self)
            state.map(LSChangeSet(changes.map(\.internal)))
            return state.public
        }

        /// What Latex Suite does whenever the selection is set: the current
        /// group becomes the first one containing the whole selection, and if
        /// that is the last group, or none, the snippet is over.
        public func selecting(_ selection: [NSRange]) -> Tabstops {
            var state = LSTabstopState(self)
            state.select(selection.map(\.lsRange))
            return state.public
        }

        /// Both, for an edit the editor made itself: `changes` against the old
        /// document, then `selection` in the new one.
        public func afterEdit(_ changes: [Change], selection: [NSRange]) -> Tabstops {
            mapped(through: changes).selecting(selection)
        }
    }

    /// What to do instead of the editor's own handling of the key.
    public struct Edit: Equatable, Sendable {
        /// The whole edit, all against the document you passed in: sorted,
        /// not overlapping. Apply them together (right to left).
        public var changes: [Change]
        /// The same edit as Latex Suite's undo history records it: apply each
        /// step's changes (against the document the previous step left) as
        /// its own undo group. When a snippet expands on a typed key, the key
        /// itself is the first step — one Undo then brings back the trigger as
        /// typed (`@a`), a second removes the key.
        public var undoSteps: [[Change]]
        /// The selection afterwards, in document order; several ranges are
        /// mirrored placeholders selected together (the first is the main one).
        public var selection: [NSRange]
        public var tabstops: Tabstops
    }

    /// The settings Latex Suite has, at its defaults, plus the two the host
    /// editor owns.
    public struct Settings: Equatable, Sendable {
        public var snippetsEnabled: Bool
        public var removeSnippetWhitespace: Bool
        public var autoDeleteDollar: Bool
        public var autofractionEnabled: Bool
        public var autofractionSymbol: String
        public var autofractionBreakingChars: String
        /// Pairs of `[open, close]` inside which `/` makes no fraction.
        public var autofractionExcludedEnvironments: [[String]]
        public var matrixShortcutsEnabled: Bool
        public var matrixShortcutsEnvironments: [String]
        public var matrixShortcutsMacros: [String]
        public var taboutEnabled: Bool
        public var taboutExitEquationOnlyOnEOL: Bool
        public var taboutClosingSymbols: [String]
        public var autoEnlargeBrackets: Bool
        public var autoEnlargeBracketsSpace: Bool
        public var autoEnlargeBracketsTriggers: [String]
        public var wordDelimiters: String
        public var forceMathLanguages: [String]
        /// The editor's tab width in columns, for the indentation snippets keep.
        public var tabSize: Int
        /// The editor's indentation unit: spaces, or a tab.
        public var indentUnit: String

        /// Latex Suite's defaults (from the bundled file), with the tab width
        /// and indentation the fixtures were made with.
        public static var `default`: Settings { Settings(LSLibrary.shared.settings) }

        init(_ s: LSData.Settings) {
            snippetsEnabled = s.snippetsEnabled
            removeSnippetWhitespace = s.removeSnippetWhitespace
            autoDeleteDollar = s.autoDeleteDollar
            autofractionEnabled = s.autofractionEnabled
            autofractionSymbol = s.autofractionSymbol
            autofractionBreakingChars = s.autofractionBreakingChars
            autofractionExcludedEnvironments = s.autofractionExcludedEnvs
            matrixShortcutsEnabled = s.matrixShortcutsEnabled
            matrixShortcutsEnvironments = s.matrixShortcutsEnvNames
            matrixShortcutsMacros = s.matrixShortcutsMacroNames
            taboutEnabled = s.taboutEnabled
            taboutExitEquationOnlyOnEOL = s.taboutExitEquationOnlyOnEOL
            taboutClosingSymbols = s.taboutClosingSymbols
            autoEnlargeBrackets = s.autoEnlargeBrackets
            autoEnlargeBracketsSpace = s.autoEnlargeBracketsSpace
            autoEnlargeBracketsTriggers = s.autoEnlargeBracketsTriggers
            wordDelimiters = s.wordDelimiters
            forceMathLanguages = s.forceMathLanguages
            tabSize = 4
            indentUnit = "  "
        }
    }

    /// The credit line the licence asks for, for an About screen.
    public static var credit: String { LSLibrary.shared.header.credit }
    /// Latex Suite's MIT licence, verbatim.
    public static var licence: String { LSLibrary.shared.header.licenceText }
    /// The Latex Suite release the defaults and behaviour come from.
    public static var version: String { LSLibrary.shared.header.version }
    /// How many default snippets the bundled file holds (199 for 1.13.1).
    /// Reading it loads the file, so it is also the quickest proof that the
    /// resource made it into a build.
    public static var snippetCount: Int { LSLibrary.shared.snippets.count }

    /// Reacts to keystrokes. Holds no document state: pass the text, the
    /// selection and the tabstops every time.
    public struct Engine: Sendable {
        public var settings: Settings
        let library: LSLibrary

        public init(settings: Settings = .default) {
            self.settings = settings
            library = LSLibrary.shared
        }

        /// Latex Suite's answer to `input` typed into `text` with `selection`
        /// (UTF-16 ranges; one range is the usual caret or selection) and the
        /// active `tabstops`. Nil means the key is not Latex Suite's: let the
        /// editor handle it.
        public func handle(_ input: Input, text: String, selection: [NSRange], tabstops: Tabstops = .none) -> Edit? {
            let doc = LS.bulkUnits(text)
            let ranges = lsNormalizedSelection(selection.map { $0.lsRange.clamped(to: 0..<doc.count) })
            guard !ranges.isEmpty else { return nil }
            // Placeholders kept from an older text may reach past this one;
            // an editor must never be handed a range outside its text.
            var state = LSTabstopState(tabstops)
            state.clamp(to: doc.count)
            let run = LSRun(doc: doc, selection: ranges, tabstops: state, settings: settings, library: library)
            guard run.handle(input) else { return nil }
            return run.edit()
        }
    }
}

extension LatexSuite.Change {
    var `internal`: LSChange {
        let r = range.lsRange
        return LSChange(from: r.lowerBound, to: r.upperBound, insert: LS.units(text))
    }
}

// MARK: - Tabstop state (tabstops_state_field.ts)

struct LSTabstopState {
    var groups: [[Range<Int>]]
    var colors: [Int]
    var index: Int
    var nextColor: Int

    init(_ t: LatexSuite.Tabstops) {
        groups = t.groups.map { $0.ranges.map(\.lsRange) }
        colors = t.groups.map(\.color)
        index = t.index
        nextColor = t.nextColor
    }

    var `public`: LatexSuite.Tabstops {
        LatexSuite.Tabstops(groups: zip(groups, colors).map { ranges, color in
            LatexSuite.Tabstops.Group(ranges: ranges.map { NSRange(ls: $0.lowerBound, $0.upperBound) }, color: color)
        }, index: index, nextColor: nextColor)
    }

    /// `TabstopGroup.map`: marks inclusive at both ends; an empty one that ends
    /// up inside replaced text is dropped (`MapMode.TrackDel`).
    mutating func map(_ changes: LSChangeSet) {
        guard !changes.isEmpty else { return }
        groups = groups.map { group in
            group.compactMap { range -> Range<Int>? in
                if range.isEmpty {
                    guard let from = changes.map(range.lowerBound, assoc: -1, mode: .trackDel) else { return nil }
                    let to = changes.mapped(range.lowerBound, assoc: 1)
                    return to < from ? nil : from..<to
                }
                let from = changes.mapped(range.lowerBound, assoc: -1)
                let to = changes.mapped(range.upperBound, assoc: 1)
                return from > to ? nil : from..<to
            }
        }
    }

    /// The selection-change rule (§6.3).
    mutating func select(_ selection: [Range<Int>]) {
        let found = groups.firstIndex { group in
            selection.allSatisfy { r in group.contains { $0.lowerBound <= r.lowerBound && $0.upperBound >= r.upperBound } }
        } ?? groups.count
        index = found
        if groups.count <= 1 || index >= groups.count - 1 {
            groups = []
            colors = []
            index = 0
            nextColor = 0
        }
    }

    /// `getNextTabstopColor`.
    mutating func takeColor() -> Int {
        defer { nextColor += 1 }
        return nextColor % 3
    }

    /// Every range cut to a text of `count` units.
    mutating func clamp(to count: Int) {
        groups = groups.map { $0.map { $0.clamped(to: 0..<count) } }
    }

    mutating func clear() {
        groups = []
        colors = []
        index = 0
        nextColor = 0
    }
}
