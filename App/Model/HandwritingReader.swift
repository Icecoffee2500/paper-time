#if os(macOS) && canImport(MLXVLM)
import CoreGraphics
import CoreImage
import Foundation
import MLX
import MLXLMCommon
import MLXVLM
import PaperCore
import Tokenizers

/// Reads handwriting — words and mathematics — off a picture of the page,
/// with the vision-language model `HandwritingModels` keeps on this Mac.
///
/// The model is loaded on the first read (two to five seconds) and let go a
/// few minutes after the last one: it holds about seven gigabytes of memory
/// while it is loaded, which is not something to keep for a lasso used once
/// an hour. Qwen3.5 thinks aloud before it answers unless told not to, and a
/// transcription has nothing to think about — `enable_thinking` is off.
actor HandwritingReader {
    static let shared = HandwritingReader()

    struct Reading: Sendable {
        /// Markdown: words, `$…$`, and `$$…$$` lines.
        var text: String
        var seconds: Double
    }

    enum Failure: Error { case noModel, nothingRead }

    private var container: ModelContainer?
    private var loadedFrom: URL?
    /// The load in flight. An actor gives up its turn at every `await`, so a
    /// read that came while the model was still loading — the lasso had
    /// started it — would otherwise start a second load of the same seven
    /// gigabytes.
    private var loading: Task<ModelContainer, Error>?
    private var unloading: Task<Void, Never>?

    static let prompt = """
        Transcribe this handwritten note exactly as written. Write every mathematical expression in \
        LaTeX between $ and $, and keep the words as they are. Keep line breaks. Output only the \
        transcription.
        """

    /// Whether this Mac can run the model at all: MLX needs Apple silicon.
    nonisolated static var canRun: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }

    /// Reads the picture. `partial` hears the answer as it is written, a
    /// few words at a time, for a reader who would rather watch than wait.
    func read(_ picture: CGImage, from directory: URL,
              partial: (@Sendable (String) -> Void)? = nil) async throws -> Reading {
        unloading?.cancel()
        let container = try await load(directory)
        let began = Date()
        let image = CIImage(cgImage: picture)
        let raw: String = try await container.perform { context in
            let input = UserInput(chat: [.user(Self.prompt, images: [.ciImage(image)])],
                                  additionalContext: ["enable_thinking": false])
            let prepared = try await context.processor.prepare(input: input)
            // Greedy, as a transcription should be; a little pressure against
            // repeating, which a model reading a grid of ruled paper can fall
            // into, and a ceiling for when it does anyway.
            let parameters = GenerateParameters(maxTokens: 700, temperature: 0, repetitionPenalty: 1.05)
            var text = ""
            for await item in try MLXLMCommon.generate(input: prepared, parameters: parameters, context: context) {
                guard let chunk = item.chunk else { continue }
                text += chunk
                partial?(text)
            }
            return text
        }
        scheduleUnload()
        let text = HandwritingText.tidy(raw)
        guard !text.isEmpty else { throw Failure.nothingRead }
        return Reading(text: text, seconds: Date().timeIntervalSince(began))
    }

    private func load(_ directory: URL) async throws -> ModelContainer {
        if let container, loadedFrom == directory { return container }
        if let loading, loadedFrom == directory { return try await loading.value }
        container = nil
        // A cap on what MLX keeps cached between reads: the model's own
        // weights are what must stay, not every intermediate it ever made.
        MLX.GPU.set(cacheLimit: 256 * 1024 * 1024)
        loadedFrom = directory
        let task = Task { try await VLMModelFactory.shared.loadContainer(from: directory, using: TokenizerFiles()) }
        loading = task
        do {
            let loaded = try await task.value
            // Unless it was let go while it loaded.
            if loadedFrom == directory {
                container = loaded
                loading = nil
            }
            return loaded
        } catch {
            if loadedFrom == directory {
                loading = nil
                loadedFrom = nil
            }
            throw error
        }
    }

    /// Loads the model ahead of a read: the lasso has just caught a picture
    /// with nothing to read but its pixels, and ⇧⌘C is what comes next. The
    /// seconds of loading go by while the hand moves to the keys.
    func prewarm(_ directory: URL) async {
        unloading?.cancel()
        _ = try? await load(directory)
        scheduleUnload()
    }

    /// Lets the model go — after a few idle minutes, or when its files are
    /// removed.
    func unload() {
        unloading?.cancel()
        container = nil
        loading = nil
        loadedFrom = nil
        MLX.GPU.clearCache()
    }

    private func scheduleUnload() {
        unloading?.cancel()
        unloading = Task { [weak self] in
            try? await Task.sleep(for: .seconds(180))
            guard !Task.isCancelled else { return }
            await self?.unload()
        }
    }
}

/// The model's tokenizer, read from its folder by swift-transformers and
/// spoken to through MLX's protocol.
private struct TokenizerFiles: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TokenizerBridge(upstream: try await AutoTokenizer.from(modelFolder: directory))
    }
}

private struct TokenizerBridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
    }
}
#endif
