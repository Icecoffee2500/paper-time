import Foundation

/// The structure of one equation, as far as Latex Suite asks about it.
///
/// Latex Suite parses every equation with a lezer LaTeX grammar (adapted from
/// Overleaf's) and asks the tree two things: which constructs enclose a
/// position — the *scope stack*, which decides `\text{}` (text mode inside
/// math), `\begin{…}` and `\color{…}` (no snippets), `\ce{}`/`\pu{}`
/// exclusions and matrix shortcuts — and which brackets pair, which decides
/// what auto-enlarge rewrites. This is a recursive-descent reading of the same
/// grammar that answers only those two questions. Where the input is broken
/// (an unclosed brace, a stray `\end`), it recovers the way the LR parser was
/// observed to: an unclosed construct runs to the end of the equation, a
/// closer that belongs further out ends everything inside it, and a closer
/// nothing is waiting for is skipped.
struct LSLatex {
    enum Kind: Equatable {
        case root
        /// A `{…}` or `[…]` argument of `command` (lezer: every node whose
        /// name ends in `Argument`), `index` counting the arguments before it.
        case argument(command: String, index: Int, bracket: Bool)
        /// `\begin{name}` / `\end{name}`'s name group; a command scope named
        /// `begin`/`end`.
        case envName(owner: String)
        case environment(name: String)
        case content
        /// A plain `{…}` group.
        case group
        /// `$…$` or `\(…\)` nested in text.
        case math(paren: Bool)
        /// `\left… \right…`.
        case delimited
        /// A command and its arguments: transparent for both questions.
        case command
    }

    enum Token: Equatable {
        case control      // \name or \symbol
        case paren(open: Bool)
        case bracketOpen
        case bracketClose
        case braceClose   // a `}` nothing was waiting for
    }

    enum Item {
        case node(Int)
        case token(Token, Range<Int>)
    }

    struct Node {
        var kind: Kind
        var from: Int
        var to: Int
        var closed = false
        var items: [Item] = []
        /// For `.delimited`: the `\left…` and `\right…` spans.
        var opening: Range<Int>?
        var closing: Range<Int>?
        var parent: Int
        /// For environments: whether the content started (the begin part was complete).
        var hasContent = false
        var nameRange: Range<Int>?
        var contentRange: Range<Int>?
        /// False for an argument that is a bare command or number (`\hat\alpha`).
        var braced = true
    }

    /// One entry of the scope stack (context.ts, `getEnvNameFromNode`).
    struct Scope: Equatable {
        enum Kind: Equatable { case command, environment, math }
        var kind: Kind
        var name: String
        var argumentIndex: Int
        var innerStart: Int
        var innerEnd: Int
        var outerStart: Int
        var outerEnd: Int
    }

    let doc: LSUnits
    private(set) var nodes: [Node]
    /// Every control sequence token, by where it ends: what `resolveInner(pos, -1)`
    /// finds when a bracket follows a command directly.
    private(set) var controlEnding: [Int: Range<Int>] = [:]

    init(doc: LSUnits, range: Range<Int>, blanks: [Range<Int>], symbols: Set<String>,
         environmentClasses: [String: String] = [:]) {
        var text = doc.slice(range.lowerBound, range.upperBound)
        for blank in blanks {
            for i in blank where i >= range.lowerBound && i < range.upperBound { text[i - range.lowerBound] = 32 }
        }
        self.doc = doc
        var parser = Parser(s: text, base: range.lowerBound, end: range.upperBound, symbols: symbols,
                            environmentClasses: environmentClasses)
        parser.i = range.lowerBound
        parser.nodes = [Node(kind: .root, from: range.lowerBound, to: range.upperBound, parent: -1)]
        _ = parser.parseList(parent: 0, mode: .math)
        nodes = parser.nodes
        controlEnding = parser.controls
    }

    // MARK: Questions

