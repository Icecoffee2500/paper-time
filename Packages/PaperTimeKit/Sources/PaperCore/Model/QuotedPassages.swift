import Foundation

/// A passage of a paper that a note quotes: where its words are on the page,
/// and where the quotation stands in the note.
///
/// ⌘L writes a passage into a note as a block quote whose page link —
/// `[4쪽](papertime://anchor?p=3&x=…)` — says which page and where on it.
/// That link is the only record there is: nothing goes into the PDF, and
/// nothing beside it. So the way back from the page is found the same way,
/// by reading the notes. A quotation deleted from its note is gone from the
/// page with it, and a note that arrives from another machine brings its
/// passages along.
public struct QuotedPassage: Hashable, Sendable {
    /// The link's address as the note spells it: what the note is searched
    /// for when the quotation is to be found again.
    public var url: String
    public var anchor: NoteAnchor
    /// The `[label](address)` link, in the body's UTF-16 offsets.
    public var link: NSRange
    /// The quotation the link closes: from the first line of its block quote
    /// to the end of the link's line — or the link's own line, for a passage
    /// dropped into a sentence rather than quoted.
    public var quote: NSRange

    public init(url: String, anchor: NoteAnchor, link: NSRange, quote: NSRange) {
        self.url = url
        self.anchor = anchor
        self.link = link
        self.quote = quote
    }
}

public enum QuotedPassages {
    /// `[label](papertime://anchor?…)`. A label may hold escaped brackets —
    /// `escape` writes them so — and brackets in pairs, as the note's own
    /// renderer reads them (`NoteMarkdown.linkPattern`); never a line break.
    static let linkPattern = try! NSRegularExpression(
        pattern: #"\[((?:\\.|[^\\\[\]\n]|\[(?:\\.|[^\\\[\]\n])*\])*)\]\((papertime://anchor[^)\s]*)\)"#
    )

    /// Every passage a note's body links to, in the order they are written.
    /// A link inside a fenced block of code is code, not a link; one whose
    /// address does not say a page and a box with some size to it is
    /// nowhere to draw.
    public static func passages(in body: String) -> [QuotedPassage] {
        guard body.contains("papertime://anchor") else { return [] }
        let text = body as NSString
        let code = NoteCode.blocks(in: body).map(\.range)
        var found: [QuotedPassage] = []
        for match in linkPattern.matches(in: body, range: NSRange(location: 0, length: text.length)) {
            let link = match.range
            if code.contains(where: { NSLocationInRange(link.location, $0) }) { continue }
            let written = text.substring(with: match.range(at: 2))
            guard let url = URL(string: written), let anchor = NoteAnchor(url: url), anchor.pageIndex >= 0,
                  [anchor.rect.minX, anchor.rect.minY, anchor.rect.width, anchor.rect.height].allSatisfy(\.isFinite),
                  anchor.rect.width > 0, anchor.rect.height > 0
            else { continue }
            found.append(QuotedPassage(url: written, anchor: anchor, link: link, quote: quote(closedBy: link, in: text)))
        }
        return found
    }

    /// The passages a note quotes from one paper: the links that name it,
    /// and — in a note about that paper — the links that name no paper.
    /// (The Mac's ⌘L names the paper every time; the Portable build's names
    /// it only when the note is about another one.)
    public static func passages(in note: Zettel, of paperID: UUID) -> [QuotedPassage] {
        passages(in: note.body).filter { ($0.anchor.paperID ?? note.paperID) == paperID }
    }

    /// The quotation a link closes. Lines are split at `\n` only, and a
    /// `\r` before it is left out — the Portable build reads lines the same
    /// way, and the two have to agree to the unit.
    static func quote(closedBy link: NSRange, in text: NSString) -> NSRange {
        let line = self.line(at: link.location, in: text)
        guard isQuote(line, in: text) else { return line }
        var start = line.location
        while start > 0 {
            let above = self.line(at: start - 1, in: text)
            // A quote line that carries a page link of its own ends the
            // quotation before this one: two passages quoted back to back
            // run together as one block.
            guard isQuote(above, in: text), !text.substring(with: above).contains("](papertime://anchor") else { break }
            start = above.location
        }
        return NSRange(location: start, length: NSMaxRange(line) - start)
    }

