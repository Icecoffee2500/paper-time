import CoreML
import Foundation
import Testing
@testable import Semantic

/// The model and the tokenizer together against sentence-transformers.
///
/// The bar is per vector, not on average: one passage that lands somewhere
/// else is one passage that is never found. Measured on an M-series Mac the
/// lowest cosine is 0.999998 on the GPU and 0.999975 on the CPU (fp16 both),
/// so 0.9999 leaves room for another GPU without letting a broken pipeline
/// through. The shared fixture's own bar is 0.999, for implementations
/// (ONNX in the Portable build) that differ more.
@Suite("Embeddings agree with sentence-transformers", .serialized)
struct EmbeddingTests {
    static let bar = 0.9999

    @Test("Each vector is within the bar, and every query ranks the passages in the same order",
          arguments: [MLComputeUnits.cpuAndGPU, .cpuOnly])
    func agreement(units: MLComputeUnits) async throws {
        let reference = Reference.shared
        let embedder = try await SemanticEmbedder.load(computeUnits: units)
        let passages = try await embedder.embed(batch: reference.passages.map(\.text))
        var queries: [[Float]] = []
        for query in reference.queries { queries.append(try await embedder.embed(query: query.text)) }

        let cosines = zip(passages, reference.passages).map { dot($0, $1.vector) }
            + zip(queries, reference.queries).map { dot($0, $1.vector) }
        let lowest = cosines.min()!
        print("semantic: \(name(units)) lowest cosine \(String(format: "%.6f", lowest)) over \(cosines.count) texts")
        #expect(cosines.count == 30)
        #expect(lowest >= Self.bar, "lowest cosine \(lowest)")

        let differ = Self.differingOrders(queries: queries, passages: passages)
        print("semantic: \(name(units)) top-5 identical on \(15 - differ.count) of 15 queries\(differ.isEmpty ? "" : ", not on \(differ)")")
        #expect(differ.isEmpty, "top-5 order differs for queries \(differ)")
    }

    @Test("Queries on the CPU still find what GPU passages found")
    func mixed() async throws {
        let reference = Reference.shared
        let gpu = try await SemanticEmbedder.load(computeUnits: .cpuAndGPU)
        let cpu = try await SemanticEmbedder.load(computeUnits: .cpuOnly)
        let passages = try await gpu.embed(batch: reference.passages.map(\.text))
        var queries: [[Float]] = []
        for query in reference.queries { queries.append(try await cpu.embed(query: query.text)) }
        let differ = Self.differingOrders(queries: queries, passages: passages)
        print("semantic: CPU queries × GPU passages top-5 identical on \(15 - differ.count) of 15\(differ.isEmpty ? "" : ", not on \(differ)")")
        #expect(differ.isEmpty)
    }

    /// The queries whose five best passages do not come back in the
    /// reference's order.
    static func differingOrders(queries: [[Float]], passages: [[Float]]) -> [Int] {
        zip(queries, Reference.shared.top5).enumerated().compactMap { index, pair in
            let scores = passages.map { dot($0, pair.0) }
            return topIndices(of: scores, k: 5) == pair.1.passages ? nil : index
        }
    }

    @Test("A passage alone, in a batch, or padded to 256 is the same vector")
    func padding() async throws {
        let embedder = try await SemanticEmbedder.load()
        let texts = Reference.shared.passages.map(\.text)
        let batched = try await embedder.embed(batch: texts)
        for (text, together) in zip(texts, batched) {
            let alone = try await embedder.embed(query: text)
            #expect(dot(alone, together) > 0.99999)
        }
        // The longest in a batch sets the padding for all of them: put a
        // 256-token text next to a short one.
        let long = Reference.shared.tokens.first { $0.note != nil }!.text
        let pair = try await embedder.embed(batch: ["catastrophic forgetting", long])
        let short = try await embedder.embed(query: "catastrophic forgetting")
        #expect(dot(pair[0], short) > 0.99999)
    }

    @Test("The stream covers every distinct passage once and stops when cancelled")
    func stream() async throws {
        let embedder = try await SemanticEmbedder.load()
        let paper = UUID()
        let page = Reference.shared.passages.map(\.text).joined(separator: " ")
        var chunks = SemanticChunker.chunks(ofPage: page + " " + page + " " + page, paperID: paper, pageIndex: 0,
                                            windowWords: 20, overlapWords: 5)
        chunks += chunks   // every key twice
        let distinct = Set(chunks.map(\.key))
        var seen: [ChunkKey] = []
        for try await embedding in embedder.embed(chunks: chunks, batchSize: 4) {
            seen.append(embedding.key)
            #expect(embedding.vector.count == 384)
        }
        #expect(seen.count == distinct.count)
        #expect(Set(seen) == distinct)

        // Take one batch and walk away: the producer must stop, not finish.
        let many = (0..<400).map { i in
            SemanticChunk(paperID: paper, pageIndex: 0, location: 0, length: 1,
                          text: "passage number \(i) about forgetting", key: ChunkKey(text: "p\(i)"))
        }
        let reader = Task { () -> Int in
            var count = 0
            for try await _ in embedder.embed(chunks: many, batchSize: 8) {
                count += 1
                if count == 8 { break }
            }
            return count
        }
        #expect(try await reader.value == 8)
    }

    private func name(_ units: MLComputeUnits) -> String {
        switch units {
        case .cpuOnly: "CPU"
        case .cpuAndGPU: "GPU"
        case .all: "all"
        case .cpuAndNeuralEngine: "ANE"
        @unknown default: "?"
        }
    }
}