    /// The scope stack at `pos`, innermost first: every construct that starts
    /// before `pos` and ends after it.
    func scopes(at pos: Int) -> [Scope] {
        var chain: [Int] = []
        var current = 0
        descend: while true {
            for item in nodes[current].items {
                if case let .node(index) = item, nodes[index].from < pos, nodes[index].to > pos {
                    chain.append(index)
                    current = index
                    continue descend
                }
            }
            break
        }
        var result: [Scope] = []
        for index in chain.reversed() {
            let node = nodes[index]
            switch node.kind {
            case let .argument(command, argIndex, _):
                result.append(Scope(kind: .command, name: command, argumentIndex: argIndex,
                                    innerStart: node.from + 1, innerEnd: node.closed ? node.to - 1 : node.to,
                                    outerStart: node.from, outerEnd: node.to))
            case let .envName(owner):
                result.append(Scope(kind: .command, name: owner, argumentIndex: 0,
                                    innerStart: node.from + 1, innerEnd: node.closed ? node.to - 1 : node.to,
                                    outerStart: node.from, outerEnd: node.to))
            case let .environment(name):
                guard node.hasContent, let content = node.contentRange else { continue }
                result.append(Scope(kind: .environment, name: name, argumentIndex: 0,
                                    innerStart: content.lowerBound, innerEnd: content.upperBound,
                                    outerStart: node.from, outerEnd: node.to))
            case let .math(paren):
                guard node.closed else { continue }
                let delimiter = paren ? 2 : 1
                result.append(Scope(kind: .math, name: "", argumentIndex: 0,
                                    innerStart: node.from + delimiter, innerEnd: node.to - delimiter,
                                    outerStart: node.from, outerEnd: node.to))
            default:
                continue
            }
        }
        return result
    }

    struct Pair {
        var open: Range<Int>
        var close: Range<Int>
    }

    /// Every bracket pair of the equation, nested ones included, in the order
    /// highlight_brackets.ts walks them (a pair before its contents).
    func pairs() -> [Pair] {
        var out: [Pair] = []
        walk(Pairing.pair(specs(of: nodes[0].items)), into: &out)
        return out
    }

    private func walk(_ list: [Pairing.Paired], into out: inout [Pair]) {
        for p in list {
            if p.kind == .bracket, let close = p.close { out.append(Pair(open: p.open, close: close)) }
            walk(p.children, into: &out)
        }
    }

    /// Whether the token right before `pos` is a control word — the check
    /// auto-enlarge makes to leave `\big(` and friends alone.
    func controlWord(endingAt pos: Int) -> String? {
        guard let range = controlEnding[pos], range.count > 1, LS.isASCIILetter(Int(doc[range.lowerBound + 1])) else { return nil }
        return doc.slice(range.lowerBound, range.upperBound).string
    }

    // MARK: Bracket specs (traverseTree)

    private func text(_ range: Range<Int>) -> String { doc.slice(range.lowerBound, range.upperBound).string }

