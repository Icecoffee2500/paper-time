#if os(macOS)
import Foundation

extension MathTypesetter {
    /// Reads LaTeX into something that can be set.
    ///
    /// It knows the mathematics people write in notes — symbols, scripts,
    /// fractions, roots, sums with limits, accents, brackets that grow — and
    /// what kind of thing each symbol is, because that is what decides the
    /// spacing around it.
    struct Parser {
        private let characters: [Character]
        private var index = 0

        init(source: String) {
            characters = Array(source)
        }

        mutating func parseSequence(until terminator: Character?) -> Node {
            var parts: [Node] = []
            while index < characters.count {
                let character = characters[index]
                if let terminator, character == terminator {
                    index += 1
                    break
                }
                if character == "^" || character == "_" {
                    index += 1
                    let script = parseAtom()
                    let base = parts.popLast() ?? .empty
                    parts.append(attach(script, to: base, superscript: character == "^"))
                    continue
                }
                if character == "\\", peekCommand() == "right" { break }
                guard let atom = parseAtomOrNil() else { break }
                parts.append(atom)
            }
            if parts.count == 1 { return parts[0] }
            return .sequence(parts)
        }

        /// Adds a script to whatever it followed, keeping any script already
        /// there — `x_i^2` is one atom with both.
        private func attach(_ script: Node, to base: Node, superscript: Bool) -> Node {
            switch base {
            case .scripted(let inner, let sup, let sub):
                return .scripted(
                    base: inner,
                    sup: superscript ? script : sup,
                    sub: superscript ? sub : script
                )
            case .bigOperator(let symbol, let sup, let sub):
                return .bigOperator(
                    symbol,
                    sup: superscript ? script : sup,
                    sub: superscript ? sub : script
                )
            default:
                return .scripted(
                    base: base,
                    sup: superscript ? script : nil,
                    sub: superscript ? nil : script
                )
            }
        }

        private mutating func parseAtom() -> Node {
            parseAtomOrNil() ?? .empty
        }

        private mutating func parseAtomOrNil() -> Node? {
            guard index < characters.count else { return nil }
            let character = characters[index]

            switch character {
            case "{":
                index += 1
                return parseSequence(until: "}")
            case "}":
                index += 1
                return nil
            case " ", "\n", "\t":
                index += 1
                return .space(0)
            case "\\":
                return parseCommand()
            default:
                index += 1
                if character.isLetter {
                    return .symbols(Alphabet.italic(character), .ord)
                }
                if character.isNumber {
                    var digits = String(character)
                    while index < characters.count,
                          characters[index].isNumber || characters[index] == "." {
                        digits.append(characters[index])
                        index += 1
                    }
                    return .symbols(digits, .ord)
                }
                let drawn = Self.punctuation[character].map(String.init) ?? String(character)
                return .symbols(drawn, Self.classOf(drawn))
            }
        }

        /// The name of the command at the cursor, without consuming it.
        private func peekCommand() -> String? {
            guard index < characters.count, characters[index] == "\\" else { return nil }
            var at = index + 1
            var name = ""
            while at < characters.count, characters[at].isLetter {
                name.append(characters[at])
                at += 1
            }
            return name.isEmpty ? nil : name
        }

