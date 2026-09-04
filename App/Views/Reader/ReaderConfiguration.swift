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
        case continuous, singlePage, twoUp
        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .continuous: "Continuous"
            case .singlePage: "Single Page"
            case .twoUp: "Two Pages"
            }
        }
        public var symbolName: String {
            switch self {
            case .continuous: "scroll"
            case .singlePage: "doc"
            case .twoUp: "book.pages"
            }
        }
    }

    /// A gentle tint for long reading sessions. Never inverts the page, because
    /// inverting a paper turns its figures into negatives.
    public enum PageTint: String, CaseIterable, Identifiable, Sendable {
        case none, sepia, dim
        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .none: "Paper White"
            case .sepia: "Sepia"
            case .dim: "Dimmed"
            }
        }
    }

    public var mode: Mode = .read
    public var layout: PageLayout = .continuous
    public var tint: PageTint = .none
    public var markupColor: MarkupColor = .yellow
    /// Allow a finger to draw as well as the pencil. Off by default so the page
    /// still scrolls under a resting hand.
    public var fingerDrawing = false
    public var showsToolPicker = false

    public init() {}
}
