import Foundation
import Testing
@testable import PaperCore

/// Latex Suite's text engine. The suites nest under this one and run one at a
/// time, so the timing suite measures a quiet process.
@Suite("Latex Suite", .serialized)
struct LatexSuiteTests {
    let engine = LatexSuite.Engine()

    // MARK: The plugin's own answers

    @Test("Every recorded case comes out the way the plugin produced it", arguments: LatexSuiteFixtures.cases)
    func fixture(_ c: LatexSuiteFixtures.Case) {
        let got = LatexSuiteFixtures.play(c, engine: engine)
        let want = LatexSuiteFixtures.expected(c)
        #expect(got == want, "\(c.id): \(LatexSuiteFixtures.render(got.doc, got.selection)) ≠ \(c.after)\n got \(got)\nwant \(want)")
    }

    @Test("Random keystrokes come out the way the plugin produced them")
    func random() {
        var differ: [String] = []
        for c in LatexSuiteFixtures.randomCases where LatexSuiteFixtures.play(c, engine: engine) != LatexSuiteFixtures.expected(c) {
            differ.append("\(c.id) \(c.before.debugDescription) + \(c.input.items)")
        }
        #expect(LatexSuiteFixtures.randomCases.count == 500)
        #expect(differ.isEmpty, "\(differ.count) differ: \(differ.prefix(10).joined(separator: "; "))")
    }

    @Test("The fixture file has every case, with unique ids")
    func fixtureFile() {
        let ids = LatexSuiteFixtures.cases.map(\.id)
        #expect(ids.count == 290)
        #expect(Set(ids).count == ids.count)
    }

    // MARK: The contract

    /// The key is not in the text yet: the edit replaces what was typed
    /// before it, and never inserts the key itself.
    @Test("The engine runs before the key is inserted")
    func beforeInsertion() throws {
        let text = "$x@$"
        let edit = try #require(engine.handle(.text("a"), text: text, selection: [NSRange(location: 3, length: 0)]))
        #expect(edit.changes == [LatexSuite.Change(range: NSRange(location: 2, length: 1), text: "\\alpha")])
        #expect(LatexSuiteFixtures.Editor.apply(edit.changes, to: text) == "$x\\alpha$")
        #expect(edit.selection == [NSRange(location: 8, length: 0)])
        // Undo sees the key typed first, then the expansion: one Undo brings
        // back `@a`, a second removes the `a`.
        #expect(edit.undoSteps.count == 2)
        let typed = LatexSuiteFixtures.Editor.apply(edit.undoSteps[0], to: text)
        #expect(typed == "$x@a$")
        #expect(LatexSuiteFixtures.Editor.apply(edit.undoSteps[1], to: typed) == "$x\\alpha$")
        #expect(!edit.tabstops.isActive)
    }

    @Test("Nil means the editor does what it always does")
    func passThrough() {
        let caret = [NSRange(location: 2, length: 0)]
        #expect(engine.handle(.text("q"), text: "$x$", selection: caret) == nil)
        #expect(engine.handle(.text("a"), text: "x @", selection: [NSRange(location: 3, length: 0)]) == nil) // text mode
        #expect(engine.handle(.tab, text: "no math here", selection: caret) == nil)
        #expect(engine.handle(.enter, text: "$x$", selection: caret) == nil)
        #expect(engine.handle(.backspace, text: "$xy$", selection: caret) == nil)
        #expect(engine.handle(.text("a"), text: "$x@$", selection: []) == nil)
        // More than one UTF-16 unit is not a keystroke Latex Suite reacts to.
        #expect(engine.handle(.text("😀"), text: "$x$", selection: caret) == nil)
        #expect(engine.handle(.text("ab"), text: "$x@$", selection: [NSRange(location: 3, length: 0)]) == nil)
    }

