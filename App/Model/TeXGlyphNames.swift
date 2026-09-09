import Foundation

/// What a TeX font calls its glyphs, and what that is in LaTeX.
///
/// A paper set in TeX draws from fonts whose glyph names are the names of the
/// commands that produced them: `summationdisplay` came from `\sum`, `bardbl`
/// from `\|`, `phi` from `\phi`. Reading those names back is the closest thing
/// there is to reading the author's source.
///
/// Where a font does not name its glyphs, the standard encodings do: Computer
/// Modern's maths italic and symbol fonts have had the same layout since 1979.
enum TeXGlyphNames {
    /// The LaTeX for a glyph, given its name and the font it came from.
    ///
    /// The order matters. A name the font gave the glyph is the truth. Failing
    /// that, a font that says it draws text means the encoding it declares —
    /// TeX ships fonts called CMSY10 that are re-encoded to MacRoman, and
    /// reading those through Computer Modern's own table turns a vertical bar
    /// into a club suit. Only a symbolic font, which keeps its own encoding,
    /// is read through the Computer Modern tables.
    static func latex(
        name: String?, code: Int, fontName: String, unicode: String?, isSymbolic: Bool = true
    ) -> String? {
        guard let resolved = resolve(
            name: name, code: code, fontName: fontName, unicode: unicode, isSymbolic: isSymbolic
        ) else { return nil }
        // Computer Modern's symbol font holds no upright letters: the only
        // Latin alphabet in it is the calligraphic one. An encoding written
        // for text calls that glyph "N", and it is drawn as a script N, so
        // that is what it has to be written down as.
        if resolved.count == 1, resolved.first?.isLetter == true,
           isCalligraphic(fontName: fontName) {
            return "\\mathcal{\(resolved)}"
        }
        return resolved
    }

    private static func resolve(
        name: String?, code: Int, fontName: String, unicode: String?, isSymbolic: Bool
    ) -> String? {
        if let name, let command = byName[name] { return command }
        if let name, name.count == 1 { return name }
        if !isSymbolic, let unicode, !unicode.isEmpty { return unicode }
        if let command = standardEncoding(code: code, fontName: fontName) { return command }
        if let unicode, !unicode.isEmpty { return unicode }
        return nil
    }

    private static func isCalligraphic(fontName: String) -> Bool {
        let family = (fontName.split(separator: "+").last.map(String.init) ?? fontName).uppercased()
        return family.hasPrefix("CMSY") || family.hasPrefix("CMBSY")
    }

    /// True when this glyph is a large operator that takes limits above and
    /// below rather than beside.
    static func isBigOperator(_ name: String?) -> Bool {
        guard let name else { return false }
        return name.hasPrefix("summation") || name.hasPrefix("product")
            || name.hasPrefix("integral") || name.hasPrefix("union")
            || name.hasPrefix("intersection") || name.hasPrefix("coproduct")
            || name.hasPrefix("logicaland") || name.hasPrefix("logicalor")
    }

    static func openingDelimiter(_ name: String?) -> String? {
        guard let name else { return nil }
        if name.hasPrefix("parenleft") { return "(" }
        if name.hasPrefix("bracketleft") { return "[" }
        if name.hasPrefix("braceleft") { return "\\{" }
        if name.hasPrefix("angbracketleft") { return "\\langle" }
        if name.hasPrefix("floorleft") { return "\\lfloor" }
        if name.hasPrefix("ceilingleft") { return "\\lceil" }
        return nil
    }

    static func closingDelimiter(_ name: String?) -> String? {
        guard let name else { return nil }
        if name.hasPrefix("parenright") { return ")" }
        if name.hasPrefix("bracketright") { return "]" }
        if name.hasPrefix("braceright") { return "\\}" }
        if name.hasPrefix("angbracketright") { return "\\rangle" }
        if name.hasPrefix("floorright") { return "\\rfloor" }
        if name.hasPrefix("ceilingright") { return "\\rceil" }
        return nil
    }

    /// A bar that fences rather than opens or closes: | and ‖.
    static func fence(_ name: String?) -> String? {
        guard let name else { return nil }
        if name.hasPrefix("vextenddouble") || name == "bardbl" { return "\\|" }
        if name.hasPrefix("vextendsingle") || name == "bar" { return "|" }
        return nil
    }

    static func accent(_ name: String?) -> String? {
        guard let name else { return nil }
        switch name {
        case "circumflex", "hatwide", "hatwider", "hatwidest": return "\\hat"
        case "tilde", "tildewide", "tildewider", "tildewidest": return "\\tilde"
        case "macron": return "\\bar"
        case "dotaccent": return "\\dot"
        case "vector", "arrowright": return "\\vec"
        default: return nil
        }
    }

