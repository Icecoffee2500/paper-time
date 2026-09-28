// Writes `Packages/PaperTimeKit/Tests/PaperCoreTests/Fixtures/feedback-names.json`:
// what `FeedbackNickname.clean` answers for each name below. The Portable
// build's `shared/feedbackName.ts` is held to the same file, so a nickname
// reaches the page the same from every desktop.
//
//   swiftc -parse-as-library Packages/PaperTimeKit/Sources/PaperCore/Model/FeedbackNickname.swift \
//       Scripts/feedback-names-fixture.swift -o /tmp/feedback-names && /tmp/feedback-names
import Foundation

@main
struct FeedbackNamesFixture {
    static let names: [String] = [
        "",
        "   ",
        " 새벽세시 ",
        "곰돌이   연구원",
        "줄\n바꿈",
        "a\r\nb",
        "탭\t이름",
        "a\u{3000}b",
        "\u{200B}zero width",
        "\u{FEFF}keeps the BOM",
        "<b>민지</b>",
        "-->",
        "a---b",
        "익명",
        "anonymous",
        "논문 읽는 고양이 🐈",
        "👨‍👩‍👧 가족",
        "Ünïcödé Émile",
        String(repeating: "가", count: 45),
        String(repeating: "a", count: 39) + " bbbb",
        String(repeating: "👍🏽", count: 42),
        "\\(not interpolation) \"quoted\"",
    ]

    static func main() throws {
        let cases = names.map { ["raw": $0, "clean": FeedbackNickname.clean($0)] }
        let file = ["limit": FeedbackNickname.limit, "cases": cases] as [String: Any]
        let data = try JSONSerialization.data(withJSONObject: file, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let url = URL(fileURLWithPath: "Packages/PaperTimeKit/Tests/PaperCoreTests/Fixtures/feedback-names.json")
        try (data + Data("\n".utf8)).write(to: url)
        print("\(url.path): \(cases.count) names")
    }
}
