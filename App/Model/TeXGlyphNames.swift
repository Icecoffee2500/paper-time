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
        // A font that holds one alphabet, and not the plain one, draws every
        // letter in that alphabet: Computer Modern's symbol font has no
        // upright letters, only the calligraphic ones, so an encoding written
        // for text that calls a glyph "N" names a script N. Euler script,
        // Euler Fraktur, Ralph Smith's script and the double-struck fonts are
        // the same, each in its own alphabet.
        // A double-struck font's digits are double-struck too: bbm's 𝟙 is
        // the indicator function, \mathbb{1}, and read plain it was a "1".
        if resolved.count == 1, let character = resolved.first,
           let style = letterStyle(fontName: fontName),
           character.isLetter || (character.isNumber && style == "\\mathbb") {
            return "\(style){\(resolved)}"
        }
        // Word's Cambria Math, and any font that says what its glyphs mean,
        // writes a formula's letters as the Mathematical Alphanumeric Symbols
        // — "𝑎", not "a". LaTeX cannot take those as they are.
        let scalars = resolved.unicodeScalars.map(\.value)
        if scalars.contains(where: { mathAlphanumeric($0) != nil }) {
            return latex(scalars: scalars) ?? resolved
        }
        return resolved
    }

    private static func resolve(
        name: String?, code: Int, fontName: String, unicode: String?, isSymbolic: Bool
    ) -> String? {
        // The AMS symbol fonts, and the tx and px fonts made after them, give
        // their own meaning to names other fonts use: "star" is ⋆ in the
        // maths italic and ★ in msam, "similar" is ∼ in the symbol font and
        // the thicker one in msbm.
        if let name, let table = amsTable(fontName: fontName),
           let command = table[name] ?? table[stripped(name)] { return command }
        if let name, let command = arevName(name, fontName: fontName) { return command }
        if let name, let command = byName[name] ?? byName[stripped(name)] { return command }
        if let name, name.count == 1 { return name }
        // newtx's and newtxsf's own names: "bbE" for the double-struck E
        // (in zsfmia and txmia), "upnabla", "uppartial" and "upalpha" for
        // the upright forms. Read as codes they were "(" and "+".
        if let name, let command = newtxName(name) { return command }
        // "u1D437", "uni2260": the glyph named after its code point, which is
        // how the newtx, newpx and Libertine maths fonts name every letter —
        // a font whose alphabet is the Mathematical Alphanumeric Symbols has
        // no "D", only "u1D437". Read as a code it was "5)" for f_θ.
        if let name, let scalars = unicodeName(name) {
            return latex(scalars: scalars)
        }
        if !isSymbolic, let unicode, !unicode.isEmpty { return unicode }
        if let command = standardEncoding(code: code, fontName: fontName) { return command }
        if let unicode, !unicode.isEmpty { return unicode }
        // A font this knows nothing about, which says nothing about itself:
        // its codes may at least be ASCII. (Asked last — the AMS fonts are
        // symbolic and say what their glyphs are, and read as ASCII their
        // "less than or equal" was a 6.)
        return asciiIfPrintable(code)
    }

    /// Arev's own names for its maths letters. The letters a formula would
    /// confuse with symbols — a, i, l, u, v, w, x, I — are drawn as variant
    /// shapes in the font's private-use area, named "uniEB" + 0x80 + the
    /// letter's ASCII code ("uniEBF8" is x); f is the florin; and three of
    /// the upright Greek capitals are private-use too (Γ, Σ, Φ). Read as
    /// nothing, x_i came out as an empty subscript.
    static func arevName(_ name: String, fontName: String) -> String? {
        let family = (fontName.split(separator: "+").last.map(String.init) ?? fontName).uppercased()
        guard family.hasPrefix("AREVSANS") else { return nil }
        if name == "florin" { return "f" }
        if name.hasPrefix("uniEB"), name.count == 7, let code = Int(name.dropFirst(5), radix: 16),
           code >= 0x80 + 0x41, code <= 0x80 + 0x7A, let scalar = UnicodeScalar(code - 0x80),
           Character(scalar).isLetter {
            return String(Character(scalar))
        }
        switch name {
        case "uniEF13": return "\\Gamma"
        case "uniEF23": return "\\Sigma"
        case "uniEF26": return "\\Phi"
        default: return nil
        }
    }

    /// newtx's names for glyphs other fonts name by code point: "bbA"–"bbZ"
    /// and "bbk" are \mathbb, "upnabla" and "uppartial" the upright signs,
    /// "upalpha" the upright Greek (written as the Greek — LaTeX's \alpha).
    static func newtxName(_ name: String) -> String? {
        if name.count == 3, name.hasPrefix("bb"), let letter = name.last, letter.isASCII, letter.isLetter {
            return "\\mathbb{\(letter)}"
        }
        guard name.hasPrefix("up"), name.count > 2 else { return nil }
        let rest = "\\" + name.dropFirst(2)
        return isGreekCommand(rest) ? rest : nil
    }

    /// Whether a command names a Greek letter, ∇ or ∂ — the letters a text
    /// face carries for a paper that sets its formulas in the text face.
    static func isGreekCommand(_ command: String) -> Bool {
        greekCommands.contains(command)
    }

    private static let greekCommands: Set<String> = Set(greekLetters.filter { $0.hasPrefix("\\") })
        .union(["\\Omega", "\\digamma"])

    /// The AMS fonts' own names, for the fonts that use them.
    static func amsTable(fontName: String) -> [String: String]? {
        let family = (fontName.split(separator: "+").last.map(String.init) ?? fontName).uppercased()
        // (cmbright's AMS fonts are hfbright's HFBRAS and HFBRBS.)
        if ["MSAM", "TXSYA", "PXSYA", "HFBRAS"].contains(where: { family.hasPrefix($0) }) { return msam }
        if ["MSBM", "TXSYB", "PXSYB", "TXSYM", "PXSYM", "HFBRBS"].contains(where: { family.hasPrefix($0) }) {
            return msbm
        }
        if ["TXSYC", "PXSYC"].contains(where: { family.hasPrefix($0) }) { return txsyc }
        return nil
    }

    static let msam: [String: String] = [
        "squaredot": "\\boxdot", "squareplus": "\\boxplus", "squaremultiply": "\\boxtimes",
        "square": "\\square", "squaresolid": "\\blacksquare", "diamond": "\\lozenge",
        "diamondsolid": "\\blacklozenge", "clockwise": "\\circlearrowright",
        "anticlockwise": "\\circlearrowleft", "harpoonleftright": "\\rightleftharpoons",
        "harpoonrightleft": "\\leftrightharpoons", "squareminus": "\\boxminus",
        "forces": "\\Vdash", "forcesbar": "\\Vvdash", "satisfies": "\\vDash",
        "dblarrowheadright": "\\twoheadrightarrow", "dblarrowheadleft": "\\twoheadleftarrow",
        "dblarrowleft": "\\leftleftarrows", "dblarrowright": "\\rightrightarrows",
        "dblarrowup": "\\upuparrows", "dblarrowdwn": "\\downdownarrows",
        "harpoonupright": "\\upharpoonright", "harpoondownright": "\\downharpoonright",
        "harpoonupleft": "\\upharpoonleft", "harpoondownleft": "\\downharpoonleft",
        "arrowtailright": "\\rightarrowtail", "arrowtailleft": "\\leftarrowtail",
        "arrowparrleftright": "\\leftrightarrows", "arrowparrrightleft": "\\rightleftarrows",
        "shiftleft": "\\Lsh", "shiftright": "\\Rsh", "squiggleright": "\\rightsquigarrow",
        "squiggleleftright": "\\leftrightsquigarrow", "curlyleft": "\\looparrowleft",
        "curlyright": "\\looparrowright", "circleequal": "\\circeq",
        "followsorequal": "\\succsim", "greaterorsimilar": "\\gtrsim",
        "greaterorapproxeql": "\\gtrapprox", "multimap": "\\multimap",
        "therefore": "\\therefore", "because": "\\because", "equalsdots": "\\doteqdot",
        "defines": "\\triangleq", "precedesorequal": "\\precsim",
        "lessorsimilar": "\\lesssim", "lessorapproxeql": "\\lessapprox",
        "equalorless": "\\eqslantless", "equalorgreater": "\\eqslantgtr",
        "equalorprecedes": "\\curlyeqprec", "equalorfollows": "\\curlyeqsucc",
        "precedesorcurly": "\\preccurlyeq", "lessdblequal": "\\leqq",
        "lessorequalslant": "\\leqslant", "lessorgreater": "\\lessgtr",
        "primereverse": "\\backprime", "equaldotrightleft": "\\risingdotseq",
        "equaldotleftright": "\\fallingdotseq", "followsorcurly": "\\succcurlyeq",
        "greaterdblequal": "\\geqq", "greaterorequalslant": "\\geqslant",
        "greaterorless": "\\gtrless", "squareimage": "\\sqsubset",
        "squareoriginal": "\\sqsupset", "triangleright": "\\vartriangleright",
        "triangleleft": "\\vartriangleleft", "trianglerightequal": "\\trianglerighteq",
        "triangleleftequal": "\\trianglelefteq", "star": "\\bigstar", "between": "\\between",
        "triangledownsld": "\\blacktriangledown", "trianglerightsld": "\\blacktriangleright",
        "triangleleftsld": "\\blacktriangleleft", "triangle": "\\vartriangle",
        "trianglesolid": "\\blacktriangle", "triangleinv": "\\triangledown",
        "ringinequal": "\\eqcirc", "lessequalgreater": "\\lesseqgtr",
        "greaterlessequal": "\\gtreqless", "lessdbleqlgreater": "\\lesseqqgtr",
        "greaterdbleqlless": "\\gtreqqless", "Yen": "\\yen", "arrowtripleright": "\\Rrightarrow",
        "arrowtripleleft": "\\Lleftarrow", "check": "\\checkmark", "orunderscore": "\\veebar",
        "nand": "\\barwedge", "perpcorrespond": "\\doublebarwedge", "angle": "\\angle",
        "measuredangle": "\\measuredangle", "sphericalangle": "\\sphericalangle",
        "proportional": "\\varpropto", "smile": "\\smallsmile", "frown": "\\smallfrown",
        "subsetdbl": "\\Subset", "supersetdbl": "\\Supset", "uniondbl": "\\Cup",
        "intersectiondbl": "\\Cap", "uprise": "\\curlywedge", "downfall": "\\curlyvee",
        "multiopenleft": "\\leftthreetimes", "multiopenright": "\\rightthreetimes",
        "subsetdblequal": "\\subseteqq", "supersetdblequal": "\\supseteqq",
        "difference": "\\bumpeq", "geomequivalent": "\\Bumpeq", "muchless": "\\lll",
        "muchgreater": "\\ggg", "rightanglenw": "\\ulcorner", "rightanglene": "\\urcorner",
        "circleR": "\\circledR", "circleS": "\\circledS", "fork": "\\pitchfork",
        "dotplus": "\\dotplus", "revsimilar": "\\backsim", "revasymptequal": "\\backsimeq",
        "rightanglesw": "\\llcorner", "rightanglese": "\\lrcorner", "maltesecross": "\\maltese",
        "complement": "\\complement", "intercal": "\\intercal", "circlering": "\\circledcirc",
        "circleasterisk": "\\circledast", "circleminus": "\\circleddash",
    ]

    static let msbm: [String: String] = [
        "lessornotequal": "\\lneq", "greaterornotequal": "\\gneq", "notlessequal": "\\nleq",
        "notgreaterequal": "\\ngeq", "notless": "\\nless", "notgreater": "\\ngtr",
        "notprecedes": "\\nprec", "notfollows": "\\nsucc", "lessornotdbleql": "\\lneqq",
        "greaterornotdbleql": "\\gneqq", "notlessorslnteql": "\\nleqslant",
        "notgreaterorslnteql": "\\ngeqslant", "lessnotequal": "\\lvertneqq",
        "greaternotequal": "\\gvertneqq", "notprecedesoreql": "\\npreceq",
        "notfollowsoreql": "\\nsucceq", "precedeornoteqvlnt": "\\precnsim",
        "followornoteqvlnt": "\\succnsim", "lessornotsimilar": "\\lnsim",
        "greaterornotsimilar": "\\gnsim", "notlessdblequal": "\\nleqq",
        "notgreaterdblequal": "\\ngeqq", "precedenotslnteql": "\\precneqq",
        "follownotslnteql": "\\succneqq", "precedenotdbleqv": "\\precnapprox",
        "follownotdbleqv": "\\succnapprox", "lessnotdblequal": "\\lnapprox",
        "greaternotdblequal": "\\gnapprox", "notsimilar": "\\nsim", "notapproxequal": "\\ncong",
        "upslope": "\\diagup", "downslope": "\\diagdown", "notsubsetoreql": "\\varsubsetneq",
        "notsupersetoreql": "\\varsupsetneq", "notsubsetordbleql": "\\nsubseteqq",
        "notsupersetordbleql": "\\nsupseteqq", "subsetornotdbleql": "\\subsetneqq",
        "supersetornotdbleql": "\\supsetneqq", "subsetornoteql": "\\varsubsetneqq",
        "supersetornoteql": "\\varsupsetneqq", "subsetnoteql": "\\subsetneq",
        "supersetnoteql": "\\supsetneq", "notsubseteql": "\\nsubseteq",
        "notsuperseteql": "\\nsupseteq", "notparallel": "\\nparallel", "notbar": "\\nmid",
        "notshortbar": "\\nshortmid", "notshortparallel": "\\nshortparallel",
        "notturnstile": "\\nvdash", "notforces": "\\nVdash", "notsatisfies": "\\nvDash",
        "notforcesextra": "\\nVDash", "nottriangeqlright": "\\ntrianglerighteq",
        "nottriangeqlleft": "\\ntrianglelefteq", "nottriangleleft": "\\ntriangleleft",
        "nottriangleright": "\\ntriangleright", "notarrowleft": "\\nleftarrow",
        "notarrowright": "\\nrightarrow", "notdblarrowleft": "\\nLeftarrow",
        "notdblarrowright": "\\nRightarrow", "notdblarrowboth": "\\nLeftrightarrow",
        "notarrowboth": "\\nleftrightarrow", "dividemultiply": "\\divideontimes",
        "emptyset": "\\varnothing", "notexistential": "\\nexists", "Finv": "\\Finv",
        "Gmir": "\\Game", "Omegainv": "\\mho", "eth": "\\eth", "equalorsimilar": "\\eqsim",
        "beth": "\\beth", "gimel": "\\gimel", "daleth": "\\daleth", "lessdot": "\\lessdot",
        "greaterdot": "\\gtrdot", "multicloseleft": "\\ltimes", "multicloseright": "\\rtimes",
        "barshort": "\\shortmid", "parallelshort": "\\shortparallel",
        "integerdivide": "\\smallsetminus", "similar": "\\thicksim",
        "approxequal": "\\thickapprox", "approxorequal": "\\approxeq",
        "followsorequal": "\\succapprox", "precedesorequal": "\\precapprox",
        "archleftdown": "\\curvearrowleft", "archrightdown": "\\curvearrowright",
        "Digamma": "\\digamma", "kappa": "\\varkappa", "k": "\\Bbbk",
        "planckover2pi": "\\hslash", "planckover2pi1": "\\hbar", "epsiloninv": "\\backepsilon",
    ]

    /// txfonts' and pxfonts' extra symbols, the negated relations among them.
    static let txsyc: [String: String] = [
        "nequal": "\\neq", "nelement": "\\notin", "nowner": "\\not\\ni", "nsimilar": "\\nsim",
        "napproxequal": "\\not\\approx", "nequivalence": "\\not\\equiv",
        "nequivasymptotic": "\\not\\asymp", "npropersubset": "\\not\\subset",
        "npropersuperset": "\\not\\supset", "nlessmuch": "\\not\\ll", "ngreatermuch": "\\not\\gg",
        "nsimilarequal": "\\not\\simeq", "nparallel": "\\nparallel", "nparallel1": "\\nparallel",
        "parallel": "\\parallel", "parallel1": "\\parallel", "doteq": "\\doteq",
        "simequal": "\\simeq", "colonequal": "\\coloneqq", "equalcolon": "\\eqqcolon",
        "mapsfrom": "\\mapsfrom", "Mapsto": "\\Mapsto", "Mapsfrom": "\\Mapsfrom",
        "leadsto": "\\leadsto", "Diamond": "\\Diamond", "Diamondsolid": "\\Diamondblack",
        "medcircle": "\\medcirc", "medbullet": "\\medbullet", "lbag": "\\lbag", "rbag": "\\rbag",
        "notsubsetdbl": "\\not\\Subset", "notsupersetdbl": "\\not\\Supset",
        "nsubsetsqequal": "\\not\\sqsubseteq", "nsupersetsqequal": "\\not\\sqsupseteq",
    ]


    /// The command that sets every letter of a font that draws one alphabet
    /// other than the plain one, or nil for a font whose letters are letters.
    ///
    /// Each was looked at, not guessed: the letters of `txsym` and `txsyb`
    /// are ℝ, ℕ, 𝔼, ℙ and 𝕊 in LeJEPA and RelTR, the letters of `txsys` and
    /// Latin Modern's `LMMathSymbols` are 𝒪, 𝒢, 𝒜 and 𝒩 in RelTR and in
    /// "EWC: Nuts and Bolts", exactly as Computer Modern's CMSY draws them.
    static func letterStyle(fontName: String) -> String? {
        let family = (fontName.split(separator: "+").last.map(String.init) ?? fontName).uppercased()
        // The tx and px fonts first, where one prefix covers several fonts
        // that each draw a different alphabet.
        for prefix in ["TXSY", "PXSY", "NTXSY", "NPXSY"] where family.hasPrefix(prefix) {
            let rest = family.dropFirst(prefix.count)
            if rest.hasPrefix("M") || rest.hasPrefix("B") { return "\\mathbb" }
            if rest.isEmpty || rest.hasPrefix("S") { return "\\mathcal" }
            return nil
        }
        if family.hasPrefix("TXBSY") || family.hasPrefix("PXBSY") { return "\\mathcal" }
        // txfonts and pxfonts keep their Fraktur in txmia and pxmia, newtx
        // and newpx in txmiaX and pxmiaX.
        if family.hasPrefix("TXMIA") || family.hasPrefix("PXMIA") { return "\\mathfrak" }
        // Fourier's and mathpazo's alphabets are fonts of their own.
        if family.hasPrefix("FOURIER-MATH-CAL") { return "\\mathcal" }
        if family.hasPrefix("FOURIER-MATH-BLACKBOARD") || family.hasPrefix("PAZOMATHBLACKBOARD") {
            return "\\mathbb"
        }
        if family.hasPrefix("CMSY") || family.hasPrefix("CMBSY") || family.hasPrefix("EUSM")
            || family.hasPrefix("EUSB") || family.hasPrefix("LMMATHSYMBOLS")
            || family.hasPrefix("HFBRSY") || family.hasPrefix("CMBRSY") { return "\\mathcal" }
        if family.hasPrefix("EUFM") || family.hasPrefix("EUFB") { return "\\mathfrak" }
        if family.hasPrefix("RSFS") { return "\\mathscr" }
        if family.hasPrefix("BBOLD") || family.hasPrefix("DSROM") || family.hasPrefix("DSSS")
            || family.hasPrefix("MSBM") || family.hasPrefix("BBM") || family.contains("STBB")
            || family.hasPrefix("HFBRBS") {
            return "\\mathbb"
        }
        return nil
    }

    // MARK: - Names that are code points

    /// The code points a glyph name spells, when it is one of the names the
    /// Adobe Glyph List reserves for that: "uniXXXX" (four hex digits, several
    /// in a row for a ligature) or "uXXXX" to "uXXXXXX". Anything after a
    /// full stop is a variant suffix and is dropped.
    static func unicodeName(_ name: String) -> [UInt32]? {
        var body = Substring(name)
        if let dot = body.firstIndex(of: ".") { body = body[..<dot] }
        if body.hasPrefix("uni") {
            let hex = body.dropFirst(3)
            guard !hex.isEmpty, hex.count % 4 == 0, hex.allSatisfy(\.isHexDigit) else { return nil }
            var scalars: [UInt32] = []
            var index = hex.startIndex
            while index < hex.endIndex {
                let next = hex.index(index, offsetBy: 4)
                guard let value = UInt32(hex[index..<next], radix: 16) else { return nil }
                scalars.append(value)
                index = next
            }
            return scalars
        }
        if body.hasPrefix("u") {
            let hex = body.dropFirst(1)
            guard (4...6).contains(hex.count), hex.allSatisfy(\.isHexDigit),
                  let value = UInt32(hex, radix: 16) else { return nil }
            return [value]
        }
        return nil
    }

    /// What a run of code points is in LaTeX: a styled letter from the
    /// Mathematical Alphanumeric Symbols written with its style, a symbol
    /// written as its command, anything else as the character itself.
    static func latex(scalars: [UInt32]) -> String? {
        var out = ""
        for value in scalars {
            // The script small l is \\ell — STIX draws its \\ell from there —
            // and LaTeX has no script lower case to write it with otherwise.
            if value == 0x1D4C1 { out += "\\ell"; continue }
            if let (base, style) = mathAlphanumeric(value) {
                out += styled(base, style)
            } else if let scalar = Unicode.Scalar(value) {
                let character = String(Character(scalar))
                out += unicodeCommands[character] ?? character
            } else {
                return nil
            }
        }
        return out.isEmpty ? nil : out
    }

    /// How a letter is set in a formula. Plain italic is what a variable is,
    /// and needs no command; every other style is one.
    enum MathStyle {
        case italic, upright, bold, boldItalic, script, boldScript, fraktur, boldFraktur,
             doubleStruck, sans, sansBold, sansItalic, sansBoldItalic, mono
    }

    /// The letter with its style written round it.
    static func styled(_ base: String, _ style: MathStyle) -> String {
        let greek = base.hasPrefix("\\")
        switch style {
        case .italic: return base
        case .upright: return greek ? base : "\\mathrm{\(base)}"
        case .bold: return greek ? "\\boldsymbol{\(base)}" : "\\mathbf{\(base)}"
        case .boldItalic: return "\\boldsymbol{\(base)}"
        case .script: return "\\mathcal{\(base)}"
        case .boldScript: return "\\boldsymbol{\\mathcal{\(base)}}"
        case .fraktur: return "\\mathfrak{\(base)}"
        case .boldFraktur: return "\\boldsymbol{\\mathfrak{\(base)}}"
        case .doubleStruck: return "\\mathbb{\(base)}"
        case .sans, .sansItalic: return "\\mathsf{\(base)}"
        case .sansBold, .sansBoldItalic: return "\\boldsymbol{\\mathsf{\(base)}}"
        case .mono: return "\\mathtt{\(base)}"
        }
    }

    /// A letter or digit from the Mathematical Alphanumeric Symbols block
    /// (U+1D400–U+1D7FF), or one of the letters Unicode had already placed
    /// among the Letterlike Symbols before that block was made: which
    /// letter, and in which style.
    static func mathAlphanumeric(_ value: UInt32) -> (base: String, style: MathStyle)? {
        if let known = letterlike[value] { return known }
        guard value >= 0x1D400, value <= 0x1D7FF else { return nil }
        // Thirteen Latin alphabets of fifty-two, in Unicode's order.
        let latin: [(UInt32, MathStyle)] = [
            (0x1D400, .bold), (0x1D434, .italic), (0x1D468, .boldItalic), (0x1D49C, .script),
            (0x1D4D0, .boldScript), (0x1D504, .fraktur), (0x1D538, .doubleStruck),
            (0x1D56C, .boldFraktur), (0x1D5A0, .sans), (0x1D5D4, .sansBold), (0x1D608, .sansItalic),
            (0x1D63C, .sansBoldItalic), (0x1D670, .mono),
        ]
        for (start, style) in latin where value >= start && value < start + 52 {
            let offset = value - start
            let letter = offset < 26 ? 65 + offset : 97 + offset - 26
            return (String(UnicodeScalar(UInt8(letter))), style)
        }
        if value == 0x1D6A4 { return ("\\imath", .italic) }
        if value == 0x1D6A5 { return ("\\jmath", .italic) }
        // Five Greek alphabets of fifty-eight: the capitals with ϴ, nabla,
        // the smalls with final sigma, then partial and the six variants.
        let greek: [(UInt32, MathStyle)] = [
            (0x1D6A8, .bold), (0x1D6E2, .italic), (0x1D71C, .boldItalic),
            (0x1D756, .sansBold), (0x1D790, .sansBoldItalic),
        ]
        for (start, style) in greek where value >= start && value < start + 58 {
            return (greekLetters[Int(value - start)], style)
        }
        if value == 0x1D7CA || value == 0x1D7CB { return ("\\digamma", .bold) }
        // Five rows of digits.
        let digits: [(UInt32, MathStyle)] = [
            (0x1D7CE, .bold), (0x1D7D8, .doubleStruck), (0x1D7E2, .sans), (0x1D7EC, .sansBold),
            (0x1D7F6, .mono),
        ]
        for (start, style) in digits where value >= start && value < start + 10 {
            return (String(value - start), style)
        }
        return nil
    }

    /// The fifty-eight of one Greek alphabet, as LaTeX writes them: a
    /// capital that looks like a Latin letter is that letter.
    private static let greekLetters: [String] = [
        "A", "B", "\\Gamma", "\\Delta", "E", "Z", "H", "\\Theta", "I", "K", "\\Lambda", "M", "N",
        "\\Xi", "O", "\\Pi", "P", "\\varTheta", "\\Sigma", "T", "\\Upsilon", "\\Phi", "X",
        "\\Psi", "\\Omega", "\\nabla",
        "\\alpha", "\\beta", "\\gamma", "\\delta", "\\varepsilon", "\\zeta", "\\eta",
        "\\theta", "\\iota", "\\kappa", "\\lambda", "\\mu", "\\nu", "\\xi", "o", "\\pi",
        "\\rho", "\\varsigma", "\\sigma", "\\tau", "\\upsilon", "\\varphi", "\\chi",
        "\\psi", "\\omega", "\\partial", "\\epsilon", "\\vartheta", "\\varkappa", "\\phi",
        "\\varrho", "\\varpi",
    ]

    /// The letters set among the Letterlike Symbols.
    private static let letterlike: [UInt32: (base: String, style: MathStyle)] = [
        0x2102: ("C", .doubleStruck), 0x210B: ("H", .script), 0x210C: ("H", .fraktur),
        0x210D: ("H", .doubleStruck), 0x210E: ("h", .italic), 0x2110: ("I", .script),
        0x2111: ("I", .fraktur), 0x2112: ("L", .script), 0x2115: ("N", .doubleStruck),
        0x2119: ("P", .doubleStruck), 0x211A: ("Q", .doubleStruck), 0x211B: ("R", .script),
        0x211C: ("R", .fraktur), 0x211D: ("R", .doubleStruck), 0x2124: ("Z", .doubleStruck),
        0x2128: ("Z", .fraktur), 0x212C: ("B", .script), 0x212D: ("C", .fraktur),
        0x212F: ("e", .script), 0x2130: ("E", .script), 0x2131: ("F", .script),
        0x2133: ("M", .script), 0x2134: ("o", .script),
    ]

    /// The characters a formula spells with a command. Asked of what a maths
    /// font drew, and of a glyph named by its code point.
    static let unicodeCommands: [String: String] = [
        // Greek. Unicode's ε and φ are the shapes TeX calls \varepsilon and
        // \varphi; its ϵ and ϕ are \epsilon and \phi.
        "α": "\\alpha", "β": "\\beta", "γ": "\\gamma", "δ": "\\delta", "ε": "\\varepsilon",
        "ϵ": "\\epsilon", "ζ": "\\zeta", "η": "\\eta", "θ": "\\theta", "ϑ": "\\vartheta",
        "ι": "\\iota", "κ": "\\kappa", "ϰ": "\\varkappa", "λ": "\\lambda", "μ": "\\mu",
        "µ": "\\mu", "ν": "\\nu", "ξ": "\\xi", "π": "\\pi", "ϖ": "\\varpi", "ρ": "\\rho",
        "ϱ": "\\varrho", "σ": "\\sigma", "ς": "\\varsigma", "τ": "\\tau", "υ": "\\upsilon",
        "φ": "\\varphi", "ϕ": "\\phi", "χ": "\\chi", "ψ": "\\psi", "ω": "\\omega",
        "Γ": "\\Gamma", "Δ": "\\Delta", "∆": "\\Delta", "Θ": "\\Theta", "ϴ": "\\varTheta",
        "Λ": "\\Lambda", "Ξ": "\\Xi", "Π": "\\Pi", "Σ": "\\Sigma", "Υ": "\\Upsilon",
        "Φ": "\\Phi", "Ψ": "\\Psi", "Ω": "\\Omega", "ϝ": "\\digamma",
        // Operators and relations.
        "·": "\\cdot", "⋅": "\\cdot", "∙": "\\bullet", "•": "\\bullet", "×": "\\times",
        "÷": "\\div", "±": "\\pm", "∓": "\\mp", "−": "-", "∗": "\\ast", "⋆": "\\star",
        "★": "\\bigstar", "∘": "\\circ", "◦": "\\circ", "⊕": "\\oplus", "⊖": "\\ominus",
        "⊗": "\\otimes", "⊘": "\\oslash", "⊙": "\\odot", "⊚": "\\circledcirc",
        "⊛": "\\circledast", "⊞": "\\boxplus", "⊟": "\\boxminus", "⊠": "\\boxtimes",
        "⊡": "\\boxdot", "⋄": "\\diamond", "◇": "\\diamond", "△": "\\triangle",
        "▽": "\\triangledown", "∖": "\\setminus", "∧": "\\wedge", "∨": "\\vee",
        "¬": "\\neg", "∪": "\\cup", "∩": "\\cap", "⊔": "\\sqcup", "⊓": "\\sqcap",
        "⊎": "\\uplus", "≀": "\\wr", "†": "\\dagger", "‡": "\\ddagger", "⋈": "\\bowtie",
        "≠": "\\neq", "≤": "\\leq", "≥": "\\geq", "⩽": "\\leqslant",
        "⩾": "\\geqslant", "≦": "\\leqq", "≧": "\\geqq", "≪": "\\ll", "≫": "\\gg",
        "≲": "\\lesssim", "≳": "\\gtrsim", "≈": "\\approx", "≉": "\\not\\approx",
        "≃": "\\simeq", "≅": "\\cong", "≡": "\\equiv", "≢": "\\not\\equiv", "∼": "\\sim",
        "≁": "\\nsim", "≍": "\\asymp", "≐": "\\doteq", "≜": "\\triangleq",
        "≔": ":=", "∝": "\\propto", "≺": "\\prec", "≻": "\\succ", "≼": "\\preceq",
        "≽": "\\succeq", "⊂": "\\subset", "⊃": "\\supset", "⊆": "\\subseteq",
        "⊇": "\\supseteq", "⊊": "\\subsetneq", "⊋": "\\supsetneq", "⊄": "\\not\\subset",
        "⊏": "\\sqsubset", "⊐": "\\sqsupset", "⊑": "\\sqsubseteq", "⊒": "\\sqsupseteq",
        "∈": "\\in", "∉": "\\notin", "∋": "\\ni", "∌": "\\not\\ni", "⊥": "\\perp",
        "⟂": "\\perp", "⊤": "\\top", "⊢": "\\vdash", "⊣": "\\dashv", "⊨": "\\models",
        "⊩": "\\Vdash", "∣": "\\mid", "∤": "\\nmid", "∥": "\\parallel", "‖": "\\|",
        "∦": "\\nparallel", "∠": "\\angle", "∡": "\\measuredangle", "∴": "\\therefore",
        "∵": "\\because", "∀": "\\forall", "∃": "\\exists", "∄": "\\nexists",
        "∅": "\\emptyset", "∞": "\\infty", "∂": "\\partial", "∇": "\\nabla", "√": "\\sqrt",
        "∛": "\\sqrt[3]", "∫": "\\int", "∬": "\\iint", "∭": "\\iiint", "∮": "\\oint",
        "∑": "\\sum", "∏": "\\prod", "∐": "\\coprod", "⋃": "\\bigcup", "⋂": "\\bigcap",
        "⋀": "\\bigwedge", "⋁": "\\bigvee", "⨁": "\\bigoplus", "⨂": "\\bigotimes",
        "⨀": "\\bigodot", "⨆": "\\bigsqcup",
        // Arrows.
        "→": "\\rightarrow", "←": "\\leftarrow", "↔": "\\leftrightarrow", "⇒": "\\Rightarrow",
        "⇐": "\\Leftarrow", "⇔": "\\Leftrightarrow", "↦": "\\mapsto", "↑": "\\uparrow",
        "↓": "\\downarrow", "⇑": "\\Uparrow", "⇓": "\\Downarrow", "↕": "\\updownarrow",
        "↗": "\\nearrow", "↘": "\\searrow", "↖": "\\nwarrow", "↙": "\\swarrow",
        "⟶": "\\longrightarrow", "⟵": "\\longleftarrow", "⟷": "\\longleftrightarrow",
        "⟹": "\\Longrightarrow", "⟸": "\\Longleftarrow", "⟺": "\\Longleftrightarrow",
        "⟼": "\\longmapsto", "↩": "\\hookleftarrow", "↪": "\\hookrightarrow",
        "⇀": "\\rightharpoonup", "↼": "\\leftharpoonup", "⇌": "\\rightleftharpoons",
        "⇝": "\\rightsquigarrow", "↝": "\\rightsquigarrow",
        // Delimiters, dots and the rest.
        "⟨": "\\langle", "⟩": "\\rangle", "〈": "\\langle", "〉": "\\rangle",
        "∶": ":", "∕": "/", "⧵": "\\setminus", "⌠": "\\int", "⌡": "", "⎮": "", "⎛": "(", "⎜": "", "⎝": "", "⎞": ")", "⎟": "", "⎠": "",
        "⎡": "[", "⎢": "", "⎣": "", "⎤": "]", "⎥": "", "⎦": "", "⎧": "\\{", "⎨": "", "⎩": "",
        "⎪": "", "⎫": "\\}", "⎬": "", "⎭": "", "⌊": "\\lfloor", "⌋": "\\rfloor", "⌈": "\\lceil", "⌉": "\\rceil",
        "{": "\\{", "}": "\\}", "#": "\\#", "%": "\\%", "&": "\\&", "_": "\\_",
        "′": "'", "″": "''", "‴": "'''", "…": "\\ldots", "⋯": "\\cdots", "⋮": "\\vdots",
        "⋱": "\\ddots", "ℓ": "\\ell", "ℏ": "\\hbar", "℘": "\\wp", "ℜ": "\\Re", "ℑ": "\\Im",
        "ℵ": "\\aleph", "°": "^\\circ", "□": "\\square", "■": "\\blacksquare",
        "♢": "\\diamondsuit", "♣": "\\clubsuit", "♡": "\\heartsuit", "♠": "\\spadesuit",
        "§": "\\S", "¶": "\\P", "✓": "\\checkmark", "✗": "\\times", "∎": "\\blacksquare",
        // Invisible operators and the odd spaces, which draw nothing.
        "\u{2061}": "", "\u{2062}": "", "\u{2063}": "", "\u{2064}": "", "\u{00A0}": " ",
        "\u{2009}": " ", "\u{200A}": " ", "\u{202F}": " ", "\u{2005}": " ", "\u{2006}": " ",
    ]

    /// A glyph that is a piece of a drawing rather than a symbol — the tips
    /// and middle of a horizontal brace, the shaft of a tall arrow — and so
    /// spells nothing, without being unreadable.
    static func isDecoration(_ name: String?) -> Bool {
        guard let name else { return false }
        return name.hasPrefix("braceh") || name.hasPrefix("braceex") || name.hasPrefix("bracketleftex")
            || name.hasPrefix("bracketrightex") || name.hasPrefix("parenleftex")
            || name.hasPrefix("parenrightex") || name.hasPrefix("arrowvertex")
            || name.hasPrefix("arrowdblvertex") || name.hasPrefix("radicalvertex")
            || name == "bracerightmid" || name == "braceleftmid" || name == "braceleftbt"
            || name == "bracerightbt" || name == "bracelefttp" || name == "bracerighttp"
    }

    /// True when this glyph is a large operator that takes limits above and
    /// below rather than beside.
    ///
    /// The extension fonts name each size of one — "uniontext",
    /// "uniondisplay", "summationdisplay.1" — and the symbol fonts name the
    /// small binary operator after the same thing: CMSY's "union" is ∪, which
    /// takes no limits. So a name is a big operator when it has a size on it,
    /// or is one of the few that exist only as operators.
    static func isBigOperator(_ name: String?) -> Bool {
        guard let name else { return false }
        let stem = stripped(name)
        for size in ["text", "display"] where stem.hasSuffix(size) {
            return bigOperatorStems.contains(String(stem.dropLast(size.count)))
        }
        return ["summation", "product", "integral", "coproduct", "contintegral"].contains(stem)
    }

    private static let bigOperatorStems: Set<String> = [
        "summation", "product", "integral", "union", "intersection", "coproduct", "logicaland",
        "logicalor", "circleplus", "circlemultiply", "circledot", "unionmulti", "unionsq",
        "contintegral",
    ]

    /// A glyph name with its variant suffix taken off: "summationdisplay.1"
    /// is the same sign as "summationdisplay", drawn from a second font.
    static func stripped(_ name: String) -> String {
        guard let dot = name.firstIndex(of: "."), dot != name.startIndex else { return name }
        return String(name[..<dot])
    }

    /// An accent that grows to cover what is under it: \widehat, \widetilde.
    static func isWideAccent(_ name: String?) -> Bool {
        guard let name else { return false }
        let stem = stripped(name)
        return stem.hasPrefix("hatwide") || stem.hasPrefix("tildewide")
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
        // STIX builds a tall bar from "bar.x" pieces: the bar with its
        // variant suffix.
        let stem = stripped(name)
        if name.hasPrefix("vextenddouble") || stem == "bardbl" || name.hasPrefix("bardblex") { return "\\|" }
        // newtx builds a tall bar from "barex" pieces.
        if name.hasPrefix("vextendsingle") || stem == "bar" || name.hasPrefix("barex") { return "|" }
        return nil
    }

    /// The accent a glyph is, by its name: the marks TeX's roman font draws
    /// for \\hat, \\bar and the rest, and the maths italic's arrow for \\vec.
    /// (An arrow from the symbol font is an arrow: the "→" of n\\to\\infty
    /// sat close enough to its "n" to be read as \\vec{n}.)
    static func accent(_ name: String?) -> String? {
        guard let name else { return nil }
        switch stripped(name) {
        case "circumflex", "hatwide", "hatwider", "hatwidest": return "\\hat"
        case "tilde", "tildewide", "tildewider", "tildewidest": return "\\tilde"
        case "macron": return "\\bar"
        case "dotaccent", "dotacc": return "\\dot"
        case "dieresis", "ddotacc": return "\\ddot"
        case "dddotacc": return "\\dddot"
        case "ddddotacc": return "\\ddddot"
        case "caron": return "\\check"
        case "breve": return "\\breve"
        case "acute": return "\\acute"
        case "grave": return "\\grave"
        case "ring": return "\\mathring"
        case "vector", "vec": return "\\vec"
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
        // The fonts call the ε "epsilon" and the ϵ "epsilon1" — Unicode's
        // U+03B5 is the ε — and in LaTeX the ε is \\varepsilon.
        table["epsilon"] = "\\varepsilon"

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
            "universalAlt": "\\forall", "existentialAlt": "\\exists",
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
            "uniontext": "\\bigcup", "intersectiontext": "\\bigcap",
            "coproductdisplay": "\\coprod", "coproducttext": "\\coprod",
            "logicalandtext": "\\bigwedge", "logicalanddisplay": "\\bigwedge",
            "logicalortext": "\\bigvee", "logicalordisplay": "\\bigvee",
            "circleplustext": "\\bigoplus", "circleplusdisplay": "\\bigoplus",
            "circlemultiplytext": "\\bigotimes", "circlemultiplydisplay": "\\bigotimes",
            "circledottext": "\\bigodot", "circledotdisplay": "\\bigodot",
            "unionmultitext": "\\biguplus", "unionmultidisplay": "\\biguplus",
            "unionsqtext": "\\bigsqcup", "unionsqdisplay": "\\bigsqcup",
            "contintegraltext": "\\oint", "contintegraldisplay": "\\oint",
            "summation": "\\sum", "product": "\\prod", "integral": "\\int",
            "coproduct": "\\coprod",
            "radical": "\\sqrt", "radicalbig": "\\sqrt", "radicalBig": "\\sqrt",
            "radicalbigg": "\\sqrt", "radicalBigg": "\\sqrt", "radicalbt": "\\sqrt",
            "radicallow": "\\sqrt", "radicalmid": "\\sqrt",
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
            // MathTime and the AMS fonts.
            "Delta1": "\\Delta", "Omega1": "\\Omega", "omega1": "\\varpi", "kappa1": "\\varkappa",
            "notsubset": "\\not\\subset",
            "lessequalslant": "\\leqslant", "greaterequalslant": "\\geqslant",
            "lessorsimilar": "\\lesssim", "greaterorsimilar": "\\gtrsim",
            "definequal": "\\triangleq", "colonequal": ":=", "hbar": "\\hbar", "planckover2pi": "\\hbar",
            "square": "\\square", "blacksquare": "\\blacksquare", "checkmark": "\\checkmark",
            "vector": "\\vec", "therefore": "\\therefore", "because": "\\because",
            "arrowlongright": "\\longrightarrow", "arrowlongleft": "\\longleftarrow",
            "arrowdbllongright": "\\Longrightarrow", "arrowlongboth": "\\longleftrightarrow",
            "mapstolong": "\\longmapsto",
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
        return nil
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