        private mutating func parseCommand() -> Node {
            index += 1  // the backslash
            guard index < characters.count else { return .empty }
            if !characters[index].isLetter {
                let symbol = characters[index]
                index += 1
                switch symbol {
                case ",": return .space(3.0 / 18)
                case ":", ">": return .space(4.0 / 18)
                case ";": return .space(5.0 / 18)
                case "!": return .space(-3.0 / 18)
                case " ": return .space(6.0 / 18)
                case "\\": return .space(0)
                case "|": return .symbols("‖", .ord)
                default: return .symbols(String(symbol), Self.classOf(String(symbol)))
                }
            }

            var name = ""
            while index < characters.count, characters[index].isLetter {
                name.append(characters[index])
                index += 1
            }

            switch name {
            case "frac", "dfrac", "tfrac", "cfrac":
                let top = parseGroup()
                let bottom = parseGroup()
                return .fraction(top, bottom)
            case "sqrt":
                skipOptionalArgument()
                return .radical(parseGroup())
            case "left":
                let open = parseDelimiter()
                let body = parseSequence(until: nil)
                var close: String?
                if peekCommand() == "right" {
                    index += 6  // "\right"
                    close = parseDelimiter()
                }
                return .delimited(open, body, close)
            case "right":
                index += 0
                _ = parseDelimiter()
                return .empty
            case "text", "textrm", "mathrm", "operatorname", "mathsf", "mathtt":
                return .symbols(plainGroup(), .ord)
            case "mathbf", "bm":
                return .symbols(Alphabet.map(plainGroup(), .bold), .ord)
            case "boldsymbol", "mathbfit":
                return .symbols(Alphabet.map(plainGroup(), .boldItalic), .ord)
            case "mathit":
                return .symbols(Alphabet.map(plainGroup(), .italic), .ord)
            case "mathcal", "mathscr":
                return .symbols(Alphabet.map(plainGroup(), .script), .ord)
            case "mathbb":
                return .symbols(Alphabet.map(plainGroup(), .blackboard), .ord)
            case "mathfrak":
                return .symbols(Alphabet.map(plainGroup(), .fraktur), .ord)
            case "big", "Big", "bigg", "Bigg", "bigl", "Bigl", "bigr", "Bigr",
                 "displaystyle", "textstyle", "limits", "nolimits", "!":
                return .empty
            case "tag":
                // The number beside a displayed equation. A renderer with a
                // margin to work to would push it out there; here it follows
                // the formula after a gap, which is what it looks like.
                return .sequence([.space(2), .symbols("(" + plainGroup() + ")", .ord)])
            case "quad": return .space(1)
            case "qquad": return .space(2)
            case "hat", "widehat": return .accent("\u{02C6}", parseGroup())
            case "tilde", "widetilde": return .accent("\u{02DC}", parseGroup())
            case "bar", "overline": return .accent("\u{00AF}", parseGroup())
            case "dot": return .accent("\u{02D9}", parseGroup())
            case "ddot": return .accent("\u{00A8}", parseGroup())
            case "check": return .accent("\u{02C7}", parseGroup())
            case "acute": return .accent("\u{00B4}", parseGroup())
            case "grave": return .accent("\u{0060}", parseGroup())
            case "vec": return .accent("\u{2192}", parseGroup())
            default:
                if let big = Self.bigOperators[name] {
                    return .bigOperator(big, sup: nil, sub: nil)
                }
                if let word = Self.operatorNames[name] {
                    return .symbols(word, .op)
                }
                if let symbol = Self.symbols[name] {
                    return .symbols(symbol, Self.classOf(symbol))
                }
                if let greek = Self.greek[name] {
                    return .symbols(Alphabet.map(greek, .italic), .ord)
                }
                return .symbols(name, .ord)
            }
        }

        /// The delimiter after `\left` or `\right`. A full stop means none.
        private mutating func parseDelimiter() -> String? {
            while index < characters.count, characters[index] == " " { index += 1 }
            guard index < characters.count else { return nil }
            if characters[index] == "\\" {
                guard let name = peekCommand() else {
                    index += 2
                    return nil
                }
                index += 1 + name.count
                if name == "." { return nil }
                return Self.symbols[name] ?? name
            }
            let symbol = characters[index]
            index += 1
            if symbol == "." { return nil }
            return Self.punctuation[symbol].map(String.init) ?? String(symbol)
        }

        private mutating func skipOptionalArgument() {
            guard index < characters.count, characters[index] == "[" else { return }
            while index < characters.count, characters[index] != "]" { index += 1 }
            if index < characters.count { index += 1 }
        }

        private mutating func parseGroup() -> Node {
            while index < characters.count, characters[index] == " " { index += 1 }
            guard index < characters.count else { return .empty }
            if characters[index] == "{" {
                index += 1
                return parseSequence(until: "}")
            }
            return parseAtom()
        }