    @Test("Offsets are UTF-16, as NSRange and JavaScript count them")
    func utf16() throws {
        // U+1F600 is two units; the caret after `@` is at 4, not 3.
        let text = "$😀@$"
        let edit = try #require(engine.handle(.text("a"), text: text, selection: [NSRange(location: 4, length: 0)]))
        #expect(LatexSuiteFixtures.Editor.apply(edit.changes, to: text) == "$😀\\alpha$")
        #expect(edit.selection == [NSRange(location: 9, length: 0)])
    }

    @Test("A selection the editor passes out of range is clamped, not trapped on")
    func outOfRange() {
        #expect(engine.handle(.text("a"), text: "$x@$", selection: [NSRange(location: 99, length: 5)]) == nil)
    }

    // MARK: Tabstops the editor moves

    /// The adapter's side of the tabstop model: after its own typing, it moves
    /// the placeholders with `afterEdit`, and Tab still lands where the plugin
    /// puts it.
    @Test("Typing inside a placeholder grows it; Tab then leaves it")
    func typingInsideTabstop() throws {
        var text = "$$"
        var selection = [NSRange(location: 1, length: 0)]
        var tabstops = LatexSuite.Tabstops.none
        func press(_ input: LatexSuite.Input) {
            if let edit = engine.handle(input, text: text, selection: selection, tabstops: tabstops) {
                text = LatexSuiteFixtures.Editor.apply(edit.changes, to: text)
                selection = edit.selection
                tabstops = edit.tabstops
            } else if case let .text(key) = input {
                let change = LatexSuite.Change(range: selection[0], text: key)
                text = LatexSuiteFixtures.Editor.apply([change], to: text)
                selection = [NSRange(location: selection[0].location + (key as NSString).length, length: 0)]
                tabstops = tabstops.afterEdit([change], selection: selection)
            }
        }
        for key in ["/", "/"] { press(.text(key)) }
        #expect(text == "$\\frac{}{}$")
        #expect(tabstops.groups.count == 3)
        for key in ["a", "+", "b"] { press(.text(key)) }
        #expect(text == "$\\frac{a+b}{}$")
        // The numerator's placeholder took in everything typed at its edge.
        #expect(tabstops.groups[0].ranges == [NSRange(location: 7, length: 3)])
        #expect(tabstops.index == 0)
        press(.tab)
        #expect(selection == [NSRange(location: 12, length: 0)])
        press(.text("c"))
        press(.tab)
        #expect(text == "$\\frac{a+b}{c}$")
        #expect(selection == [NSRange(location: 14, length: 0)])
        #expect(!tabstops.isActive)
    }