    private func specs(of items: [Item]) -> [Pairing.Spec] {
        var out: [Pairing.Spec] = []
        var i = 0
        while i < items.count {
            switch items[i] {
            case let .token(kind, range):
                switch kind {
                case .control:
                    let name = text(range)
                    if Pairing.opening[name] != nil {
                        out.append(.open(name, range))
                    } else if Pairing.closing[name] != nil {
                        out.append(.close(name, range))
                    }
                case let .paren(open):
                    out.append(open ? .open("(", range) : .close(")", range))
                case .bracketOpen:
                    // lezer pairs `[` with the next `]` among its siblings.
                    if let j = items[(i + 1)...].firstIndex(where: {
                        if case .token(.bracketClose, _) = $0 { return true } else { return false }
                    }), case let .token(_, closeRange) = items[j] {
                        out.append(.bracket(open: range, close: closeRange, specs(of: Array(items[(i + 1)..<j]))))
                        i = j
                    } else {
                        out.append(.open("[", range))
                        out += specs(of: Array(items[(i + 1)...]))
                        return out
                    }
                case .bracketClose:
                    out.append(.close("]", range))
                case .braceClose:
                    out.append(.close("}", range))
                }
            case let .node(index):
                let node = nodes[index]
                switch node.kind {
                case .group, .argument, .envName, .math(paren: true):
                    guard node.braced else {
                        out += specs(of: node.items)
                        break
                    }
                    let isParen: Bool
                    if case .math = node.kind { isParen = true } else { isParen = false }
                    var isBracket = false
                    if case let .argument(_, _, bracket) = node.kind { isBracket = bracket }
                    let openWidth = isParen ? 2 : 1
                    let open = node.from..<(node.from + openWidth)
                    if node.closed {
                        out.append(.bracket(open: open, close: (node.to - openWidth)..<node.to, specs(of: node.items)))
                    } else {
                        out.append(.open(isParen ? "\\(" : isBracket ? "[" : "{", open))
                        out += specs(of: node.items)
                    }
                case .delimited:
                    if node.closed, let opening = node.opening, let closing = node.closing {
                        out.append(.bracket(open: opening, close: closing, specs(of: node.items)))
                    } else {
                        out += specs(of: node.items)
                    }
                default:
                    out += specs(of: node.items)
                }
            }
            i += 1
        }
        return out
    }

    // MARK: The parser

    private enum Mode { case math, text }
    private enum Closer: Equatable { case brace, bracket, end, right, dollar, paren }
    private enum Stop: Equatable { case end, closer(Closer) }

    private struct Parser {
        /// The equation's text, container prefixes blanked; `s[0]` is at `base`.
        let s: LSUnits
        let base: Int
        let end: Int
        let symbols: Set<String>
        let environmentClasses: [String: String]
        var i = 0
        var nodes: [Node] = []
        var closers: [Closer] = []
        var controls: [Int: Range<Int>] = [:]

        init(s: LSUnits, base: Int, end: Int, symbols: Set<String>, environmentClasses: [String: String]) {
            self.s = s
            self.base = base
            self.end = end
            self.symbols = symbols
            self.environmentClasses = environmentClasses
        }

        @inline(__always) func c(_ k: Int) -> Int { k < end && k >= base ? Int(s[k - base]) : -1 }

        func string(_ from: Int, _ to: Int) -> String { s.slice(from - base, to - base).string }

        mutating func add(_ node: Node) -> Int {
            nodes.append(node)
            let index = nodes.count - 1
            nodes[node.parent].items.append(.node(index))
            return index
        }

        mutating func token(_ kind: Token, _ range: Range<Int>, parent: Int) {
            nodes[parent].items.append(.token(kind, range))
            if kind == .control { controls[range.upperBound] = range }
        }

        /// A control sequence at `i`: its end and, for a control word, its name.
        func control(at k: Int) -> (end: Int, name: String?) {
            if LS.isASCIILetter(c(k + 1)) {
                var j = k + 1
                while LS.isASCIILetter(c(j)) { j += 1 }
                return (j, string(k + 1, j))
            }
            return (Swift.min(k + 2, end), nil)
        }

        func skipBlanks(_ k: Int) -> Int {
            var j = k
            while c(j) == 32 || c(j) == 9 { j += 1 }
            return j
        }

        /// Whether a closer `kind` should end the current construct (someone
        /// is waiting for it) or be skipped as stray.
        func expects(_ kind: Closer) -> Bool { closers.contains(kind) }

        mutating func skipComment() {
            while i < end, c(i) != 10 { i += 1 }
            if i < end { i += 1 }
        }

