import Foundation
import PDFKit

/// Holds Ultracopy to formulas whose LaTeX is known.
///
///     Scripts/ultracopy-bench/make.sh /tmp/bench          # the PDFs
///     swiftc -O App/Model/MathReader.swift App/Model/MathTranscriber.swift \
///       App/Model/PDFContentScanner.swift App/Model/TeXGlyphNames.swift \
///       Scripts/probe-localized.swift Scripts/ultracopy-bench.swift -o /tmp/bench-read
///     /tmp/bench-read Scripts/ultracopy-bench/formulas.txt /tmp/bench/*.pdf [--show N] [--case N]
///
/// Each page of a bench PDF is one formula, set once inside a sentence and
/// once on its own line. The page is read the way ⌘L reads a selection, and
/// what comes back is compared with the formula's source — structurally, so
/// that `x_{i}` is `x_i` and `\to` is `\rightarrow`, while `x_{ij}` is still
/// not `x_ij`: which glyphs a script holds is the thing being tested.
@main
struct UltracopyBench {
    /// One formula, and what a reading of it may say: the source itself, or
    /// any of the readings after `=>`, separated by `||` (`-` is "nothing":
    /// an upright sans T in a sentence is a letter, and nobody can tell). A
    /// reading written `setup: …` is allowed in that setup only — mathptmx
    /// has no bold maths, so \boldsymbol{\mu} draws the plain μ there.
    struct Case {
        var number: Int
        var source: String
        /// Each allowed reading, and the one setup it is allowed in, if only one.
        var expected: [(setup: String?, reading: String)]
        var displayOnly = false
        func allowed(in setup: String) -> [String] {
            expected.filter { reading in
                guard let names = reading.setup else { return true }
                return names.split(separator: ",").contains { $0 == setup }
            }.map(\.reading)
        }
    }

    @MainActor
    static func main() {
        var arguments = Array(CommandLine.arguments.dropFirst())
        var show = 12
        var onlyCase: Int?
        if let at = arguments.firstIndex(of: "--show"), at + 1 < arguments.count {
            show = Int(arguments[at + 1]) ?? show
            arguments.removeSubrange(at...(at + 1))
        }
        if let at = arguments.firstIndex(of: "--case"), at + 1 < arguments.count {
            onlyCase = Int(arguments[at + 1])
            arguments.removeSubrange(at...(at + 1))
        }
        guard arguments.count >= 2, let text = try? String(contentsOfFile: arguments[0], encoding: .utf8) else {
            print("usage: ultracopy-bench <formulas.txt> <pdf>… [--show N] [--case N]")
            exit(2)
        }
        var cases: [Case] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            // `@display`: set on its own line only, so there is no inline
            // reading to hold it to.
            let displayOnly = trimmed.hasPrefix("@display ")
            let written = displayOnly ? String(trimmed.dropFirst(9)) : trimmed
            let parts = written.components(separatedBy: " => ")
            var expected: [(setup: String?, reading: String)] = [(nil, parts[0])]
            if parts.count > 1 {
                expected = parts[1].components(separatedBy: " || ").map { alternative in
                    var setup: String?
                    var reading = alternative
                    if let match = alternative.range(of: #"^[a-z0-9,-]+: "#, options: .regularExpression) {
                        setup = String(alternative[match].dropLast(2))
                        reading = String(alternative[match.upperBound...])
                    }
                    if reading == "=" { reading = parts[0] }
                    if reading == "-" { reading = "" }
                    return (setup, reading)
                }
            }
            cases.append(Case(number: cases.count + 1, source: parts[0], expected: expected,
                              displayOnly: displayOnly))
        }

