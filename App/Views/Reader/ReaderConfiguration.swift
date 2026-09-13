import Foundation
import InkEngine
import SwiftUI

/// What the reader is currently set up to do.
@Observable
public final class ReaderConfiguration {
    public enum Mode: String, CaseIterable, Identifiable, Sendable {
        /// Text selection, links and scrolling. Pencil marks nothing.
        case read
        /// Pencil draws; fingers still scroll.
        case draw

        public var id: String { rawValue }
        public var symbolName: String {
            switch self {
            case .read: "hand.point.up.left"
            case .draw: "pencil.tip"
            }
        }
        public var label: String {
            switch self {
            case .read: "Read"
            case .draw: "Draw"
            }
        }
    }

    public enum PageLayout: String, CaseIterable, Identifiable, Sendable {
        case continuous, singlePage, book
        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .continuous: "Continuous"
            case .singlePage: "Single Page"
            case .book: "Book"
            }
        }
        public var symbolName: String {
            switch self {
            case .continuous: "scroll"
            case .singlePage: "doc"
            case .book: "book.pages"
            }
        }
    }

    /// A gentle tint for long reading sessions. Never inverts the page, because
    /// inverting a paper turns its figures into negatives.
    public enum PageTint: String, CaseIterable, Identifiable, Sendable {
        case none, sepia, dim, glass
        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .none: "Paper White"
            case .sepia: "Sepia"
            case .dim: "Dimmed"
            case .glass: "Glass"
            }
        }

        /// Whether the paper itself is glass — the page's white multiplied
        /// away so the panel behind it shows through, leaving the ink.
        ///
        /// Its own tint rather than a setting of its own, because it is a way
        /// of tinting the page and because the other three are what it has to
        /// be chosen instead of: a page cannot be both dimmed and see-through.
        public var isGlass: Bool { self == .glass }
    }

    public var mode: Mode = .read
    /// Both start from the setting, so what Settings says is what the reader
    /// does — the picker there used to write a preference nothing read.
    public var layout: PageLayout = PageLayout(
        rawValue: UserDefaults.standard.string(forKey: "readerPageMode") ?? ""
    ) ?? .continuous
    public var tint: PageTint = PageTint(
        rawValue: UserDefaults.standard.string(forKey: "readerTint") ?? ""
    ) ?? .none
    public var markupColor: MarkupColor = .yellow
    /// Allow a finger to draw as well as the pencil. Off by default so the page
    /// still scrolls under a resting hand.
    public var fingerDrawing = false
    public var showsToolPicker = false

    public init() {}
}
