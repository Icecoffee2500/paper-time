import Foundation
import Testing
@testable import Semantic

@Suite("The tokenizer gives Hugging Face's ids")
struct TokenizerTests {
    let tokenizer = try! WordPieceTokenizer.bundled()

    @Test("The vocabulary is the model's: 30,522 entries")
    func vocabulary() {
        #expect(tokenizer.vocabularySize == 30522)
    }

    @Test("Every reference string, id for id")
    func reference() {
        let cases = Reference.shared.tokens
        #expect(cases.count == 51)
        var wrong: [String] = []
        for item in cases {
            let ids = tokenizer.encode(item.text, maxLength: Reference.shared.max_seq_length)
            if ids != item.ids {
                wrong.append("\(item.text.prefix(40).debugDescription): \(ids.prefix(24)) ≠ \(item.ids.prefix(24))")
            }
        }
        #expect(wrong.isEmpty, "\(wrong.count) of \(cases.count) differ:\n\(wrong.joined(separator: "\n"))")
    }

    @Test("A text longer than the model reads is cut to 256 ids, [SEP] last")
    func truncation() {
        let long = Reference.shared.tokens.first { $0.note != nil }!
        let ids = tokenizer.encode(long.text)
        #expect(ids.count == 256)
        #expect(ids.first == WordPieceTokenizer.classID)
        #expect(ids.last == WordPieceTokenizer.separatorID)
        #expect(tokenizer.pieces(of: long.text).count > 254)
    }

    /// Cases outside the shared fixture, each pinning one rule, with the ids
    /// `BertTokenizerFast` (tokenizers 0.22.2) gave for them. Several are
    /// about which Unicode the rules are read from: the categories come from
    /// tables frozen at Unicode 8.0, so a mark or punctuation added later is
    /// a letter to the model, and a character whose category changed since
    /// keeps the old one.
    @Test("The edges the fixture does not reach", arguments: [
        ("[MASK] x [CLS]", [101, 103, 1060, 101, 102]),        // special tokens are found first, anywhere
        ("[mask]", [101, 1031, 7308, 1033, 102]),              // …but only as written
        ("a[SEP]b", [101, 1037, 102, 1038, 102]),              // …even inside a word
        ("x [PAD] y", [101, 1060, 0, 1061, 102]),
        ("İstanbul", [101, 9960, 102]),                         // NFD strips the dot before lowercasing
        ("ΣΑΣ", [101, 1173, 14608, 29733, 102]),                // lowercase by character: σ, not ς
        ("ẞ", [101, 1096, 102]),
        ("ǅ", [101, 100, 102]),
        ("a\u{00AD}b", [101, 11113, 102]),                     // Cf is dropped
        ("x\u{200D}y", [101, 1060, 2100, 102]),                 // and joins what was either side
        ("a\u{E000}b", [101, 11113, 102]),                      // Co is dropped
        ("a\u{000B}b", [101, 11113, 102]),                      // a control that is also white space: dropped
        ("a\u{2028}b", [101, 1037, 1038, 102]),                 // white space that is not a control: a break
        ("a\u{3000}b", [101, 1037, 1038, 102]),
        ("a \u{0378} b", [101, 1037, 100, 1038, 102]),          // unassigned is not dropped
        ("a \u{1F970} b", [101, 1037, 100, 1038, 102]),         // an emoji newer than Unicode 9 is a word
        ("a\u{2E42}b", [101, 1037, 100, 1038, 102]),            // punctuation from Unicode 7: split off
        ("a\u{2E45}b", [101, 100, 102]),                        // punctuation from Unicode 10: part of the word
        ("ab\u{1AB0}", [101, 11113, 102]),                      // a mark from Unicode 7: stripped
        ("q\u{1AC1}", [101, 100, 102]),                         // a mark from Unicode 14: kept
        ("a\u{08D4}b", [101, 100, 102]),                        // a mark from Unicode 9: kept, so 8.0 is the cut
        ("a\u{166D}b", [101, 1037, 100, 1038, 102]),            // Po in 8.0, So now: still punctuation
        ("a\u{1734}b", [101, 11113, 102]),                      // Mn in 8.0, Mc now: still stripped
        ("a\u{1885}b", [101, 100, 102]),                        // Lo in 8.0, Mn now: still a letter
        ("a\u{2B820}b", [101, 100, 102]),                       // the library's CJK range starts at 2B920…
        ("a\u{2B920}b", [101, 1037, 100, 1038, 102]),           // …so this one is split off and that one is not
        ("x\u{20DD}", [101, 100, 102]),                         // an enclosing mark (Me) is not Mn
        ("a·b", [101, 1037, 1087, 1038, 102]),                  // Po outside ASCII is punctuation
        ("a´b", [101, 1037, 29658, 2497, 102]),                 // Sk outside ASCII is not
        ("a^b", [101, 1037, 1034, 1038, 102]),                  // Sk inside ASCII is
        ("\u{FB01}", [101, 1984, 102]),                         // NFD, not NFKD: the ligature stays
        (String(repeating: "\u{00E9}", count: 101), [101, 100, 102]),  // 101 characters once decomposed
    ] as [(String, [Int32])])
    func edges(text: String, ids: [Int32]) {
        #expect(tokenizer.encode(text) == ids)
    }

    @Test("A limit stops the work, not only the output")
    func limit() {
        let text = String(repeating: "catastrophic forgetting ", count: 400)
        let ids = tokenizer.encode(text, maxLength: 16)
        #expect(ids.count == 16)
        #expect(ids == [101] + Array(tokenizer.pieces(of: text).prefix(14)) + [102])
    }
}