    // MARK: - Names

    static let byName: [String: String] = {
        var table: [String: String] = [:]
        // Greek, as the fonts name them.
        let greek = ["alpha", "beta", "gamma", "delta", "epsilon", "varepsilon", "zeta", "eta",
                     "theta", "vartheta", "iota", "kappa", "lambda", "mu", "nu", "xi", "pi",
                     "varpi", "rho", "varrho", "sigma", "varsigma", "tau", "upsilon", "phi",
                     "varphi", "chi", "psi", "omega", "Gamma", "Delta", "Theta", "Lambda", "Xi",
                     "Pi", "Sigma", "Upsilon", "Phi", "Psi", "Omega"]
        for name in greek { table[name] = "\\\(name)" }

        // Computer Modern's symbol font names every glyph it draws, and the
        // name is the command that drew it. A subset font re-encodes itself
        // constantly — the same slot is a club suit in one file and a vertical
        // bar in the next — but it carries the right names either way, so the
        // names have to be able to answer on their own.
        let cmsy: [String: String] = [
            "minus": "-", "asteriskmath": "\\ast", "diamondmath": "\\diamond",
            "plusminus": "\\pm", "minusplus": "\\mp", "circleplus": "\\oplus",
            "circleminus": "\\ominus", "circlemultiply": "\\otimes",
            "circledivide": "\\oslash", "circledot": "\\odot",
            "circlecopyrt": "\\bigcirc", "openbullet": "\\circ", "bullet": "\\bullet",
            "equivasymptotic": "\\asymp", "equivalence": "\\equiv",
            "reflexsubset": "\\subseteq", "reflexsuperset": "\\supseteq",
            "lessequal": "\\leq", "greaterequal": "\\geq",
            "precedesequal": "\\preceq", "followsequal": "\\succeq",
            "similar": "\\sim", "approxequal": "\\approx",
            "propersubset": "\\subset", "propersuperset": "\\supset",
            "lessmuch": "\\ll", "greatermuch": "\\gg",
            "precedes": "\\prec", "follows": "\\succ",
            "arrowleft": "\\leftarrow", "arrowright": "\\rightarrow",
            "arrowup": "\\uparrow", "arrowdown": "\\downarrow",
            "arrowboth": "\\leftrightarrow", "arrownortheast": "\\nearrow",
            "arrowsoutheast": "\\searrow", "similarequal": "\\simeq",
            "arrowdblleft": "\\Leftarrow", "arrowdblright": "\\Rightarrow",
            "arrowdblup": "\\Uparrow", "arrowdbldown": "\\Downarrow",
            "arrowdblboth": "\\Leftrightarrow", "arrownorthwest": "\\nwarrow",
            "arrowsouthwest": "\\swarrow", "proportional": "\\propto",
            "prime": "'", "infinity": "\\infty", "element": "\\in", "owner": "\\ni",
            "triangle": "\\triangle", "triangleinv": "\\triangledown",
            "negationslash": "\\not", "mapsto": "\\mapsto",
            "universal": "\\forall", "existential": "\\exists",
            "logicalnot": "\\neg", "emptyset": "\\emptyset",
            "Rfractur": "\\Re", "Ifractur": "\\Im",
            "latticetop": "\\top", "perpendicular": "\\bot", "aleph": "\\aleph",
            "union": "\\cup", "intersection": "\\cap", "unionmulti": "\\uplus",
            "logicaland": "\\wedge", "logicalor": "\\vee",
            "turnstileleft": "\\vdash", "turnstileright": "\\dashv",
            "arrowbothv": "\\updownarrow", "arrowdblbothv": "\\Updownarrow",
            "backslash": "\\backslash", "wreathproduct": "\\wr",
            "radical": "\\surd", "unionsq": "\\sqcup", "intersectionsq": "\\sqcap",
            "subsetsqequal": "\\sqsubseteq", "supersetsqequal": "\\sqsupseteq",
            "section": "\\S", "dagger": "\\dagger", "daggerdbl": "\\ddagger",
            "paragraph": "\\P", "club": "\\clubsuit", "diamond": "\\diamondsuit",
            "heart": "\\heartsuit", "spade": "\\spadesuit",
        ]
        for (name, command) in cmsy { table[name] = command }

        // The maths italic font's names for what is not a letter.
        let cmmi: [String: String] = [
            "partialdiff": "\\partial", "lscript": "\\ell", "weierstrass": "\\wp",
            "dotlessi": "\\imath", "dotlessj": "\\jmath", "star": "\\star",
            "epsilon1": "\\epsilon", "theta1": "\\vartheta", "pi1": "\\varpi",
            "rho1": "\\varrho", "sigma1": "\\varsigma", "phi1": "\\varphi",
            "arrowhookleft": "\\hookleftarrow", "arrowhookright": "\\hookrightarrow",
            "triangleright": "\\triangleright", "triangleleft": "\\triangleleft",
            "flat": "\\flat", "natural": "\\natural", "sharp": "\\sharp",
            "period": ".", "comma": ",", "less": "<", "greater": ">", "slash": "/",
        ]
        for (name, command) in cmmi { table[name] = command }

        let direct: [String: String] = [
            "summationdisplay": "\\sum", "summationtext": "\\sum",
            "productdisplay": "\\prod", "producttext": "\\prod",
            "integraldisplay": "\\int", "integraltext": "\\int",
            "uniondisplay": "\\bigcup", "intersectiondisplay": "\\bigcap",
            "coproductdisplay": "\\coprod",
            "radical": "\\sqrt", "radicalbig": "\\sqrt", "radicalBig": "\\sqrt",
            "partialdiff": "\\partial", "partial": "\\partial", "infinity": "\\infty",
            "gradient": "\\nabla", "nabla": "\\nabla", "emptyset": "\\emptyset",
            "element": "\\in", "notelement": "\\notin", "owner": "\\ni",
            "propersubset": "\\subset", "reflexsubset": "\\subseteq",
            "propersuperset": "\\supset", "reflexsuperset": "\\supseteq",
            "union": "\\cup", "intersection": "\\cap", "logicaland": "\\land",
            "logicalor": "\\lor", "logicalnot": "\\neg",
            "universal": "\\forall", "existential": "\\exists",
            "lessequal": "\\leq", "greaterequal": "\\geq", "notequal": "\\neq",
            "approxequal": "\\approx", "similar": "\\sim", "equivalence": "\\equiv",
            "congruent": "\\cong", "proportional": "\\propto",
            "much less": "\\ll", "muchless": "\\ll", "muchgreater": "\\gg",
            "arrowright": "\\rightarrow", "arrowleft": "\\leftarrow",
            "arrowboth": "\\leftrightarrow", "arrowdblright": "\\Rightarrow",
            "arrowdblleft": "\\Leftarrow", "arrowdblboth": "\\Leftrightarrow",
            "arrowup": "\\uparrow", "arrowdown": "\\downarrow",
            "minus": "-", "plusminus": "\\pm", "minusplus": "\\mp",
            "multiply": "\\times", "divide": "\\div", "periodcentered": "\\cdot",
            "asteriskmath": "\\ast", "circlemultiply": "\\otimes", "circleplus": "\\oplus",
            "circledot": "\\odot", "bullet": "\\bullet", "ellipsis": "\\ldots",
            "ellipsiscentered": "\\cdots", "ellipsisdiagonal": "\\ddots",
            "ellipsisvertical": "\\vdots",
            "bardbl": "\\|", "bar": "|", "backslash": "\\backslash",
            "dagger": "\\dagger", "daggerdbl": "\\ddagger", "section": "\\S",
            "prime": "'", "degree": "^\\circ", "angle": "\\angle",
            "perpendicular": "\\perp", "parallel": "\\parallel",
            "aleph": "\\aleph", "weierstrass": "\\wp", "dotlessi": "\\imath",
            "dotlessj": "\\jmath", "openbullet": "\\circ", "star": "\\star",
            "triangleleft": "\\triangleleft", "triangleright": "\\triangleright",
            "lessmuch": "\\ll", "greatermuch": "\\gg",
            "precedesequal": "\\preceq", "followsequal": "\\succeq",
            "precedes": "\\prec", "follows": "\\succ",
            "colon": ":", "semicolon": ";", "comma": ",", "period": ".",
            "slash": "/", "equal": "=", "plus": "+", "less": "<", "greater": ">",
            "parenleft": "(", "parenright": ")", "bracketleft": "[", "bracketright": "]",
            "braceleft": "\\{", "braceright": "\\}", "bardash": "\\vdash",
            "quotesingle": "'", "quoteright": "'", "quoteleft": "`",
            "hyphen": "-", "endash": "--", "emdash": "---",
            "space": " ", "exclam": "!", "question": "?", "percent": "\\%",
            "fi": "fi", "fl": "fl", "ff": "ff", "ffi": "ffi", "ffl": "ffl",
            "ampersand": "\\&", "numbersign": "\\#", "dollar": "\\$",
            "underscore": "\\_", "asciitilde": "\\sim", "at": "@",
        ]
        for (name, command) in direct { table[name] = command }

        // Letters and digits are named after themselves.
        for scalar in UnicodeScalar("a").value...UnicodeScalar("z").value {
            table[String(UnicodeScalar(scalar)!)] = String(UnicodeScalar(scalar)!)
        }
        for scalar in UnicodeScalar("A").value...UnicodeScalar("Z").value {
            table[String(UnicodeScalar(scalar)!)] = String(UnicodeScalar(scalar)!)
        }
        let digits = ["zero", "one", "two", "three", "four",
                      "five", "six", "seven", "eight", "nine"]
        for (value, name) in digits.enumerated() { table[name] = String(value) }
        return table
    }()

