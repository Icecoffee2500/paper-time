import Foundation

/// One keystroke's worth of Latex Suite: the document, selection and tabstops
/// as they evolve through the transactions the plugin would dispatch, in the
/// order its keymap tries things (latex_suite.ts, `getKeymaps`).
final class LSRun {
    private(set) var doc: LSUnits
    private(set) var selection: [Range<Int>]
    private(set) var tabstops: LSTabstopState
    let settings: LatexSuite.Settings
    let library: LSLibrary
    private let original: LSUnits
    private let originalSelection: [Range<Int>]
    private var transactions: [LSChangeSet] = []
    /// The typed key, committed as its own undo step before an expansion
    /// replaces it (snippet_management.ts, `handleUndoKeypresses`).
    private var echo: [LSChange] = []
    private var cachedContext: LSContext?

    init(doc: LSUnits, selection: [Range<Int>], tabstops: LSTabstopState, settings: LatexSuite.Settings, library: LSLibrary) {
        self.doc = doc
        self.selection = selection
        self.tabstops = tabstops
        self.settings = settings
        self.library = library
        original = doc
        originalSelection = selection
    }

    var context: LSContext {
        if let cachedContext { return cachedContext }
        let ctx = LSContext(doc: doc, selection: selection, library: library, forceMathLanguages: settings.forceMathLanguages)
        cachedContext = ctx
        return ctx
    }

    private var main: Range<Int> { selection[0] }

    // MARK: The keymap

    func handle(_ input: LatexSuite.Input) -> Bool {
        switch input {
        case let .text(string):
            let units = LS.units(string)
            guard units.count == 1 else { return false }
            let key = units[0]
            if settings.snippetsEnabled, runSnippets(library.automatic, key: key) { return true }
            if settings.snippetsEnabled, let visual = library.visual[key], runSnippets(visual, key: nil) { return true }
            if key == 47, settings.autofractionEnabled, context.mode.strictlyInMath, autofraction() { return true }
            if settings.taboutEnabled, key == 41 || key == 125 || key == 93, main.isEmpty,
               main.lowerBound < doc.count, doc[main.lowerBound] == key, tabout() {
                return true
            }
            return false
        case .tab:
            if settings.snippetsEnabled, runSnippets(library.onTab, key: nil) { return true }
            if jumpToTabstop(forward: true) { return true }
            if settings.matrixShortcutsEnabled {
                if settings.taboutEnabled, matrix(priorityTabout) { return true }
                if matrix(addCell) { return true }
            }
            if settings.taboutEnabled, main.isEmpty, tabout() { return true }
            return false
        case .shiftTab:
            return jumpToTabstop(forward: false)
        case .enter:
            return settings.matrixShortcutsEnabled && matrix(newline)
        case .shiftEnter:
            return settings.matrixShortcutsEnabled && matrix(exit)
        case .backspace:
            return settings.autoDeleteDollar && autoDeleteDollar()
        }
    }

    // MARK: Transactions

    /// Applies one transaction. With `explicit`, the selection is set (and the
    /// tabstops react, §6.3); without, it is mapped through the changes.
    private func dispatch(_ changes: LSChangeSet, explicit: [Range<Int>]? = nil, assoc: Int = -1,
                          newGroups: [[Range<Int>]]? = nil, color: Int = 0) {
        tabstops.map(changes)
        if let newGroups {
            if tabstops.groups.indices.contains(tabstops.index) {
                tabstops.groups.replaceSubrange(tabstops.index...tabstops.index, with: newGroups)
                tabstops.colors.replaceSubrange(tabstops.index...tabstops.index, with: Array(repeating: color, count: newGroups.count))
            } else {
                tabstops.groups += newGroups
                tabstops.colors += Array(repeating: color, count: newGroups.count)
            }
        }
        if let explicit {
            selection = lsNormalizedSelection(explicit)
            tabstops.select(selection)
        } else {
            selection = lsNormalizedSelection(selection.map { changes.map($0, assoc: assoc) })
        }
        doc = changes.apply(doc)
        if !changes.isEmpty { transactions.append(changes) }
        cachedContext = nil
    }

    private func setCursor(_ pos: Int) {
        dispatch(.empty, explicit: [pos..<pos])
    }

