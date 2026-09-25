import Foundation

/// BERT's uncased WordPiece tokenizer, as all-MiniLM-L6-v2 uses it.
///
/// The model only ever saw ids made by Hugging Face's `tokenizers` (the Rust
/// library behind `BertTokenizerFast`, which is what sentence-transformers
/// loads), so the job here is not "a WordPiece tokenizer" but *that one*: a
/// different id for the same text is a different point in the space, and the
/// search quietly gets worse without anything looking wrong. Every rule below
/// is there because that library does it, in the order it does it:
///
/// 1. The five special tokens (`[PAD]` `[UNK]` `[CLS]` `[SEP]` `[MASK]`) are
///    found in the raw text first, before anything is lowercased, and become
///    their own ids wherever they stand — even inside a word, even when the
///    text is a paper about BERT that writes `[MASK]` in its prose.
/// 2. Clean: NUL, U+FFFD and control characters (Cc, Cf, Co — but not
///    unassigned code points, which survive to become `[UNK]`) are dropped;
///    every kind of white space becomes a space.
/// 3. CJK ideographs get a space on either side, so each is a word.
///    Hangul and kana are not in those ranges and are not split.
/// 4. NFD, then every non-spacing mark (Mn) is dropped: "Almudévar" is read
///    as "almudevar". Hangul syllables decompose into jamo here, which is why
///    Korean comes out as a string of jamo pieces.
/// 5. Lowercase, one character at a time — so a final Σ is σ, not ς, because
///    that is what a per-character mapping gives.
/// 6. Split on white space and around punctuation: the ASCII punctuation
///    set (which includes `$ + < = > ^ \` | ~`) and Unicode's P categories.
/// 7. WordPiece: a word longer than 100 characters is `[UNK]`; otherwise the
///    longest prefix in the vocabulary, then the longest `##` continuation,
///    and if any step finds nothing the whole word is `[UNK]`.
///
/// Steps 2, 4 and 6 read general categories from tables frozen at Unicode
/// 8.0, not from whatever the OS knows: a punctuation mark or combining mark
/// added since then is, to the model, a letter. `Unicode.Scalar.Properties.age`
/// answers "added when", so the categories below are the OS's, cut off at
/// 8.0, and the seven code points whose category Unicode changed after 8.0
/// are answered from a list (`categoryThen`). Both were found by tokenizing
/// every code point, alone and between two letters, with both tokenizers
/// (`Scripts/wordpiece-sweep.py codepoints`): with the cut-off, the list and
/// the library's own CJK ranges, all 528,394 strings give the same ids.
/// White space, NFD and the
/// lowercase mapping come from the Rust standard library and the
/// normalisation crate, which follow current Unicode, so those are not cut.
public struct WordPieceTokenizer: Sendable {
    public static let padID: Int32 = 0
    public static let unknownID: Int32 = 100
    public static let classID: Int32 = 101
    public static let separatorID: Int32 = 102
    public static let maskID: Int32 = 103
    /// The model's `max_seq_length`: longer texts are cut to this many ids,
    /// `[CLS]` and `[SEP]` included.
    public static let maxLength = 256
    static let maxCharactersPerWord = 100

    /// The vocabulary as two tries sharing one edge table: node 0 is the root
    /// for the first piece of a word, node 1 the root for `##` pieces. A trie
    /// rather than a dictionary of strings because Swift's `String` compares
    /// by canonical equivalence and the vocabulary must be matched by code
    /// point, and because walking it finds the longest match in one pass.
    private let edges: [UInt64: Int32]
    private let idAtNode: [Int32]
    public let vocabularySize: Int
    private static let wordRoot: Int32 = 0
    private static let pieceRoot: Int32 = 1

    private static let specials: [(name: [Unicode.Scalar], id: Int32)] = [
        ("[PAD]", padID), ("[UNK]", unknownID), ("[CLS]", classID), ("[SEP]", separatorID), ("[MASK]", maskID),
    ].map { (Array($0.0.unicodeScalars), $0.1) }

    /// `vocab.txt`: one token per line, the line number is the id.
    public init(vocabulary: String) {
        var edges: [UInt64: Int32] = [:]
        var idAtNode: [Int32] = [-1, -1]
        var lines = vocabulary.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true { lines.removeLast() }
        edges.reserveCapacity(lines.count * 4)
        for (index, line) in lines.enumerated() {
            var scalars = Array(line.unicodeScalars)
            var node = Self.wordRoot
            if scalars.count > 2, scalars[0] == "#", scalars[1] == "#" {
                scalars.removeFirst(2)
                node = Self.pieceRoot
            }
            for scalar in scalars {
                let key = Self.edge(node, scalar)
                if let next = edges[key] {
                    node = next
                } else {
                    let next = Int32(idAtNode.count)
                    idAtNode.append(-1)
                    edges[key] = next
                    node = next
                }
            }
            idAtNode[Int(node)] = Int32(index)
        }
        self.edges = edges
        self.idAtNode = idAtNode
        self.vocabularySize = lines.count
    }

