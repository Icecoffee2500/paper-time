import Foundation
import Testing
@testable import PaperCore

@Suite("What a PDF is")
struct DocumentKindTests {
    @Test("A printed identifier settles it")
    func identifier() {
        let guess = DocumentGuess.of(hasIdentifier: true, hasAbstract: false, hasReferences: false)
        #expect(guess.kind == .paper)
        #expect(guess.reason == .identifier)
    }

    @Test("An abstract and a reference list together read as a paper")
    func structure() {
        #expect(DocumentGuess.of(hasIdentifier: false, hasAbstract: true, hasReferences: true).kind == .paper)
        // One without the other is not enough: a report has a summary, and a
        // manual can cite a standard.
        #expect(DocumentGuess.of(hasIdentifier: false, hasAbstract: true, hasReferences: false).kind == .document)
        #expect(DocumentGuess.of(hasIdentifier: false, hasAbstract: false, hasReferences: true).kind == .document)
    }

    @Test("Nothing found means a document")
    func nothing() {
        let guess = DocumentGuess.of(hasIdentifier: false, hasAbstract: false, hasReferences: false)
        #expect(guess.kind == .document)
        #expect(guess.reason == .nothingFound)
    }

    @Test("A record without an answer is read as a paper, and written without the key")
    func absentFromOldRecords() throws {
        var meta = PaperMeta()
        #expect(meta.kind == nil)
        #expect(meta.kindIsUnanswered)
        #expect(meta.effectiveKind == .paper)

        let written = String(decoding: try JSONCoding.encoder.encode(meta), as: UTF8.self)
        #expect(!written.contains("\"kind\""))
        #expect(!written.contains("guessedKind"))

        meta.guessedKind = .document
        #expect(meta.effectiveKind == .document)
        meta.kind = .paper
        // The answer wins over the guess, always.
        #expect(meta.effectiveKind == .paper)
        #expect(!meta.kindIsUnanswered)
    }
}