        var failuresByCase: [Int: [String]] = [:]
        var totalMatch = 0, totalExact = 0, total = 0
        for path in arguments.dropFirst() {
            guard let document = PDFDocument(url: URL(fileURLWithPath: path)) else { print("!! cannot open \(path)"); continue }
            let setup = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            var matched = 0, exact = 0, count = 0
            var shown = 0
            for index in 0..<min(document.pageCount, cases.count) {
                let one = cases[index]
                if let onlyCase, onlyCase != one.number { continue }
                guard let page = document.page(at: index),
                      let selection = page.selection(for: page.bounds(for: .cropBox)) else { continue }
                let lines = MathReader.structured(from: selection)
                let joined = lines.joined(separator: "\n")
                for (kind, from, to) in [("inline", "Inline:", "end"), ("display", "Display:", "Done")]
                where !(one.displayOnly && kind == "inline") {
                    let read = formula(in: joined, from: from, to: to)
                    count += 1
                    let wants = one.allowed(in: setup).map(Canon.form)
                    let want = wants[0]
                    let got = Canon.form(read)
                    let isExact = squeeze(read) == squeeze(one.source)
                    if isExact { exact += 1 }
                    if wants.contains(got) {
                        matched += 1
                    } else {
                        failuresByCase[one.number, default: []].append("\(setup)/\(kind)")
                        if shown < show || onlyCase != nil {
                            shown += 1
                            print("  ✗ \(setup) #\(one.number) \(kind)")
                            print("      source   \(one.source)")
                            print("      read     \(read)")
                            print("      compared \(want)  ≠  \(got)")
                            if onlyCase != nil { print("      page     \(joined.replacingOccurrences(of: "\n", with: " ⏎ "))") }
                        }
                    }
                }
            }
            totalMatch += matched; totalExact += exact; total += count
            print(String(format: "%@: %d/%d read right (%.1f%%), %d word for word", setup, matched, count, 100 * Double(matched) / Double(max(count, 1)), exact))
        }
        print(String(format: "— all: %d/%d read right (%.1f%%), %d word for word", totalMatch, total, 100 * Double(totalMatch) / Double(max(total, 1)), totalExact))
        if onlyCase == nil {
            print("— formulas read wrong most often:")
            for (number, where_) in failuresByCase.sorted(by: { $0.value.count > $1.value.count }).prefix(40) {
                print(String(format: "  #%-3d %3d× %@", number, where_.count, cases[number - 1].source))
            }
        }
    }

    static func squeeze(_ text: String) -> String { text.filter { !$0.isWhitespace } }

    /// The mathematics the reading put between two marker words.
    static func formula(in text: String, from: String, to: String) -> String {
        guard let start = text.range(of: from) else { return "" }
        let rest = text[start.upperBound...]
        let end = rest.range(of: to)?.lowerBound ?? rest.endIndex
        let span = String(rest[..<end])
        var found: [String] = []
        let pattern = try! NSRegularExpression(pattern: #"\$\$(.+?)\$\$|\$(.+?)\$"#, options: [.dotMatchesLineSeparators])
        for match in pattern.matches(in: span, range: NSRange(span.startIndex..., in: span)) {
            for group in 1...2 {
                if let range = Range(match.range(at: group), in: span) { found.append(String(span[range])) }
            }
        }
        var joined = found.joined(separator: " ")
        if let tag = joined.range(of: #"\\tag\{[^}]*\}"#, options: .regularExpression) { joined.removeSubrange(tag) }
        return joined.trimmingCharacters(in: CharacterSet(charactersIn: " ,."))
    }
}

/// LaTeX read into a small tree and printed back one way, so that two ways of
/// writing the same formula compare equal and two different formulas do not.
enum Canon {
    enum Token: Equatable { case command(String), open, close, sup, sub, prime, char(Character) }

    struct Item { var base: String; var sub: [Item]?; var sup: [Item]?; var primes = 0 }

    static func form(_ latex: String) -> String {
        var parser = Parser(tokens: tokens(latex))
        return print(tidy(parser.sequence()))
    }

    static func tokens(_ text: String) -> [Token] {
        var out: [Token] = []
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            index = text.index(after: index)
            switch character {
            case "\\":
                guard index < text.endIndex else { break }
                if text[index].isLetter {
                    var name = ""
                    while index < text.endIndex, text[index].isLetter { name.append(text[index]); index = text.index(after: index) }
                    out.append(.command(name))
                } else {
                    out.append(.command(String(text[index])))
                    index = text.index(after: index)
                }
            case "{": out.append(.open)
            case "}": out.append(.close)
            case "^": out.append(.sup)
            case "_": out.append(.sub)
            case "'": out.append(.prime)
            case " ", "\t", "\n", "~": continue
            default: out.append(.char(character))
            }
        }
        return out
    }

    static let dropped: Set<String> = [
        "left", "right", "big", "Big", "bigg", "Bigg", "bigl", "bigr", "Bigl", "Bigr", "biggl", "biggr",
        "Biggl", "Biggr", "middle", "displaystyle", "textstyle", "scriptstyle", "quad", "qquad",
        "limits", "nolimits", ",", ";", ":", "!", " ", "enspace", "thinspace", "medspace", "thickspace",
    ]
    static let synonyms: [String: String] = [
        "to": "rightarrow", "gets": "leftarrow", "le": "leq", "ge": "geq", "ne": "neq",
        // One bar is `|`, whatever it is called; two bars are `\|`.
        "lbrace": "{", "rbrace": "}", "lvert": "vertbar", "rvert": "vertbar", "vert": "vertbar",
        "mid": "vertbar", "lVert": "|", "rVert": "|", "Vert": "|",
        "dots": "ldots", "dotsc": "ldots", "dotsb": "cdots",
        "land": "wedge", "lor": "vee", "lnot": "neg", "iff": "Longleftrightarrow",
        "implies": "Longrightarrow", "colon": ":", "bm": "boldsymbol", "mathscr": "mathcal",
        "dfrac": "frac", "tfrac": "frac", "dbinom": "binom", "tbinom": "binom", "backslash": "setminus",
        "varnothing": "emptyset", "intercal": "top", "lparen": "(", "rparen": ")",
        "mathbfit": "boldsymbol", "symbf": "mathbf", "symbfit": "boldsymbol", "mathup": "mathrm",
        // eulervm draws \leq as the slanted ⩽, and the page cannot tell them apart.
        "leqslant": "leq", "geqslant": "geq",
    ]
    static let operatorNames: Set<String> = [
        "log", "ln", "lg", "exp", "sin", "cos", "tan", "cot", "sec", "csc", "sinh", "cosh", "tanh",
        "coth", "arcsin", "arccos", "arctan", "min", "max", "inf", "sup", "lim", "liminf", "limsup",
        "det", "dim", "ker", "deg", "gcd", "hom", "arg", "Pr", "argmin", "argmax",
    ]
    static let styles: Set<String> = [
        "mathbf", "boldsymbol", "mathcal", "mathbb", "mathfrak", "mathsf", "mathtt", "mathit",
    ]
    static let uprightInBold: Set<String> = [
        "\\Gamma", "\\Delta", "\\Theta", "\\Lambda", "\\Xi", "\\Pi", "\\Sigma", "\\Upsilon",
        "\\Phi", "\\Psi", "\\Omega",
    ]
    static let upright: Set<String> = ["mathrm", "text", "textrm", "textnormal", "operatorname", "mathup", "textup"]
    static let arity: [String: Int] = [
        "begin": 1, "end": 1,
        "frac": 2, "binom": 2, "overset": 2, "underset": 2, "sqrt": 1, "hat": 1, "bar": 1, "tilde": 1,
        "vec": 1, "dot": 1, "ddot": 1, "dddot": 1, "mathring": 1, "check": 1, "acute": 1, "grave": 1, "breve": 1, "widehat": 1,
        "widetilde": 1, "overline": 1, "underline": 1, "mathbf": 1, "boldsymbol": 1, "mathcal": 1,
        "mathbb": 1, "mathfrak": 1, "mathsf": 1, "mathtt": 1, "mathit": 1, "tag": 1,
    ]

    struct Parser {
        var tokens: [Token]
        var at = 0

        mutating func next() -> Token? { at < tokens.count ? tokens[at] : nil }

        mutating func sequence() -> [Item] {
            var items: [Item] = []
            while let token = next() {
                if token == .close { return items }
                at += 1
                switch token {
                case .sup, .sub:
                    let script = argument()
                    if items.isEmpty { items.append(Item(base: "")) }
                    if token == .sup {
                        items[items.count - 1].sup = (items[items.count - 1].sup ?? []) + script
                    } else {
                        items[items.count - 1].sub = (items[items.count - 1].sub ?? []) + script
                    }
                case .prime:
                    if items.isEmpty { items.append(Item(base: "")) }
                    items[items.count - 1].primes += 1
                default:
                    items += atom(token)
                }
            }
            return items
        }

        mutating func argument() -> [Item] {
            guard let token = next() else { return [] }
            at += 1
            if token == .open {
                let inner = sequence()
                if next() == .close { at += 1 }
                return inner
            }
            return atom(token)
        }

        mutating func atom(_ token: Token) -> [Item] {
            switch token {
            case .open:
                let inner = sequence()
                if next() == .close { at += 1 }
                if (next() == .sup || next() == .sub), inner.count > 1 {
                    return [Item(base: "{" + Canon.print(Canon.tidy(inner)) + "}")]
                }
                return inner
            case .char(let character):
                return [Item(base: String(character))]
            case .command(var name):
                if Canon.dropped.contains(name) { return [] }
                name = Canon.synonyms[name] ?? name
                if name == "{" || name == "}" { return [Item(base: "\\" + name)] }
                if name == "vertbar" { return [Item(base: "|")] }
                if name == "|" { return [Item(base: "\\|")] }
                if name.count == 1, !name.first!.isLetter { return [Item(base: name == "|" ? "|" : name)] }
                if name == "prime" { return [Item(base: "\\prime")] }
                if Canon.operatorNames.contains(name) { return [Item(base: "\\text{\(name)}")] }
                if Canon.upright.contains(name) {
                    if next() == .char("*") { at += 1 }
                    let inner = Canon.print(Canon.tidy(argument()))
                    return [Item(base: "\\text{\(inner)}")]
                }
                var optional = ""
                if name == "sqrt", next() == .char("[") {
                    at += 1
                    var inside: [Token] = []
                    while let token = next(), token != .char("]") { inside.append(token); at += 1 }
                    at += 1
                    var sub = Parser(tokens: inside)
                    optional = "[" + Canon.print(Canon.tidy(sub.sequence())) + "]"
                }
                // A style wraps each symbol it holds: `\mathbf{Wy}` is
                // `\mathbf{W}\mathbf{y}`, which is how the page draws it.
                if Canon.styles.contains(name) {
                    let inner = Canon.tidy(argument())
                    guard inner.allSatisfy({ $0.sub == nil && $0.sup == nil && $0.primes == 0 }) else {
                        return [Item(base: "\\" + name + "{" + Canon.print(inner) + "}")]
                    }
                    return inner.map { item in
                        // A bold capital Greek letter or digit is upright
                        // either way: \boldsymbol and \mathbf draw the same.
                        let upright = Canon.uprightInBold.contains(item.base)
                            || (item.base.count == 1 && item.base.first!.isNumber)
                        let style = name == "boldsymbol" && upright ? "mathbf" : name
                        return Item(base: "\\" + style + "{" + item.base + "}")
                    }
                }
                if let count = Canon.arity[name] {
                    var text = "\\" + name + optional
                    for _ in 0..<count { text += "{" + Canon.print(Canon.tidy(argument())) + "}" }
                    return [Item(base: text)]
                }
                return [Item(base: "\\" + name)]
            default:
                return []
            }
        }
    }

    static func tidy(_ items: [Item]) -> [Item] {
        var out: [Item] = []
        for var item in items {
            if let sup = item.sup, !sup.isEmpty, sup.allSatisfy({ $0.base == "\\prime" && $0.sub == nil && $0.sup == nil }) {
                item.primes += sup.count
                item.sup = nil
            }
            // An upright single letter reads as the letter: the page draws
            // "d" and a reading that says "d" has it.
            if item.base.hasPrefix("\\text{"), item.base.count == 8 { item.base = String(item.base.dropFirst(6).prefix(1)) }
            if let last = out.last, last.sub == nil, last.sup == nil, last.primes == 0,
               last.base.hasPrefix("\\text{"), item.base.hasPrefix("\\text{") {
                out[out.count - 1].base = String(last.base.dropLast()) + String(item.base.dropFirst(6))
                out[out.count - 1].sub = item.sub
                out[out.count - 1].sup = item.sup
                out[out.count - 1].primes = item.primes
                continue
            }
            out.append(item)
        }
        return out
    }

    static func print(_ items: [Item]) -> String {
        items.map { item in
            var text = item.base + String(repeating: "'", count: item.primes)
            if let sub = item.sub { text += "_" + wrap(sub) }
            if let sup = item.sup { text += "^" + wrap(sup) }
            return text
        }.joined()
    }

    static func wrap(_ items: [Item]) -> String {
        let tidied = tidy(items)
        let text = print(tidied)
        if tidied.count == 1, tidied[0].sub == nil, tidied[0].sup == nil, tidied[0].primes == 0 { return text }
        return "{" + text + "}"
    }
}
