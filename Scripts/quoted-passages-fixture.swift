// The answers the Portable build's `shared/quotedPassages.ts` is held to: the
// Mac's own `QuotedPassages` on a set of note bodies, which passages a paper
// gets from a handful of notes, and where a quotation's words are in the
// text of the page it was quoted from.
//
//     swiftc -O -parse-as-library \
//       Packages/PaperTimeKit/Sources/PaperCore/Model/NoteAnchor.swift \
//       Packages/PaperTimeKit/Sources/PaperCore/Model/NoteMath.swift \
//       Packages/PaperTimeKit/Sources/PaperCore/Model/NoteCode.swift \
//       Packages/PaperTimeKit/Sources/PaperCore/Model/Zettel.swift \
//       Packages/PaperTimeKit/Sources/PaperCore/Model/QuotedPassages.swift \
//       Scripts/quoted-passages-fixture.swift -o /tmp/quoted-passages-fixture
//     /tmp/quoted-passages-fixture > Packages/PaperTimeKit/Tests/PaperCoreTests/Fixtures/quoted-passages.json
//
// Change QuotedPassages and run this again; both builds' tests read the file.
import Foundation

@main
enum QuotedPassagesFixture {
    static let paperA = "4F3A1C08-1111-2222-3333-444455556666"
    static let paperB = "9B2E7D10-AAAA-BBBB-CCCC-DDDDEEEEFFFF"

    static let bodies = [
        // ⌘L on the Mac: the paper is named every time.
        "> the encoder is trained with a masked objective [4쪽](papertime://anchor?p=3&x=145.00&y=95.00&w=366.50&h=12.00&paper=\(paperA))\n",
        // Portable's: no paper, two lines, thoughts after.
        "Intro line\n> first line of the quote\n> second line [p. 2](papertime://anchor?p=1&x=72.00&y=600.00&w=240.00&h=24.00)\n\nmy thoughts",
        // Two passages quoted back to back run together as one block.
        "> one [1쪽](papertime://anchor?p=0&x=1.00&y=2.00&w=3.00&h=4.00)\n> two\n> two more [2쪽](papertime://anchor?p=1&x=5.00&y=6.00&w=7.00&h=8.00)\n",
        // A displayed formula puts the page link on a line of its own.
        "> Loss is\n> $$\\mathcal{L} = 1$$\n> [5쪽](papertime://anchor?p=4&x=100.00&y=200.00&w=300.00&h=40.00)",
        // A passage dropped into a sentence, the way links were once made.
        "As shown in [the encoder is trained…](papertime://anchor?p=2&x=10.00&y=20.00&w=30.00&h=5.00), we see.",
        // In a block of code it is code.
        "```\n[p. 1](papertime://anchor?p=0&x=1.00&y=1.00&w=1.00&h=1.00)\n```\nafter",
        // Nowhere to draw: no height, no width, no page.
        "[p](papertime://anchor?p=0&x=1&y=1&w=1) [q](papertime://anchor?p=0&x=1.00&y=1.00&w=0.00&h=1.00) [r](papertime://anchor?x=1&y=1&w=1&h=1)",
        // Brackets in the label, escaped.
        "> words [see \\[1\\] 3쪽](papertime://anchor?p=2&x=50.00&y=60.00&w=70.00&h=8.00)",
        // Three spaces is still a quote; four is not.
        "   > quoted [p. 9](papertime://anchor?p=8&x=1.00&y=2.00&w=3.00&h=4.00)\n    > not a quote [p. 10](papertime://anchor?p=9&x=1.00&y=2.00&w=3.00&h=4.00)",
        // Windows line breaks.
        "> crlf quote [p. 1](papertime://anchor?p=0&x=1.00&y=2.00&w=3.00&h=4.00)\r\nnext",
        // Offsets are UTF-16, past a surrogate pair.
        "😀 메모\n> 인용 [3쪽](papertime://anchor?p=2&x=1.00&y=2.00&w=3.00&h=4.00)",
        // An aside typed right over a quotation joins it.
        "> my own aside\n> the quoted words [7쪽](papertime://anchor?p=6&x=9.00&y=8.00&w=7.00&h=6.00)",
        // Another paper's passage, the paper written in small letters.
        "> elsewhere [2쪽](papertime://anchor?p=1&x=3.00&y=4.00&w=5.00&h=6.00&paper=\(paperB.lowercased()))",
        // A citation in the quoted words: the link is the page's, not "[48] …".
        "> Tip-Adapter [48] solves the cache memory problem [3쪽](papertime://anchor?p=2&x=50.00&y=554.00&w=236.00&h=21.00)",
        // An older link written round words with a citation in them.
        "> [Tip-Adapter [48] solves the problem](papertime://anchor?p=2&x=1.00&y=2.00&w=3.00&h=4.00)",
        // No passages at all.
        "Just a thought, with a [[202609081530|link]] to another note.",
    ]

