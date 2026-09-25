import Foundation
import Testing
@testable import PaperCore

/// The fixture files, and a small editor that plays a fixture's keystrokes
/// through the engine the way the harness that recorded them played them
/// through the plugin: a key the engine leaves alone is typed over the
/// selection, a pass-through Tab or Enter changes nothing, Undo steps back one
/// history entry and drops the tabstops, `Caret:N` clicks.
enum LatexSuiteFixtures {
    struct Selection: Decodable, Sendable {
        var anchor: Int
        var head: Int
        var range: NSRange { NSRange(location: Swift.min(anchor, head), length: abs(head - anchor)) }
    }

    struct Group: Decodable, Sendable {
        var group: Int
        var ranges: [[Int]]
    }

    struct State: Decodable, Sendable {
        var doc: String
        var selection: [Selection]
        var tabstops: [Group]?
        var tabstopIndex: Int?
    }

    struct Case: Decodable, Sendable, CustomTestStringConvertible {
        enum Input: Decodable, Sendable {
            case one(String)
            case many([String])
            init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                if let s = try? c.decode(String.self) { self = .one(s) } else { self = .many(try c.decode([String].self)) }
            }
            var items: [String] {
                switch self {
                case let .one(s): return [s]
                case let .many(a): return a
                }
            }
        }

        var id: String
        var name: String
        var before: String
        var input: Input
        var after: String
        var handled: [Bool]
        var passThrough: String?
        var flags: [String]
        var beforeState: State
        var afterState: State

        var testDescription: String { "\(id) \(name)" }

        /// One keypress per character, or a named key, as the harness split them.
        var steps: [String] {
            let named: Set<String> = ["Tab", "Shift+Tab", "Enter", "Shift+Enter", "Backspace", "Undo"]
            var out: [String] = []
            for item in input.items {
                if named.contains(item) || item.hasPrefix("Caret:") {
                    out.append(item)
                } else {
                    for scalar in item.unicodeScalars { out.append(String(scalar)) }
                }
            }
            return out
        }
    }

    struct File: Decodable {
        var cases: [Case]
    }

    static func url(_ name: String) -> URL {
        if let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") { return url }
        if let url = Bundle.module.url(forResource: name, withExtension: "json") { return url }
        fatalError("fixture \(name).json is missing")
    }

    static let cases: [Case] = {
        // swiftlint:disable:next force_try
        try! JSONDecoder().decode(File.self, from: Data(contentsOf: url("latex-suite-cases"))).cases
    }()

    /// Random notes and keys, recorded from the plugin the same way.
    static let randomCases: [Case] = {
        // swiftlint:disable:next force_try
        try! JSONDecoder().decode(File.self, from: Data(contentsOf: url("latex-suite-random"))).cases
    }()

    /// The state a fixture ends in, in the fixture's own terms.
    struct Outcome: Equatable, CustomStringConvertible {
        var doc: String
        var selection: [NSRange]
        var groups: [[NSRange]]
        var index: Int?
        var handled: [Bool]

        var description: String {
            "doc=\(doc.debugDescription) sel=\(selection.map { "\($0.location)+\($0.length)" }) " +
                "groups=\(groups.map { $0.map { "\($0.location)+\($0.length)" } }) index=\(index.map(String.init) ?? "-") handled=\(handled)"
        }
    }

    static func expected(_ c: Case) -> Outcome {
        let groups = (c.afterState.tabstops ?? []).map { $0.ranges.map { NSRange(location: $0[0], length: $0[1] - $0[0]) } }
        return Outcome(doc: c.afterState.doc,
                       selection: c.afterState.selection.map(\.range).sorted { $0.location < $1.location },
                       groups: groups, index: groups.isEmpty ? nil : c.afterState.tabstopIndex,
                       handled: c.handled)
    }

    /// Plays a fixture through the engine.
    static func play(_ c: Case, engine: LatexSuite.Engine = LatexSuite.Engine()) -> Outcome {
        var editor = Editor(text: c.beforeState.doc, selection: c.beforeState.selection.map(\.range))
        var handled: [Bool] = []
        for step in c.steps { handled.append(editor.press(step, engine: engine)) }
        return Outcome(doc: editor.text, selection: editor.selection.sorted { $0.location < $1.location },
                       groups: editor.tabstops.groups.map(\.ranges),
                       index: editor.tabstops.isActive ? editor.tabstops.index : nil, handled: handled)
    }

    struct Editor {
        var text: String
        var selection: [NSRange]
        var tabstops = LatexSuite.Tabstops.none
        private var history: [(String, [NSRange])] = []

        init(text: String, selection: [NSRange]) {
            self.text = text
            self.selection = selection
        }

        static func apply(_ changes: [LatexSuite.Change], to text: String) -> String {
            let s = NSMutableString(string: text)
            for change in changes.sorted(by: { $0.range.location > $1.range.location }) {
                s.replaceCharacters(in: change.range, with: change.text)
            }
            return s as String
        }

        mutating func press(_ step: String, engine: LatexSuite.Engine) -> Bool {
            if step == "Undo" {
                guard let (doc, sel) = history.popLast() else { return false }
                text = doc
                selection = sel
                tabstops = .none
                return true
            }
            if step.hasPrefix("Caret:") {
                let p = Int(step.dropFirst(6))!
                selection = [NSRange(location: p, length: 0)]
                tabstops = tabstops.selecting(selection)
                return true
            }
            let input: LatexSuite.Input
            switch step {
            case "Tab": input = .tab
            case "Shift+Tab": input = .shiftTab
            case "Enter": input = .enter
            case "Shift+Enter": input = .shiftEnter
            case "Backspace": input = .backspace
            default: input = .text(step)
            }
            if let edit = engine.handle(input, text: text, selection: selection, tabstops: tabstops) {
                // One history entry per undo step, each remembering the
                // selection it started from.
                var sel = selection
                for (n, step) in edit.undoSteps.enumerated() {
                    history.append((text, sel))
                    text = Self.apply(step, to: text)
                    if n == 0 && edit.undoSteps.count > 1 {
                        // The echoed key: the caret after it.
                        let set = step.map(\.internal)
                        let changes = LSChangeSet(set)
                        sel = sel.map { NSRange(location: changes.mapped($0.location, assoc: 1), length: 0) }
                    }
                }
                selection = edit.selection
                tabstops = edit.tabstops
                return true
            }
            guard case let .text(key) = input else { return false }
            // The editor's own typing: every range replaced, the caret after it.
            history.append((text, selection))
            let changes = selection.map { LatexSuite.Change(range: $0, text: key) }
            text = Self.apply(changes, to: text)
            var shift = 0
            let keyLength = (key as NSString).length
            var carets: [NSRange] = []
            for range in selection.sorted(by: { $0.location < $1.location }) {
                carets.append(NSRange(location: range.location + shift + keyLength, length: 0))
                shift += keyLength - range.length
            }
            selection = carets
            tabstops = tabstops.afterEdit(changes, selection: carets)
            return false
        }
    }

    /// Renders a document with its selection the way the fixtures write it.
    static func render(_ doc: String, _ selection: [NSRange]) -> String {
        let s = NSMutableString(string: doc.replacingOccurrences(of: "|", with: "¦"))
        for r in selection.sorted(by: { $0.location > $1.location }) {
            if r.length == 0 {
                s.insert("|", at: r.location)
            } else {
                s.insert("»", at: r.location + r.length)
                s.insert("«", at: r.location)
            }
        }
        return s as String
    }
}
