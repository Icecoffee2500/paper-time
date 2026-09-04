import Testing
@testable import Bibliography

@Suite("LaTeXEscaping")
struct LaTeXEscapingTests {

    // MARK: - Special characters

    @Test("Backslash escapes to \\textbackslash{} without being re-escaped")
    func escapesBackslash() {
        #expect(LaTeXEscaping.escape("a\\b") == "a\\textbackslash{}b")
    }

    @Test("Ampersand escapes to \\&")
    func escapesAmpersand() {
        #expect(LaTeXEscaping.escape("Q&A") == "Q\\&A")
    }

    @Test("Percent escapes to \\%")
    func escapesPercent() {
        #expect(LaTeXEscaping.escape("50%") == "50\\%")
    }

    @Test("Dollar sign escapes to \\$")
    func escapesDollar() {
        #expect(LaTeXEscaping.escape("$5") == "\\$5")
    }

    @Test("Hash escapes to \\#")
    func escapesHash() {
        #expect(LaTeXEscaping.escape("#1") == "\\#1")
    }

    @Test("Underscore escapes to \\_")
    func escapesUnderscore() {
        #expect(LaTeXEscaping.escape("a_b") == "a\\_b")
    }

    @Test("Curly braces escape to \\{ and \\}")
    func escapesBraces() {
        #expect(LaTeXEscaping.escape("{x}") == "\\{x\\}")
    }

    @Test("Tilde escapes to \\textasciitilde{}")
    func escapesTilde() {
        #expect(LaTeXEscaping.escape("a~b") == "a\\textasciitilde{}b")
    }

    @Test("Caret escapes to \\textasciicircum{}")
    func escapesCaret() {
        #expect(LaTeXEscaping.escape("x^2") == "x\\textasciicircum{}2")
    }

    @Test("All ten special characters together stay independently escaped")
    func escapesAllSpecialCharactersTogether() {
        let input = "\\&%$#_{}~^"
        let escaped = LaTeXEscaping.escape(input)
        #expect(escaped == "\\textbackslash{}\\&\\%\\$\\#\\_\\{\\}\\textasciitilde{}\\textasciicircum{}")
    }

    // MARK: - Dashes

    @Test("En dash and em dash escape to double/triple hyphen")
    func escapesDashes() {
        #expect(LaTeXEscaping.escape("pp. 1\u{2013}20") == "pp. 1--20")
        #expect(LaTeXEscaping.escape("a\u{2014}b") == "a---b")
    }

    @Test("Triple hyphen unescapes to em dash before double hyphen collapses it")
    func unescapesTripleDashAsEmDashNotEnDashPlusHyphen() {
        #expect(LaTeXEscaping.unescape("a---b") == "a\u{2014}b")
        #expect(LaTeXEscaping.unescape("a--b") == "a\u{2013}b")
    }

    // MARK: - Greek letters

    @Test("Greek letters map to inline math")
    func escapesGreekLetters() {
        #expect(LaTeXEscaping.escape("\u{03B1}-divergence") == "$\\alpha$-divergence")
        #expect(LaTeXEscaping.escape("\u{03A9}") == "$\\Omega$")
    }

    @Test("Greek math mode round-trips through unescape")
    func roundTripsGreekLetters() {
        let title = "\u{03B1}-divergence and \u{03C7}\u{00B2} tests under \u{03A9}"
        #expect(LaTeXEscaping.unescape(LaTeXEscaping.escape(title)) == title)
    }

    // MARK: - Alternate accent spellings found in real .bib files

    @Test("The three common alternate spellings of an acute accent all decode to the same letter")
    func unescapesAlternateAccentSpellings() {
        #expect(LaTeXEscaping.unescape("{\\'{e}}") == "\u{00E9}") // é
        #expect(LaTeXEscaping.unescape("\\'{e}") == "\u{00E9}")
        #expect(LaTeXEscaping.unescape("\\'e") == "\u{00E9}")
    }

    @Test("Alternate spellings work for other accent marks too")
    func unescapesAlternateSpellingsForOtherMarks() {
        #expect(LaTeXEscaping.unescape("{\\\"{o}}") == "\u{00F6}") // ö
        #expect(LaTeXEscaping.unescape("\\\"{o}") == "\u{00F6}")
        #expect(LaTeXEscaping.unescape("\\\"o") == "\u{00F6}")
        #expect(LaTeXEscaping.unescape("{\\~{n}}") == "\u{00F1}") // ñ
        #expect(LaTeXEscaping.unescape("\\~{n}") == "\u{00F1}")
        #expect(LaTeXEscaping.unescape("\\~n") == "\u{00F1}")
    }

    @Test("Cedilla and other letter-word marks decode with or without braces")
    func unescapesLetterWordMarks() {
        #expect(LaTeXEscaping.unescape("{\\c{c}}") == "\u{00E7}") // ç
        #expect(LaTeXEscaping.unescape("\\c{c}") == "\u{00E7}")
        #expect(LaTeXEscaping.unescape("\\c c") == "\u{00E7}")
        #expect(LaTeXEscaping.unescape("{\\v z}") == "\u{017E}") // ž (caron)
    }