    /// Notes about A, about B and about nothing, each quoting a passage
    /// of A and of B one way or the other.
    static let notes: [(paper: String?, body: String)] = [
        (paperA, "> own, unnamed [1쪽](papertime://anchor?p=0&x=1.00&y=1.00&w=1.00&h=1.00)\n> own, named [2쪽](papertime://anchor?p=1&x=1.00&y=1.00&w=1.00&h=1.00&paper=\(paperA))\n\n> of B [3쪽](papertime://anchor?p=2&x=1.00&y=1.00&w=1.00&h=1.00&paper=\(paperB))"),
        (paperB, "> B's own [4쪽](papertime://anchor?p=3&x=1.00&y=1.00&w=1.00&h=1.00)\n\n> of A [5쪽](papertime://anchor?p=4&x=1.00&y=1.00&w=1.00&h=1.00&paper=\(paperA.lowercased()))"),
        (nil, "A draft quoting [A](papertime://anchor?p=5&x=1.00&y=1.00&w=1.00&h=1.00&paper=\(paperA)) and an unnamed one [?](papertime://anchor?p=6&x=1.00&y=1.00&w=1.00&h=1.00)"),
    ]

    /// A quotation as a note writes it, and a stretch of a page's text it
    /// was quoted from — the text a passage's box holds, line by line.
    static let spans: [(quotation: String, text: String)] = [
        // The slide a reader quoted, as MathReader read its «ï» then, and as
        // PDFKit hands the page over: the accent and a dotless i apart.
        ("> (na\\\u{308}imathve method $O(n)$) [27쪽](papertime://anchor?p=26&x=153.13&y=154.78&w=110.56&h=10.46)\n", "(na\u{A8} \u{131}ve method O(n))\n"),
        // The same passage read well, its line whole: only the passage.
        ("> (naïve method $O(n)$) [27쪽](papertime://anchor?p=26&x=153.13&y=154.78&w=110.56&h=10.46)\n", "Sample data: O(ln(n)) (na\u{A8} \u{131}ve method O(n))\n"),
        // Two lines of a column, the passage starting and ending mid-line.
        ("> Tip-Adapter [48] solves the cache memory problem by only storing few-shot samples per class [3쪽](papertime://anchor?p=2&x=50.00&y=554.00&w=236.00&h=21.00)\n", "natively, Tip-Adapter [48] solves the cache memory prob-\nlem by only storing few-shot samples per class to create a\n"),
        // A heading and a list as MathReader writes them.
        ("> ## Method\n> - First item\n> - Second item [2쪽](papertime://anchor?p=1&x=1.00&y=2.00&w=3.00&h=4.00)\n", "3 Method\n• First item\n• Second item\nThird item\n"),
        // Ligatures and capitals.
        ("> The FINAL efficiency [p. 1](papertime://anchor?p=0&x=1.00&y=1.00&w=1.00&h=1.00)", "and the \u{FB01}nal e\u{FB03}ciency of"),
        // A formula in the middle, spelled differently on either side.
        ("> We minimize $\\mathcal{L}(\\theta)$ over the data. [4쪽](papertime://anchor?p=3&x=1.00&y=1.00&w=1.00&h=1.00)", "Then we minimize L(\u{3B8}) over the data. Next"),
        // Words taken out of the middle by hand.
        ("> The results show … improvements on all benchmarks.", "As expected, the results show that our method yields consistent improvements on all benchmarks. Further"),
        // A passage that runs on to the next page: its close is not here.
        ("> We propose a simple method that works well across many settings and scales [p. 5](papertime://anchor?p=4&x=1.00&y=1.00&w=1.00&h=1.00)", "intro text. We propose a simple method that\nworks well across"),
        // Nothing in common.
        ("> $$\\frac{a}{b}$$\n> [1쪽](papertime://anchor?p=0&x=1.00&y=1.00&w=1.00&h=1.00)", "completely different words"),
        // Short, and exact.
        ("> loss [1쪽](papertime://anchor?p=0&x=1.00&y=1.00&w=1.00&h=1.00)", "the loss function"),
        // Korean, with its full stop.
        ("> 한국어 문장을 인용했어요. [3쪽](papertime://anchor?p=2&x=1.00&y=1.00&w=1.00&h=1.00)", "앞 문장이에요. 한국어 문장을 인용했어요. 뒤 문장"),
        // Mathematical letters outside the basic plane: UTF-16 offsets.
        ("> $x + y = 1$ [1쪽](papertime://anchor?p=0&x=1.00&y=1.00&w=1.00&h=1.00)", "so \u{1D465} + \u{1D466} = 1 holds"),
        // Brackets the quotation opens and closes with.
        ("> (see Fig. 2) [p. 4](papertime://anchor?p=3&x=1.00&y=1.00&w=1.00&h=1.00)", "as shown (see Fig. 2) here"),
        // Only the link: no words.
        ("[1쪽](papertime://anchor?p=0&x=1.00&y=1.00&w=1.00&h=1.00)", "anything at all"),
        // The phrase twice: the first place it is whole.
        ("> the model is good", "the model the model is good"),
        // Windows line breaks, and a dotless j.
        ("> line one\r\n> line \u{237}oins [p](papertime://anchor?p=0&x=1.00&y=1.00&w=1.00&h=1.00)", "line one\nline joins"),
    ]

