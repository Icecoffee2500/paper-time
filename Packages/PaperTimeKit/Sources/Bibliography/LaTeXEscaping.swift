import Foundation

/// Converts between plain Unicode text and the LaTeX markup that BibTeX field
/// values traditionally use. `.bib` files were designed around 7-bit ASCII, so
/// anything outside that range is conventionally spelled out as a LaTeX command.
public enum LaTeXEscaping {

    // MARK: - Source-of-truth tables
    //
    // `unescape` derives its reverse-lookup tables from these dictionaries at
    // static-init time (see `argumentlessCommands` / `markLetterToAccented` /
    // `greekNameToChar` below) instead of duplicating the mappings by hand, so
    // escape and unescape can never drift out of sync with each other.

    /// The ten characters LaTeX itself treats specially.
    static let specialCharacters: [Character: String] = [
        "\\": "\\textbackslash{}",
        "&": "\\&",
        "%": "\\%",
        "$": "\\$",
        "#": "\\#",
        "_": "\\_",
        "{": "\\{",
        "}": "\\}",
        "~": "\\textasciitilde{}",
        "^": "\\textasciicircum{}",
    ]

    /// Accented Latin letters (Latin-1 Supplement + the common Latin Extended-A
    /// letters, plus a couple of Extended-B/Extended-Additional examples for
    /// caron- and dot-below-marked vowels). Every command is wrapped in braces
    /// so BibTeX's brace-counting field parser, and its case-folding logic for
    /// sorting/abbreviating names, treat the accent + letter as one opaque
    /// "character" instead of splitting on the backslash or lower-casing just
    /// the base letter.
    static let accentedLetters: [Character: String] = [
        // Latin-1 Supplement
        "À": "{\\`A}", "Á": "{\\'A}", "Â": "{\\^A}", "Ã": "{\\~A}", "Ä": "{\\\"A}",
        "Å": "{\\AA}", "Æ": "{\\AE}", "Ç": "{\\c C}",
        "È": "{\\`E}", "É": "{\\'E}", "Ê": "{\\^E}", "Ë": "{\\\"E}",
        "Ì": "{\\`I}", "Í": "{\\'I}", "Î": "{\\^I}", "Ï": "{\\\"I}",
        "Ð": "{\\DH}", "Ñ": "{\\~N}",
        "Ò": "{\\`O}", "Ó": "{\\'O}", "Ô": "{\\^O}", "Õ": "{\\~O}", "Ö": "{\\\"O}", "Ø": "{\\O}",
        "Ù": "{\\`U}", "Ú": "{\\'U}", "Û": "{\\^U}", "Ü": "{\\\"U}",
        "Ý": "{\\'Y}", "Þ": "{\\TH}", "ß": "{\\ss}",
        "à": "{\\`a}", "á": "{\\'a}", "â": "{\\^a}", "ã": "{\\~a}", "ä": "{\\\"a}",
        "å": "{\\aa}", "æ": "{\\ae}", "ç": "{\\c c}",
        "è": "{\\`e}", "é": "{\\'e}", "ê": "{\\^e}", "ë": "{\\\"e}",
        "ì": "{\\`i}", "í": "{\\'i}", "î": "{\\^i}", "ï": "{\\\"i}",
        "ð": "{\\dh}", "ñ": "{\\~n}",
        "ò": "{\\`o}", "ó": "{\\'o}", "ô": "{\\^o}", "õ": "{\\~o}", "ö": "{\\\"o}", "ø": "{\\o}",
        "ù": "{\\`u}", "ú": "{\\'u}", "û": "{\\^u}", "ü": "{\\\"u}",
        "ý": "{\\'y}", "þ": "{\\th}", "ÿ": "{\\\"y}",

        // Latin Extended-A
        "Ā": "{\\=A}", "ā": "{\\=a}", "Ă": "{\\u A}", "ă": "{\\u a}", "Ą": "{\\k A}", "ą": "{\\k a}",
        "Ć": "{\\'C}", "ć": "{\\'c}", "Ĉ": "{\\^C}", "ĉ": "{\\^c}", "Ċ": "{\\.C}", "ċ": "{\\.c}",
        "Č": "{\\v C}", "č": "{\\v c}", "Ď": "{\\v D}", "ď": "{\\v d}", "Đ": "{\\DJ}", "đ": "{\\dj}",
        "Ē": "{\\=E}", "ē": "{\\=e}", "Ĕ": "{\\u E}", "ĕ": "{\\u e}", "Ė": "{\\.E}", "ė": "{\\.e}",
        "Ę": "{\\k E}", "ę": "{\\k e}", "Ě": "{\\v E}", "ě": "{\\v e}",
        "Ĝ": "{\\^G}", "ĝ": "{\\^g}", "Ğ": "{\\u G}", "ğ": "{\\u g}", "Ġ": "{\\.G}", "ġ": "{\\.g}",
        "Ģ": "{\\c G}", "ģ": "{\\c g}", "Ĥ": "{\\^H}", "ĥ": "{\\^h}",
        "Ĩ": "{\\~I}", "ĩ": "{\\~i}", "Ī": "{\\=I}", "ī": "{\\=i}", "Ĭ": "{\\u I}", "ĭ": "{\\u i}",
        "Į": "{\\k I}", "į": "{\\k i}", "İ": "{\\.I}", "ı": "{\\i}",
        "Ĵ": "{\\^J}", "ĵ": "{\\^j}", "Ķ": "{\\c K}", "ķ": "{\\c k}",
        "Ĺ": "{\\'L}", "ĺ": "{\\'l}", "Ļ": "{\\c L}", "ļ": "{\\c l}", "Ľ": "{\\v L}", "ľ": "{\\v l}",
        "Ł": "{\\L}", "ł": "{\\l}",
        "Ń": "{\\'N}", "ń": "{\\'n}", "Ņ": "{\\c N}", "ņ": "{\\c n}", "Ň": "{\\v N}", "ň": "{\\v n}",
        "Ō": "{\\=O}", "ō": "{\\=o}", "Ŏ": "{\\u O}", "ŏ": "{\\u o}", "Ő": "{\\H O}", "ő": "{\\H o}",
        "Œ": "{\\OE}", "œ": "{\\oe}",
        "Ŕ": "{\\'R}", "ŕ": "{\\'r}", "Ŗ": "{\\c R}", "ŗ": "{\\c r}", "Ř": "{\\v R}", "ř": "{\\v r}",
        "Ś": "{\\'S}", "ś": "{\\'s}", "Ŝ": "{\\^S}", "ŝ": "{\\^s}", "Ş": "{\\c S}", "ş": "{\\c s}",
        "Š": "{\\v S}", "š": "{\\v s}",
        "Ţ": "{\\c T}", "ţ": "{\\c t}", "Ť": "{\\v T}", "ť": "{\\v t}",
        "Ũ": "{\\~U}", "ũ": "{\\~u}", "Ū": "{\\=U}", "ū": "{\\=u}", "Ŭ": "{\\u U}", "ŭ": "{\\u u}",
        "Ů": "{\\r U}", "ů": "{\\r u}", "Ű": "{\\H U}", "ű": "{\\H u}", "Ų": "{\\k U}", "ų": "{\\k u}",
        "Ŵ": "{\\^W}", "ŵ": "{\\^w}", "Ŷ": "{\\^Y}", "ŷ": "{\\^y}", "Ÿ": "{\\\"Y}",
        "Ź": "{\\'Z}", "ź": "{\\'z}", "Ż": "{\\.Z}", "ż": "{\\.z}", "Ž": "{\\v Z}", "ž": "{\\v z}",

        // A couple of illustrative marks outside Extended-A (caron/dot-below),
        // called out explicitly because they show up in Vietnamese and Slavic names.
        "Ǎ": "{\\v A}", "ǎ": "{\\v a}", "Ạ": "{\\d A}", "ạ": "{\\d a}",
    ]

