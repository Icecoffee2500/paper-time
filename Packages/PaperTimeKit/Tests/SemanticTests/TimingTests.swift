import CoreML
import Foundation
import Testing
@testable import Semantic

/// How long the parts take, printed so the numbers can be read off a test
/// run (`swift test -c release --filter SemanticTests.Timing`). The bounds
/// are loose on purpose: they catch "the GPU path fell back to something
/// forty times slower", which happened with enumerated shapes, and not a
/// busy machine.
@Suite("Timing", .serialized)
struct TimingTests {
    private func milliseconds(_ body: () async throws -> Void) async rethrows -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        try await body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
    }

    /// Passages of 60 to 100 real words, so that batches come in many
    /// lengths as a library's do.
    private func passages(_ count: Int, seed: Int) -> [SemanticChunk] {
        let words = Reference.shared.passages.map(\.text).joined(separator: " ").split(separator: " ")
        return (0..<count).map { i in
            let n = 60 + (i * 13 + seed) % 41
            let text = (0..<n).map { words[(i * 7 + seed + $0) % words.count] }.joined(separator: " ")
            return SemanticChunk(paperID: UUID(), pageIndex: 0, location: 0, length: 0,
                                 text: text, key: ChunkKey(text: "\(seed) \(i) \(text)"))
        }
    }

    @Test("Embedding a passage", arguments: [MLComputeUnits.cpuAndGPU, .cpuOnly])
    func embedding(units: MLComputeUnits) async throws {
        var embedder: SemanticEmbedder!
        let load = try await milliseconds { embedder = try await SemanticEmbedder.load(computeUnits: units) }
        let first = passages(512, seed: 1)
        let tokens = first.map { embedder.tokenizer.encode($0.text).count }
        // The first pass pays for compiling each padded shape once; the
        // second is what the rest of a library costs.
        let cold = try await milliseconds { for try await _ in embedder.embed(chunks: first) {} }
        let second = passages(512, seed: 2)
        let warm = try await milliseconds { for try await _ in embedder.embed(chunks: second) {} }
        var queries: [Double] = []
        for query in Reference.shared.queries {
            queries.append(try await milliseconds { _ = try await embedder.embed(query: query.text) })
        }
        let firstQuery = queries[0]
        queries.sort()
        let label = units == .cpuOnly ? "CPU" : "GPU"
        print(String(format: "semantic timing: %@ load %.0f ms · %.2f ms a passage the first time, %.2f after (%d passages, %d–%d tokens, mean %d) · first query %.2f ms, median %.2f ms, worst %.2f ms",
                     label, load, cold / Double(first.count), warm / Double(second.count), second.count,
                     tokens.min()!, tokens.max()!, tokens.reduce(0, +) / tokens.count,
                     firstQuery, queries[queries.count / 2], queries.last!))
        #expect(warm / Double(second.count) < 30)
    }

    @Test("Tokenizing a passage")
    func tokenizing() throws {
        let tokenizer = try WordPieceTokenizer.bundled()
        let texts = passages(2000, seed: 3).map(\.text)
        let start = DispatchTime.now().uptimeNanoseconds
        var total = 0
        for text in texts { total += tokenizer.encode(text).count }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        print(String(format: "semantic timing: tokenizer %.3f ms a passage (%d passages, %d ids)", ms / Double(texts.count), texts.count, total))
    }

    @Test("Searching every vector", arguments: [13_000, 130_000])
    func search(count: Int) async {
        var random = Randoms(state: UInt64(count))
        var store = SemanticVectorStore()
        for i in 0..<count { store.insert(random.unit(), for: ChunkKey(high: UInt64(i), low: 0)) }
        let queries = (0..<20).map { _ in random.unit() }
        _ = store.search(queries[0], k: 50)
        var times: [Double] = []
        for query in queries {
            times.append(await milliseconds { _ = store.search(query, k: 50) })
        }
        times.sort()
        print(String(format: "semantic timing: search over %d vectors (%.1f MB fp16), top 50: median %.2f ms, worst %.2f ms",
                     count, Double(count * 384 * 2) / 1e6, times[times.count / 2], times.last!))
        #expect(times[times.count / 2] < 1000)
    }
}