    func edit() -> LatexSuite.Edit {
        let changes = lsPublicChanges(lsCompose(original, transactions), in: original)
        var steps: [[LatexSuite.Change]] = []
        if !echo.isEmpty {
            let echoSet = LSChangeSet(echo)
            let echoed = echoSet.apply(original)
            // The key characters as they sit in the echoed document.
            var undo: [LSChange] = []
            var shift = 0
            for change in echoSet.changes {
                undo.append(LSChange(from: change.from + shift, to: change.from + shift + change.insert.count, insert: []))
                shift += change.insert.count
            }
            steps.append(lsPublicChanges(echoSet.changes, in: original))
            steps.append(lsPublicChanges(lsCompose(echoed, [LSChangeSet(undo)] + transactions), in: echoed))
        } else {
            steps = changes.isEmpty ? [] : [changes]
        }
        return LatexSuite.Edit(changes: changes, undoSteps: steps,
                               selection: selection.map { NSRange(ls: $0.lowerBound, $0.upperBound) },
                               tabstops: tabstops.public)
    }

    // MARK: Snippets (run_snippets.ts)

    private struct Queued {
        var from: Int
        var to: Int
        var insert: LSInsert
        var key: UInt16?
    }

    private enum VisualFailure: Error { case emptySelection }

    private func runSnippets(_ snippets: [LSSnippet], key: UInt16?) -> Bool {
        guard !snippets.isEmpty else { return false }
        let ctx = context
        var queue: [Queued] = []
        var enlarge = false
        do {
            for range in ctx.selection.reversed() {
                guard let (queued, triggers) = try runCursor(ctx, snippets, range, key) else { continue }
                queue.append(queued)
                if triggers { enlarge = true }
            }
        } catch {
            return false
        }
        guard !queue.isEmpty else { return false }
        expand(queue)
        if enlarge { autoEnlargeBrackets() }
        return true
    }

    private func runCursor(_ ctx: LSContext, _ snippets: [LSSnippet], _ range: Range<Int>, _ key: UInt16?) throws -> (Queued, Bool)? {
        let to = range.upperBound
        let hasSelection = !range.isEmpty
        let scopes = ctx.scopes(at: to)
        var regexInput: LSRegexInput?
        let keyUnits: LSUnits = key.map { [$0] } ?? []
        for snippet in snippets {
            guard snippet.mode.runs(in: ctx.mode) else { continue }
            var triggerPos = to
            var insert: LSInsert
            switch snippet.trigger {
            case let .string(trigger):
                guard !hasSelection, endsWith(trigger, at: to, key: key) else { continue }
                triggerPos = to + keyUnits.count - trigger.count
                switch snippet.replacement {
                case let .template(template): insert = LSReplacement.expand(template)
                case .function: continue
                }
            case let .regex(regex, shape, groupNames):
                guard !hasSelection else { continue }
                if regexInput == nil { regexInput = LSRegexInput(doc: doc, to: to, key: keyUnits) }
                guard let match = regexInput!.match(regex, shape: shape, groupNames: groupNames) else { continue }
                triggerPos = match.index
                switch snippet.replacement {
                case let .template(template):
                    insert = LSReplacement.expand(template, captures: match.groups.map { $0 ?? [] })
                case let .function(function):
                    guard let text = function(match.whole, match.groups, match.named, library: library) else { continue }
                    insert = LSReplacement.expandTabstops(text)
                }
            case .visual:
                guard hasSelection else { continue }
                let parsed = parsedSelection(range)
                triggerPos = range.lowerBound
                guard case let .template(template) = snippet.replacement else { continue }
                // VisualSnippetNode throws without a selection to put in.
                if parsed.text.isEmpty { throw VisualFailure.emptySelection }
                insert = LSReplacement.expand(template, visual: parsed.text)
                if insert.tabstops.isEmpty {
                    let prefix = doc.slice(range.lowerBound, parsed.from)
                    insert.text = prefix + insert.text
                    insert.tabstops = [LSTabstopSpec(index: [0], from: 0, to: insert.text.count)]
                }
            }
            if snippet.isExcluded(by: scopes) { continue }
            if snippet.onWordBoundary && !isOnWordBoundary(triggerPos, to) { continue }
            if ctx.mode.inlineMath && settings.removeSnippetWhitespace { insert = LSReplacement.trimmed(insert) }
            let echo = snippet.automatic && !snippet.isVisual && snippet.undoKey ? key : nil
            let triggers = settings.autoEnlargeBracketsTriggers.contains { insert.text.contains(LS.units($0)) }
            return (queue(from: triggerPos, to: to, insert, key: echo), triggers)
        }
        return nil
    }

    private func endsWith(_ trigger: LSUnits, at to: Int, key: UInt16?) -> Bool {
        let n = trigger.count
        if let key {
            guard n >= 1, trigger[n - 1] == key, n - 1 <= to else { return n == 0 }
            return doc.hasPrefix(Array(trigger[0..<(n - 1)]), at: to - (n - 1))
        }
        guard n <= to else { return false }
        return doc.hasPrefix(trigger, at: to - n)
    }

