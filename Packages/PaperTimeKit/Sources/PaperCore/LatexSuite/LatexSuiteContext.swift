import Foundation

/// A math region of the note (mathbounds.ts, `MathBounds`).
struct LSBound: Equatable {
    enum Mode: Equatable { case inline, block, code }

    var outerStart: Int
    var innerStart: Int
    var innerEnd: Int
    var outerEnd: Int
    var mode: Mode
    /// The text the LaTeX parser runs over, and the container prefixes inside
    /// it that are not part of the equation. Nil when there is no tree.
    var tree: Range<Int>?
    var blanks: [Range<Int>] = []

    static func == (a: LSBound, b: LSBound) -> Bool {
        a.outerStart == b.outerStart && a.innerStart == b.innerStart && a.innerEnd == b.innerEnd &&
            a.outerEnd == b.outerEnd && a.mode == b.mode
    }
}

/// Where the caret is, as Latex Suite's `Context` works it out
/// (context.ts, `updateFromView`), for one document and one selection.
final class LSContext {
    let doc: LSUnits
    let selection: [Range<Int>]
    let library: LSLibrary
    let forceMathLanguages: [String]
    /// The main selection's end: where the mode is read.
    let pos: Int
    private(set) var mode = LSMode()
    let markdown: LSMarkdown
    let bounds: [LSBound]
    private var trees: [Int: LSLatex] = [:]

    init(doc: LSUnits, selection: [Range<Int>], library: LSLibrary, forceMathLanguages: [String]) {
        self.doc = doc
        self.selection = selection
        self.library = library
        self.forceMathLanguages = forceMathLanguages
        pos = selection[0].upperBound
        let low = selection.map(\.lowerBound).min() ?? 0
        let high = selection.map(\.upperBound).max() ?? 0
        markdown = LSMarkdown(doc, window: Swift.max(0, low - 2)...(high + 2))
        bounds = Self.mathBounds(markdown, forceMathLanguages: forceMathLanguages)
        computeMode()
    }

    // MARK: Math bounds

    private static func mathBounds(_ md: LSMarkdown, forceMathLanguages: [String]) -> [LSBound] {
        var out: [LSBound] = []
        for block in md.displayBlocks {
            // getDollarBounds: the closing delimiter is the block's last child
            // when that is a `Dollar` — which, in a block with nothing after its
            // opening `$$`, is the opening delimiter itself.
            let close = block.close ?? (block.content.isEmpty && !block.hasMarkers ? block.open : block.to..<block.to)
            var bound = LSBound(outerStart: block.open.lowerBound, innerStart: block.open.upperBound,
                                innerEnd: close.lowerBound, outerEnd: close.upperBound, mode: .block)
            if let first = block.content.first, let last = block.content.last {
                bound.tree = first.lowerBound..<last.upperBound
                bound.blanks = gaps(block.content)
            }
            out.append(bound)
        }
        for math in md.inlineMath {
            out.append(LSBound(outerStart: math.from, innerStart: math.open.upperBound, innerEnd: math.close.lowerBound,
                               outerEnd: math.to, mode: math.display ? .block : .inline,
                               tree: math.open.upperBound..<math.close.lowerBound))
        }
        for fence in md.fences {
            guard let info = fence.info, forceMathLanguages.contains(md.text(info, in: nil)),
                  let first = fence.codeText.first, let last = fence.codeText.last else { continue }
            out.append(LSBound(outerStart: fence.from, innerStart: first.lowerBound, innerEnd: last.upperBound,
                               outerEnd: fence.to, mode: .code, tree: first.lowerBound..<last.upperBound,
                               blanks: gaps(fence.codeText)))
        }
        return out.sorted { $0.outerStart < $1.outerStart }
    }

    private static func gaps(_ ranges: [Range<Int>]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        for k in 1..<Swift.max(1, ranges.count) where ranges[k - 1].upperBound < ranges[k].lowerBound {
            out.append(ranges[k - 1].upperBound..<ranges[k].lowerBound)
        }
        return out
    }

    /// `inMathBound`, including its binary search and its special case: a caret
    /// between (or right before) the two dollars of a `$$` delimiter is an empty
    /// inline equation — that is how `$|$` alone on a line works.
    func bound(at pos: Int) -> LSBound? {
        guard let first = bounds.first, let last = bounds.last else { return nil }
        if pos < first.outerStart || pos > last.outerEnd { return nil }
        var left = 0
        var right = bounds.count - 1
        while left <= right {
            let mid = (left + right) >> 1
            let b = bounds[mid]
            if pos < b.outerStart {
                right = mid - 1
            } else if pos >= b.outerEnd && b.outerEnd != b.innerEnd {
                left = mid + 1
            } else if pos < b.innerStart && b.mode == .block && b.innerStart - b.outerStart == 2 {
                return LSBound(outerStart: b.outerStart, innerStart: b.outerStart + 1, innerEnd: b.outerStart + 1,
                               outerEnd: b.outerStart + 2, mode: .inline, tree: nil)
            } else if pos < b.innerStart || pos > b.innerEnd {
                break
            } else {
                return b
            }
        }
        return nil
    }