    @Test("Tabstops map through edits the editor makes elsewhere")
    func mapping() {
        let tabstops = LatexSuite.Tabstops(groups: [.init(ranges: [NSRange(location: 10, length: 0)]),
                                                    .init(ranges: [NSRange(location: 20, length: 2)]),
                                                    .init(ranges: [NSRange(location: 30, length: 0)])], index: 0)
        // Text inserted before everything shifts every range.
        let shifted = tabstops.mapped(through: [LatexSuite.Change(range: NSRange(location: 0, length: 0), text: "abc")])
        #expect(shifted.groups.map(\.ranges) == [[NSRange(location: 13, length: 0)], [NSRange(location: 23, length: 2)],
                                                 [NSRange(location: 33, length: 0)]])
        // Text typed at either edge of a placeholder becomes part of it.
        let grown = tabstops.mapped(through: [LatexSuite.Change(range: NSRange(location: 22, length: 0), text: "x")])
        #expect(grown.groups[1].ranges == [NSRange(location: 20, length: 3)])
        // An empty placeholder inside deleted text goes away; a deletion that
        // covers a placeholder's text leaves it empty.
        let deleted = tabstops.mapped(through: [LatexSuite.Change(range: NSRange(location: 5, length: 20), text: "")])
        #expect(deleted.groups[0].ranges.isEmpty)
        #expect(deleted.groups[1].ranges == [NSRange(location: 5, length: 0)])
        #expect(deleted.groups[2].ranges == [NSRange(location: 10, length: 0)])
        // Moving the caret out of every group ends the snippet.
        #expect(!tabstops.selecting([NSRange(location: 25, length: 0)]).isActive)
        // Into a later group makes it current; into the last one ends it too.
        #expect(tabstops.selecting([NSRange(location: 21, length: 1)]).index == 1)
        #expect(!tabstops.selecting([NSRange(location: 30, length: 0)]).isActive)
    }

    // MARK: Math in Markdown

    /// Whether the caret is in math, straight from the context: the recorded
    /// cases cover the same ground through what a snippet did.
    @Test("Math in Markdown", arguments: [
        ("a $x‸$ b", "n"), ("$$\nx‸\n$$", "M"), ("a $$x‸$$ b", "M"), ("```\n$x‸$\n```", "c="), ("`$x‸$`", "t,C"),
        ("\\$x‸$", "t"), ("$a\\$b‸$", "n"), ("$x‸\n$", "t"), ("> $$\n> x‸\n> $$", "M"), ("```math\nx‸\n```", "k"),
        ("[[a $x‸$]]", "t"), ("%%$x‸$%%", "t"), ("$x $ y‸$", "n"), ("$x$1 y‸$", "n"), ("a $‸$ b", "n"),
    ])
    func mathInMarkdown(_ marked: String, _ mode: String) {
        let caret = (marked as NSString).range(of: "‸").location
        let text = marked.replacingOccurrences(of: "‸", with: "")
        #expect(Context.describe(LS.units(text), caret).mode == mode, "\(marked.debugDescription)")
    }

    @Test("A long paragraph of stray dollars and code spans above does not reach the caret's paragraph")
    func farAboveTheCaret() {
        let prose = String(repeating: "Plain prose, with a $5 price and a `$` in code. ", count: 200)
        let text = prose + "\n\nNow $x‸ + y$ here."
        let caret = (text as NSString).range(of: "‸").location
        let clean = text.replacingOccurrences(of: "‸", with: "")
        #expect(Context.describe(LS.units(clean), caret).mode == "n")
    }

    // MARK: Where the plugin fails

    /// The one place the engine does not follow the plugin: Latex Suite
    /// counts a caret right before the `$$` of an inline `$$x$$` as inside
    /// an empty inline equation that starts after it, and `/` there makes a
    /// change from 1 to 0 — CodeMirror throws a RangeError, the key goes
    /// through, and the key the plugin had already echoed for Undo stays
    /// behind (`/|/$$x$$`, recorded from the plugin). The engine lets the key
    /// through and leaves nothing behind.
    @Test("A fraction that would start after the caret lets the key through")
    func fractionBeforeDisplayDollars() {
        #expect(engine.handle(.text("/"), text: "$$x$$", selection: [NSRange(location: 0, length: 0)]) == nil)
        // The same caret still counts as math for everything else, as in the plugin.
        #expect(engine.handle(.text("a"), text: "@$$x$$", selection: [NSRange(location: 1, length: 0)]) != nil)
    }

    // MARK: Credit

    @Test("The licence travels with the data")
    func credit() {
        #expect(LatexSuite.version == "1.13.1")
        #expect(LatexSuite.licence.hasPrefix("MIT License\n\nCopyright (c) 2022 artisticat1\n"))
        #expect(LatexSuite.credit.contains("artisticat1") && LatexSuite.credit.contains("MIT"))
    }
}

// MARK: - Whatever it is given

extension LatexSuiteTests {
    /// The engine runs inside the editor on every key: it must never trap,
    /// and what it hands back must always be something an editor can apply.
    @Suite("Robustness")
    struct Robustness {
        let engine = LatexSuite.Engine()

        static let inputs: [LatexSuite.Input] = [
            .text("a"), .text("/"), .text("$"), .text("\\"), .text("{"), .text("("), .text(")"), .text("}"), .text("m"),
            .text("@"), .text("_"), .text("2"), .text(" "), .text("\""), .text("S"),
            .tab, .shiftTab, .enter, .shiftEnter, .backspace,
        ]