    private func isOnWordBoundary(_ triggerPos: Int, _ to: Int) -> Bool {
        let delimiters = Set(LS.units(settings.wordDelimiters))
        let prevOK = triggerPos <= 0 || delimiters.contains(doc[triggerPos - 1])
        let nextOK = to >= doc.count || delimiters.contains(doc[to])
        return prevOK && nextOK
    }

    /// `getParsedSelection`: callout markers and indentation on continuation
    /// lines are not part of the selected text.
    private func parsedSelection(_ range: Range<Int>) -> (from: Int, text: LSUnits) {
        let originalText = doc.slice(range.lowerBound, range.upperBound)
        var lineStart = range.lowerBound
        while lineStart > 0, doc[lineStart - 1] != LS.newline { lineStart -= 1 }
        var lineEnd = range.lowerBound
        while lineEnd < doc.count, doc[lineEnd] != LS.newline { lineEnd += 1 }
        let startLine = doc.slice(lineStart, lineEnd)
        let (calloutLength, callouts, indentation) = Self.calloutPrefix(startLine, 0)
        _ = calloutLength
        // `\n((?:> ?)*)(\s*)`, replaced by a bare newline while every line has
        // the same callout depth and at least the first line's indentation.
        var parsed = LSUnits()
        var i = 0
        while i < originalText.count {
            if originalText[i] == LS.newline {
                let (length, count, indent) = Self.calloutPrefix(originalText, i + 1)
                if count != callouts || indent < indentation { return (range.lowerBound, originalText) }
                parsed.append(LS.newline)
                i += 1 + length
                continue
            }
            parsed.append(originalText[i])
            i += 1
        }
        var from = range.lowerBound
        if lineStart == range.lowerBound {
            // `/^(> ?)*\s*/` on the parsed text.
            var j = 0
            while j < parsed.count, parsed[j] == 62 {
                j += 1
                if j < parsed.count, parsed[j] == 32 { j += 1 }
            }
            while j < parsed.count, LS.isSpace(parsed[j]) { j += 1 }
            from += j
            parsed = Array(parsed[j...])
        }
        return (from, parsed)
    }

    /// `(?:> ?)*` then `\s*` from `start`: the total length, the number of `>`
    /// and the length of the whitespace.
    private static func calloutPrefix(_ text: LSUnits, _ start: Int) -> (Int, Int, Int) {
        var j = start
        var count = 0
        while j < text.count, text[j] == 62 {
            count += 1
            j += 1
            if j < text.count, text[j] == 32 { j += 1 }
        }
        let indentStart = j
        while j < text.count, LS.isSpace(text[j]) { j += 1 }
        return (j - start, count, j - indentStart)
    }

    /// `queueSnippet` with `keepIndentAndCallout`: every newline in the
    /// replacement carries the line's callout markers and indentation, and
    /// tabs right after a newline become that many indent units more.
    private func queue(from: Int, to: Int, _ insert: LSInsert, key: UInt16?) -> Queued {
        var lineStart = to
        while lineStart > 0, doc[lineStart - 1] != LS.newline { lineStart -= 1 }
        var j = lineStart
        while j < doc.count, doc[j] == 62 { j += 1 }
        let callouts = doc.slice(lineStart, j)
        let indentStart = j
        while j < doc.count, doc[j] != LS.newline, LS.isSpace(doc[j]) { j += 1 }
        let indentation = doc.slice(indentStart, j)
        let tabSize = Swift.max(1, settings.tabSize)
        var column = 0
        for c in indentation { column += c == 9 ? tabSize - column % tabSize : 1 }
        let unitUnits = LS.units(settings.indentUnit)
        var unitWidth = 0
        for c in unitUnits { unitWidth += c == 9 ? tabSize - unitWidth % tabSize : 1 }
        unitWidth = Swift.max(1, unitWidth)
        let misalignment = column % unitWidth
        let tabsIndent = unitUnits.first == 9

        func indentString(_ columns: Int) -> LSUnits {
            var out = LSUnits()
            var n = columns
            if tabsIndent {
                while n >= tabSize {
                    out.append(9)
                    n -= tabSize
                }
            }
            while n > 0 {
                out.append(32)
                n -= 1
            }
            return out
        }

        var text = LSUnits()
        var tabstops = insert.tabstops
        var offset = 0
        var i = 0
        let source = insert.text
        while i < source.count {
            if source[i] == LS.newline {
                var k = i + 1
                while k < source.count, source[k] == 9 { k += 1 }
                let tabs = k - (i + 1)
                let newColumn = tabs * unitWidth + column - (tabs > 0 ? misalignment : 0)
                let replacement: LSUnits = [LS.newline] + callouts + indentString(newColumn)
                let added = replacement.count - (k - i)
                for t in tabstops.indices {
                    if tabstops[t].from - offset > i { tabstops[t].from += added }
                    if tabstops[t].to - offset > i { tabstops[t].to += added }
                }
                offset += added
                text += replacement
                i = k
                continue
            }
            text.append(source[i])
            i += 1
        }
        return Queued(from: from, to: to, insert: LSInsert(text: text, tabstops: tabstops), key: key)
    }