        /// Reads elements into `parent` until the end or a closer someone expects.
        mutating func parseList(parent: Int, mode: Mode) -> Stop {
            while i < end {
                let ch = c(i)
                switch ch {
                case 92:
                    if let stop = parseControl(parent: parent, mode: mode) { return stop }
                case 123:
                    parseBraced(kind: .group, parent: parent, mode: mode)
                case 125:
                    if expects(.brace) { return .closer(.brace) }
                    token(.braceClose, i..<(i + 1), parent: parent)
                    i += 1
                case 91:
                    token(.bracketOpen, i..<(i + 1), parent: parent)
                    i += 1
                case 93:
                    if expects(.bracket) { return .closer(.bracket) }
                    token(.bracketClose, i..<(i + 1), parent: parent)
                    i += 1
                case 36:
                    if expects(.dollar) { return .closer(.dollar) }
                    if mode == .text {
                        parseMathInText(parent: parent, paren: false)
                    } else {
                        i += 1
                    }
                case 37:
                    skipComment()
                case 40, 41:
                    if mode == .math { token(.paren(open: ch == 40), i..<(i + 1), parent: parent) }
                    i += 1
                default:
                    i += 1
                }
            }
            return .end
        }

        /// A control sequence and whatever it opens. Returns a stop when the
        /// sequence is a closer someone is waiting for.
        mutating func parseControl(parent: Int, mode: Mode) -> Stop? {
            let start = i
            let (cEnd, name) = control(at: i)
            guard let name else {
                let sym = c(start + 1)
                if sym == 40 && mode == .text { // \(
                    parseMathInText(parent: parent, paren: true)
                    return nil
                }
                if sym == 41 && expects(.paren) { return .closer(.paren) }
                token(.control, start..<cEnd, parent: parent)
                i = cEnd
                if sym == 92 && c(i) == 91 { // \\[…]
                    parseBraced(kind: .argument(command: "\\", index: 0, bracket: true), parent: parent, mode: .text, bracket: true)
                }
                return nil
            }
            switch name {
            case "begin":
                parseEnvironment(parent: parent)
                return nil
            case "end":
                if expects(.end) { return .closer(.end) }
                i = cEnd // a stray \end: its name group is read as an ordinary group
                return nil
            case "left":
                if mode == .math {
                    parseDelimited(parent: parent)
                    return nil
                }
            case "right":
                if expects(.right) { return .closer(.right) }
            default:
                break
            }
            let command = add(Node(kind: .command, from: start, to: cEnd, parent: parent))
            token(.control, start..<cEnd, parent: command)
            i = cEnd
            parseArguments(of: name, command: command, mode: mode)
            nodes[command].to = i
            return nil
        }

