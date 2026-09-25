import Foundation

/// The model that ships, named once so that everything keyed by it — the
/// vector cache above all — changes together when it does.
///
/// The only file here that touches `Bundle.module`, so that the tokenizer
/// can be compiled on its own with `swiftc` (`Scripts/wordpiece-probe.swift`)
/// and checked against Hugging Face's without building the package.
public enum SemanticModel {
    /// sentence-transformers/all-MiniLM-L6-v2 at the revision the reference
    /// was made from, converted by `Scripts/semantic-convert.py`. A new
    /// conversion that changes the numbers must change this string, or old
    /// caches would be mixed with new vectors.
    public static let identifier = "all-MiniLM-L6-v2@1110a243/coreml-fp16/1"
    public static let dimension = 384
    public static let resourceName = "MiniLM-L6-v2"

    /// The compiled model inside the package's resource bundle.
    public static var bundledModelURL: URL? {
        Bundle.module.url(forResource: resourceName, withExtension: "mlmodelc")
    }

    /// The licence the model is distributed under, for an acknowledgements
    /// screen.
    public static var licenceURL: URL? {
        Bundle.module.url(forResource: "\(resourceName)-LICENSE", withExtension: "txt")
    }
}

extension WordPieceTokenizer {
    /// The vocabulary that ships with the model, read once.
    public static func bundled() throws -> WordPieceTokenizer {
        try bundledVocabulary.get()
    }
}

private let bundledVocabulary: Result<WordPieceTokenizer, Error> = Result {
    guard let url = Bundle.module.url(forResource: "vocab", withExtension: "txt") else {
        throw CocoaError(.fileNoSuchFile)
    }
    return try WordPieceTokenizer(contentsOf: url)
}