    /// `expandSnippets`: all queued replacements in one change set; with
    /// tabstops, their groups spliced in place of the current one and group 0
    /// selected.
    private func expand(_ queue: [Queued]) {
        let changes = lsChangeSetOf(queue.map { LSChange(from: $0.from, to: $0.to, insert: $0.insert.text) }, in: doc)
        if echo.isEmpty && transactions.isEmpty {
            echo = queue.compactMap { q in q.key.map { LSChange(from: q.to, to: q.to, insert: [$0]) } }
        }
        let undone = Self.undoneKeypresses(queue, in: doc)
        let specs = queue.flatMap { q in
            let from = undone.mapped(q.from, assoc: 1)
            return q.insert.tabstops.map { LSTabstopSpec(index: $0.index, from: from + $0.from, to: from + $0.to) }
        }
        let mapped = selection.map { changes.map($0, assoc: 1) }
        if specs.isEmpty {
            dispatch(changes, explicit: mapped)
            return
        }
        let groups = Self.groups(from: specs)
        let color = tabstops.takeColor()
        dispatch(changes, explicit: groups[0], newGroups: groups, color: color)
    }

    /// Where the plugin measures each snippet's tabstops from
    /// (snippet_management.ts, `handleUndoKeypresses` and `applyChange`): the
    /// typed keys are put in and taken out again for Undo, and each snippet's
    /// start is mapped through that taking-out — as if it were a position in
    /// the text with the keys in, which it is not, and without the other
    /// snippets of the same keystroke. With one caret this changes nothing.
    /// With several, the placeholders of all but the first land where the
    /// other carets' keys and expansions push them, not on their own text;
    /// that is what Latex Suite users get, so it is kept.
    private static func undoneKeypresses(_ queue: [Queued], in doc: LSUnits) -> LSChangeSet {
        let presses = LSChangeSet(queue.compactMap { q -> LSChange? in
            guard let key = q.key else { return nil }
            // `prevChar + key` over `[to - 1, to)`, so carets land after the key.
            let from = q.to == 0 ? 0 : q.to - 1
            return LSChange(from: from, to: q.to, insert: doc.slice(from, q.to) + [key])
        })
        guard !presses.isEmpty else { return .empty }
        var inverse: [LSChange] = []
        var shift = 0
        for press in presses.changes {
            let from = press.from + shift
            inverse.append(LSChange(from: from, to: from + press.insert.count, insert: doc.slice(press.from, press.to)))
            shift += press.insert.count - (press.to - press.from)
        }
        return LSChangeSet(inverse)
    }

    /// `tabstopSpecsToTabstopGroups`: sorted by number (lowest first), equal
    /// numbers one group, renumbered without gaps.
    static func groups(from specs: [LSTabstopSpec]) -> [[Range<Int>]] {
        let sorted = specs.enumerated().sorted { a, b in
            let x = a.element.index, y = b.element.index
            for k in 0..<Swift.min(x.count, y.count) where x[k] != y[k] { return x[k] < y[k] }
            if x.count != y.count { return x.count < y.count }
            return a.offset < b.offset
        }.map(\.element)
        var groups: [[Range<Int>]] = []
        var last: [Int]?
        for spec in sorted {
            if spec.index != last { groups.append([]) }
            groups[groups.count - 1].append(spec.from..<spec.to)
            last = spec.index
        }
        return groups.map { $0.sorted { $0.lowerBound < $1.lowerBound } }
    }

    // MARK: Tabstops (snippet_management.ts, setSelectionToNextTabstop)

    private func jumpToTabstop(forward: Bool) -> Bool {
        let direction = forward ? 1 : -1
        var next = tabstops.index + direction
        while tabstops.groups.indices.contains(next) {
            let group = tabstops.groups[next]
            var target = lsNormalizedSelection(group)
            let contains = selection.allSatisfy { r in group.contains { $0.lowerBound <= r.lowerBound && $0.upperBound >= r.upperBound } }
            if contains { target = lsNormalizedSelection(target.map { $0.upperBound..<$0.upperBound }) }
            if target == selection {
                next += direction
                continue
            }
            dispatch(.empty, explicit: target)
            return true
        }
        return false
    }