        /// A group read as plain letters, for `\text{…}` and its relatives.
        private mutating func plainGroup() -> String {
            while index < characters.count, characters[index] == " " { index += 1 }
            guard index < characters.count else { return "" }
            guard characters[index] == "{" else {
                if characters[index] == "\\" {
                    let name = peekCommand() ?? ""
                    index += 1 + name.count
                    return Self.greek[name] ?? Self.symbols[name] ?? name
                }
                let single = characters[index]
                index += 1
                return String(single)
            }
            index += 1
            var text = ""
            var depth = 1
            while index < characters.count {
                let character = characters[index]
                index += 1
                if character == "{" { depth += 1 }
                if character == "}" {
                    depth -= 1
                    if depth == 0 { break }
                }
                if character == "\\" {
                    var name = ""
                    while index < characters.count, characters[index].isLetter {
                        name.append(characters[index])
                        index += 1
                    }
                    text += Self.greek[name] ?? Self.symbols[name] ?? name
                    continue
                }
                text.append(character)
            }
            return text
        }

        // MARK: What kind of thing a symbol is

        static func classOf(_ symbol: String) -> Class {
            if relations.contains(symbol) { return .rel }
            if binaries.contains(symbol) { return .bin }
            if openings.contains(symbol) { return .open }
            if closings.contains(symbol) { return .close }
            if punctuations.contains(symbol) { return .punct }
            return .ord
        }

        static let relations: Set<String> = [
            "=", "<", ">", "≤", "≥", "≠", "≈", "∼", "≃", "≅", "≡", "∝", "≪", "≫",
            "∈", "∉", "∋", "⊂", "⊆", "⊃", "⊇", "⊏", "⊑", "→", "←", "↔", "⇒", "⇐",
            "⇔", "↦", "⊢", "⊨", "≜", "≐", "≺", "≻", "⪯", "⪰", "∥", ":=",
        ]
        static let binaries: Set<String> = [
            "+", "−", "×", "÷", "±", "∓", "∗", "⋆", "∘", "·", "∪", "∩", "∖",
            "⊕", "⊖", "⊗", "⊘", "⊙", "⊔", "⊓", "∧", "∨", "†", "‡", "⋅",
        ]
        static let openings: Set<String> = ["(", "[", "{", "⟨", "⌊", "⌈"]
        static let closings: Set<String> = [")", "]", "}", "⟩", "⌋", "⌉"]
        static let punctuations: Set<String> = [",", ";"]

        /// What a typed character is drawn as: a hyphen is a minus sign, an
        /// apostrophe is a prime.
        static let punctuation: [Character: Character] = [
            "-": "−", "*": "∗", "'": "′",
        ]

        static let bigOperators: [String: String] = [
            "sum": "∑", "prod": "∏", "coprod": "∐", "int": "∫", "iint": "∬",
            "iiint": "∭", "oint": "∮", "bigcup": "⋃", "bigcap": "⋂",
            "bigoplus": "⨁", "bigotimes": "⨂", "bigvee": "⋁", "bigwedge": "⋀",
            "lim": "lim", "max": "max", "min": "min", "sup": "sup", "inf": "inf",
            "argmax": "arg max", "argmin": "arg min", "limsup": "lim sup",
            "liminf": "lim inf",
        ]

        static let operatorNames: [String: String] = [
            "log": "log", "ln": "ln", "lg": "lg", "exp": "exp", "sin": "sin",
            "cos": "cos", "tan": "tan", "cot": "cot", "sec": "sec", "csc": "csc",
            "sinh": "sinh", "cosh": "cosh", "tanh": "tanh", "arcsin": "arcsin",
            "arccos": "arccos", "arctan": "arctan", "det": "det", "dim": "dim",
            "ker": "ker", "deg": "deg", "gcd": "gcd", "hom": "hom", "Pr": "Pr",
            "arg": "arg", "mod": "mod", "bmod": "mod",
        ]

        static let greek: [String: String] = [
            "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ϵ",
            "varepsilon": "ε", "zeta": "ζ", "eta": "η", "theta": "θ",
            "vartheta": "ϑ", "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ",
            "nu": "ν", "xi": "ξ", "omicron": "ο", "pi": "π", "varpi": "ϖ",
            "rho": "ρ", "varrho": "ϱ", "sigma": "σ", "varsigma": "ς", "tau": "τ",
            "upsilon": "υ", "phi": "ϕ", "varphi": "φ", "chi": "χ", "psi": "ψ",
            "omega": "ω",
            "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ",
            "Pi": "Π", "Sigma": "Σ", "Upsilon": "Υ", "Phi": "Φ", "Psi": "Ψ",
            "Omega": "Ω",
        ]

