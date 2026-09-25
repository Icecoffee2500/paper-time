import Foundation
import Testing
@testable import Semantic

/// Deterministic unit vectors, so a failure can be run again.
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

@Suite("The vector cache")
struct VectorStoreTests {
    private func key(_ i: Int) -> ChunkKey { ChunkKey(text: "passage \(i)") }

    @Test("A vector comes back as fp16 would keep it, and unit length")
    func roundTrip() throws {
        var random = Randoms(state: 1)
        var store = SemanticVectorStore()
        let v = random.unit().map { $0 * 3 }   // not unit on the way in
        store.insert(v, for: key(0))
        let back = try #require(store.vector(for: key(0)))
        let norm = back.reduce(0) { $0 + $1 * $1 }.squareRoot()
        #expect(abs(norm - 1) < 1e-3)
        let expected = v.map { $0 / 3 }
        #expect(zip(back, expected).allSatisfy { abs($0 - $1) < 1e-3 })
        #expect(store.contains(key(0)))
        #expect(!store.contains(key(1)))
    }

    @Test("A key inserted twice holds the second vector once")
    func replace() throws {
        var random = Randoms(state: 2)
        var store = SemanticVectorStore()
        store.insert(random.unit(), for: key(0))
        let second = random.unit()
        store.insert(second, for: key(0))
        #expect(store.count == 1)
        let back = try #require(store.vector(for: key(0)))
        #expect(dot(back, second) > 0.9999)
    }

    @Test("The file says the same thing back, byte for byte")
    func file() throws {
        var random = Randoms(state: 3)
        var store = SemanticVectorStore()
        for i in 0..<50 { store.insert(random.unit(), for: key(i)) }
        let data = store.encoded()
        #expect(data.count == 4 + 4 * 4 + SemanticModel.identifier.utf8.count + 50 * 16 + 50 * 384 * 2)
        let read = try SemanticVectorStore(data: data)
        #expect(read.keys == store.keys)
        #expect(read.encoded() == data)
        for i in 0..<50 { #expect(read.vector(for: key(i)) == store.vector(for: key(i))) }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("semantic-\(UUID().uuidString)/vectors.bin")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try store.write(to: url)
        #expect(SemanticVectorStore.load(from: url).encoded() == data)
    }

    @Test("Another model's cache, a damaged one, or none at all is an empty cache")
    func refusals() throws {
        var random = Randoms(state: 4)
        var store = SemanticVectorStore(model: "some-other-model")
        store.insert(random.unit(), for: key(0))
        let data = store.encoded()
        #expect(throws: SemanticVectorStore.FileError.otherModel("some-other-model")) {
            try SemanticVectorStore(data: data)
        }
        #expect(throws: SemanticVectorStore.FileError.truncated) {
            try SemanticVectorStore(data: data.prefix(data.count - 1), model: "some-other-model")
        }
        #expect(throws: SemanticVectorStore.FileError.notAStore) {
            try SemanticVectorStore(data: Data("not a store".utf8))
        }
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).bin")
        #expect(SemanticVectorStore.load(from: missing).count == 0)
    }

    @Test("Retaining drops the passages that are gone and keeps the rest intact")
    func retain() throws {
        var random = Randoms(state: 5)
        var store = SemanticVectorStore()
        var vectors: [[Float]] = []
        for i in 0..<20 {
            vectors.append(random.unit())
            store.insert(vectors[i], for: key(i))
        }
        let keep = Set((0..<20).filter { $0 % 3 == 0 }.map(key))
        let before = (0..<20).filter { $0 % 3 == 0 }.map { store.vector(for: key($0))! }
        store.retain(keep)
        #expect(store.count == keep.count)
        #expect(Set(store.keys) == keep)
        #expect((0..<20).filter { $0 % 3 == 0 }.map { store.vector(for: key($0))! } == before)
        #expect(!store.contains(key(1)))
    }

    @Test("Search scores every vector: the same answer as doing it by hand")
    func exact() {
        var random = Randoms(state: 6)
        var store = SemanticVectorStore()
        for i in 0..<5000 { store.insert(random.unit(), for: key(i)) }
        for _ in 0..<5 {
            let query = random.unit()
            let byHand = store.keys.map { dot(store.vector(for: $0)!, query) }
            let expected = topIndices(of: byHand, k: 10).map { store.keys[$0] }
            let hits = store.search(query, k: 10)
            #expect(hits.map(\.key) == expected)
            #expect(zip(hits, topIndices(of: byHand, k: 10)).allSatisfy { abs(Double($0.score) - byHand[$1]) < 1e-4 })
            #expect(zip(hits, hits.dropFirst()).allSatisfy { $0.score >= $1.score })
        }
    }

    @Test("Asking for more than there is returns all of it, best first; ties keep their order")
    func small() {
        var store = SemanticVectorStore()
        var v = [Float](repeating: 0, count: 384)
        v[0] = 1
        store.insert(v, for: key(0))
        store.insert(v, for: key(1))
        var w = [Float](repeating: 0, count: 384)
        w[1] = 1
        store.insert(w, for: key(2))
        let hits = store.search(v, k: 10)
        #expect(hits.map(\.key) == [key(0), key(1), key(2)])
        #expect(hits.map(\.score) == [1, 1, 0])
        #expect(SemanticVectorStore().search(v, k: 5).isEmpty)
        #expect(store.search(v, k: 0).isEmpty)
    }
}