        /// The arguments the grammar gives `name` (latex.grammar, KnownCommand
        /// and the unknown-command rules).
        mutating func parseArguments(of name: String, command: Int, mode: Mode) {
            if symbols.contains(name) || name == "left" || name == "right" { return }
            var index = 0
            func argument(_ kind: Mode, bracket: Bool = false) {
                parseBraced(kind: .argument(command: name, index: index, bracket: bracket), parent: command, mode: kind, bracket: bracket)
                index += 1
            }
            let argumentMode: Mode = mode
            switch name {
            case "text", "tag", "textrm":
                i = skipBlanks(i)
                if c(i) == 42 { i += 1 }
                if c(i) == 123 { argument(.text) }
            case "textbf", "textit", "texttt", "textsf", "textup", "textnormal", "clap", "textclap",
                 "textllap", "textrlap", "mbox", "fbox", "framebox", "fcolorbox":
                if c(i) == 123 { argument(.text) }
            case "hbox":
                i = skipBlanks(i)
                if c(i) == 123 { argument(.text) }
            case "textcolor", "colorbox":
                i = skipBlanks(i)
                guard c(i) == 123 else { return }
                argument(.text)
                i = skipBlanks(i)
                typedArgument(argumentMode, &index, name, command)
            case "emph", "underline":
                typedArgument(argumentMode, &index, name, command)
            case "label":
                i = skipBlanks(i)
                if c(i) == 123 { wrappedArgument(name, &index, command) }
            case "ref", "eqref":
                if name == "ref" && c(i) == 42 { i += 1 }
                for _ in 0..<2 {
                    let k = skipBlanks(i)
                    if c(k) == 91 {
                        i = k
                        argument(.text, bracket: true)
                    }
                }
                i = skipBlanks(i)
                if c(i) == 123 { wrappedArgument(name, &index, command) }
            case "newcommand", "renewcommand", "newenvironment", "renewenvironment":
                // The name (a control word, or `{…}` taken literally) is not an
                // argument node; the optional arguments and the definitions are.
                i = skipBlanks(i)
                if c(i) == 92 {
                    i += 1
                    while LS.isASCIILetter(c(i)) || c(i) == 64 { i += 1 }
                } else if c(i) == 123 {
                    while i < end, c(i) != 125 { i += 1 }
                    if i < end { i += 1 }
                } else {
                    return
                }
                for _ in 0..<2 where c(i) == 91 { argument(.text, bracket: true) }
                for _ in 0..<(name.hasSuffix("environment") ? 2 : 1) {
                    var k = i
                    if c(k) == 10 { k += 1 }
                    k = skipBlanks(k)
                    guard c(k) == 123 else { return }
                    i = k
                    argument(.text)
                }
            case "def":
                i = skipBlanks(i)
                guard c(i) == 92 else { return }
                i = control(at: i).end
                while true {
                    let k = skipBlanks(i)
                    if c(k) == 35 && c(k + 1) >= 49 && c(k + 1) <= 57 {
                        i = k + 2
                    } else if c(k) == 91 && c(k + 1) == 35 && c(k + 3) == 93 {
                        i = k + 4
                    } else {
                        break
                    }
                }
                var k = skipBlanks(i)
                if c(k) == 10 { k = skipBlanks(k + 1) }
                if c(k) == 123 {
                    i = k
                    argument(.text)
                }
            case "let":
                return
            case "href":
                i = skipBlanks(i)
                if c(i) == 123 {
                    // UrlArgument: its content is taken literally, up to `}`.
                    let from = i
                    var j = i + 1
                    while j < end, c(j) != 125 { j += 1 }
                    let closed = j < end
                    let to = closed ? j + 1 : end
                    _ = add(Node(kind: .argument(command: name, index: index, bracket: false), from: from, to: to, closed: closed, parent: command))
                    index += 1
                    i = to
                    if c(i) == 123 { argument(.text) }
                }
            case "verb":
                if c(i) == 42 { i += 1 }
                let delimiter = c(i)
                guard delimiter >= 0, !LS.isSpace(delimiter), delimiter != 42 else { return }
                var j = i + 1
                while j < end, c(j) != 10 {
                    if c(j) == delimiter {
                        i = j + 1
                        return
                    }
                    j += 1
                }
            case "hline", "toprule", "midrule", "bottomrule":
                i = skipBlanks(i)
            default:
                if mode == .math {
                    while true {
                        let k = skipBlanks(i)
                        guard c(k) == 123 else { break }
                        i = k
                        argument(.math)
                    }
                } else {
                    var k = i
                    if c(k) == 32 || c(k) == 9 { k = skipBlanks(k) }
                    guard c(k) == 123 || c(k) == 91 else { return }
                    i = k
                    while c(i) == 123 || c(i) == 91 {
                        argument(.text, bracket: c(i) == 91)
                    }
                }
            }
        }

        /// `\label{…}`, `\ref{…}`: an argument node around a `ShortTextArgument`
        /// node. The inner one reads as a command scope too, named after its own
        /// text past the brace (context.ts takes the parent's first child as
        /// the command) — a name nothing matches, kept for the stack's sake.
        mutating func wrappedArgument(_ name: String, _ index: inout Int, _ command: Int) {
            var outerNode = Node(kind: .argument(command: name, index: index, bracket: false), from: i, to: i, parent: command)
            outerNode.braced = false
            let outer = add(outerNode)
            index += 1
            let inner = nodes.count
            parseBraced(kind: .argument(command: "", index: 0, bracket: false), parent: outer, mode: .text)
            nodes[inner].kind = .argument(command: string(nodes[inner].from + 1, nodes[inner].to), index: 0, bracket: false)
            nodes[outer].to = nodes[inner].to
            nodes[outer].closed = nodes[inner].closed
        }