    /// Typographic punctuation with conventional TeX spellings.
    static let punctuation: [Character: String] = [
        "\u{2013}": "--",               // en dash
        "\u{2014}": "---",              // em dash
        "\u{2018}": "`",                // left single quote
        "\u{2019}": "'",                // right single quote
        "\u{201C}": "``",               // left double quote
        "\u{201D}": "''",               // right double quote
        "\u{2026}": "\\ldots{}",        // ellipsis
        "\u{00A0}": "~",                // non-breaking space -> TeX tie
        "\u{00B0}": "{\\textdegree}",
        "\u{00D7}": "{\\texttimes}",
        "\u{00B1}": "{\\textpm}",
        "\u{00B5}": "{\\textmu}",
        "\u{00A9}": "{\\textcopyright}",
        "\u{2192}": "{\\textrightarrow}",
    ]

    /// Greek letters have no accent-style command of their own; the only
    /// portable way to render one in a LaTeX document is inline math mode.
    static let greekLetters: [Character: String] = {
        let lower: [(Character, String)] = [
            ("\u{03B1}", "alpha"), ("\u{03B2}", "beta"), ("\u{03B3}", "gamma"),
            ("\u{03B4}", "delta"), ("\u{03B5}", "epsilon"), ("\u{03B6}", "zeta"),
            ("\u{03B7}", "eta"), ("\u{03B8}", "theta"), ("\u{03B9}", "iota"),
            ("\u{03BA}", "kappa"), ("\u{03BB}", "lambda"), ("\u{03BC}", "mu"),
            ("\u{03BD}", "nu"), ("\u{03BE}", "xi"), ("\u{03C0}", "pi"),
            ("\u{03C1}", "rho"), ("\u{03C3}", "sigma"), ("\u{03C4}", "tau"),
            ("\u{03C5}", "upsilon"), ("\u{03C6}", "phi"), ("\u{03C7}", "chi"),
            ("\u{03C8}", "psi"), ("\u{03C9}", "omega"),
        ]
        let upper: [(Character, String)] = [
            ("\u{0393}", "Gamma"), ("\u{0394}", "Delta"), ("\u{0398}", "Theta"),
            ("\u{039B}", "Lambda"), ("\u{039E}", "Xi"), ("\u{03A0}", "Pi"),
            ("\u{03A3}", "Sigma"), ("\u{03A6}", "Phi"), ("\u{03A8}", "Psi"),
            ("\u{03A9}", "Omega"),
        ]
        var table: [Character: String] = [:]
        for (character, name) in lower + upper {
            table[character] = "$\\\(name)$"
        }
        return table
    }()