    // MARK: Auto-enlarge brackets (auto_enlarge_brackets.ts)

    private static let sizeControls: Set<String> = ["\\big", "\\Big", "\\bigg", "\\Bigg", "\\bigl", "\\Bigl", "\\biggl",
                                                    "\\Biggl", "\\bigr", "\\Bigr", "\\biggr", "\\Biggr", "\\left", "\\right"]

    private func autoEnlargeBrackets() {
        guard settings.autoEnlargeBrackets else { return }
        let ctx = context
        let pos = main.upperBound
        guard let bound = ctx.bounds.first(where: { $0.tree != nil && $0.innerStart <= pos && $0.innerEnd >= pos }),
              let latex = ctx.latex(for: bound) else { return }
        let space: LSUnits = settings.autoEnlargeBracketsSpace ? [32] : []
        let triggers = settings.autoEnlargeBracketsTriggers.map(LS.units)
        var queue: [Queued] = []
        var taken: [Range<Int>] = []
        for pair in latex.pairs() {
            let open = doc.slice(pair.open.lowerBound, pair.open.upperBound)
            let close = doc.slice(pair.close.lowerBound, pair.close.upperBound)
            if open == [123] || open == LS.units("\\(") || open.hasPrefix(LS.units("\\left")) || close.hasPrefix(LS.units("\\right")) {
                continue
            }
            if let word = latex.controlWord(endingAt: pair.open.lowerBound), Self.sizeControls.contains(word) { continue }
            let content = doc.slice(pair.open.upperBound, pair.close.lowerBound)
            if triggers.allSatisfy({ !content.contains($0) }) { continue }
            if taken.contains(where: { $0.overlaps(pair.open) || $0.overlaps(pair.close) }) { continue }
            taken += [pair.open, pair.close]
            queue.append(self.queue(from: pair.open.lowerBound, to: pair.open.upperBound,
                                    LSInsert(text: LS.units("\\left") + open + space, tabstops: []), key: nil))
            queue.append(self.queue(from: pair.close.lowerBound, to: pair.close.upperBound,
                                    LSInsert(text: space + LS.units("\\right") + close, tabstops: []), key: nil))
        }
        guard !queue.isEmpty else { return }
        expand(queue)
    }

    // MARK: Autofraction (autofraction.ts)

    private static let fractionGreek = ["alpha", "beta", "gamma", "Gamma", "delta", "Delta", "epsilon", "varepsilon", "zeta",
                                        "eta", "theta", "Theta", "iota", "kappa", "lambda", "Lambda", "mu", "nu", "omicron",
                                        "xi", "Xi", "pi", "Pi", "rho", "sigma", "Sigma", "tau", "upsilon", "Upsilon", "varphi",
                                        "phi", "Phi", "chi", "psi", "Psi", "omega", "Omega"].map(LS.units)

    private func autofraction() -> Bool {
        let ctx = context
        var queue: [Queued] = []
        for range in ctx.selection.reversed() {
            if let q = fraction(ctx, range) { queue.append(q) }
        }
        guard !queue.isEmpty else { return false }
        expand(queue)
        autoEnlargeBrackets()
        return true
    }