        static let symbols: [String: String] = [
            "times": "×", "cdot": "·", "cdots": "⋯", "ldots": "…", "dots": "…",
            "vdots": "⋮", "ddots": "⋱", "div": "÷", "pm": "±", "mp": "∓",
            "ast": "∗", "star": "⋆", "circ": "∘", "bullet": "∙", "dagger": "†",
            "leq": "≤", "le": "≤", "geq": "≥", "ge": "≥", "neq": "≠", "ne": "≠",
            "approx": "≈", "sim": "∼", "simeq": "≃", "cong": "≅", "equiv": "≡",
            "propto": "∝", "ll": "≪", "gg": "≫", "prec": "≺", "succ": "≻",
            "preceq": "⪯", "succeq": "⪰", "triangleq": "≜", "doteq": "≐",
            "in": "∈", "notin": "∉", "ni": "∋", "subset": "⊂", "subseteq": "⊆",
            "supset": "⊃", "supseteq": "⊇", "sqsubseteq": "⊑", "cup": "∪",
            "cap": "∩", "setminus": "∖", "emptyset": "∅", "varnothing": "∅",
            "forall": "∀", "exists": "∃", "nexists": "∄", "neg": "¬", "lnot": "¬",
            "land": "∧", "wedge": "∧", "lor": "∨", "vee": "∨",
            "rightarrow": "→", "to": "→", "leftarrow": "←", "gets": "←",
            "leftrightarrow": "↔", "Rightarrow": "⇒", "Leftarrow": "⇐",
            "Leftrightarrow": "⇔", "mapsto": "↦", "implies": "⇒", "iff": "⇔",
            "uparrow": "↑", "downarrow": "↓", "nearrow": "↗", "searrow": "↘",
            "infty": "∞", "partial": "∂", "nabla": "∇", "hbar": "ℏ", "ell": "ℓ",
            "Re": "ℜ", "Im": "ℑ", "aleph": "ℵ", "prime": "′", "degree": "°",
            "angle": "∠", "triangle": "△", "square": "□", "surd": "√",
            "langle": "⟨", "rangle": "⟩", "lfloor": "⌊", "rfloor": "⌋",
            "lceil": "⌈", "rceil": "⌉", "lbrace": "{", "rbrace": "}",
            "vert": "|", "mid": "∣", "Vert": "‖", "lVert": "‖", "rVert": "‖",
            "|": "‖", "parallel": "∥", "perp": "⊥", "top": "⊤", "bot": "⊥",
            "vdash": "⊢", "models": "⊨", "oplus": "⊕", "ominus": "⊖",
            "otimes": "⊗", "oslash": "⊘", "odot": "⊙", "sqcup": "⊔",
            "sqcap": "⊓", "colon": ":", "cdotp": "·", "backslash": "\\",
            "%": "%", "&": "&", "#": "#", "$": "$", "_": "_", "{": "{", "}": "}",
        ]
    }

    /// The Unicode alphabets a maths font draws its letters from.
    ///
    /// A variable is not a letter in italics — it is a different character,
    /// with its own shape and spacing, and asking the font for it is the whole
    /// difference between a formula that looks set and one that looks typed.
    enum Alphabet {
        case italic, bold, boldItalic, script, blackboard, fraktur

        static func italic(_ character: Character) -> String {
            map(String(character), .italic)
        }

        static func map(_ text: String, _ alphabet: Alphabet) -> String {
            String(String.UnicodeScalarView(text.unicodeScalars.map {
                alphabet.scalar(for: $0)
            }))
        }

