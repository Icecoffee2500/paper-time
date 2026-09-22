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
/// So the library holds four kinds of thing, and asks which one it has
/// rather than guessing silently. The guess is still made (`DocumentGuess`),
/// because a question with a suggested answer is one tap and a blank question
/// is an interruption; but the answer is the reader's, and it is what decides
/// which fields the inspector shows, whether the record is looked up online at
/// all, and whether the thing turns up in a BibTeX export.
///
/// A book is its own kind rather than a document, because a book is cited.
/// Sent through the paper's form it comes back wrong in a way that is hard to
/// notice — a textbook matched to a journal article of the same title, with a
/// volume, an issue and a page range of `1054-1054` — and sent through the
/// document's form it cannot be cited at all. What a book has is a publisher,
/// an edition and an ISBN, and that is a third shape.
///
/// Course material is the fourth, and it is here for the opposite reason to
/// the book: not because it is cited, but because there is so much of it. A
/// term's worth of slides, notes and a syllabus is thirty files that are not
/// papers, and left as documents they sit in the same run as the contracts and
/// the manuals, or worse, in the same run as the papers. It is a shelf before
/// it is a citation.
public enum DocumentKind: String, Codable, Hashable, Sendable, CaseIterable {
    /// Something published in a venue: a paper, a preprint, a thesis.
    case paper
    /// Something published whole, by a publisher: a book, a textbook, a
    /// monograph. Cited, but not out of a journal.
    case book
    /// A term's reading: slides, lecture notes, a syllabus, a problem set.
    case lecture
    /// Everything else somebody reads: a manual, a contract, a report.
    case document

    /// Whether a record of this kind wants a bibliography's fields.
    ///
    /// A book does. It was the whole reason for having a third kind. Course
    /// material does not: a deck of slides has no publisher and no venue, and
    /// an entry invented for it would be a citation somebody has to correct
    /// by hand in the manuscript. It is read, not cited.
    public var isCitable: Bool { self == .paper || self == .book }

    /// Whether a registrar can be asked about it.
    ///
    /// Only a paper: the lookup is by DOI or arXiv identifier, which a book
    /// does not carry. A book's record is typed in, which is why its fields
    /// are few.
    public var isLookedUp: Bool { self == .paper }
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
        /// Hundreds of pages, and a reference list at the back. No paper is
        /// that long; nothing but a book has both.
        case length
        /// Pages wider than they are tall. A paper is portrait, a book is
        /// portrait; a deck of slides is not.
        case slides
        /// The words a course puts on its own reading: a lecture number, a
        /// syllabus, a week, a course code.
        case course
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
    ///   - pageCount: how many pages the file has, where that is known.
    ///   - isLandscape: the pages are wider than they are tall.
    ///   - hasCourseWords: a course names itself on its own reading.
    public static func of(
        hasIdentifier: Bool,
        hasAbstract: Bool,
        hasReferences: Bool,
        pageCount: Int = 0,
        isLandscape: Bool = false,
        hasCourseWords: Bool = false
    ) -> DocumentGuess {
        if hasIdentifier { return DocumentGuess(kind: .paper, reason: .identifier) }
        if hasAbstract, hasReferences { return DocumentGuess(kind: .paper, reason: .structure) }
        // Slides, and then the words. A landscape page is the one thing no
        // paper and no book has, so it goes first — but only once the two
        // paper tests above have failed, because a conference paper printed
        // two-up is landscape too and it has an abstract.
        if isLandscape { return DocumentGuess(kind: .lecture, reason: .slides) }
        if hasCourseWords { return DocumentGuess(kind: .lecture, reason: .course) }
        // Long, and with a reference list at the back. The length alone is not
        // enough — a scanned manual is long too — and the references alone are
        // not either, since a short paper without an abstract has them. Both
        // together, at this length, is a book. The threshold is well past any
        // paper: a long one with appendices reaches forty pages, and a thesis
        // that reaches a hundred is a book for our purposes anyway.
        if hasReferences, pageCount >= Self.bookLength {
            return DocumentGuess(kind: .book, reason: .length)
        }
        return DocumentGuess(kind: .document, reason: .nothingFound)
    }

    /// Where a PDF stops being long and starts being a book.
    public static let bookLength = 100

    /// What a course calls its own reading, in the two languages this app
    /// is read in.
    ///
    /// Looked for in the file's name and the first page, and only after the
    /// paper tests have failed — "lecture" turns up in the prose of plenty of
    /// papers, and refusing to call those papers would be the old mistake in
    /// a new place. A course code (three or four letters and three digits,
    /// `STA 512`) is the strongest of them and the one nothing else has.
    public static let courseWords = [
        "lecture", "syllabus", "problem set", "homework", "midterm", "final exam",
        "course notes", "class notes", "tutorial",
        "강의", "강의자료", "강의노트", "수업", "주차", "차시", "과제", "중간고사", "기말고사", "실습",
    ]

    /// Whether a course names itself here. `text` is the file's name and the
    /// front of its first page, together.
    public static func namesACourse(_ text: String) -> Bool {
        let lower = text.lowercased()
        if courseWords.contains(where: { lower.contains($0) }) { return true }
        // A course code: letters then digits, the way a timetable writes one.
        return lower.range(of: #"\b[a-z]{2,4}\s?-?\s?\d{3}\b"#, options: .regularExpression) != nil
    }
}