    private func fraction(_ ctx: LSContext, _ range: Range<Int>) -> Queued? {
        let from = range.lowerBound
        let to = range.upperBound
        for env in settings.autofractionExcludedEnvironments where env.count == 2 {
            if ctx.isWithinEnvironment(to, open: LS.units(env[0]), close: LS.units(env[1])) { return nil }
        }
        guard let bound = ctx.equation else { return nil }
        let eqnStart = bound.innerStart
        var start = eqnStart
        if from != to {
            start = from
        } else {
            var line = to > eqnStart ? doc.slice(eqnStart, to) : []
            // A space after a Greek name does not break the numerator.
            var i = 0
            scan: while i < line.count {
                for name in Self.fractionGreek where line.hasPrefix(name, at: i) {
                    let space = i + name.count
                    if space + 1 < line.count, line[space] == 32, line[space + 1] != 32 {
                        line[space] = 35
                        i = space + 2
                        continue scan
                    }
                }
                i += 1
            }
            let breaking = Set(LS.units(" $([{\n" + settings.autofractionBreakingChars))
            var k = line.count - 1
            while k >= 0 {
                let c = line[k]
                if c == 41 || c == 93 || c == 125 {
                    let open: UInt16 = c == 41 ? 40 : c == 93 ? 91 : 123
                    guard let j = LSText.matchingBracketBackwards(line, from: k, open: open, close: c) else { return nil }
                    k = j
                }
                if breaking.contains(c) {
                    start = k + 1 + eqnStart
                    break
                }
                k -= 1
            }
        }
        // Nothing to take (the plugin's `start === to`). `start > to` is the
        // caret right before the `$$` of `$$x$$`, which Latex Suite counts as
        // inside an empty inline equation that starts after it: the plugin
        // throws a RangeError there and leaves a stray `/` in the text. The
        // engine lets the key through instead.
        if start >= to { return nil }
        var numerator = doc.slice(start, to)
        if numerator.first == 40, numerator.last == 41,
           LSText.matchingBracket(numerator, from: 0, open: [40], close: [41]) == numerator.count - 1 {
            numerator = Array(numerator[1..<(numerator.count - 1)])
        }
        var text = LS.units(settings.autofractionSymbol + "{")
        var tabstops: [LSTabstopSpec] = []
        if numerator.isEmpty {
            tabstops.append(LSTabstopSpec(index: [0], from: text.count, to: text.count))
        } else {
            text += numerator
        }
        text += LS.units("}{")
        tabstops.append(LSTabstopSpec(index: [1], from: text.count, to: text.count))
        text += [125]
        tabstops.append(LSTabstopSpec(index: [2], from: text.count, to: text.count))
        return queue(from: start, to: to, LSInsert(text: text, tabstops: tabstops), key: from != to ? nil : 47)
    }

    // MARK: Tabout (tabout.ts)

    struct Token {
        var start: Int
        var end: Int
        var text: LSUnits
    }

    /// utils/tokenizer.ts, including what it does with a trailing backslash
    /// (JavaScript tests `undefined` against `[A-Za-z]` and gets true).
    static func tokenize(_ s: LSUnits) -> [Token] {
        var tokens: [Token] = []
        var i = 0
        while i < s.count {
            let c = s[i]
            if LS.isSpace(c) {
                i += 1
                continue
            }
            var end = i + 1
            if c == 37 {
                while end < s.count, s[end] != LS.newline { end += 1 }
            } else if c == LS.backslash {
                if i + 1 >= s.count || LS.isASCIILetter(Int(s[i + 1])) {
                    end = i + 2
                    while end < s.count, LS.isASCIILetter(Int(s[end])) { end += 1 }
                } else {
                    end = i + 2
                }
            }
            tokens.append(Token(start: i, end: end, text: s.slice(i, end)))
            i = Swift.min(end, s.count)
        }
        return tokens
    }

    private static let leftCommands: Set<LSUnits> = Set(["\\left", "\\bigl", "\\Bigl", "\\biggl", "\\Biggl"].map(LS.units))
    private static let rightCommands: Set<LSUnits> = Set(["\\right", "\\bigr", "\\Bigr", "\\biggr", "\\Biggr"].map(LS.units))
    private static let delimiters: Set<LSUnits> = Set(["(", ")", "[", "]", "\\lbrack", "\\rbrack", "\\{", "\\}", "\\lbrace",
                                                       "\\rbrace", "<", ">", "\\langle", "\\rangle", "\\lt", "\\gt", "|",
                                                       "\\vert", "\\lvert", "\\rvert", "\\|", "\\Vert", "\\lVert", "\\rVert",
                                                       "\\lfloor", "\\rfloor", "\\lceil", "\\rceil", "\\ulcorner",
                                                       "\\urcorner", "/", "\\\\", "\\backslash", "\\uparrow", "\\downarrow",
                                                       "\\Uparrow", "\\Downarrow", "."].map(LS.units))
    private static let delimiterPairs: [(String, String)] = [("(", ")"), ("[", "]"), ("{", "}"), ("\\lbrack", "\\rbrack"),
                                                              ("\\lbrace", "\\rbrace"), ("\\langle", "\\rangle"),
                                                              ("\\lvert", "\\rvert"), ("\\lVert", "\\rVert"),
                                                              ("\\lfloor", "\\rfloor"), ("\\lceil", "\\rceil"),
                                                              ("\\ulcorner", "\\urcorner"), ("<", ">")]

    private func isClosingDelimiter(_ tokens: [Token], _ i: Int, _ closing: Set<LSUnits>) -> Bool {
        if i > 0 {
            let prev = tokens[i - 1].text
            if Self.rightCommands.contains(prev) && Self.delimiters.contains(tokens[i].text) { return true }
            if Self.leftCommands.contains(prev) && Self.delimiters.contains(tokens[i].text) { return false }
        }
        return closing.contains(tokens[i].text)
    }