    // MARK: - Standard encodings

    /// Computer Modern has not moved a glyph since 1979, so a font that names
    /// nothing can still be read by knowing which font it is.
    private static func standardEncoding(code: Int, fontName: String) -> String? {
        let family = fontName.split(separator: "+").last.map(String.init) ?? fontName
        let upper = family.uppercased()
        if upper.hasPrefix("CMMI") { return mathItalic[code] }
        if upper.hasPrefix("CMSY") { return symbols[code] }
        if upper.hasPrefix("MSBM") { return blackboard[code] }
        if upper.hasPrefix("CMEX") { return extensions[code] }
        // Roman and sans text fonts: ASCII, with the handful TeX moves.
        if upper.hasPrefix("CMR") || upper.hasPrefix("CMB") || upper.hasPrefix("CMTI")
            || upper.hasPrefix("CMTT") || upper.hasPrefix("SF") || upper.hasPrefix("CMSS") {
            return roman[code] ?? asciiIfPrintable(code)
        }
        return asciiIfPrintable(code)
    }

    private static func asciiIfPrintable(_ code: Int) -> String? {
        guard code >= 0x20, code < 0x7F, let scalar = Unicode.Scalar(UInt32(code)) else {
            return nil
        }
        return String(Character(scalar))
    }

    /// CMMI: maths italic — Greek, then italic letters.
    static let mathItalic: [Int: String] = {
        var table: [Int: String] = [:]
        let capitals = ["\\Gamma", "\\Delta", "\\Theta", "\\Lambda", "\\Xi", "\\Pi", "\\Sigma",
                        "\\Upsilon", "\\Phi", "\\Psi", "\\Omega"]
        for (offset, command) in capitals.enumerated() { table[offset] = command }
        let smalls = ["\\alpha", "\\beta", "\\gamma", "\\delta", "\\epsilon", "\\zeta", "\\eta",
                      "\\theta", "\\iota", "\\kappa", "\\lambda", "\\mu", "\\nu", "\\xi", "\\pi",
                      "\\rho", "\\sigma", "\\tau", "\\upsilon", "\\phi", "\\chi", "\\psi",
                      "\\omega"]
        for (offset, command) in smalls.enumerated() { table[0x0B + offset] = command }
        table[0x22] = "\\varepsilon"
        table[0x23] = "\\vartheta"
        table[0x24] = "\\varpi"
        table[0x25] = "\\varrho"
        table[0x26] = "\\varsigma"
        table[0x27] = "\\varphi"
        table[0x2C] = ","
        table[0x2E] = "/"
        table[0x2F] = "\\star"
        for digit in 0...9 { table[0x30 + digit] = String(digit) }
        table[0x3A] = "."
        table[0x3B] = ","
        table[0x3C] = "<"
        table[0x3D] = "/"
        table[0x3E] = ">"
        table[0x40] = "\\partial"
        for offset in 0..<26 {
            table[0x41 + offset] = String(UnicodeScalar(UInt32(65 + offset))!)
        }
        table[0x60] = "\\ell"
        for offset in 0..<26 {
            table[0x61 + offset] = String(UnicodeScalar(UInt32(97 + offset))!)
        }
        table[0x7B] = "\\imath"
        table[0x7C] = "\\jmath"
        table[0x7D] = "\\wp"
        return table
    }()