    /// The line holding a character, without its line break.
    static func line(at index: Int, in text: NSString) -> NSRange {
        let newline = unichar(10), carriage = unichar(13)
        var start = min(max(index, 0), text.length)
        while start > 0, text.character(at: start - 1) != newline { start -= 1 }
        var end = min(max(index, 0), text.length)
        while end < text.length, text.character(at: end) != newline { end += 1 }
        if end > start, text.character(at: end - 1) == carriage { end -= 1 }
        return NSRange(location: start, length: end - start)
    }

    /// A block quote's line: up to three spaces, then `>`.
    static func isQuote(_ line: NSRange, in text: NSString) -> Bool {
        var index = line.location
        var spaces = 0
        while index < NSMaxRange(line), text.character(at: index) == 32, spaces < 3 {
            index += 1
            spaces += 1
        }
        return index < NSMaxRange(line) && text.character(at: index) == 62
    }
}

// MARK: - Where the quoted words are on the page

extension QuotedPassages {
    /// Where a quotation's words lie in a stretch of the page's text — so
    /// the page can tint exactly the passage that was quoted.
    ///
    /// The anchor keeps only the box round the passage, and the box of a
    /// passage that starts in the middle of a line takes in the words before
    /// it: two lines of a column make one box from margin to margin. The
    /// note still holds the words, so they are looked for in the text that
    /// box holds. Only letters and digits are compared — case folded,
    /// accents and ligatures taken apart — since the two were written by
    /// different hands: the note's words came through MathReader (`$…$`,
    /// `**`, headings), the page's through PDFKit or pdf.js (ligatures,
    /// hyphens, line breaks). LaTeX's command words are left out, as the
    /// page has θ where the note has `\theta`.
    ///
    /// The whole quotation is looked for first. One that was edited, or
    /// whose formulas read differently, is placed by the longest stretch of
    /// its opening the text holds and the longest of its close — eight
    /// letters at the least, or the text's own start and end stand in, less
    /// any line there that holds almost nothing of the quotation. Nil when
    /// neither end is there, and for a quotation of fewer than four letters,
    /// which could be found anywhere. The span takes in the punctuation the
    /// quotation opens and closes with («(», «.»). Offsets are UTF-16, into
    /// `text`, whose lines are its `\n`s.
    public static func span(of quotation: String, in text: String) -> Range<Int>? {
        let words = cleaned(quotation)
        let wanted = Keys(words).values
        let page = Keys(text)
        let found = page.values
        guard wanted.count >= 4, !found.isEmpty else { return nil }

        var start: Int?
        var end: Int?
        let head = longestOpening(of: wanted, in: found)
        if head.length == wanted.count {
            start = head.end - head.length
            end = head.end
        } else {
            let enough = min(wanted.count, 8)
            let tail = longestOpening(of: Array(wanted.reversed()), in: Array(found.reversed()))
            if head.length >= enough { start = head.end - head.length }
            if tail.length >= enough { end = found.count - tail.end + tail.length }
            // The two ends found out of order: the longer is believed.
            if let from = start, let to = end, to <= from {
                if head.length >= tail.length { end = nil } else { start = nil }
            }
        }
        guard start != nil || end != nil else { return nil }
        var from = start ?? 0, to = end ?? found.count
        guard to > from else { return nil }
        // Where an end was not found, a line at that end that holds almost
        // nothing of the quotation is a neighbour the box reached into:
        // PDFKit draws the box round a displayed formula as deep as its
        // brackets' font goes, over the line under it.
        let line = lineNumbers(of: page, in: text)
        let belongs = Neighbours(wanted)
        if end == nil {
            while to - 1 > from, line[to - 1] > line[from] {
                var first = to - 1
                while first > from, line[first - 1] == line[to - 1] { first -= 1 }
                if belongs(found[first..<to]) { break }
                to = first
            }
        }
        if start == nil {
            while from < to - 1, line[from] < line[to - 1] {
                var last = from + 1
                while last < to, line[last] == line[from] { last += 1 }
                if belongs(found[from..<last]) { break }
                from = last
            }
        }

        let scalars = Array(text.unicodeScalars)
        var offsets: [Int] = []
        offsets.reserveCapacity(scalars.count + 1)
        var offset = 0
        for scalar in scalars {
            offsets.append(offset)
            offset += scalar.utf16.count
        }
        offsets.append(offset)
        // The quotation's own opening and closing punctuation, where the
        // text has it right against the words — and where it opens or closes
        // with a formula, the formula's marks the text has there: «∇θ» before
        // «L», which the formula's commands do not spell. Any more
        // punctuation than the quotation's own is the sentence's.
        var first = offsets.firstIndex(of: page.from[from]) ?? 0
        let opening = edge(of: words, fromEnd: false)
        if opening.math {
            let core = first
            while first > 0, isFormulaMark(scalars[first - 1]) { first -= 1 }
            var marks = (first..<core).filter { isPunctuation(scalars[$0]) }.count
            while marks > opening.punctuation, first < core, isPunctuation(scalars[first]) {
                first += 1
                marks -= 1
            }
        } else {
            for _ in 0..<opening.punctuation {
                guard first > 0, isPunctuation(scalars[first - 1]) else { break }
                first -= 1
            }
        }
        var last = offsets.firstIndex(of: page.to[to - 1]) ?? scalars.count
        let closing = edge(of: words, fromEnd: true)
        if closing.math {
            let core = last
            while last < scalars.count, isFormulaMark(scalars[last]) { last += 1 }
            var marks = (core..<last).filter { isPunctuation(scalars[$0]) }.count
            while marks > closing.punctuation, last > core, isPunctuation(scalars[last - 1]) {
                last -= 1
                marks -= 1
            }
        } else {
            for _ in 0..<closing.punctuation {
                guard last < scalars.count, isPunctuation(scalars[last]) else { break }
                last += 1
            }
        }
        return offsets[first]..<offsets[last]
    }