        /// A `MathArgument` (or `TextArgument` in text): braces, or a single
        /// command or number standing in for them.
        mutating func typedArgument(_ mode: Mode, _ index: inout Int, _ name: String, _ command: Int) {
            if c(i) == 123 {
                parseBraced(kind: .argument(command: name, index: index, bracket: false), parent: command, mode: mode)
                index += 1
            } else if mode == .math, c(i) == 92 || LS.isDigit(c(i)) {
                let from = i
                var bare = Node(kind: .argument(command: name, index: index, bracket: false), from: from, to: from, parent: command)
                bare.braced = false
                let arg = add(bare)
                index += 1
                if c(i) == 92 {
                    _ = parseControl(parent: arg, mode: .math)
                } else {
                    while LS.isDigit(c(i)) { i += 1 }
                    if c(i) == 46 {
                        i += 1
                        while LS.isDigit(c(i)) { i += 1 }
                    }
                }
                nodes[arg].to = i
                nodes[arg].closed = true
            }
        }

        /// `{…}` (or `[…]`) at `i`: a group or an argument.
        mutating func parseBraced(kind: Kind, parent: Int, mode: Mode, bracket: Bool = false) {
            let from = i
            let node = add(Node(kind: kind, from: from, to: end, parent: parent))
            i += 1
            let closer: Closer = bracket ? .bracket : .brace
            closers.append(closer)
            let stop = parseList(parent: node, mode: mode)
            closers.removeLast()
            if stop == .closer(closer) {
                i += 1
                nodes[node].to = i
                nodes[node].closed = true
            } else {
                nodes[node].to = stop == .end ? end : i
            }
        }

        /// `$…$` or `\(…\)` inside a text argument.
        mutating func parseMathInText(parent: Int, paren: Bool) {
            let from = i
            let node = add(Node(kind: .math(paren: paren), from: from, to: end, parent: parent))
            i += paren ? 2 : 1
            let closer: Closer = paren ? .paren : .dollar
            closers.append(closer)
            let stop = parseList(parent: node, mode: .math)
            closers.removeLast()
            if stop == .closer(closer) {
                i += paren ? 2 : 1
                nodes[node].to = i
                nodes[node].closed = true
            } else {
                nodes[node].to = stop == .end ? end : i
            }
        }