    /// CMSY: the symbol font.
    static let symbols: [Int: String] = {
        var table: [Int: String] = [:]
        let ordered = [
            "-", "\\cdot", "\\times", "\\ast", "\\div", "\\diamond", "\\pm", "\\mp",
            "\\oplus", "\\ominus", "\\otimes", "\\oslash", "\\odot", "\\bigcirc", "\\circ",
            "\\bullet", "\\asymp", "\\equiv", "\\subseteq", "\\supseteq", "\\leq", "\\geq",
            "\\preceq", "\\succeq", "\\sim", "\\approx", "\\subset", "\\supset", "\\ll",
            "\\gg", "\\prec", "\\succ", "\\leftarrow", "\\rightarrow", "\\uparrow",
            "\\downarrow", "\\leftrightarrow", "\\nearrow", "\\searrow", "\\simeq",
            "\\Leftarrow", "\\Rightarrow", "\\Uparrow", "\\Downarrow", "\\Leftrightarrow",
            "\\nwarrow", "\\swarrow", "\\propto", "'", "\\infty", "\\in", "\\ni",
            "\\triangle", "\\triangledown", "\\not", "\\mapsto", "\\forall", "\\exists", "\\neg",
            "\\emptyset", "\\Re", "\\Im", "\\top", "\\bot",
        ]
        for (offset, command) in ordered.enumerated() { table[offset] = command }
        table[0x40] = "\\aleph"
        for offset in 0..<26 {
            let letter = String(UnicodeScalar(UInt32(65 + offset))!)
            table[0x41 + offset] = "\\mathcal{\(letter)}"
        }
        let tail: [Int: String] = [
            0x5B: "\\cup", 0x5C: "\\cap", 0x5D: "\\uplus", 0x5E: "\\wedge", 0x5F: "\\vee",
            0x60: "\\vdash", 0x61: "\\dashv", 0x62: "\\lfloor", 0x63: "\\rfloor",
            0x64: "\\lceil", 0x65: "\\rceil", 0x66: "\\{", 0x67: "\\}",
            0x68: "\\langle", 0x69: "\\rangle", 0x6A: "|", 0x6B: "\\|",
            0x6C: "\\updownarrow", 0x6D: "\\Updownarrow", 0x6E: "\\backslash", 0x6F: "\\wr",
            0x70: "\\sqrt", 0x71: "\\amalg", 0x72: "\\nabla", 0x73: "\\int",
            0x74: "\\sqcup", 0x75: "\\sqcap", 0x76: "\\sqsubseteq", 0x77: "\\sqsupseteq",
            0x78: "\\S", 0x79: "\\dagger", 0x7A: "\\ddagger", 0x7B: "\\P",
            0x7C: "\\clubsuit", 0x7D: "\\diamondsuit", 0x7E: "\\heartsuit",
            0x7F: "\\spadesuit",
        ]
        for (code, command) in tail { table[code] = command }
        return table
    }()