    /// Which line of the text each key is on.
    static func lineNumbers(of keys: Keys, in text: String) -> [Int] {
        var breaks: [Int] = []
        var offset = 0
        for unit in text.utf16 {
            if unit == 10 { breaks.append(offset) }
            offset += 1
        }
        var numbers: [Int] = []
        numbers.reserveCapacity(keys.from.count)
        var passed = 0
        for at in keys.from {
            while passed < breaks.count, breaks[passed] < at { passed += 1 }
            numbers.append(passed)
        }
        return numbers
    }

    /// Whether a line's keys are the quotation's: three in ten of its
    /// neighbouring pairs are pairs the quotation has too. A line of one key
    /// is if the quotation has that key — an equation's «(3)».
    struct Neighbours {
        let pairs: Set<UInt64>
        let keys: Set<UInt32>

        init(_ wanted: [UInt32]) {
            pairs = Set(zip(wanted, wanted.dropFirst()).map { UInt64($0) << 32 | UInt64($1) })
            keys = Set(wanted)
        }

        func callAsFunction(_ line: ArraySlice<UInt32>) -> Bool {
            guard line.count >= 2 else { return line.allSatisfy(keys.contains) }
            let shared = zip(line, line.dropFirst()).filter { pairs.contains(UInt64($0) << 32 | UInt64($1)) }.count
            return Double(shared) >= Double(line.count - 1) * 0.3
        }
    }