    public init(contentsOf url: URL) throws {
        self.init(vocabulary: try String(contentsOf: url, encoding: .utf8))
    }

    // MARK: - Encoding

    /// `[CLS]`, the text's pieces, `[SEP]` — cut so the whole is at most
    /// `maxLength` ids, as sentence-transformers cuts it (by piece, not by
    /// word: the last word may lose its tail).
    public func encode(_ text: String, maxLength: Int = WordPieceTokenizer.maxLength) -> [Int32] {
        var ids: [Int32] = [Self.classID]
        ids.reserveCapacity(min(maxLength, text.utf8.count / 3 + 8))
        pieces(of: text, limit: max(maxLength - 2, 0), into: &ids)
        ids.append(Self.separatorID)
        return ids
    }

    /// The text's pieces without `[CLS]`/`[SEP]` and without a limit.
    public func pieces(of text: String) -> [Int32] {
        var ids: [Int32] = []
        pieces(of: text, limit: .max, into: &ids)
        return ids
    }

    private func pieces(of text: String, limit: Int, into ids: inout [Int32]) {
        let start = ids.count
        let scalars = Array(text.unicodeScalars)
        var from = 0
        var index = 0
        func full() -> Bool { ids.count - start >= limit }
        while index < scalars.count, !full() {
            if scalars[index] == "[", let special = Self.special(in: scalars, at: index) {
                words(in: scalars[from..<index], limit: limit - (ids.count - start), into: &ids)
                if full() { break }
                ids.append(special.id)
                index += special.length
                from = index
            } else {
                index += 1
            }
        }
        if !full() {
            words(in: scalars[from..<scalars.count], limit: limit - (ids.count - start), into: &ids)
        }
        if ids.count - start > limit { ids.removeLast(ids.count - start - limit) }
    }

    private static func special(in scalars: [Unicode.Scalar], at index: Int) -> (id: Int32, length: Int)? {
        for special in specials where index + special.name.count <= scalars.count {
            if scalars[index..<index + special.name.count].elementsEqual(special.name) {
                return (special.id, special.name.count)
            }
        }
        return nil
    }

    /// Steps 2–7 for a stretch of text with no special token in it.
    private func words(in segment: ArraySlice<Unicode.Scalar>, limit: Int, into ids: inout [Int32]) {
        guard limit > 0, !segment.isEmpty else { return }
        let normalized = Self.normalize(segment)
        let before = ids.count
        var word: [Unicode.Scalar] = []
        word.reserveCapacity(32)
        func flush() {
            guard !word.isEmpty else { return }
            wordPiece(word, into: &ids)
            word.removeAll(keepingCapacity: true)
        }
        for scalar in normalized {
            if ids.count - before >= limit { break }
            if scalar == " " || Self.isWhitespace(scalar) {
                flush()
            } else if Self.isPunctuation(scalar) {
                flush()
                word.append(scalar)
                flush()
            } else {
                word.append(scalar)
            }
        }
        if ids.count - before < limit { flush() }
    }

    private func wordPiece(_ word: [Unicode.Scalar], into ids: inout [Int32]) {
        if word.count > Self.maxCharactersPerWord {
            ids.append(Self.unknownID)
            return
        }
        let mark = ids.count
        var start = 0
        while start < word.count {
            var node = start == 0 ? Self.wordRoot : Self.pieceRoot
            var best: (end: Int, id: Int32)?
            var index = start
            while index < word.count, let next = edges[Self.edge(node, word[index])] {
                node = next
                index += 1
                let id = idAtNode[Int(node)]
                if id >= 0 { best = (index, id) }
            }
            guard let best else {
                ids.removeLast(ids.count - mark)
                ids.append(Self.unknownID)
                return
            }
            ids.append(best.id)
            start = best.end
        }
    }

    private static func edge(_ node: Int32, _ scalar: Unicode.Scalar) -> UInt64 {
        UInt64(UInt32(bitPattern: node)) << 32 | UInt64(scalar.value)
    }

    // MARK: - Normalisation (steps 2–5)