    func latex(for bound: LSBound) -> LSLatex? {
        guard let tree = bound.tree else { return nil }
        if let cached = trees[bound.outerStart] { return cached }
        let latex = LSLatex(doc: doc, range: tree, blanks: bound.blanks, symbols: library.symbols,
                            environmentClasses: library.environmentClasses)
        trees[bound.outerStart] = latex
        return latex
    }

    /// `getEnvNames`: the scope stack at `pos`, innermost first. The walk
    /// goes on past the equation's own tree into the Markdown one, so inline
    /// `$…$` ends the stack with a `math` entry of its own.
    func scopes(at pos: Int) -> [LSLatex.Scope] {
        guard let bound = bound(at: pos), let latex = latex(for: bound) else { return [] }
        var scopes = latex.scopes(at: pos)
        if bound.mode == .inline, bound.outerStart < pos, bound.outerEnd > pos {
            scopes.append(LSLatex.Scope(kind: .math, name: "", argumentIndex: 0, innerStart: bound.innerStart,
                                        innerEnd: bound.innerEnd, outerStart: bound.outerStart, outerEnd: bound.outerEnd))
        }
        return scopes
    }

    // MARK: Mode

    private func computeMode() {
        var mode = LSMode()
        // Code blocks and inline code come from the editor's own tree in
        // Obsidian. The rule used here is the one the fixtures were made with:
        // a *closed* fence, after its opening line and not past the start of
        // its closing line; inline code when the caret is after an opening
        // backtick and at most right after the closing one.
        let codeInfo = codeBlockLanguage(at: selection.map(\.lowerBound).min() ?? pos)
        let inCodeBlock = codeInfo != nil
        mode.code = inCodeBlock ? false : inInlineCode(pos)
        let forceMath = inCodeBlock && forceMathLanguages.contains(codeInfo!)
        mode.codeMath = forceMath
        mode.codeBlock = inCodeBlock && !forceMath ? .language(codeInfo!) : .no
        let inMath = bound(at: pos)
        if let inMath {
            mode.blockMath = inMath.mode == .block
            mode.inlineMath = inMath.mode == .inline
            switch textEnvironment(at: pos) {
            case "text": mode.textEnv = true
            case "none": mode.snippetlessEnv = true
            default: break
            }
        }
        mode.text = !inCodeBlock && inMath == nil
        self.mode = mode
    }

    private func lineStart(_ p: Int) -> Int {
        var i = Swift.min(p, doc.count)
        while i > 0, doc[i - 1] != LS.newline { i -= 1 }
        return i
    }

    private func lineEnd(_ p: Int) -> Int {
        var i = Swift.max(0, p)
        while i < doc.count, doc[i] != LS.newline { i += 1 }
        return i
    }

    private func codeBlockLanguage(at pos: Int) -> String? {
        for fence in markdown.fences where fence.from < pos && fence.to >= pos {
            guard let close = fence.closeMark else { return nil }
            if pos <= lineEnd(fence.from) || pos > lineStart(close.lowerBound) { return nil }
            guard let info = fence.info else { return "" }
            let text = markdown.text(info, in: doc)
            return String(text.split(separator: " ", omittingEmptySubsequences: false).first ?? "")
        }
        return nil
    }

    private func inInlineCode(_ pos: Int) -> Bool {
        markdown.inlineCode.contains { $0.lowerBound < pos && $0.upperBound >= pos }
    }

    /// `inTextEnvironment`: "text" inside a text macro, "none" inside a
    /// snippet-less one, nil otherwise.
    private func textEnvironment(at pos: Int) -> String? {
        guard let scope = withinMacros(pos, LSContext.allTextAreas) else { return nil }
        return LSContext.snippetlessAreas.contains { $0.name == scope.name } ? "none" : "text"
    }

    /// `isWithinMacros`: the first listed macro on the way out, stopping at a
    /// nested equation and walking past environments.
    func withinMacros(_ pos: Int, _ macros: [LSData.MacroArea]) -> LSLatex.Scope? {
        for scope in scopes(at: pos) {
            switch scope.kind {
            case .environment: continue
            case .math: return nil
            case .command:
                if Self.matches(scope, macros) { return scope }
            }
        }
        return nil
    }

