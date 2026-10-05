#if os(macOS) && canImport(OnnxRuntimeBindings)
import Foundation
import CoreGraphics
import PDFKit
import PaperCore
import OnnxRuntimeBindings

/// Reads a formula off a picture of the page — for the lasso, when the
/// rectangle holds no glyphs the reader can use: a scanned page, a formula
/// pasted in as an image, a Word equation in a font with no meanings.
///
/// The model is pix2text's math formula recogniser 1.5 (MIT): a DeiT encoder
/// over a 384×384 picture and a small TrOCR decoder, as ONNX, int8 — 30 MB
/// in `App/Resources/MathOCR`, run by ONNX Runtime on the CPU (the Core ML
/// provider compiles the encoder for forty seconds at launch and leaves 400
/// MB of cache for a 60 ms saving; measured, not worth it). One formula is a
/// second or two: the decoder has no cache and re-reads the whole sequence
/// each step. The Portable build runs the same two files in onnxruntime-web.
///
/// What comes back is tokens with spaces between; `FormulaOCRText.tidy`
/// makes Ultracopy's LaTeX of it.
actor FormulaOCR {
    static let shared = FormulaOCR()

    struct Reading: Sendable {
        /// The formula, wrapped as Ultracopy wraps a displayed one.
        var latex: String
        var tokens: Int
        var seconds: Double
    }

    enum Failure: Error { case noModel, noPicture, nothingRead }

    private var env: ORTEnv?
    private var encoder: ORTSession?
    private var decoder: ORTSession?
    private var tokenizer: Tokenizer?

    static let side = 384
    private static let vocabulary = 1868
    private static let start: Int64 = 1
    private static let end: Int64 = 2
    private static let longest = 400

    /// Whether the models are in the bundle at all.
    nonisolated static var isAvailable: Bool {
        Bundle.main.url(forResource: "encoder_model", withExtension: "onnx") != nil
    }

    private func load() throws {
        if encoder != nil { return }
        guard let encoderURL = Bundle.main.url(forResource: "encoder_model", withExtension: "onnx"),
              let decoderURL = Bundle.main.url(forResource: "decoder_model", withExtension: "onnx"),
              let vocabularyURL = Bundle.main.url(forResource: "tokenizer", withExtension: "json")
        else { throw Failure.noModel }
        let env = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setGraphOptimizationLevel(.all)
        try options.setIntraOpNumThreads(4)
        try options.setLogSeverityLevel(.warning)
        encoder = try ORTSession(env: env, modelPath: encoderURL.path, sessionOptions: options)
        decoder = try ORTSession(env: env, modelPath: decoderURL.path, sessionOptions: options)
        tokenizer = try Tokenizer(url: vocabularyURL)
        self.env = env
    }

    /// Reads the formula in a picture of the page (`PictureReading.picture`,
    /// drawn three times its size with room round the rectangle — pressed
    /// against the edge of the picture, the letters of a label came back
    /// wrong, "messace"), stretched to the model's square. The drawing
    /// happens where the page is (the main actor — a `PDFPage` does not
    /// travel); the model runs here.
    @MainActor
    static func read(picture: CGImage) async throws -> Reading {
        try await shared.read(pixels: pixelValues(of: picture))
    }

    /// Blank paper makes a model invent things — LaTeX preambles here, a sum
    /// of fractions from the handwriting model — so a picture with fewer
    /// than 64 dark values (of 442,368) is nothing to read. The Portable
    /// build asks the same (`isBlankPicture`).
    nonisolated static func isBlank(pixels: [Float]) -> Bool {
        let ink = Float((242.0 / 255.0 - 0.5) / 0.5)
        return pixels.lazy.filter { $0 < ink }.count < 64
    }

    nonisolated static func isBlank(_ picture: CGImage) -> Bool {
        isBlank(pixels: pixelValues(of: picture))
    }

    /// Reads a formula from the model's input: the picture's pixel values,
    /// as `pixelValues(of:)` makes them.
    func read(pixels: [Float]) throws -> Reading {
        guard !Self.isBlank(pixels: pixels) else { throw Failure.nothingRead }
        try load()
        guard let encoder, let decoder, let tokenizer else { throw Failure.noModel }
        let began = Date()
        let input = try Self.tensor(pixels, .float, shape: [1, 3, Self.side, Self.side])
        let encoded = try encoder.run(withInputs: ["pixel_values": input], outputNames: ["last_hidden_state"], runOptions: nil)
        guard let hidden = encoded["last_hidden_state"] else { throw Failure.nothingRead }

        var ids: [Int64] = [Self.start]
        for _ in 0..<Self.longest {
            let inputIDs = try Self.tensor(ids, .int64, shape: [1, ids.count])
            let out = try decoder.run(withInputs: ["input_ids": inputIDs, "encoder_hidden_states": hidden],
                                      outputNames: ["logits"], runOptions: nil)
            guard let logits = try out["logits"]?.tensorData() else { throw Failure.nothingRead }
            let count = logits.length / MemoryLayout<Float>.size
            let last = count - Self.vocabulary
            var best = 0
            var bestValue = -Float.infinity
            logits.bytes.withMemoryRebound(to: Float.self, capacity: count) { pointer in
                for k in 0..<Self.vocabulary where pointer[last + k] > bestValue {
                    bestValue = pointer[last + k]
                    best = k
                }
            }
            ids.append(Int64(best))
            if Int64(best) == Self.end { break }
        }
        let raw = tokenizer.decode(ids.map { Int($0) })
        let tidied = FormulaOCRText.tidy(raw)
        guard !tidied.body.isEmpty else { throw Failure.nothingRead }
        let latex = tidied.tag.map { "\\begin{equation} \(tidied.body)\\tag{\($0)} \\end{equation}" }
            ?? "$$\(tidied.body)$$"
        return Reading(latex: latex, tokens: ids.count, seconds: Date().timeIntervalSince(began))
    }

    // MARK: - The picture

    /// The rectangle of the page, drawn three times its size on white.
    ///
    /// `draw(with:to:)` puts the crop box's corner at the context's origin
    /// (and turns a turned page), while the rectangle is in the file's own
    /// coordinates, as PDFKit gives them: it goes where the page's transform
    /// takes it. Translated by itself alone, a page whose crop box does not
    /// start at the origin had its picture taken that far off the formula.
    ///
    /// `over` draws what the page itself does not — the ink and shapes kept
    /// beside the file — in the same space the page was drawn in: the crop
    /// box, turned, its corner at the origin, in points.
    nonisolated static func picture(of page: PDFPage, rect: CGRect, scale: CGFloat = 3,
                                    over: ((CGContext) -> Void)? = nil) throws -> CGImage {
        let drawn = rect.applying(page.transform(for: .cropBox))
        let width = max(1, Int((drawn.width * scale).rounded()))
        let height = max(1, Int((drawn.height * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw Failure.noPicture }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -drawn.minX, y: -drawn.minY)
        page.draw(with: .cropBox, to: context)
        if let over {
            context.saveGState()
            over(context)
            context.restoreGState()
        }
        guard let image = context.makeImage() else { throw Failure.noPicture }
        return image
    }

    /// The picture stretched — not fitted — to the model's square, as the
    /// model was trained, normalised to (x/255 − 0.5)/0.5, planes CHW.
    nonisolated static func pixelValues(of image: CGImage) -> [Float] {
        let side = Self.side
        var rgba = [UInt8](repeating: 0, count: side * side * 4)
        rgba.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        var out = [Float](repeating: 0, count: 3 * side * side)
        let plane = side * side
        for i in 0..<plane {
            let p = i * 4
            out[i] = (Float(rgba[p]) / 255 - 0.5) / 0.5
            out[plane + i] = (Float(rgba[p + 1]) / 255 - 0.5) / 0.5
            out[2 * plane + i] = (Float(rgba[p + 2]) / 255 - 0.5) / 0.5
        }
        return out
    }

    private static func tensor<T>(_ values: [T], _ type: ORTTensorElementDataType, shape: [Int]) throws -> ORTValue {
        let data = values.withUnsafeBufferPointer {
            NSMutableData(bytes: $0.baseAddress, length: $0.count * MemoryLayout<T>.stride)
        }
        return try ORTValue(tensorData: data, elementType: type, shape: shape.map { NSNumber(value: $0) })
    }

    // MARK: - The tokenizer

    /// Hugging Face's `tokenizer.json`, decoded the byte-level way: a token
    /// is GPT-2's unicode spelling of bytes, so the vocabulary's characters
    /// go back to bytes before they are read as UTF-8.
    struct Tokenizer {
        let tokens: [Int: String]
        let special: Set<Int>
        let byteOf: [Character: UInt8]

        init(url: URL) throws {
            let data = try Data(contentsOf: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let model = json["model"] as? [String: Any],
                  let vocabulary = model["vocab"] as? [String: Int]
            else { throw Failure.noModel }
            var tokens: [Int: String] = [:]
            for (token, id) in vocabulary { tokens[id] = token }
            var special = Set<Int>()
            for added in (json["added_tokens"] as? [[String: Any]]) ?? [] {
                guard let id = added["id"] as? Int else { continue }
                tokens[id] = added["content"] as? String
                if added["special"] as? Bool == true { special.insert(id) }
            }
            self.tokens = tokens
            self.special = special
            // GPT-2's bytes_to_unicode, inverted.
            var bytes: [Int] = Array(33...126) + Array(161...172) + Array(174...255)
            var characters = bytes
            var next = 0
            for byte in 0..<256 where !bytes.contains(byte) {
                bytes.append(byte)
                characters.append(256 + next)
                next += 1
            }
            var map: [Character: UInt8] = [:]
            for (byte, character) in zip(bytes, characters) {
                if let scalar = UnicodeScalar(character) { map[Character(scalar)] = UInt8(byte) }
            }
            byteOf = map
        }

        func decode(_ ids: [Int]) -> String {
            var bytes: [UInt8] = []
            for id in ids where !special.contains(id) {
                guard let token = tokens[id] else { continue }
                for character in token {
                    if let byte = byteOf[character] { bytes.append(byte) }
                }
            }
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}
#endif
