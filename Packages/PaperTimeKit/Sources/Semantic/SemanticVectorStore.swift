import Accelerate
import Foundation

/// One scored passage from `SemanticVectorStore.search`.
public struct SemanticHit: Hashable, Sendable {
    public var key: ChunkKey
    /// Cosine similarity: the vectors are unit length, so this is the dot
    /// product, between −1 and 1.
    public var score: Float
}

/// Every passage's vector, in half precision, keyed by the passage's text.
///
/// This is a cache and is treated as one: it lives with the device (next to
/// the full-text index, never in the library folder, which is synced and
/// belongs to the person), it knows which model made it and will not be read
/// by another, and anything wrong with the file means "start again", not an
/// error to show. Half precision because 384 floats a passage is 1.5 KB and
/// a library of 13,000 passages would be 20 MB — at fp16 it is 10 MB, and
/// the model itself only computes in fp16, so the bits dropped were never
/// there.
///
/// Stored as raw fp16 bit patterns (`UInt16`) rather than `Float16`, which
/// Swift does not offer on Intel Macs; vImage converts either way.
///
/// Search is exact: every vector is scored. At this size that is a matrix-
/// vector product that Accelerate finishes in milliseconds, and an
/// approximate index would buy nothing but a chance of missing the best
/// passage.
public struct SemanticVectorStore: Sendable {
    public static let dimension = SemanticModel.dimension

    /// The model whose vectors these are. A store made by another model is
    /// a different space; its scores would be noise.
    public let model: String
    public private(set) var keys: [ChunkKey] = []
    private var rows: [ChunkKey: Int] = [:]
    /// `keys.count × dimension` fp16 bit patterns, row after row.
    private var halves: [UInt16] = []

    public init(model: String = SemanticModel.identifier) {
        self.model = model
    }

    public var count: Int { keys.count }

    public func contains(_ key: ChunkKey) -> Bool { rows[key] != nil }

    /// The stored vector, back in single precision.
    public func vector(for key: ChunkKey) -> [Float]? {
        guard let row = rows[key] else { return nil }
        let d = Self.dimension
        var out = [Float](repeating: 0, count: d)
        halves.withUnsafeBufferPointer { source in
            out.withUnsafeMutableBufferPointer { target in
                Self.widen(source.baseAddress! + row * d, into: target.baseAddress!, count: d)
            }
        }
        return out
    }

    /// Adds or replaces a vector. It is normalised on the way in, so a
    /// caller's rounding never shows up as one passage outscoring another.
    public mutating func insert(_ vector: [Float], for key: ChunkKey) {
        precondition(vector.count == Self.dimension, "a \(Self.dimension)-dimensional vector")
        var unit = vector
        var norm: Float = 0
        vDSP_svesq(unit, 1, &norm, vDSP_Length(unit.count))
        norm = norm.squareRoot()
        if norm > 0 {
            var scale = 1 / norm
            vDSP_vsmul(unit, 1, &scale, &unit, 1, vDSP_Length(unit.count))
        }
        var half = [UInt16](repeating: 0, count: Self.dimension)
        unit.withUnsafeBufferPointer { source in
            half.withUnsafeMutableBufferPointer { target in
                Self.narrow(source.baseAddress!, into: target.baseAddress!, count: Self.dimension)
            }
        }
        if let row = rows[key] {
            halves.replaceSubrange(row * Self.dimension..<(row + 1) * Self.dimension, with: half)
        } else {
            rows[key] = keys.count
            keys.append(key)
            halves.append(contentsOf: half)
        }
    }

    /// Keeps only these keys: the passages that still exist. Without this a
    /// removed paper's passages would go on taking places in every answer.
    public mutating func retain(_ keep: Set<ChunkKey>) {
        guard keys.contains(where: { !keep.contains($0) }) else { return }
        let d = Self.dimension
        var keptKeys: [ChunkKey] = []
        var keptHalves: [UInt16] = []
        keptKeys.reserveCapacity(min(keep.count, keys.count))
        keptHalves.reserveCapacity(min(keep.count, keys.count) * d)
        for (row, key) in keys.enumerated() where keep.contains(key) {
            keptKeys.append(key)
            keptHalves.append(contentsOf: halves[row * d..<(row + 1) * d])
        }
        keys = keptKeys
        halves = keptHalves
        rows = Dictionary(uniqueKeysWithValues: keys.enumerated().map { ($1, $0) })
    }