    /// `isMacroArgumentCount`.
    static func matches(_ scope: LSLatex.Scope, _ macros: [LSData.MacroArea]) -> Bool {
        guard let macro = macros.first(where: { $0.name == scope.name }) else { return false }
        guard let arguments = macro.arguments else { return true }
        return arguments.contains(scope.argumentIndex)
    }

    /// default_text_areas.ts.
    static let textAreas: [LSData.MacroArea] = ["text", "textrm", "textup", "textit", "textbf", "textsf", "texttt",
                                                "textnormal", "clap", "textllap", "textrlap", "textclap", "hbox",
                                                "mbox", "fbox", "framebox"].map { LSData.MacroArea(name: $0) }
    static let snippetlessAreas: [LSData.MacroArea] = [
        LSData.MacroArea(name: "tag"), LSData.MacroArea(name: "begin"), LSData.MacroArea(name: "end"),
        LSData.MacroArea(name: "mmlToken"), LSData.MacroArea(name: "unicode"),
        LSData.MacroArea(name: "textcolor", arguments: [0]), LSData.MacroArea(name: "color"),
        LSData.MacroArea(name: "colorbox"), LSData.MacroArea(name: "fcolorbox"),
    ]
    static let allTextAreas = textAreas + snippetlessAreas

    // MARK: Bounds for the features

    /// `getBounds()` at the main caret: the equation it is in.
    var equation: LSBound? { bound(at: pos) }

    /// `getInnerEquationBounds`, including its quirk: it searches the
    /// equation's text for `$` with the caret's *document* offset, so outside
    /// the first lines of a note it finds nothing and returns the equation.
    func innerEquation() -> (innerStart: Int, innerEnd: Int)? {
        if mode.codeMath {
            guard let b = equation else { return nil }
            return (b.innerStart, b.innerEnd)
        }
        guard let b = bound(at: pos) else { return nil }
        var text = doc.slice(b.innerStart, b.innerEnd)
        var i = 0
        while i + 1 < text.count {
            if text[i] == LS.backslash && text[i + 1] == 36 { text[i + 1] = 82 }
            i += 1
        }
        guard let left = text.lastIndex(of: [36], from: pos - 1), let right = text.index(of: [36], from: pos) else {
            return (b.innerStart, b.innerEnd)
        }
        return (left + 1, right)
    }

    /// `isWithinEnvironment` for one `[open, close]` pair of
    /// `autofractionExcludedEnvs`.
    func isWithinEnvironment(_ position: Int, open: LSUnits, close: LSUnits) -> Bool {
        guard mode.inMath, let bounds = innerEquation() else { return false }
        let start = bounds.innerStart
        let text = bounds.innerEnd > start ? doc.slice(start, bounds.innerEnd) : []
        let pos = position - start
        guard let openBracket = open.last else { return false }
        let closeBracket: UInt16? = openBracket == 123 ? 125 : openBracket == 91 ? 93 : openBracket == 40 ? 41 : nil
        let offset: Int
        let search: LSUnits
        if let closeBracket, close == [closeBracket] {
            offset = open.count - 1
            search = [openBracket]
        } else {
            offset = 0
            search = open
        }
        var left = text.lastIndex(of: open, from: pos - 1)
        while let l = left {
            guard let right = LSText.matchingBracket(text, from: l + offset, open: search, close: close) else { return false }
            if right >= pos && pos >= l + open.count { return true }
            if l <= 0 { return false }
            left = text.lastIndex(of: open, from: l - 1)
        }
        return false
    }
}

enum LSText {
    /// `findMatchingBracket(text, start, open, close, false)`.
    static func matchingBracket(_ text: LSUnits, from start: Int, open: LSUnits, close: LSUnits) -> Int? {
        var depth = 0
        var i = Swift.max(0, start)
        while i < text.count {
            if text.hasPrefix(open, at: i) {
                depth += 1
            } else if text.hasPrefix(close, at: i) {
                depth -= 1
                if depth == 0 { return i }
            }
            i += 1
        }
        return nil
    }

    /// The same, backwards from a closing bracket at `start` (single characters).
    static func matchingBracketBackwards(_ text: LSUnits, from start: Int, open: UInt16, close: UInt16) -> Int? {
        var depth = 0
        var i = start
        while i >= 0 {
            if text[i] == close {
                depth += 1
            } else if text[i] == open {
                depth -= 1
                if depth == 0 { return i }
            }
            i -= 1
        }
        return nil
    }
}

extension LSMarkdown {
    func text(_ range: Range<Int>, in doc: LSUnits?) -> String {
        (doc ?? source).slice(range.lowerBound, range.upperBound).string
    }
}