        /// `\begin{name}[opt]{arg}… content \end{name}`.
        mutating func parseEnvironment(parent: Int) {
            let start = i
            let (beginEnd, _) = control(at: i)
            let env = add(Node(kind: .environment(name: ""), from: start, to: end, parent: parent))
            token(.control, start..<beginEnd, parent: env)
            i = beginEnd
            guard c(i) == 123 else {
                nodes[env].to = i
                return
            }
            guard let name = parseNameGroup(owner: "begin", parent: env) else {
                nodes[env].to = end
                return
            }
            nodes[env].kind = .environment(name: name)
            var index = 0
            if c(i) == 91 {
                let arg = nodes.count
                parseBraced(kind: .argument(command: "begin", index: index, bracket: true), parent: env, mode: .text, bracket: true)
                index += 1
                if !nodes[arg].closed {
                    nodes[env].to = nodes[arg].to
                    return
                }
            }
            while c(i) == 123 {
                let arg = nodes.count
                parseBraced(kind: .argument(command: "begin", index: index, bracket: false), parent: env, mode: .text)
                index += 1
                if !nodes[arg].closed {
                    // The begin part never finished, so there is no environment.
                    nodes[env].to = nodes[arg].to
                    return
                }
            }
            let content = add(Node(kind: .content, from: i, to: end, parent: env))
            nodes[env].hasContent = true
            closers.append(.end)
            let stop = parseList(parent: content, mode: .math)
            closers.removeLast()
            nodes[content].to = stop == .end ? end : i
            nodes[env].contentRange = nodes[content].from..<nodes[content].to
            if stop == .closer(.end) {
                let (endEnd, _) = control(at: i)
                token(.control, i..<endEnd, parent: env)
                i = endEnd
                if c(i) == 123 {
                    // How the LR parser's error recovery reads an `\end{…}`
                    // whose name is not a clean match (observed from the
                    // plugin; this is what decides whether the name is
                    // snippet-less while it is being retyped). Held directly
                    // by another environment, any name is taken whole.
                    // Otherwise: an environment whose name has a class of its
                    // own (`pmatrix`, `equation`…) ends right after `\end{`
                    // unless the name starts with one of the same class (or is
                    // empty); a generic one ends right after the name's letters
                    // when a character follows that starts another token.
                    let open = i
                    let first = skipBlanks(open + 1)
                    var k = first
                    while LS.isASCIILetter(c(k)) { k += 1 }
                    if k > first, c(k) == 42 { k += 1 }
                    if nodes[parent].kind != .content {
                        if let kind = environmentClasses[name] {
                            if c(first) != 125, environmentClasses[string(first, k)] != kind {
                                i = open + 1
                                nodes[env].to = i
                                nodes[env].closed = true
                                return
                            }
                        } else if k > first, Self.breaksName(c(k)) {
                            let group = add(Node(kind: .envName(owner: "end"), from: open, to: k, parent: env))
                            nodes[group].nameRange = (open + 1)..<k
                            i = k
                            nodes[env].to = i
                            nodes[env].closed = true
                            return
                        }
                    }
                    _ = parseNameGroup(owner: "end", parent: env)
                }
                nodes[env].to = i
                nodes[env].closed = true
            } else {
                nodes[env].to = stop == .end ? end : i
            }
        }

        /// A character that starts a token of its own after an environment
        /// name's letters (latex.grammar: Number, Whitespace, MathSpecialChar,
        /// the script signs, `&`, `~`, brackets and braces). Observed from the
        /// plugin, like the exception: a second `*` does not.
        static func breaksName(_ ch: Int) -> Bool {
            switch ch {
            case 48...57, 32, 9, 10, 13, 95, 94, 61, 60, 62, 40, 41, 45, 43, 47, 38, 126, 91, 93, 123: return true
            default: return false
            }
        }

        /// `{name}` after `\begin`/`\end`: read literally up to `}`.
        mutating func parseNameGroup(owner: String, parent: Int) -> String? {
            let from = i
            var j = i + 1
            while j < end, c(j) != 125 { j += 1 }
            let closed = j < end
            let to = closed ? j + 1 : end
            let group = add(Node(kind: .envName(owner: owner), from: from, to: to, closed: closed, parent: parent))
            nodes[group].nameRange = (from + 1)..<j
            i = to
            return closed ? string(from + 1, j) : nil
        }

        /// `\left<delim> … \right<delim>`.
        mutating func parseDelimited(parent: Int) {
            let start = i
            let node = add(Node(kind: .delimited, from: start, to: end, parent: parent))
            let (leftEnd, _) = control(at: i)
            i = skipBlanks(leftEnd)
            i = delimiterEnd(i) ?? i
            nodes[node].opening = start..<i
            closers.append(.right)
            let stop = parseList(parent: node, mode: .math)
            closers.removeLast()
            if stop == .closer(.right) {
                let closeStart = i
                let (rightEnd, _) = control(at: i)
                i = skipBlanks(rightEnd)
                i = delimiterEnd(i) ?? i
                nodes[node].closing = closeStart..<i
                nodes[node].to = i
                nodes[node].closed = true
            } else {
                nodes[node].to = stop == .end ? end : i
            }
        }

