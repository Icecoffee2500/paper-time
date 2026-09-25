import Foundation
import Testing

/// `Fixtures/minilm-reference.json`: what sentence-transformers itself says,
/// made by `Scripts/semantic-reference.py`. The Portable build's tests read
/// the same file, so both implementations answer to the reference and not
/// merely to each other.
struct Reference: Decodable {
    struct Tokens: Decodable {
        var text: String
        var ids: [Int32]
        var note: String?
    }

    struct Embedded: Decodable {
        var text: String
        var vector: [Float]
    }

    struct Order: Decodable {
        var query: String
        var passages: [Int]
    }

    var model: String
    var max_seq_length: Int
    var tokens: [Tokens]
    var passages: [Embedded]
    var queries: [Embedded]
    var top5: [Order]

    static let shared: Reference = {
        let url = Bundle.module.url(forResource: "minilm-reference", withExtension: "json", subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: "minilm-reference", withExtension: "json")
        guard let url, let data = try? Data(contentsOf: url) else {
            fatalError("Fixtures/minilm-reference.json is missing from the test bundle")
        }
        do {
            return try JSONDecoder().decode(Reference.self, from: data)
        } catch {
            fatalError("Fixtures/minilm-reference.json does not decode: \(error)")
        }
    }()
}

func dot(_ a: [Float], _ b: [Float]) -> Double {
    zip(a, b).reduce(0) { $0 + Double($1.0) * Double($1.1) }
}

/// Indices of the `k` best-scoring rows, best first.
func topIndices(of scores: [Double], k: Int) -> [Int] {
    Array(scores.indices.sorted { scores[$0] > scores[$1] || (scores[$0] == scores[$1] && $0 < $1) }.prefix(k))
}
