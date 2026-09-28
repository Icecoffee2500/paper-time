import Foundation

/// The name a report is credited to on the download page — what the feedback
/// sheet sends as `name`, the same on both desktops (`shared/feedbackName.ts`;
/// both are held to `Fixtures/feedback-names.json`, which this code wrote).
///
/// One line, no longer than a name, and nothing that could end the HTML
/// comment the worker keeps it in (`<!-- credit: … -->`). Empty when none was
/// given: the page thanks those people apart, and lists nobody as «익명».
public enum FeedbackNickname {
    public static let limit = 40

    public static func clean(_ raw: String) -> String {
        var name = raw
            .replacingOccurrences(of: "<", with: "")
            .replacingOccurrences(of: ">", with: "")
        while name.contains("--") { name = name.replacingOccurrences(of: "--", with: "-") }
        name = name
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return String(name.prefix(limit)).trimmingCharacters(in: .whitespaces)
    }
}