    // MARK: - Search

    /// The `k` passages closest to `query`, best first; ties go to the
    /// passage stored first, so the same store always answers the same way.
    ///
    /// Scores in blocks: widen a block of rows to fp32, one matrix-vector
    /// product, keep the best `k` in a small heap. The block keeps the fp32
    /// scratch at a few megabytes however large the library gets.
    public func search(_ query: [Float], k: Int) -> [SemanticHit] {
        precondition(query.count == Self.dimension, "a \(Self.dimension)-dimensional query")
        guard k > 0, !keys.isEmpty else { return [] }
        let d = Self.dimension
        let block = 2048
        var best = TopK(capacity: min(k, keys.count))
        var scratch = [Float](repeating: 0, count: block * d)
        var scores = [Float](repeating: 0, count: block)
        halves.withUnsafeBufferPointer { all in
            scratch.withUnsafeMutableBufferPointer { wide in
                scores.withUnsafeMutableBufferPointer { out in
                    query.withUnsafeBufferPointer { q in
                        var start = 0
                        while start < keys.count {
                            let n = min(block, keys.count - start)
                            Self.widen(all.baseAddress! + start * d, into: wide.baseAddress!, count: n * d)
                            // scores (n×1) = rows (n×d) · query (d×1)
                            vDSP_mmul(wide.baseAddress!, 1, q.baseAddress!, 1, out.baseAddress!, 1,
                                      vDSP_Length(n), 1, vDSP_Length(d))
                            for i in 0..<n { best.offer(out[i], row: start + i) }
                            start += n
                        }
                    }
                }
            }
        }
        return best.sorted().map { SemanticHit(key: keys[$0.row], score: $0.score) }
    }

    /// A fixed-size min-heap of the best rows so far.
    private struct TopK {
        let capacity: Int
        var heap: [(score: Float, row: Int)] = []

        init(capacity: Int) {
            self.capacity = capacity
            heap.reserveCapacity(capacity)
        }

        /// Worse means lower score, or the same score on a later row.
        private static func worse(_ a: (score: Float, row: Int), _ b: (score: Float, row: Int)) -> Bool {
            a.score < b.score || (a.score == b.score && a.row > b.row)
        }

        mutating func offer(_ score: Float, row: Int) {
            let item = (score: score, row: row)
            if heap.count < capacity {
                heap.append(item)
                var child = heap.count - 1
                while child > 0 {
                    let parent = (child - 1) / 2
                    guard Self.worse(heap[child], heap[parent]) else { break }
                    heap.swapAt(child, parent)
                    child = parent
                }
            } else if Self.worse(heap[0], item) {
                heap[0] = item
                var parent = 0
                while true {
                    let left = 2 * parent + 1, right = left + 1
                    var worst = parent
                    if left < heap.count, Self.worse(heap[left], heap[worst]) { worst = left }
                    if right < heap.count, Self.worse(heap[right], heap[worst]) { worst = right }
                    if worst == parent { break }
                    heap.swapAt(parent, worst)
                    parent = worst
                }
            }
        }

        func sorted() -> [(score: Float, row: Int)] {
            heap.sorted { Self.worse($1, $0) }
        }
    }

    // MARK: - fp16