    // MARK: - Case-protection brace stripping

    @Test("A brace group that is only there for case protection is stripped")
    func stripsCaseProtectionBraces() {
        #expect(LaTeXEscaping.unescape("{GAN}") == "GAN")
        #expect(LaTeXEscaping.unescape("{DNA} sequencing") == "DNA sequencing")
    }

    @Test("Brace stripping happens after command substitution, not before")
    func stripsCaseProtectionBracesAfterCommandSubstitution() {
        // The outer braces around the accent command are consumed as part of
        // the command itself, not left behind for the stripping pass to eat.
        #expect(LaTeXEscaping.unescape("{\\'e}tude") == "\u{00E9}tude")
        #expect(LaTeXEscaping.unescape("{GAN}s for {\\'e}tudes") == "GANs for \u{00E9}tudes")
    }

    // MARK: - Idempotence

    @Test("Unescaping plain ASCII text is a no-op")
    func unescapeIsIdempotentOnPlainASCII() {
        let plain = "A Simple Study of Ordinary English Sentences, 2024."
        #expect(LaTeXEscaping.unescape(plain) == plain)
        #expect(LaTeXEscaping.unescape(LaTeXEscaping.unescape(plain)) == plain)
    }

    @Test("Unescaping malformed/unknown commands never crashes and passes them through")
    func unescapeToleratesUnknownCommands() {
        #expect(LaTeXEscaping.unescape("\\cite{foo} says \\unknownmacro hi") == "\\cite{foo} says \\unknownmacro hi")
        #expect(LaTeXEscaping.unescape("\\") == "\\")
        #expect(LaTeXEscaping.unescape("\\'") == "\\'")
    }

    // MARK: - Round-tripping realistic bibliography text

    @Test(
        "Realistic paper titles and author names round-trip through escape/unescape",
        arguments: [
            "Müller, Schrödinger & Gödel", // German umlauts + ampersand
            "François Beauchêne", // French
            "Núñez, Peña, and García", // Spanish
            "Åse Søgaard and Björn Ångström", // Nordic
            "Łukasz Kowalski and Wojciech Żółć", // Polish
            "İnönü, Öztürk, and Çelik", // Turkish
            "Naïve Bayes for Café Menus", // French/mixed diacritics
            "The α-divergence and χ² Statistic", // Greek + special char
            "50% Faster — A New Approach", // percent + em dash
            "Section #3: A_B Testing at $Cost$", // hash, underscore, dollar
            "Deep Learning — 2020\u{2013}2024 Survey", // em dash + en dash
            "Erdős, Rényi, and Turán", // Hungarian double acute
            "Æther Theory Revisited", // ae ligature
            "Œuvre Complète de Œrsted", // oe ligature
        ]
    )
    func roundTripsRealisticText(_ original: String) {
        let escaped = LaTeXEscaping.escape(original)
        let restored = LaTeXEscaping.unescape(escaped)
        #expect(restored == original)
    }

    // MARK: - Individual accent coverage across scripts

    @Test(
        "Individual accented letters escape and unescape symmetrically",
        arguments: [
            "\u{00E9}", "\u{00E8}", "\u{00EA}", "\u{00EB}", // é è ê ë
            "\u{00F1}", "\u{00E7}", "\u{00F8}", "\u{00E5}", // ñ ç ø å
            "\u{00E6}", "\u{0153}", "\u{00DF}", "\u{0142}", // æ œ ß ł
            "\u{0111}", "\u{0101}", "\u{0103}", "\u{01CE}", // đ ā ă ǎ
            "\u{0151}", "\u{1EA1}", // ő ạ
        ]
    )
    func roundTripsIndividualAccentedLetters(_ character: String) {
        let escaped = LaTeXEscaping.escape(character)
        #expect(escaped.hasPrefix("{\\"))
        #expect(LaTeXEscaping.unescape(escaped) == character)
    }

    @Test("Non-ASCII characters with no mapping pass through escape unchanged")
    func passesThroughUnmappedNonASCII() {
        let emoji = "Paper 📄 Notes"
        #expect(LaTeXEscaping.escape(emoji) == emoji)
        #expect(LaTeXEscaping.unescape(emoji) == emoji)
    }

    @Test("Non-breaking space escapes to a TeX tie")
    func escapesNonBreakingSpace() {
        #expect(LaTeXEscaping.escape("Fig.\u{00A0}1") == "Fig.~1")
    }

    @Test("Ellipsis escapes to \\ldots{}")
    func escapesEllipsis() {
        #expect(LaTeXEscaping.escape("wait\u{2026}") == "wait\\ldots{}")
        #expect(LaTeXEscaping.unescape("wait\\ldots{}") == "wait\u{2026}")
    }

    @Test("Double backtick/apostrophe pairs round-trip as curly double quotes")
    func roundTripsCurlyDoubleQuotes() {
        let title = "\u{201C}Attention Is All You Need\u{201D}"
        let escaped = LaTeXEscaping.escape(title)
        #expect(escaped == "``Attention Is All You Need''")
        #expect(LaTeXEscaping.unescape(escaped) == title)
    }
}