    private func isUnmatchedRightCommand(_ tokens: [Token], _ i: Int) -> Bool {
        guard Self.rightCommands.contains(tokens[i].text) else { return false }
        if i + 1 >= tokens.count { return true }
        return !Self.delimiters.contains(tokens[i + 1].text)
    }

    private func lineStart(_ p: Int) -> Int {
        var i = Swift.min(Swift.max(0, p), doc.count)
        while i > 0, doc[i - 1] != LS.newline { i -= 1 }
        return i
    }

    private func lineEnd(_ p: Int) -> Int {
        var i = Swift.max(0, p)
        while i < doc.count, doc[i] != LS.newline { i += 1 }
        return i
    }

    private func isMultiline(_ from: Int, _ to: Int) -> Bool {
        lineStart(from) != lineStart(to)
    }

    private func tabout() -> Bool {
        let ctx = context
        guard ctx.mode.inMath, let bound = ctx.equation, bound.outerEnd > ctx.pos else { return false }
        let cursor = main.upperBound
        let relative = cursor - bound.innerStart
        let tokens = Self.tokenize(doc.slice(bound.innerStart, bound.innerEnd))
        let closing = Set(settings.taboutClosingSymbols.map(LS.units))
        let startIndex = tokens.firstIndex { $0.end > relative } ?? tokens.count
        for i in startIndex..<tokens.count where isClosingDelimiter(tokens, i, closing) || isUnmatchedRightCommand(tokens, i) {
            setCursor(bound.innerStart + tokens[i].end)
            return true
        }
        let atEnd = doc.slice(cursor, bound.innerEnd).isAllSpace()
        if !atEnd && settings.taboutExitEquationOnlyOnEOL { return false }
        if !isMultiline(bound.outerStart, bound.outerEnd) {
            setCursor(bound.outerEnd)
            return true
        }
        let endLineStart = lineStart(bound.outerEnd)
        let endLineEnd = lineEnd(endLineStart)
        let startLine = doc.slice(lineStart(bound.outerStart), lineEnd(bound.outerStart))
        var indentCount = 0
        while indentCount < startLine.count, LS.isSpace(startLine[indentCount]) { indentCount += 1 }
        let indent = Array(startLine[0..<indentCount])
        var changes: [LSChange] = []
        var target: Int
        if endLineEnd >= doc.count {
            changes.append(LSChange(from: endLineEnd, to: endLineEnd, insert: [LS.newline] + indent))
            target = endLineEnd + 1 + indent.count
        } else {
            let afterStart = endLineEnd + 1
            let afterEnd = lineEnd(afterStart)
            if doc.slice(afterStart, afterEnd).isAllSpace() {
                changes.append(LSChange(from: afterStart, to: afterEnd, insert: indent))
                target = endLineEnd + 1 + indent.count
            } else {
                target = endLineEnd + 1
            }
        }
        // Trailing whitespace on the caret's line goes in the same transaction;
        // the caret, set by the first spec, moves back by what it removes.
        let currentStart = lineStart(cursor)
        let currentEnd = lineEnd(cursor)
        let current = doc.slice(currentStart, currentEnd)
        let trimmed = current.trimmingEnd()
        if trimmed.count != current.count {
            changes.insert(LSChange(from: currentStart, to: currentEnd, insert: trimmed), at: 0)
            if currentEnd <= target { target -= current.count - trimmed.count }
        }
        dispatch(LSChangeSet(changes), explicit: [target..<target])
        return true
    }

    // MARK: Matrix shortcuts (matrix_shortcuts.ts)

    private typealias MatrixShortcut = (LSLatex.Scope) -> Bool

    private func matrix(_ shortcut: MatrixShortcut) -> Bool {
        let ctx = context
        guard ctx.mode.strictlyInMath, ctx.equation != nil, let scope = ctx.scopes(at: ctx.pos).first else { return false }
        switch scope.kind {
        case .environment:
            guard settings.matrixShortcutsEnvironments.contains(scope.name) else { return false }
        case .command:
            guard settings.matrixShortcutsMacros.contains(scope.name) else { return false }
        case .math:
            return false
        }
        return shortcut(scope)
    }

    private func priorityTabout(_ scope: LSLatex.Scope) -> Bool {
        let pos = context.pos
        let rest = doc.slice(pos, lineEnd(pos))
        let tokens = Self.tokenize(rest)
        let closingSymbols = Set(settings.taboutClosingSymbols.map(LS.units))
        let closing = Set(Self.delimiterPairs.map { LS.units($0.1) }).intersection(closingSymbols)
        let opening = Set(Self.delimiterPairs.filter { closing.contains(LS.units($0.1)) }.map { LS.units($0.0) })
        var depth = 0
        for token in tokens {
            if closing.contains(token.text) {
                if depth == 0 {
                    setCursor(pos + token.end)
                    return true
                }
                depth -= 1
            } else if opening.contains(token.text) {
                depth += 1
            }
        }
        return false
    }