    static func widen(_ source: UnsafePointer<UInt16>, into target: UnsafeMutablePointer<Float>, count: Int) {
        var from = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: source), height: 1,
                                 width: vImagePixelCount(count), rowBytes: count * 2)
        var to = vImage_Buffer(data: target, height: 1, width: vImagePixelCount(count), rowBytes: count * 4)
        vImageConvert_Planar16FtoPlanarF(&from, &to, vImage_Flags(kvImageNoFlags))
    }

    static func narrow(_ source: UnsafePointer<Float>, into target: UnsafeMutablePointer<UInt16>, count: Int) {
        var from = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: source), height: 1,
                                 width: vImagePixelCount(count), rowBytes: count * 4)
        var to = vImage_Buffer(data: target, height: 1, width: vImagePixelCount(count), rowBytes: count * 2)
        vImageConvert_PlanarFtoPlanar16F(&from, &to, vImage_Flags(kvImageNoFlags))
    }

    // MARK: - File

    /// `PTSV`, a format version, the dimension, the count, the model
    /// identifier, then every key (16 bytes) and every vector (2 bytes a
    /// component), all little-endian.
    private static let magic: [UInt8] = Array("PTSV".utf8)
    private static let formatVersion: UInt32 = 1

    public enum FileError: Error, Equatable {
        case notAStore
        case otherVersion(UInt32)
        case otherModel(String)
        case otherDimension(Int)
        case truncated
    }

    public func encoded() -> Data {
        var data = Data()
        let modelBytes = Array(model.utf8)
        data.reserveCapacity(24 + modelBytes.count + keys.count * 16 + halves.count * 2)
        data.append(contentsOf: Self.magic)
        Self.append(Self.formatVersion, to: &data)
        Self.append(UInt32(Self.dimension), to: &data)
        Self.append(UInt32(keys.count), to: &data)
        Self.append(UInt32(modelBytes.count), to: &data)
        data.append(contentsOf: modelBytes)
        for key in keys {
            Self.append(key.high, to: &data)
            Self.append(key.low, to: &data)
        }
        halves.withUnsafeBufferPointer { buffer in
            if UInt16(1).littleEndian == 1 {
                data.append(UnsafeBufferPointer(start: UnsafeRawPointer(buffer.baseAddress!)
                    .assumingMemoryBound(to: UInt8.self), count: buffer.count * 2))
            } else {
                for half in buffer { Self.append(half, to: &data) }
            }
        }
        return data
    }

    /// Reads a store, and says why when it will not.
    public init(data: Data, model: String = SemanticModel.identifier) throws {
        var reader = Reader(bytes: [UInt8](data))
        guard reader.take(4).map(Array.init) == Self.magic else { throw FileError.notAStore }
        let version: UInt32 = try reader.number()
        guard version == Self.formatVersion else { throw FileError.otherVersion(version) }
        let dimension = Int(try reader.number() as UInt32)
        guard dimension == Self.dimension else { throw FileError.otherDimension(dimension) }
        let count = Int(try reader.number() as UInt32)
        let modelLength = Int(try reader.number() as UInt32)
        guard let modelBytes = reader.take(modelLength) else { throw FileError.truncated }
        let stored = String(decoding: modelBytes, as: UTF8.self)
        guard stored == model else { throw FileError.otherModel(stored) }
        self.model = model
        var keys: [ChunkKey] = []
        keys.reserveCapacity(count)
        for _ in 0..<count {
            keys.append(ChunkKey(high: try reader.number(), low: try reader.number()))
        }
        guard let raw = reader.take(count * dimension * 2) else { throw FileError.truncated }
        var halves = [UInt16](repeating: 0, count: count * dimension)
        halves.withUnsafeMutableBytes { $0.copyBytes(from: raw) }
        if UInt16(1).littleEndian != 1 {
            for index in halves.indices { halves[index] = UInt16(littleEndian: halves[index]) }
        }
        self.keys = keys
        self.halves = halves
        self.rows = Dictionary(keys.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The cache at `url`, or an empty one when there is none, it is damaged,
    /// or another model made it. A cache that cannot be read is rebuilt, and
    /// nobody needs to hear about it.
    public static func load(from url: URL, model: String = SemanticModel.identifier) -> SemanticVectorStore {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let store = try? SemanticVectorStore(data: data, model: model)
        else { return SemanticVectorStore(model: model) }
        return store
    }

    /// Writes atomically, so a crash halfway leaves the old cache, not half
    /// of a new one.
    public func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoded().write(to: url, options: .atomic)
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private struct Reader {
        let bytes: [UInt8]
        var offset = 0

        mutating func take(_ count: Int) -> ArraySlice<UInt8>? {
            guard count >= 0, offset + count <= bytes.count else { return nil }
            defer { offset += count }
            return bytes[offset..<offset + count]
        }

        mutating func number<T: FixedWidthInteger>() throws -> T {
            guard let slice = take(MemoryLayout<T>.size) else { throw FileError.truncated }
            var value: T = 0
            for (shift, byte) in slice.enumerated() { value |= T(byte) << (8 * shift) }
            return value
        }
    }
}
