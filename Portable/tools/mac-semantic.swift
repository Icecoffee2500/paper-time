import Foundation

/// The Mac's own passages and vector cache, for the port to be held to.
///
/// The semantic index is shared between the two builds as a file — the
/// vector cache is keyed by the passage's text and carries the model's name
/// — so "the same index" has to mean the same passages, the same keys and
/// the same bytes. Rather than describe the Swift code in a second language,
/// this compiles the real `SemanticChunker` and `SemanticVectorStore` and
/// asks them. `generate-semantic-fixtures.mjs` compiles and runs it:
///
///     swiftc -O ../Packages/PaperTimeKit/Sources/Semantic/SemanticChunker.swift \
///         ../Packages/PaperTimeKit/Sources/Semantic/SemanticVectorStore.swift \
///         tools/mac-semantic.swift -o /tmp/mac-semantic
///
/// `SemanticModel.swift` is left out because it reaches for `Bundle.module`;
/// the two things it says that matter here are said again below.
///
/// Modes:
///   chunks           stdin: `[{text, paperID, pageIndex, windowWords?, overlapWords?}]`;
///                    stdout: the same list with each page's chunks.
///   store <out>      writes a store of 50 deterministic vectors to `out`
///                    (the generator is `Randoms` from `VectorStoreTests`),
///                    and prints its keys and the first vector as JSON.
///   verify <file>    reads a store, re-encodes it and says whether the bytes
///                    are the same; prints count and first key.
public enum SemanticModel {
    public static let identifier = "all-MiniLM-L6-v2@1110a243/coreml-fp16/1"
    public static let dimension = 384
}

struct Randoms {
    var state: UInt64

    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53)
    }

    mutating func unit(_ d: Int = SemanticModel.dimension) -> [Float] {
        var v = (0..<d).map { _ in Float(next() * 2 - 1) }
        let n = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        for i in v.indices { v[i] /= n }
        return v
    }
}

struct PageRequest: Decodable {
    var text: String
    var paperID: String
    var pageIndex: Int
    var windowWords: Int?
    var overlapWords: Int?
}

struct ChunkOut: Encodable {
    var location: Int
    var length: Int
    var text: String
    var key: String
}

struct PageOut: Encodable {
    var text: String
    var paperID: String
    var pageIndex: Int
    var windowWords: Int
    var overlapWords: Int
    var chunks: [ChunkOut]
}

@main
struct MacSemantic {
    static func main() throws {
        let mode = CommandLine.arguments.dropFirst().first ?? ""
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        switch mode {
        case "chunks":
            let input = FileHandle.standardInput.readDataToEndOfFile()
            let pages = try JSONDecoder().decode([PageRequest].self, from: input)
            let out = pages.map { page -> PageOut in
                let window = page.windowWords ?? SemanticChunker.windowWords
                let overlap = page.overlapWords ?? SemanticChunker.overlapWords
                let chunks = SemanticChunker.chunks(
                    ofPage: page.text, paperID: UUID(uuidString: page.paperID)!, pageIndex: page.pageIndex,
                    windowWords: window, overlapWords: overlap)
                return PageOut(text: page.text, paperID: page.paperID, pageIndex: page.pageIndex,
                               windowWords: window, overlapWords: overlap,
                               chunks: chunks.map { ChunkOut(location: $0.location, length: $0.length, text: $0.text, key: $0.key.description) })
            }
            FileHandle.standardOutput.write(try encoder.encode(out))
        case "store":
            let out = CommandLine.arguments[2]
            var random = Randoms(state: 3)
            var store = SemanticVectorStore()
            var first: [Float] = []
            for i in 0..<50 {
                let v = random.unit()
                if i == 0 { first = v }
                store.insert(v, for: ChunkKey(text: "passage \(i)"))
            }
            try store.encoded().write(to: URL(fileURLWithPath: out))
            struct Report: Encodable { var keys: [String]; var first: [Float]; var bytes: Int }
            FileHandle.standardOutput.write(try encoder.encode(
                Report(keys: store.keys.map(\.description), first: first, bytes: store.encoded().count)))
        case "verify":
            let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
            let store = try SemanticVectorStore(data: data)
            let same = store.encoded() == data
            var probe = [Float](repeating: 0, count: SemanticModel.dimension)
            probe[0] = 1
            let hits = store.search(probe, k: 3)
            struct Report: Encodable { var count: Int; var firstKey: String; var sameBytes: Bool; var top: [String]; var scores: [Float] }
            FileHandle.standardOutput.write(try encoder.encode(
                Report(count: store.count, firstKey: store.keys.first?.description ?? "", sameBytes: same,
                       top: hits.map(\.key.description), scores: hits.map(\.score))))
        default:
            FileHandle.standardError.write(Data("modes: chunks | store <out> | verify <file>\n".utf8))
            exit(2)
        }
    }
}
