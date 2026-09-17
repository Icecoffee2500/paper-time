import Foundation
import PaperCore

#if canImport(FoundationModels)
import FoundationModels

/// The fields the on-device model is asked to fill in.
///
/// Gated to the systems that have the framework at run time as well as at
/// build time: the app is built on macOS 26 and runs back to Sonoma, where
/// FoundationModels does not exist and every symbol below would be unresolved.
@available(macOS 26, iOS 26, *)
@Generable
struct GeneratedPaperHeader {
    @Guide(description: "The complete title of the paper, on one line, with no line breaks")
    var title: String

    @Guide(description: "Every author's full name, in the order printed, without affiliations, superscripts or email addresses")
    var authors: [String]

    @Guide(description: "The journal, conference or workshop the paper appeared in, or an empty string if it is not stated")
    var venue: String

    @Guide(description: "The four-digit publication year, or 0 if it is not stated")
    var year: Int
}
#endif

/// Reads a paper's title and authors with Apple's on-device language model.
///
/// Availability is narrow and worth stating plainly: Apple Intelligence needs
/// an M1 or newer iPad, an A17 Pro or newer iPhone, or an Apple silicon Mac.
/// On an iPad Air 4 or an iPhone 12 Pro this extractor reports itself
/// unavailable and the heuristics run instead — and because the library is a
/// synced folder, a record resolved on the Mac reaches those devices anyway.
public struct OnDeviceHeaderExtractor: HeaderExtracting {
    public enum Availability: Sendable, Hashable {
        case available
        case deviceNotEligible
        case appleIntelligenceOff
        case modelNotReady
        case frameworkMissing

        public var message: String {
            switch self {
            case .available:
                "On-device extraction is available."
            case .deviceNotEligible:
                "This device does not support Apple Intelligence, so titles are read using layout heuristics."
            case .appleIntelligenceOff:
                "Turn on Apple Intelligence in Settings to improve title extraction."
            case .modelNotReady:
                "The on-device model is still downloading."
            case .frameworkMissing:
                "This version of the system does not include on-device models."
            }
        }
    }

    public init() {}

    public var availability: Availability {
        #if canImport(FoundationModels)
        guard #available(macOS 26, iOS 26, *) else { return .frameworkMissing }
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case let .unavailable(reason):
            switch reason {
            case .deviceNotEligible: return .deviceNotEligible
            case .appleIntelligenceNotEnabled: return .appleIntelligenceOff
            case .modelNotReady: return .modelNotReady
            @unknown default: return .modelNotReady
            }
        @unknown default:
            return .modelNotReady
        }
        #else
        return .frameworkMissing
        #endif
    }

    public var isAvailable: Bool { availability == .available }

    public func extract(from signals: DocumentSignals) async -> [ExtractedHeader] {
        #if canImport(FoundationModels)
        guard #available(macOS 26, iOS 26, *), isAvailable else { return [] }
        let excerpt = Self.excerpt(from: signals)
        guard excerpt.count > 40 else { return [] }

        let session = LanguageModelSession(instructions: Self.instructions)
        do {
            let response = try await session.respond(
                to: excerpt,
                generating: GeneratedPaperHeader.self
            )
            return [Self.header(from: response.content)].compactMap { $0 }
        } catch {
            // A refusal, a context overflow or a cancelled session all mean the
            // same thing here: fall back to the heuristics, never block import.
            return []
        }
        #else
        return []
        #endif
    }

    static let instructions = """
        You extract bibliographic details from the first page of an academic paper.
        Report only what is printed on the page. Never invent a venue or a year. \
        Ignore page headers, preprint stamps, copyright notices, affiliations and \
        email addresses. If a value is not printed, leave it empty or zero.
        """

    /// The model's context window is small, so it is given the top of the page
    /// only — which is where every template puts the title and authors.
    static func excerpt(from signals: DocumentSignals) -> String {
        var lines: [String] = []
        if let title = signals.embeddedTitle {
            lines.append("Embedded PDF title: \(title)")
        }
        if !signals.embeddedAuthors.isEmpty {
            lines.append("Embedded PDF authors: \(signals.embeddedAuthors.joined(separator: "; "))")
        }
        if let subject = signals.embeddedSubject {
            lines.append("Embedded PDF subject: \(subject)")
        }
        lines.append("First page text:")
        lines += signals.firstPageLines.prefix(30)

        let joined = lines.joined(separator: "\n")
        return String(joined.prefix(3000))
    }

    #if canImport(FoundationModels)
    @available(macOS 26, iOS 26, *)
    static func header(from generated: GeneratedPaperHeader) -> ExtractedHeader? {
        let title = TextNormalization.collapsingWhitespace(generated.title)
        guard title.count >= 8 else { return nil }
        let year = (1500...2200).contains(generated.year) ? generated.year : nil
        let venue = generated.venue.trimmingCharacters(in: .whitespacesAndNewlines)

        return ExtractedHeader(
            title: title,
            authors: generated.authors
                .map { TextNormalization.collapsingWhitespace($0) }
                .filter { $0.count > 2 }
                .map(CSLName.parse),
            venueHint: venue.isEmpty ? nil : venue,
            year: year,
            // Ranked above typography but below the PDF's own metadata: the
            // model reads the page well, yet still guesses when text is messy.
            strength: 0.8,
            source: .onDeviceModel
        )
    }
    #endif
}