    static func normalize(_ segment: ArraySlice<Unicode.Scalar>) -> [Unicode.Scalar] {
        // Most of a paper is ASCII, and for ASCII the whole of steps 2–5 is
        // "drop controls, space for white space, lowercase".
        if segment.allSatisfy({ $0.isASCII }) {
            var out: [Unicode.Scalar] = []
            out.reserveCapacity(segment.count)
            for scalar in segment {
                let value = scalar.value
                if value == 9 || value == 10 || value == 13 || value == 32 {
                    out.append(" ")
                } else if value < 32 || value == 127 {
                    continue
                } else if value >= 65, value <= 90 {
                    out.append(Unicode.Scalar(value + 32)!)
                } else {
                    out.append(scalar)
                }
            }
            return out
        }
        var cleaned = String.UnicodeScalarView()
        for scalar in segment {
            let value = scalar.value
            if value == 0 || value == 0xFFFD || isControl(scalar) { continue }
            if isWhitespace(scalar) {
                cleaned.append(" ")
            } else if isCJK(value) {
                cleaned.append(" ")
                cleaned.append(scalar)
                cleaned.append(" ")
            } else {
                cleaned.append(scalar)
            }
        }
        let decomposed = String(cleaned).decomposedStringWithCanonicalMapping
        var out: [Unicode.Scalar] = []
        out.reserveCapacity(decomposed.unicodeScalars.count)
        for scalar in decomposed.unicodeScalars {
            if scalar.isASCII {
                let value = scalar.value
                out.append(value >= 65 && value <= 90 ? Unicode.Scalar(value + 32)! : scalar)
                continue
            }
            if isNonspacingMark(scalar) { continue }
            let lower = scalar.properties.lowercaseMapping
            if lower.unicodeScalars.count == 1, lower.unicodeScalars.first == scalar {
                out.append(scalar)
            } else {
                out.append(contentsOf: lower.unicodeScalars)
            }
        }
        return out
    }

    /// The Unicode version the tokenizer's category tables were made from.
    static let categoryTables = Unicode.Version(major: 8, minor: 0)

    static func known(_ scalar: Unicode.Scalar) -> Bool {
        guard let age = scalar.properties.age else { return false }
        return age.major < categoryTables.major
            || (age.major == categoryTables.major && age.minor <= categoryTables.minor)
    }

    enum Then { case punctuation, nonspacingMark, other }

    /// Code points that existed in Unicode 8.0 with a category that matters
    /// here and have since been given another one. The OS answers with the
    /// new category; the model was trained on the old.
    static let categoryThen: [UInt32: Then] = [
        0x166D: .punctuation,     // CANADIAN SYLLABICS CHI SIGN: Po, now So
        0x111C9: .punctuation,    // SHARADA SANDHI MARK: Po, now Mn
        0x1734: .nonspacingMark,  // HANUNOO SIGN PAMUDPOD: Mn, now Mc
        0x1171E: .nonspacingMark, // AHOM CONSONANT SIGN MEDIAL RA: Mn, now Mc
        0x1885: .other,           // MONGOLIAN LETTER ALI GALI BALUDA: Lo, now Mn
        0x1886: .other,           // MONGOLIAN LETTER ALI GALI THREE BALUDA: Lo, now Mn
        0xA9BD: .other,           // JAVANESE CONSONANT SIGN KERET: Mc, now Mn
    ]

    static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 9, 10, 13: return false
        default: break
        }
        switch scalar.properties.generalCategory {
        case .control, .privateUse, .surrogate: return true
        case .format: return known(scalar)
        default: return false
        }
    }

    static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 9, 10, 13, 32: return true
        default: return scalar.properties.isWhitespace
        }
    }

    static func isPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if value < 128 {
            return (33...47).contains(value) || (58...64).contains(value)
                || (91...96).contains(value) || (123...126).contains(value)
        }
        if let then = categoryThen[value] { return then == .punctuation }
        switch scalar.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation:
            return known(scalar)
        default:
            return false
        }
    }

    static func isNonspacingMark(_ scalar: Unicode.Scalar) -> Bool {
        if let then = categoryThen[scalar.value] { return then == .nonspacingMark }
        return scalar.properties.generalCategory == .nonspacingMark && known(scalar)
    }

    /// BERT's CJK ranges as the Rust library writes them — which is with
    /// 0x2B920 where Google's original has 0x2B820, so the first 256
    /// ideographs of Extension E are not split off. The model learned from
    /// that library's ids, so this copies the slip rather than fixing it.
    static func isCJK(_ value: UInt32) -> Bool {
        (0x4E00...0x9FFF).contains(value) || (0x3400...0x4DBF).contains(value)
            || (0x20000...0x2A6DF).contains(value) || (0x2A700...0x2B73F).contains(value)
            || (0x2B740...0x2B81F).contains(value) || (0x2B920...0x2CEAF).contains(value)
            || (0xF900...0xFAFF).contains(value) || (0x2F800...0x2FA1F).contains(value)
    }
}
