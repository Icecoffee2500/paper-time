import CoreGraphics
import Foundation

/// A place in a paper that a note can point at.
///
/// Written into the note as an ordinary Markdown link, so a note stays a note:
/// readable in any editor, greppable, and still meaningful if this app is not
/// the thing opening it.
///
///     [the encoder is trained…](papertime://anchor?p=4&x=145&y=95&w=366&h=12)
public struct NoteAnchor: Hashable, Sendable, Codable {
    public var pageIndex: Int
    public var rect: CGRect
    public var quotedText: String

    public init(pageIndex: Int, rect: CGRect, quotedText: String) {
        self.pageIndex = pageIndex
        self.rect = rect
        self.quotedText = quotedText
    }

    public static let scheme = "papertime"
    public static let host = "anchor"

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        components.queryItems = [
            URLQueryItem(name: "p", value: String(pageIndex)),
            URLQueryItem(name: "x", value: Self.format(rect.minX)),
            URLQueryItem(name: "y", value: Self.format(rect.minY)),
            URLQueryItem(name: "w", value: Self.format(rect.width)),
            URLQueryItem(name: "h", value: Self.format(rect.height)),
        ]
        return components.url ?? URL(string: "papertime://anchor")!
    }

    public init?(url: URL) {
        guard url.scheme == Self.scheme, url.host == Self.host,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return nil }
        func value(_ name: String) -> Double? {
            items.first { $0.name == name }?.value.flatMap(Double.init)
        }
        guard let page = value("p"), let x = value("x"), let y = value("y"),
              let width = value("w"), let height = value("h")
        else { return nil }
        self.pageIndex = Int(page)
        self.rect = CGRect(x: x, y: y, width: width, height: height)
        self.quotedText = ""
    }

    /// What the link reads as in the note.
    ///
    /// The quoted words, shortened, so a page of notes stays a page of notes
    /// rather than a page of quotations.
    public var label: String {
        let words = quotedText
            .replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ")
            .filter { !$0.isEmpty }
        let short = words.prefix(7).joined(separator: " ")
        let ellipsis = words.count > 7 ? "…" : ""
        return short.isEmpty ? "p. \(pageIndex + 1)" : "\(short)\(ellipsis)"
    }

    private static func format(_ value: CGFloat) -> String {
        String(format: "%.2f", value)
    }
}