    private func addCell(_ scope: LSLatex.Scope) -> Bool {
        guard main.isEmpty else { return false }
        replaceSelection(LS.units(" & "))
        return true
    }

    /// `view.state.replaceSelection`: every range replaced, the caret after it.
    private func replaceSelection(_ text: LSUnits) {
        let changes = LSChangeSet(selection.map { LSChange(from: $0.lowerBound, to: $0.upperBound, insert: text) })
        let carets = selection.map { r -> Range<Int> in
            let p = changes.mapped(r.lowerBound, assoc: -1) + text.count
            return p..<p
        }
        dispatch(changes, explicit: carets)
    }

    private func newline(_ scope: LSLatex.Scope) -> Bool {
        let pos = context.pos
        let line = doc.slice(lineStart(pos), lineEnd(pos))
        let cells = Self.matrixRowPrefix(line)
        if isMultiline(scope.outerStart, scope.outerEnd) {
            let text = LS.units(" \\\\\n") + cells
            let insert = LSInsert(text: text, tabstops: [LSTabstopSpec(index: [0], from: text.count, to: text.count)])
            expand([queue(from: pos, to: pos, insert, key: nil)])
        } else {
            replaceSelection(LS.units(" \\\\  ") + cells)
        }
        return true
    }

    /// `/(\\begin{[^]]*}|\\\\|^)((?:\s|&)+)/` — `[^]` is "any character" in
    /// JavaScript, so the first branch only takes a one-letter environment name.
    /// Returns the second group with its leading whitespace trimmed.
    static func matrixRowPrefix(_ line: LSUnits) -> LSUnits {
        func run(_ at: Int) -> Int {
            var j = at
            while j < line.count, LS.isSpace(line[j]) || line[j] == 38 { j += 1 }
            return j
        }
        let begin = LS.units("\\begin{")
        for p in 0...line.count {
            var candidates: [Int] = []
            if line.hasPrefix(begin, at: p), p + begin.count < line.count {
                var j = p + begin.count + 1
                while j < line.count, line[j] == 93 { j += 1 }
                if j < line.count, line[j] == 125 { candidates.append(j + 1) }
            }
            if p + 1 < line.count, line[p] == LS.backslash, line[p + 1] == LS.backslash { candidates.append(p + 2) }
            if p == 0 { candidates.append(0) }
            for c in candidates {
                let e = run(c)
                if e > c {
                    var group = Array(line[c..<e])
                    var k = 0
                    while k < group.count, LS.isSpace(group[k]) { k += 1 }
                    group.removeFirst(k)
                    return group
                }
            }
        }
        return []
    }

    private func exit(_ scope: LSLatex.Scope) -> Bool {
        let pos = context.pos
        if isMultiline(scope.outerStart, scope.outerEnd) {
            let end = lineEnd(pos)
            guard end < doc.count else { return false }
            let nextStart = end + 1
            let nextEnd = lineEnd(nextStart)
            let next = doc.slice(nextStart, nextEnd)
            var to = nextEnd
            if let at = next.index(of: LS.units("\\end{")) {
                var j = at + 5
                while j < next.count, next[j] != 125 { j += 1 }
                if j < next.count {
                    let name = next.slice(at + 5, j).string
                    if !name.isEmpty, settings.matrixShortcutsEnvironments.contains(name) { to = nextStart + j + 1 }
                }
            }
            setCursor(to)
        } else {
            setCursor(scope.outerEnd)
        }
        return true
    }

    // MARK: Auto-delete $ (latex_suite.ts, autoDelete$)

    /// Backspace between the dollars of an empty `$$` line deletes both. The
    /// plugin asks its tree for a `Dollar` node with nothing before it and
    /// nothing but another `Dollar` after it — true only for the opening run of
    /// a `$$` block that has no content yet (never for inline math, whose empty
    /// content still carries a zero-length LaTeX node).
    private func autoDeleteDollar() -> Bool {
        let pos = main.upperBound
        guard pos > 0, pos < doc.count, doc[pos - 1] == 36, doc[pos] == 36 else { return false }
        let ctx = context
        guard let block = ctx.markdown.displayBlocks.first(where: { $0.open.lowerBound < pos && $0.open.upperBound > pos }),
              block.content.isEmpty, !block.hasMarkers else { return false }
        dispatch(LSChangeSet([LSChange(from: pos - 1, to: pos + 1, insert: [])]))
        tabstops.clear()
        return true
    }
}
