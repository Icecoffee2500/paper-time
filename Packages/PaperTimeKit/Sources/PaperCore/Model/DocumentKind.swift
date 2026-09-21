import Foundation

/// What a PDF in the library is.
///
/// The app began as a reader for papers, and a paper is a strong shape: it
/// has a venue, a year, authors in a citation order, a DOI, a key you cite it
/// by. Everything else somebody reads — a manual, a contract, a set of
/// slides, a book chapter scanned off a photocopier — has none of that, and a
/// form asking a car manual for its journal is a form that makes the app look
/// silly and the reader wrong.
///
/// So the library holds two kinds of thing, and asks which one it has rather
/// than guessing silently. The guess is still made (`DocumentGuess`), because
/// a question with a suggested answer is one tap and a blank question is an
/// interruption; but the answer is the reader's, and it is what decides which
/// fields the inspector shows, whether the record is looked up online at all,
/// and whether the thing turns up in a BibTeX export.
public enum DocumentKind: String, Codable, Hashable, Sendable, CaseIterable {
    /// Something published and citable: a paper, a preprint, a thesis.
    case paper
    /// Everything else somebody reads: a manual, a report, slides, a book.
    case document

    /// Whether a record of this kind wants a bibliography's fields.
    public var isCitable: Bool { self == .paper }
}

/// What the app thinks a file is, before anybody has said.
///
/// Deliberately small and explainable. A DOI or an arXiv identifier printed
/// on the page is close to proof; an abstract and a reference list together
/// are strong; a file with none of that is probably not a paper, and if the
/// guess is wrong the answer is one tap away.
public struct DocumentGuess: Hashable, Sendable {
    public let kind: DocumentKind
    /// Why, in the app's own words, for the question to show underneath.
    public let reason: Reason

    public enum Reason: String, Hashable, Sendable {
        /// A DOI or an arXiv identifier was printed on the page.
        case identifier
        /// An abstract, a reference list — the furniture of a paper.
        case structure
        /// None of the above.
        case nothingFound
    }

    public init(kind: DocumentKind, reason: Reason) {
        self.kind = kind
        self.reason = reason
    }

    /// The guess for a document with these signals.
    ///
    /// - Parameters:
    ///   - hasIdentifier: a DOI or arXiv identifier was found in the text.
    ///   - hasAbstract: the first page has something that reads as an abstract.
    ///   - hasReferences: a references or bibliography heading was found.
    public static func of(
        hasIdentifier: Bool,
        hasAbstract: Bool,
        hasReferences: Bool
    ) -> DocumentGuess {
        if hasIdentifier { return DocumentGuess(kind: .paper, reason: .identifier) }
        if hasAbstract, hasReferences { return DocumentGuess(kind: .paper, reason: .structure) }
        return DocumentGuess(kind: .document, reason: .nothingFound)
    }
}