        private func scalar(for scalar: Unicode.Scalar) -> Unicode.Scalar {
            let value = scalar.value
            if let exception = Self.exceptions[self]?[scalar] { return exception }
            switch self {
            case .italic:
                if let base = offset(value, "A", "Z", 0x1D434) { return base }
                if let base = offset(value, "a", "z", 0x1D44E) { return base }
                // Capital Greek stays upright, as TeX leaves it.
                if let base = offset(value, 0x03B1, 0x03C9, 0x1D6FC) { return base }
            case .bold:
                if let base = offset(value, "A", "Z", 0x1D400) { return base }
                if let base = offset(value, "a", "z", 0x1D41A) { return base }
                if let base = offset(value, "0", "9", 0x1D7CE) { return base }
                if let base = offset(value, 0x0391, 0x03A9, 0x1D6A8) { return base }
                if let base = offset(value, 0x03B1, 0x03C9, 0x1D6C2) { return base }
            case .boldItalic:
                if let base = offset(value, "A", "Z", 0x1D468) { return base }
                if let base = offset(value, "a", "z", 0x1D482) { return base }
                if let base = offset(value, "0", "9", 0x1D7CE) { return base }
                if let base = offset(value, 0x0391, 0x03A9, 0x1D71C) { return base }
                if let base = offset(value, 0x03B1, 0x03C9, 0x1D736) { return base }
            case .script:
                if let base = offset(value, "A", "Z", 0x1D49C) { return base }
                if let base = offset(value, "a", "z", 0x1D4B6) { return base }
            case .blackboard:
                if let base = offset(value, "A", "Z", 0x1D538) { return base }
                if let base = offset(value, "a", "z", 0x1D552) { return base }
                if let base = offset(value, "0", "9", 0x1D7D8) { return base }
            case .fraktur:
                if let base = offset(value, "A", "Z", 0x1D504) { return base }
                if let base = offset(value, "a", "z", 0x1D51E) { return base }
            }
            return scalar
        }

        private func offset(
            _ value: UInt32, _ from: Unicode.Scalar, _ to: Unicode.Scalar, _ base: UInt32
        ) -> Unicode.Scalar? {
            offset(value, from.value, to.value, base)
        }

        private func offset(
            _ value: UInt32, _ from: UInt32, _ to: UInt32, _ base: UInt32
        ) -> Unicode.Scalar? {
            guard value >= from, value <= to else { return nil }
            return Unicode.Scalar(base + (value - from))
        }

        /// The letters Unicode gave a home of their own before it laid the
        /// alphabets out, so the run they belong to has a hole where they were.
        private static let exceptions: [Alphabet: [Unicode.Scalar: Unicode.Scalar]] = [
            .italic: [
                "h": "\u{210E}",
                // The variant letters Unicode keeps outside the Greek run.
                "\u{2202}": "\u{1D715}", "\u{03F5}": "\u{1D716}",
                "\u{03D1}": "\u{1D717}", "\u{03F0}": "\u{1D718}",
                "\u{03D5}": "\u{1D719}", "\u{03F1}": "\u{1D71A}",
                "\u{03D6}": "\u{1D71B}",
            ],
            .boldItalic: [
                "\u{2202}": "\u{1D74F}", "\u{03F5}": "\u{1D750}",
                "\u{03D1}": "\u{1D751}", "\u{03F0}": "\u{1D752}",
                "\u{03D5}": "\u{1D753}", "\u{03F1}": "\u{1D754}",
                "\u{03D6}": "\u{1D755}",
            ],
            .bold: [
                "\u{2202}": "\u{1D6DB}", "\u{03F5}": "\u{1D6DC}",
                "\u{03D1}": "\u{1D6DD}", "\u{03F0}": "\u{1D6DE}",
                "\u{03D5}": "\u{1D6DF}", "\u{03F1}": "\u{1D6E0}",
                "\u{03D6}": "\u{1D6E1}",
            ],
            .script: [
                "B": "\u{212C}", "E": "\u{2130}", "F": "\u{2131}", "H": "\u{210B}",
                "I": "\u{2110}", "L": "\u{2112}", "M": "\u{2133}", "R": "\u{211B}",
                "e": "\u{212F}", "g": "\u{210A}", "o": "\u{2134}",
            ],
            .blackboard: [
                "C": "\u{2102}", "H": "\u{210D}", "N": "\u{2115}", "P": "\u{2119}",
                "Q": "\u{211A}", "R": "\u{211D}", "Z": "\u{2124}",
            ],
            .fraktur: [
                "C": "\u{212D}", "H": "\u{210C}", "I": "\u{2111}", "R": "\u{211C}",
                "Z": "\u{2128}",
            ],
        ]
    }
}
#endif