    /// A quotation as words: its page links taken out, and LaTeX's command
    /// words (`\theta`) and control symbols (`\{`, `\\`) — with the
    /// argument of a command whose argument the page does not print, and
    /// an equation's tag as the number the page prints.
    static func cleaned(_ quotation: String) -> String {
        let linked = linkPattern.stringByReplacingMatches(
            in: quotation, range: NSRange(location: 0, length: (quotation as NSString).length), withTemplate: " "
        )
        let scalars = Array(linked.unicodeScalars)
        var kept = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            guard scalars[index] == "\\" else {
                kept.append(scalars[index])
                index += 1
                continue
            }
            index += 1
            guard index < scalars.count, isASCIILetter(scalars[index]) else {
                if index < scalars.count { index += 1 }
                continue
            }
            var word = ""
            while index < scalars.count, isASCIILetter(scalars[index]) {
                word.unicodeScalars.append(scalars[index])
                index += 1
            }
            guard word == "tag" || unprinted.contains(word) else { continue }
            var next = index
            while next < scalars.count, scalars[next] == " " { next += 1 }
            guard next < scalars.count, scalars[next] == "{" else { continue }
            let open = next
            var depth = 0
            while next < scalars.count {
                if scalars[next] == "{" { depth += 1 }
                if scalars[next] == "}" { depth -= 1 }
                next += 1
                if depth == 0 { break }
            }
            // An equation's number is printed in brackets: «(3)».
            if word == "tag" {
                kept.append("(")
                for scalar in scalars[(open + 1)..<max(open + 1, next - 1)] { kept.append(scalar) }
                kept.append(")")
            }
            index = next
        }
        return String(kept)
    }

    /// Commands whose argument the page does not print: an environment's
    /// name (`\begin{equation}`), a label and what refers to it, a
    /// citation's key, a colour.
    static let unprinted: Set<String> = ["begin", "end", "label", "ref", "eqref", "cite", "color", "textcolor"]

    /// The letters and digits of a text, folded so two hands' spellings of
    /// one passage agree — each with the UTF-16 span of the character it
    /// came from.
    struct Keys {
        var values: [UInt32] = []
        var from: [Int] = []
        var to: [Int] = []

        init(_ text: String) {
            var offset = 0
            for scalar in text.unicodeScalars {
                let width = scalar.utf16.count
                for value in QuotedPassages.keys(of: scalar) {
                    values.append(value)
                    from.append(offset)
                    to.append(offset + width)
                }
                offset += width
            }
        }
    }

    /// One character's keys: taken apart (NFKD — «ﬁ» is «fi», «é» is «e»
    /// and an accent, 𝑥 is x), each letter or digit of that lowercased.
    /// The dotless ı and ȷ are i and j: TeX sets «ï» as a dotless i under
    /// an accent, and PDFKit hands the two over apart — «na¨ ıve».
    static func keys(of scalar: Unicode.Scalar) -> [UInt32] {
        if scalar.isASCII {
            switch scalar.value {
            case 0x41...0x5A: return [scalar.value + 0x20]
            case 0x61...0x7A, 0x30...0x39: return [scalar.value]
            default: return []
            }
        }
        var values: [UInt32] = []
        for part in String(scalar).decomposedStringWithCompatibilityMapping.unicodeScalars where isKey(part) {
            for lower in part.properties.lowercaseMapping.unicodeScalars where isKey(lower) {
                switch lower.value {
                case 0x131: values.append(0x69)
                case 0x237: values.append(0x6A)
                default: values.append(lower.value)
                }
            }
        }
        return values
    }

    /// A letter or a digit — not a modifier letter, which is mostly the
    /// accents a PDF sets on their own (ˆ).
    static func isKey(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .otherLetter, .decimalNumber: true
        default: false
        }
    }

    static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        (0x41...0x5A).contains(scalar.value) || (0x61...0x7A).contains(scalar.value)
    }

    /// Punctuation a passage can open or close with. Not Markdown's own
    /// marks, nor LaTeX's braces.
    static func isPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation:
            !"*_#{}\\".unicodeScalars.contains(scalar)
        default: false
        }
    }

    /// How the words open (or close), before their first (or after their
    /// last) letter or digit: how many marks of punctuation, and whether in
    /// a formula.
    static func edge(of words: String, fromEnd: Bool) -> (punctuation: Int, math: Bool) {
        let scalars = fromEnd ? Array(words.unicodeScalars.reversed()) : Array(words.unicodeScalars)
        var count = 0
        var math = false
        for scalar in scalars {
            if !keys(of: scalar).isEmpty { break }
            if scalar == "$" { math = true }
            if isPunctuation(scalar) { count += 1 }
        }
        return (count, math)
    }

    /// What a formula sets that the words round it are not made of: not a
    /// space, not a Latin letter or a digit — a symbol, a bracket, a Greek
    /// letter, a glyph the text has no letter for.
    static func isFormulaMark(_ scalar: Unicode.Scalar) -> Bool {
        !scalar.properties.isWhitespace && !(scalar.isASCII && keys(of: scalar).count == 1)
    }

    /// The longest opening of `pattern` that `text` holds, and where the
    /// first such stretch ends (exclusive). Knuth–Morris–Pratt: one pass.
    static func longestOpening(of pattern: [UInt32], in text: [UInt32]) -> (length: Int, end: Int) {
        guard !pattern.isEmpty, !text.isEmpty else { return (0, 0) }
        var failure = [Int](repeating: 0, count: pattern.count)
        var matched = 0
        for index in 1..<max(pattern.count, 1) {
            while matched > 0, pattern[index] != pattern[matched] { matched = failure[matched - 1] }
            if pattern[index] == pattern[matched] { matched += 1 }
            failure[index] = matched
        }
        var best = 0, end = 0
        matched = 0
        for (index, value) in text.enumerated() {
            while matched > 0, matched == pattern.count || pattern[matched] != value { matched = failure[matched - 1] }
            if pattern[matched] == value { matched += 1 }
            if matched > best {
                best = matched
                end = index + 1
                if best == pattern.count { break }
            }
        }
        return (best, end)
    }
}
