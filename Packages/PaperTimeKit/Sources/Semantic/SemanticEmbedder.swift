import Accelerate
import CoreML
import Foundation

/// One passage's vector, as `SemanticEmbedder.embed(chunks:)` streams them.
public struct SemanticEmbedding: Sendable {
    public var key: ChunkKey
    public var vector: [Float]
}

/// Text in, unit vectors out: the tokenizer and the Core ML model together.
///
/// An actor because one `MLModel` is one queue of work: the passages of a
/// whole library go through it in batches, and anything else asked of the
/// same embedder waits at most one batch — the stream gives the actor back
/// between batches.
///
/// Two of them, one for each job, is the arrangement that measured best
/// (M1 Pro, release build, passages of about 107 tokens):
///
/// - **Passages on the GPU** (`.cpuAndGPU`, the default): 1.4 ms a passage
///   against 2.1 on the CPU, and it leaves the CPU to the reader. It costs
///   about 150 MB while loaded (68 MB to load, 84 more once it has run), so
///   it is worth letting go of once the library is embedded.
/// - **Queries on the CPU** (`.cpuOnly`): 1.3 ms a query against 20 ms on
///   the GPU, whose fixed cost per call is large for one short text. A second
///   instance costs about 1 MB, because it shares the mapped weights, and a
///   query on its own instance never waits behind a batch. CPU queries
///   against GPU passages rank the reference's passages exactly as
///   sentence-transformers does.
///
/// The Neural Engine is left out on purpose: it wants fixed shapes, and its
/// first load of this model took 21 s.
///
/// Inputs are padded to a few fixed shapes, not to exactly the longest text.
/// The model accepts any shape, but the GPU compiles each new one the first
/// time it sees it — 130–180 ms, against 13–28 ms for a batch it has seen —
/// and a library's batches come in every length from 30 to 256 tokens, so
/// "any shape" meant a compile on nearly every batch: 41 ms a passage instead
/// of about 2. Padding changes nothing in the vectors (padded positions are
/// masked out of attention and out of the mean), so the only cost is some
/// arithmetic on zeros.
public actor SemanticEmbedder {
    /// Sequence lengths the input is padded up to.
    static let lengths = [16, 32, 64, 96, 128, 160, 192, 224, 256]
    /// Batch sizes the input is padded up to, with `[CLS] [SEP]` rows.
    static let batches = [1, 16, 32, 64]

    public nonisolated let tokenizer: WordPieceTokenizer
    public nonisolated let computeUnits: MLComputeUnits
    private let model: MLModel

    public enum LoadError: Error {
        case missingModel
    }

    private init(model: MLModel, tokenizer: WordPieceTokenizer, computeUnits: MLComputeUnits) {
        self.model = model
        self.tokenizer = tokenizer
        self.computeUnits = computeUnits
    }

    /// Loads the bundled model. It takes a few hundred milliseconds, so it
    /// is asynchronous and nobody should do it at launch.
    public static func load(
        computeUnits: MLComputeUnits = .cpuAndGPU,
        modelURL: URL? = SemanticModel.bundledModelURL
    ) async throws -> SemanticEmbedder {
        guard let modelURL else { throw LoadError.missingModel }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        let model = try await MLModel.load(contentsOf: modelURL, configuration: configuration)
        return SemanticEmbedder(model: model, tokenizer: try WordPieceTokenizer.bundled(), computeUnits: computeUnits)
    }

    /// A query, embedded the way a passage is: the model was trained with no
    /// prefix and no separate query encoder, so there is nothing to add.
    public func embed(query: String) throws -> [Float] {
        try embed(batch: [query])[0]
    }

    /// Several texts in one call to the model. At most 64 (the model's
    /// largest batch).
    public func embed(batch texts: [String]) throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        precondition(texts.count <= 64, "the model takes at most 64 texts at a time")
        return try run(texts.map { tokenizer.encode($0) })
    }

    func embed(encoded: [[Int32]]) throws -> [[Float]] {
        try run(encoded)
    }

    /// Every passage's vector, a batch at a time, for the passages it is
    /// given — pass only those not already in the store.
    ///
    /// Cancelling the task that reads the stream, or dropping the stream,
    /// stops the work after the batch in flight: nothing keeps running for
    /// a palette that has closed. Passages with the same key are embedded
    /// once. They come back in their own order within each stretch of
    /// `batchSize × 16`: inside a stretch they are sorted by length, so a
    /// batch pads to its own length and not to the longest in the library.
    public nonisolated func embed(
        chunks: [SemanticChunk],
        batchSize: Int = 16
    ) -> AsyncThrowingStream<SemanticEmbedding, Error> {
        var seen = Set<ChunkKey>()
        let unique = chunks.filter { seen.insert($0.key).inserted }
        let size = min(max(batchSize, 1), 64)
        let tokenizer = self.tokenizer
        return AsyncThrowingStream { continuation in
            let work = Task {
                do {
                    var stretch = 0
                    while stretch < unique.count {
                        try Task.checkCancellation()
                        let window = Array(unique[stretch..<min(stretch + size * 16, unique.count)])
                        let encoded = window.map { tokenizer.encode($0.text) }
                        let order = encoded.indices.sorted { encoded[$0].count < encoded[$1].count }
                        var start = 0
                        while start < order.count {
                            try Task.checkCancellation()
                            let picked = Array(order[start..<min(start + size, order.count)])
                            let vectors = try await self.embed(encoded: picked.map { encoded[$0] })
                            for (index, vector) in zip(picked, vectors) {
                                continuation.yield(SemanticEmbedding(key: window[index].key, vector: vector))
                            }
                            start += size
                        }
                        stretch += size * 16
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    // MARK: - Core ML

    private func run(_ encoded: [[Int32]]) throws -> [[Float]] {
        let longest = encoded.map(\.count).max() ?? 2
        let length = Self.lengths.first { $0 >= longest } ?? longest
        let rows = Self.batches.first { $0 >= encoded.count } ?? encoded.count
        let filler: [Int32] = [WordPieceTokenizer.classID, WordPieceTokenizer.separatorID]
        let padded = encoded + Array(repeating: filler, count: rows - encoded.count)
        return Array(try run(padded, length: length).prefix(encoded.count))
    }

    private func run(_ encoded: [[Int32]], length: Int) throws -> [[Float]] {
        let rows = encoded.count
        let shape = [NSNumber(value: rows), NSNumber(value: length)]
        let ids = try MLMultiArray(shape: shape, dataType: .int32)
        let mask = try MLMultiArray(shape: shape, dataType: .int32)
        ids.withUnsafeMutableBufferPointer(ofType: Int32.self) { idBuffer, idStrides in
            mask.withUnsafeMutableBufferPointer(ofType: Int32.self) { maskBuffer, maskStrides in
                for (row, tokens) in encoded.enumerated() {
                    for column in 0..<length {
                        let real = column < tokens.count
                        idBuffer[row * idStrides[0] + column * idStrides[1]] =
                            real ? tokens[column] : WordPieceTokenizer.padID
                        maskBuffer[row * maskStrides[0] + column * maskStrides[1]] = real ? 1 : 0
                    }
                }
            }
        }
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "ids": MLFeatureValue(multiArray: ids),
            "mask": MLFeatureValue(multiArray: mask),
        ])
        let output = try model.prediction(from: input)
        guard let embedding = output.featureValue(for: "embedding")?.multiArrayValue else {
            throw CocoaError(.coderReadCorrupt)
        }
        return Self.rows(of: embedding, count: rows)
    }

    /// The output as unit vectors in fp32, whatever type and strides Core ML
    /// chose for it. Renormalised here because the model's own normalisation
    /// happened in fp16.
    static func rows(of array: MLMultiArray, count: Int) -> [[Float]] {
        let d = SemanticModel.dimension
        var out: [[Float]] = []
        out.reserveCapacity(count)
        // Raw bytes, because `Float16` does not exist in Swift on Intel Macs
        // and the model's output is fp16.
        let type = array.dataType
        let wide: [[Float]] = array.withUnsafeBytes { raw in
            let strides = array.strides.map(\.intValue)
            let rowStride = strides.count > 1 ? strides[0] : d
            let columnStride = strides.last ?? 1
            return (0..<count).map { row in
                var vector = [Float](repeating: 0, count: d)
                switch type {
                case .float16:
                    let base = raw.bindMemory(to: UInt16.self)
                    var halves = [UInt16](repeating: 0, count: d)
                    for column in 0..<d { halves[column] = base[row * rowStride + column * columnStride] }
                    halves.withUnsafeBufferPointer { source in
                        vector.withUnsafeMutableBufferPointer { target in
                            SemanticVectorStore.widen(source.baseAddress!, into: target.baseAddress!, count: d)
                        }
                    }
                case .double:
                    let base = raw.bindMemory(to: Double.self)
                    for column in 0..<d { vector[column] = Float(base[row * rowStride + column * columnStride]) }
                default:
                    let base = raw.bindMemory(to: Float.self)
                    for column in 0..<d { vector[column] = base[row * rowStride + column * columnStride] }
                }
                return vector
            }
        }
        for var vector in wide {
            var norm: Float = 0
            vDSP_svesq(vector, 1, &norm, vDSP_Length(d))
            norm = norm.squareRoot()
            if norm > 0 {
                var scale = 1 / norm
                vDSP_vsmul(vector, 1, &scale, &vector, 1, vDSP_Length(d))
            }
            out.append(vector)
        }
        return out
    }
}