        /// latex.grammar's MathDelimiter.
        func delimiterEnd(_ k: Int) -> Int? {
            let ch = c(k)
            if [47, 124, 40, 41, 91, 93, 60, 62, 46].contains(ch) { return k + 1 }
            guard ch == 92 else { return nil }
            let (e, name) = control(at: k)
            if let name {
                let allowed: Set<String> = ["lfloor", "rfloor", "lceil", "rceil", "langle", "rangle", "backslash", "uparrow",
                                            "Uparrow", "Downarrow", "updownarrow", "Updownarrow", "downarrow", "lvert", "lVert",
                                            "rVert", "rvert", "vert", "Vert", "lbrace", "rbrace", "lbrack", "rbrack", "lt", "gt"]
                return allowed.contains(name) ? e : nil
            }
            let sym = c(k + 1)
            return sym == 123 || sym == 125 || sym == 124 ? k + 2 : nil
        }
    }
}

/// highlight_brackets.ts: `pairBrackets` over the specs `traverseTree` makes.
enum Pairing {
    /// `bracket_delimiters`, verbatim — including its two oddities: `[` is
    /// listed as closing with `}`, and `\langle ` carries a trailing space, so
    /// `\langle … \rangle` never pairs.
    static let pairs: [(String, String)] = [
        ("{", "}"), ("[", "}"), ("(", ")"), ("\\{", "\\}"), ("\\left<", "\\right>"), ("\\langle ", "\\rangle"),
        ("\\lvert", "\\rvert"), ("\\lVert", "\\rVert"), ("\\right\\lt", "\\right\\gt"), ("\\lbrace", "\\rbrace"),
        ("\\lbrack", "\\rbrack"), ("\\lceil", "\\rceil"), ("\\lfloor", "\\rfloor"), ("\\lgroup", "\\rgroup"),
        ("\\llcorner", "\\lrcorner"), ("\\lmoustache", "\\rmoustache"), ("\\lparen", "\\rparen"),
    ]
    static let opening: [String: String] = Dictionary(pairs.map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
    /// `Object.fromEntries` of the reversed pairs: a later entry wins, so `}` → `[`.
    static let closing: [String: String] = Dictionary(pairs.map { ($0.1, $0.0) }, uniquingKeysWith: { _, b in b })

    enum Spec {
        case open(String, Range<Int>)
        case close(String, Range<Int>)
        case bracket(open: Range<Int>, close: Range<Int>, [Spec])
    }

    enum Kind { case open, close, bracket }

    final class Paired {
        var kind: Kind
        var bracket: String
        var open: Range<Int>
        var close: Range<Int>?
        var children: [Paired] = []
        weak var parent: Paired?
        init(kind: Kind, bracket: String, open: Range<Int>, close: Range<Int>?) {
            self.kind = kind
            self.bracket = bracket
            self.open = open
            self.close = close
        }
    }

    static func pair(_ specs: [Spec]) -> [Paired] {
        var paired: [Paired] = []
        var parent: Paired?
        var stack: [Paired] = []
        for spec in specs {
            switch spec {
            case let .open(bracket, range):
                let p = Paired(kind: .open, bracket: bracket, open: range, close: nil)
                p.parent = parent
                if let parent { parent.children.append(p) } else { paired.append(p) }
                stack.append(p)
                parent = p
            case let .close(bracket, range):
                let wanted = closing[bracket]
                if let wanted, let index = stack.lastIndex(where: { $0.bracket == wanted }) {
                    let open = stack[index]
                    stack.removeSubrange(index...)
                    open.kind = .bracket
                    open.close = range
                    parent = open.parent
                } else {
                    let p = Paired(kind: .close, bracket: bracket, open: range, close: nil)
                    p.parent = parent
                    if let parent { parent.children.append(p) } else { paired.append(p) }
                }
            case let .bracket(open, close, children):
                let p = Paired(kind: .bracket, bracket: "", open: open, close: close)
                p.parent = parent
                if let parent { parent.children.append(p) } else { paired.append(p) }
                for child in pair(children) {
                    child.parent = p
                    p.children.append(child)
                }
            }
        }
        return paired
    }
}
