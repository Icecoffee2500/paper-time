import Foundation
import Testing
@testable import PaperCore

/// `Fixtures/feedback-names.json` is what this code answers
/// (`Scripts/feedback-names-fixture.swift`); the Portable build's tests read
/// the same file, so a name goes on the page the same from every desktop.
@Suite struct FeedbackNicknameTests {
    struct Case: Decodable { var raw: String; var clean: String }
    struct File: Decodable { var limit: Int; var cases: [Case] }

    @Test func namesAreCleanedAsTheFileSays() throws {
        let url = try #require(Bundle.module.url(forResource: "feedback-names", withExtension: "json", subdirectory: "Fixtures"))
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        #expect(file.limit == FeedbackNickname.limit)
        for one in file.cases {
            #expect(FeedbackNickname.clean(one.raw) == one.clean, "\(one.raw.debugDescription)")
        }
    }

    @Test func nothingCanCloseTheComment() {
        for raw in ["-->", "a-->b", "<!-- x -->", "--->", "- - >"] {
            let clean = FeedbackNickname.clean(raw)
            #expect(!clean.contains("-->") && !clean.contains("<") && !clean.contains(">"), "\(raw) → \(clean)")
        }
    }
}
