import Foundation
import PaperCore

/// A source of title/author guesses for a document.
///
/// Exists so the on-device language model can be plugged in where it is
/// available without the resolver knowing or caring. On this project's own
/// hardware only the Mac can run that model, so the heuristic implementation is
/// not a fallback — it is the everyday path on iPad and iPhone.
public protocol HeaderExtracting: Sendable {
    var isAvailable: Bool { get }
    func extract(from signals: DocumentSignals) async -> [ExtractedHeader]
}

/// Offline extraction from the PDF's own metadata and typography.
public struct HeuristicHeaderExtractor: HeaderExtracting {
    public init() {}

    public var isAvailable: Bool { true }

    public func extract(from signals: DocumentSignals) async -> [ExtractedHeader] {
        HeaderExtractor.candidates(from: signals)
    }
}

/// Runs several extractors and merges their guesses, strongest first.
public struct CompositeHeaderExtractor: HeaderExtracting {
    private let extractors: [any HeaderExtracting]

    public init(_ extractors: [any HeaderExtracting]) {
        self.extractors = extractors
    }

    public var isAvailable: Bool { extractors.contains(where: \.isAvailable) }

    public func extract(from signals: DocumentSignals) async -> [ExtractedHeader] {
        var merged: [ExtractedHeader] = []
        for extractor in extractors where extractor.isAvailable {
            for header in await extractor.extract(from: signals) {
                let duplicate = merged.contains {
                    StringSimilarity.titleSimilarity($0.title, header.title) > 0.95
                }
                if !duplicate { merged.append(header) }
            }
        }
        return merged.sorted { $0.strength > $1.strength }
    }
}
