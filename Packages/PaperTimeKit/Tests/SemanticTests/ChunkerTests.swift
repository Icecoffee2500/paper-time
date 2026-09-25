import Foundation
import Testing
@testable import Semantic

@Suite("Pages cut into passages")
struct ChunkerTests {
    let paper = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!

    private func words(_ count: Int, from start: Int = 0) -> String {
        (start..<start + count).map { "w\($0)" }.joined(separator: " ")
    }

    @Test("A page with no words has no passages")
    func empty() {
        #expect(SemanticChunker.chunks(ofPage: "", paperID: paper, pageIndex: 0).isEmpty)
        #expect(SemanticChunker.chunks(ofPage: " \n\t\u{3000} ", paperID: paper, pageIndex: 0).isEmpty)
    }

    @Test("A short page is one passage from its first word to its last")
    func short() throws {
        let page = "  \nElastic weight\tconsolidation   slows learning.\n"
        let chunks = SemanticChunker.chunks(ofPage: page, paperID: paper, pageIndex: 4)
        let chunk = try #require(chunks.first)
        #expect(chunks.count == 1)
        #expect(chunk.paperID == paper)
        #expect(chunk.pageIndex == 4)
        #expect(chunk.text == "Elastic weight consolidation slows learning.")
        #expect((page as NSString).substring(with: chunk.range) == "Elastic weight\tconsolidation   slows learning.")
    }

    @Test("Windows of 100 words step by 75, and the last one ends at the page's end")
    func windows() {
        let chunks = SemanticChunker.chunks(ofPage: words(250), paperID: paper, pageIndex: 0)
        #expect(chunks.map { $0.text.split(separator: " ").first! } == ["w0", "w75", "w150"])
        #expect(chunks.map { $0.text.split(separator: " ").count } == [100, 100, 100])
        #expect(chunks.last!.text.hasSuffix("w249"))

        let uneven = SemanticChunker.chunks(ofPage: words(180), paperID: paper, pageIndex: 0)
        #expect(uneven.map { $0.text.split(separator: " ").first! } == ["w0", "w75", "w150"])
        #expect(uneven.map { $0.text.split(separator: " ").count } == [100, 100, 30])

        let exact = SemanticChunker.chunks(ofPage: words(100), paperID: paper, pageIndex: 0)
        #expect(exact.count == 1)
        let one = SemanticChunker.chunks(ofPage: words(101), paperID: paper, pageIndex: 0)
        #expect(one.count == 2)
        #expect(one[1].text.split(separator: " ").count == 26)
    }

    @Test("Neighbouring windows share 25 words")
    func overlap() {
        let chunks = SemanticChunker.chunks(ofPage: words(400), paperID: paper, pageIndex: 0)
        for (a, b) in zip(chunks, chunks.dropFirst()) {
            let tail = a.text.split(separator: " ").suffix(25)
            let head = b.text.split(separator: " ").prefix(25)
            #expect(Array(tail) == Array(head))
        }
    }

    @Test("Ranges are UTF-16 offsets on the page, past emoji and Hangul")
    func utf16() {
        let prefix = "😀 강화학습의 기초 "   // an emoji is two UTF-16 units
        let page = prefix + words(120)
        let chunks = SemanticChunker.chunks(ofPage: page, paperID: paper, pageIndex: 0)
        let ns = page as NSString
        #expect(chunks[0].location == 0)
        #expect(ns.substring(with: chunks[0].range).hasPrefix("😀 강화학습의"))
        for chunk in chunks {
            let original = ns.substring(with: chunk.range)
            #expect(original.split(whereSeparator: \.isWhitespace).joined(separator: " ") == chunk.text)
        }
        #expect(ns.substring(with: chunks[1].range).hasPrefix("w72"))   // 3 words before w0
    }

    @Test("The key is the text's, not its line breaks' or its place's")
    func keys() {
        let a = SemanticChunker.chunks(ofPage: "machine\nunlearning  removes data", paperID: paper, pageIndex: 0)[0]
        let b = SemanticChunker.chunks(ofPage: "machine unlearning removes\tdata", paperID: UUID(), pageIndex: 9)[0]
        #expect(a.key == b.key)
        #expect(a.key != SemanticChunker.chunks(ofPage: "machine unlearning removes datum", paperID: paper, pageIndex: 0)[0].key)
    }

    @Test("The key is the first half of the text's SHA-256")
    func digest() {
        // sha256("hello") = 2cf24dba5fb0a30e 26e83b2ac5b9e29e 1b161e5c1fa7425e 73043362938b9824
        let key = ChunkKey(text: "hello")
        #expect(key.high == 0x2cf2_4dba_5fb0_a30e)
        #expect(key.low == 0x26e8_3b2a_c5b9_e29e)
        #expect(key.description == "2cf24dba5fb0a30e26e83b2ac5b9e29e")
    }
}
