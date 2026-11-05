import Foundation
import Testing
@testable import PaperCore

/// `Fixtures/paper-addresses.json` is what `PaperAddress` answers
/// (`Scripts/paper-address-fixture.swift`); the Portable build's tests read
/// the same file. A change here that is not written back fails.
@Suite struct PaperAddressFixtureTests {
    struct Case: Decodable {
        var text: String
        var kind: String?
        var value: String?
        var address: String?
        var pdf: String?
        var lookup: String?
        var file: String?
    }
    struct Answer: Decodable { var json: String; var pdfs: [String] }
    struct Guess: Decodable { var doi: String; var json: String; var pdfs: [String] }
    struct File: Decodable { var addresses: [Case]; var openAlex: [Answer]; var publishers: [Guess] }

    func fixture() throws -> File {
        let url = try #require(Bundle.module.url(forResource: "paper-addresses", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
    }

    @Test func addressesReadAsTheFileSays() throws {
        for expected in try fixture().addresses {
            let read = PaperAddress.read(expected.text)
            switch read {
            case nil:
                #expect(expected.kind == nil, Comment(rawValue: expected.text))
            case let .arxiv(id)?:
                #expect(expected.kind == "arxiv" && expected.value == id, Comment(rawValue: expected.text))
            case let .doi(doi)?:
                #expect(expected.kind == "doi" && expected.value == doi, Comment(rawValue: expected.text))
            case let .web(url)?:
                #expect(expected.kind == "web" && expected.value == url.absoluteString, Comment(rawValue: expected.text))
            }
            #expect(read?.text == expected.address, Comment(rawValue: expected.text))
            #expect(read?.pdfURL?.absoluteString == expected.pdf, Comment(rawValue: expected.text))
            #expect(read?.lookupURL?.absoluteString == expected.lookup, Comment(rawValue: expected.text))
            #expect(read?.fileName == expected.file, Comment(rawValue: expected.text))
        }
    }

    @Test func openAlexAnswersReadAsTheFileSays() throws {
        for answer in try fixture().openAlex {
            #expect(PaperAddress.openAccessPDFs(inOpenAlex: Data(answer.json.utf8)).map(\.absoluteString) == answer.pdfs)
        }
    }

    @Test func publishersFilesAreGuessedAsTheFileSays() throws {
        for guess in try fixture().publishers {
            #expect(PaperAddress.publisherPDFs(for: guess.doi, inOpenAlex: Data(guess.json.utf8)).map(\.absoluteString) == guess.pdfs, Comment(rawValue: guess.doi))
        }
    }

    @Test func theFieldsWordsAreAddresses() {
        #expect(PaperAddress.read("https://arxiv.org/abs/2512.11732") == .arxiv("2512.11732"))
        #expect(PaperAddress.read("a sentence with 10.1145/3292500.3330701 in it") == nil)
        #expect(PaperAddress.arxiv("cs/0101001").identifiers.arxiv == "cs/0101001")
        #expect(PaperAddress.doi("10.1145/3292500.3330701").identifiers.doi == "10.1145/3292500.3330701")
    }
}