    // MARK: - escape

    /// One merged lookup used by `escape`. Building it once avoids repeated
    /// dictionary merges on every call.
    private static let escapeTable: [Character: String] = {
        var table = specialCharacters
        for (character, latex) in accentedLetters { table[character] = latex }
        for (character, latex) in punctuation { table[character] = latex }
        for (character, latex) in greekLetters { table[character] = latex }
        return table
    }()

    /// Converts a plain Unicode string into a BibTeX-safe LaTeX field value.
    ///
    /// This walks `text` exactly once and only ever reads from `text` (never
    /// from what it has already written to `result`), so a backslash that
    /// `escapeTable` introduces - e.g. the one in `\textbackslash{}` - can
    /// never be picked back up and escaped a second time.
    public static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            if let mapped = escapeTable[character] {
                result += mapped
            } else {
                // No LaTeX mapping: pass through unchanged. Modern .bib files
                // are UTF-8, so an un-escaped character is still valid output.
                result.append(character)
            }
        }
        return result
    }

    // MARK: - unescape

    /// Marks that attach directly to their letter with no separating space,
    /// e.g. `\'e`.
    private static let markCharacters: Set<Character> = ["'", "`", "^", "\"", "~", "=", "."]

    /// Marks spelled as a short word that conventionally takes a space before
    /// their letter argument, e.g. `\c c`, `\v z`, `\H o`.
    private static let letterMarks: Set<String> = ["u", "v", "k", "H", "d", "c", "r"]

    /// `\&`, `\%`, ... escape a single literal character with no argument and
    /// no letter-command form, so they're handled before anything else.
    private static let directEscapes: Set<Character> = ["&", "%", "$", "#", "_"]

    /// Strips at most one layer of wrapping braces and the leading backslash
    /// from a table's LaTeX spelling, returning the bare command word only if
    /// what's left is a plain letter run (i.e. a no-argument command like
    /// `aa`, `ss`, `textdegree`). Mark commands like `'e` or `c c` fail this
    /// and are handled by `markLetterKey` instead.
    private static func bareCommandWord(from latex: String) -> String? {
        var body = Substring(latex)
        if body.count >= 2, body.first == "{", body.last == "}" {
            body = body.dropFirst().dropLast()
        }
        guard body.first == "\\" else { return nil }
        body = body.dropFirst()
        if body.hasSuffix("{}") {
            body = body.dropLast(2)
        }
        guard !body.isEmpty, body.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        return String(body)
    }

    /// Parses an accent table entry into the `"<mark><letter>"` key used by
    /// `markLetterToAccented`, e.g. `{\'e}` -> `"'e"`, `{\c c}` -> `"cc"`.
    /// Returns nil for entries `bareCommandWord` already handles.
    private static func markLetterKey(from latex: String) -> String? {
        var body = Substring(latex)
        if body.count >= 2, body.first == "{", body.last == "}" {
            body = body.dropFirst().dropLast()
        }
        guard body.first == "\\" else { return nil }
        body = body.dropFirst()
        guard !body.isEmpty else { return nil }

        if let spaceIndex = body.firstIndex(of: " ") {
            let markWord = body[body.startIndex..<spaceIndex]
            let rest = body[body.index(after: spaceIndex)...]
            guard rest.count == 1, let letter = rest.first, letter.isASCII, letter.isLetter else { return nil }
            return "\(markWord)\(letter)"
        }
        guard let first = body.first, !(first.isASCII && first.isLetter) else { return nil }
        let rest = body.dropFirst()
        guard rest.count == 1, let letter = rest.first, letter.isASCII, letter.isLetter else { return nil }
        return "\(first)\(letter)"
    }

    /// No-argument commands (`\aa`, `\ss`, `\textdegree`, `\ldots`, ...),
    /// derived from every table entry whose LaTeX spelling is just a bare
    /// command word, so this can't drift from what `escape` actually emits.
    private static let argumentlessCommands: [String: String] = {
        var table: [String: String] = [:]
        for (character, latex) in accentedLetters {
            if let word = bareCommandWord(from: latex) { table[word] = String(character) }
        }
        for (character, latex) in specialCharacters {
            if let word = bareCommandWord(from: latex) { table[word] = String(character) }
        }
        for (character, latex) in punctuation {
            if let word = bareCommandWord(from: latex) { table[word] = String(character) }
        }
        return table
    }()

    /// `"<mark><letter>"` -> accented character, derived from `accentedLetters`.
    private static let markLetterToAccented: [String: Character] = {
        var table: [String: Character] = [:]
        for (character, latex) in accentedLetters {
            if let key = markLetterKey(from: latex) { table[key] = character }
        }
        return table
    }()

    /// Greek command name (no backslash/`$`) -> character, derived from `greekLetters`.
    private static let greekNameToChar: [String: Character] = {
        var table: [String: Character] = [:]
        for (character, latex) in greekLetters {
            var body = Substring(latex)
            guard body.count >= 2, body.first == "$", body.last == "$" else { continue }
            body = body.dropFirst().dropLast()
            guard body.first == "\\" else { continue }
            table[String(body.dropFirst())] = character
        }
        return table
    }()

    /// Matches `$\command$` (Greek math mode) starting at `chars[i] == "$"`.
    private static func matchGreek(_ chars: [Character], _ i: Int) -> (String, Int)? {
        guard i + 1 < chars.count, chars[i + 1] == "\\" else { return nil }
        var j = i + 2
        var name = ""
        while j < chars.count, chars[j].isASCIILetter {
            name.append(chars[j])
            j += 1
        }
        guard j < chars.count, chars[j] == "$", let character = greekNameToChar[name] else { return nil }
        return (String(character), j + 1)
    }

    /// Attempts to parse one LaTeX command starting at the backslash at
    /// `chars[backslashIndex]`. Returns the plain-text replacement and the
    /// index just past everything the command consumed (its own trailing
    /// `{}` if any, but not an outer wrapping brace - the caller owns that),
    /// or nil if this isn't a command this type recognizes.
    private static func handleBackslashAt(_ chars: [Character], _ backslashIndex: Int) -> (String, Int)? {
        let idx = backslashIndex + 1
        guard idx < chars.count else { return nil }

        if chars[idx] == "{" { return ("\u{E002}", idx + 1) } // literal '{', shielded from case-brace stripping
        if chars[idx] == "}" { return ("\u{E003}", idx + 1) } // literal '}', ditto
        if directEscapes.contains(chars[idx]) { return (String(chars[idx]), idx + 1) }

        var wordEnd = idx
        while wordEnd < chars.count, chars[wordEnd].isASCIILetter {
            wordEnd += 1
        }
        let word = String(chars[idx..<wordEnd])

        if let replacement = argumentlessCommands[word] {
            var end = wordEnd
            // \textbackslash{} etc. use an empty group to terminate the command
            // name; consume it so it isn't mistaken for a case-protection brace.
            if end + 1 < chars.count, chars[end] == "{", chars[end + 1] == "}" {
                end += 2
            }
            return (replacement, end)
        }

        var mark = ""
        var markEnd = idx
        if markCharacters.contains(chars[idx]) {
            mark = String(chars[idx])
            markEnd = idx + 1
        } else if wordEnd > idx, letterMarks.contains(word) {
            mark = word
            markEnd = wordEnd
        } else {
            return nil // unrecognized command; caller leaves it untouched
        }

        var argIndex = markEnd
        if argIndex < chars.count, chars[argIndex] == " " {
            argIndex += 1
        }
        var braced = false
        if argIndex < chars.count, chars[argIndex] == "{" {
            braced = true
            argIndex += 1
        }
        guard argIndex < chars.count, chars[argIndex].isASCIILetter else { return nil }
        let letter = chars[argIndex]
        var end = argIndex + 1
        if braced {
            guard end < chars.count, chars[end] == "}" else { return nil }
            end += 1
        }
        guard let accented = markLetterToAccented["\(mark)\(letter)"] else { return nil }
        return (String(accented), end)
    }

    /// Converts LaTeX markup back into plain Unicode. Used when importing .bib files.
    public static func unescape(_ latex: String) -> String {
        // The three-dash form must be checked before the two-dash form, or
        // "---" would be read as an en dash followed by a stray hyphen.
        var text = latex.replacingOccurrences(of: "---", with: "\u{2014}")
        text = text.replacingOccurrences(of: "--", with: "\u{2013}")

        let chars = Array(text)
        var result = ""
        result.reserveCapacity(chars.count)
        var i = 0

        // Braces that wrap a command we don't recognize (e.g. the `{...}` in
        // `\cite{foo}`) are shielded with sentinels so the case-protection
        // pass below - which runs after every command has been substituted -
        // can tell them apart from bare `{GAN}`-style protection braces.
        var braceIsShielded: [Bool] = []
        var nextBraceIsShielded = false

        while i < chars.count {
            let c = chars[i]

            if c == "$", let (replacement, next) = matchGreek(chars, i) {
                result += replacement
                i = next
                nextBraceIsShielded = false
                continue
            }

            if c == "{", i + 1 < chars.count, chars[i + 1] == "\\",
               let (replacement, next) = handleBackslashAt(chars, i + 1) {
                var end = next
                if end < chars.count, chars[end] == "}" { end += 1 } // outer wrap, e.g. {\'e} / {\textdegree}
                result += replacement
                i = end
                nextBraceIsShielded = false
                continue
            }

            if c == "\\" {
                if let (replacement, next) = handleBackslashAt(chars, i) {
                    result += replacement
                    i = next
                    nextBraceIsShielded = false
                    continue
                }
                // Unknown command: keep it verbatim, but remember that a
                // brace group immediately following belongs to its argument,
                // not to plain case protection.
                result.append("\\")
                var j = i + 1
                while j < chars.count, chars[j].isASCIILetter {
                    result.append(chars[j])
                    j += 1
                }
                i = j
                nextBraceIsShielded = true
                continue
            }

            if c == "{" {
                braceIsShielded.append(nextBraceIsShielded)
                result.append(nextBraceIsShielded ? "\u{E000}" : "{")
                nextBraceIsShielded = false
                i += 1
                continue
            }

            if c == "}" {
                let shielded = braceIsShielded.popLast() ?? false
                result.append(shielded ? "\u{E001}" : "}")
                nextBraceIsShielded = false
                i += 1
                continue
            }

            nextBraceIsShielded = false
            result.append(c)
            i += 1
        }

        // Any braces left at this point were never part of a recognized
        // command, so they only ever existed to protect capitalization.
        result = result.replacingOccurrences(of: "{", with: "")
        result = result.replacingOccurrences(of: "}", with: "")

        // Restore literal braces (\{ \}) and unrecognized-command argument
        // braces that were shielded from the stripping pass above.
        result = result.replacingOccurrences(of: "\u{E000}", with: "{")
        result = result.replacingOccurrences(of: "\u{E001}", with: "}")
        result = result.replacingOccurrences(of: "\u{E002}", with: "{")
        result = result.replacingOccurrences(of: "\u{E003}", with: "}")

        // The doubled form is LaTeX's unambiguous curly-quote convention.
        // A single ' or ` is left alone: plain apostrophes/backticks are far
        // more common in real titles than an intentional curly-quote escape,
        // and misreading one would corrupt names like "O'Brien".
        result = result.replacingOccurrences(of: "``", with: "\u{201C}")
        result = result.replacingOccurrences(of: "''", with: "\u{201D}")

        return result
    }
}

extension Character {
    fileprivate var isASCIILetter: Bool { isASCII && isLetter }
}