    static func main() throws {
        func span(_ range: NSRange) -> [Int] { [range.location, NSMaxRange(range)] }
        func passage(_ found: QuotedPassage) -> [String: Any] {
            let rect = found.anchor.rect
            return [
                "url": found.url, "page": found.anchor.pageIndex,
                "rect": [rect.minX, rect.minY, rect.width, rect.height],
                "paper": found.anchor.paperID?.uuidString ?? NSNull(),
                "link": span(found.link), "quote": span(found.quote),
            ]
        }
        let notes = bodies.map { body in ["body": body, "passages": QuotedPassages.passages(in: body).map(passage)] as [String: Any] }
        var papers: [[String: Any]] = []
        for paper in [paperA, paperB] {
            let id = UUID(uuidString: paper)!
            var urls: [[Any]] = []
            for (index, note) in Self.notes.enumerated() {
                let zettel = Zettel(id: "n\(index)", title: "", body: note.body, paperID: note.paper.flatMap(UUID.init(uuidString:)))
                for found in QuotedPassages.passages(in: zettel, of: id) { urls.append([index, found.url]) }
            }
            papers.append(["paper": paper, "passages": urls])
        }
        let shelf = Self.notes.map { ["paper": $0.paper ?? NSNull(), "body": $0.body] as [String: Any] }
        let found = spans.map { item -> [String: Any] in
            let span = QuotedPassages.span(of: item.quotation, in: item.text)
            return ["quotation": item.quotation, "text": item.text,
                    "span": span.map { [$0.lowerBound, $0.upperBound] as Any } ?? NSNull()]
        }
        let data = try JSONSerialization.data(
            withJSONObject: ["bodies": notes, "notes": shelf, "papers": papers, "spans": found],
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