    /// MSBM: blackboard bold and a few AMS symbols.
    static let blackboard: [Int: String] = {
        var table: [Int: String] = [:]
        for offset in 0..<26 {
            let letter = String(UnicodeScalar(UInt32(65 + offset))!)
            table[0x41 + offset] = "\\mathbb{\(letter)}"
        }
        return table
    }()

    /// CMEX: the big operators and the tall delimiters.
    static let extensions: [Int: String] = [
        0x50: "\\sum", 0x51: "\\prod", 0x52: "\\int",
        0x58: "\\sum", 0x59: "\\prod", 0x5A: "\\int",
        0x00: "(", 0x01: ")", 0x02: "[", 0x03: "]",
        0x10: "(", 0x11: ")", 0x12: "[", 0x13: "]",
        0x0C: "|", 0x0D: "\\|",
        0x70: "\\sqrt", 0x71: "\\sqrt", 0x72: "\\sqrt", 0x73: "\\sqrt",
    ]

    /// The handful of places TeX's roman encoding is not ASCII.
    static let roman: [Int: String] = [
        0x00: "\\Gamma", 0x01: "\\Delta", 0x02: "\\Theta", 0x03: "\\Lambda", 0x04: "\\Xi",
        0x05: "\\Pi", 0x06: "\\Sigma", 0x07: "\\Upsilon", 0x08: "\\Phi", 0x09: "\\Psi",
        0x0A: "\\Omega", 0x0B: "ff", 0x0C: "fi", 0x0D: "fl", 0x0E: "ffi", 0x0F: "ffl",
        0x10: "\\imath", 0x11: "\\jmath", 0x19: "\\ss", 0x1A: "\\ae", 0x1B: "\\oe",
        0x1C: "\\o", 0x1D: "\\AE", 0x1E: "\\OE", 0x1F: "\\O",
        0x22: "”", 0x27: "’", 0x5C: "“", 0x60: "‘",
        0x7B: "--", 0x7C: "---",
    ]
}