        /// Checks an edit against the text it was made for.
        static func check(_ edit: LatexSuite.Edit, _ text: String, _ label: String) {
            let count = (text as NSString).length
            var last = 0
            for change in edit.changes {
                #expect(change.range.location >= last && NSMaxRange(change.range) <= count, "\(label): change \(change.range) out of order or range")
                last = NSMaxRange(change.range)
            }
            let after = LatexSuiteFixtures.Editor.apply(edit.changes, to: text)
            let newCount = (after as NSString).length
            var stepped = text
            for step in edit.undoSteps { stepped = LatexSuiteFixtures.Editor.apply(step, to: stepped) }
            #expect(stepped == after, "\(label): the undo steps end somewhere else")
            for r in edit.selection { #expect(NSMaxRange(r) <= newCount, "\(label): selection \(r) past \(newCount)") }
            for g in edit.tabstops.groups { for r in g.ranges { #expect(NSMaxRange(r) <= newCount, "\(label): tabstop \(r) past \(newCount)") } }
            if !text.contains("\u{FFFD}") { #expect(!after.contains("\u{FFFD}"), "\(label): half a surrogate pair was lost") }
        }

        @Test("Every key at every caret of the context notes gives an edit an editor can apply")
        func everyKeyEverywhere() {
            // The hand-written notes whole, and the short random ones.
            let docs = LatexSuiteTests.Context.fixture.docs
                .filter { $0.set == "written" || ($0.doc as NSString).length <= 24 }.map(\.doc)
                + ["😀 $x😀al$ 😀", "$$\n😀\\frac{a}{b}😀\n$$", "- 😀 item $x$", "> $$\n> \\begin{pmatrix}\n> a & b\n> \\end{pmatrix}\n> $$"]
            var edits = 0
            for text in docs {
                let units = LS.units(text)
                // Every caret an editor can have: not between the halves of a
                // surrogate pair, where no text view puts one.
                for pos in 0...units.count where pos == 0 || pos == units.count || units[pos] & 0xFC00 != 0xDC00 {
                    for input in Self.inputs {
                        guard let edit = engine.handle(input, text: text, selection: [NSRange(location: pos, length: 0)]) else { continue }
                        edits += 1
                        Self.check(edit, text, "\(text.debugDescription) at \(pos), \(input)")
                    }
                }
            }
            #expect(edits > 1_000)
            print("Latex Suite robustness: \(edits) edits from \(docs.count) notes")
        }

        @Test("Nonsense from the editor is clamped, not trapped on")
        func nonsense() {
            let text = "$x@$ and $\\frac{a}{b}$"
            let stale = LatexSuite.Tabstops(groups: [.init(ranges: [NSRange(location: 500, length: 3)]),
                                                     .init(ranges: [NSRange(location: 900, length: 0)])], index: 0)
            let selections: [[NSRange]] = [
                [NSRange(location: NSNotFound, length: 0)], [NSRange(location: 3, length: -4)],
                [NSRange(location: 3, length: Int.max)], [NSRange(location: 3, length: 0), NSRange(location: 2, length: 5)],
            ]
            for selection in selections {
                for input in Self.inputs {
                    for tabstops in [LatexSuite.Tabstops.none, stale] {
                        if let edit = engine.handle(input, text: text, selection: selection, tabstops: tabstops) {
                            Self.check(edit, text, "\(selection) \(input)")
                        }
                    }
                }
            }
            _ = stale.mapped(through: [LatexSuite.Change(range: NSRange(location: NSNotFound, length: 2), text: "x")])
            _ = stale.selecting([NSRange(location: -5, length: -5)])
        }

        @Test("Two carets, a selection, and tabstops together")
        func several() throws {
            let text = "$x@$ and $y@$"
            let edit = try #require(engine.handle(.text("a"), text: text,
                                                  selection: [NSRange(location: 3, length: 0), NSRange(location: 12, length: 0)]))
            Self.check(edit, text, "two carets")
            #expect(LatexSuiteFixtures.Editor.apply(edit.changes, to: text) == "$x\\alpha$ and $y\\alpha$")
            #expect(edit.selection == [NSRange(location: 8, length: 0), NSRange(location: 22, length: 0)])
        }
    }
}
