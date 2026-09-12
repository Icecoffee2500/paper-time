import Foundation
import InkEngine
import PencilKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// What the pencil is being: the three tools of a notebook app, in the order
/// GoodNotes puts them. Each keeps its own colours and widths.
public enum InkTool: String, CaseIterable, Identifiable, Codable, Sendable {
    case pen, highlighter, eraser
    public var id: String { rawValue }
    public var symbolName: String {
        switch self {
        case .pen: "pencil.tip"
        case .highlighter: "highlighter"
        case .eraser: "eraser"
        }
    }
    public var label: String {
        switch self {
        case .pen: "Pen"
        case .highlighter: "Highlighter"
        case .eraser: "Eraser"
        }
    }
}

/// The pen's palette: ink colours, as a notebook offers them.
public enum PenColor: String, CaseIterable, Identifiable, Codable, Sendable {
    case black, blue, red, green, purple, orange, grey
    public var id: String { rawValue }
    public var components: (red: CGFloat, green: CGFloat, blue: CGFloat) {
        switch self {
        case .black: (0.10, 0.10, 0.12)
        case .blue: (0.12, 0.36, 0.98)
        case .red: (0.90, 0.20, 0.18)
        case .green: (0.16, 0.62, 0.32)
        case .purple: (0.52, 0.30, 0.88)
        case .orange: (0.96, 0.55, 0.12)
        case .grey: (0.55, 0.55, 0.58)
        }
    }
    public var color: Color { Color(red: components.red, green: components.green, blue: components.blue) }
    public var label: String { rawValue.capitalized }
}

/// The three quick colours and three widths beside each tool, and the tool
/// options behind them. Saved on the device; the same shape on every device.
public struct InkPresets: Codable, Equatable, Sendable {
    public var penColors: [PenColor] = [.black, .blue, .red]
    public var penColorIndex = 0
    public var penWidths: [CGFloat] = [1.5, 3, 5]
    public var penWidthIndex = 1
    public var highlighterColors: [MarkupColor] = [.yellow, .green, .pink]
    public var highlighterColorIndex = 0
    public var highlighterWidths: [CGFloat] = [12, 18, 26]
    public var highlighterWidthIndex = 1
    /// A highlighter stroke over words becomes a highlight fitted to them,
    /// one under the words an underline — GoodNotes' "draw in straight
    /// line", taken one step further. Off, the stroke stays as drawn.
    public var fitsToText = true
    /// The eraser takes highlights and underlines off along with strokes.
    public var eraserErasesMarks = true

    public var penColor: PenColor { penColors[min(penColorIndex, penColors.count - 1)] }
    public var penWidth: CGFloat { penWidths[min(penWidthIndex, penWidths.count - 1)] }
    public var highlighterColor: MarkupColor { highlighterColors[min(highlighterColorIndex, highlighterColors.count - 1)] }
    public var highlighterWidth: CGFloat { highlighterWidths[min(highlighterWidthIndex, highlighterWidths.count - 1)] }

    static let key = "inkPresets"
    static func load() -> InkPresets {
        guard let data = UserDefaults.standard.data(forKey: key),
              let presets = try? JSONDecoder().decode(InkPresets.self, from: data) else { return InkPresets() }
        return presets
    }
    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

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
    /// On a phone there is no pencil, so a finger is the pen.
    public var fingerDrawing: Bool = {
        #if canImport(UIKit)
        MainActor.assumeIsolated { UIDevice.current.userInterfaceIdiom == .phone }
        #else
        false
        #endif
    }()

    public var tool: InkTool = .pen
    public var presets = InkPresets.load() {
        didSet { presets.save() }
    }
    /// Which tool the canvases should hold, as a string that changes when
    /// anything about it does — the cheap way for the reader to notice.
    public var toolKey: String {
        switch tool {
        case .pen: "pen \(presets.penColor.rawValue) \(presets.penWidth)"
        case .highlighter: "highlighter \(presets.highlighterColor.rawValue) \(presets.highlighterWidth)"
        case .eraser: "eraser"
        }
    }

    #if canImport(UIKit)
    public var currentTool: PKTool {
        switch tool {
        case .pen:
            let c = presets.penColor.components
            return PKInkingTool(.pen, color: UIColor(red: c.red, green: c.green, blue: c.blue, alpha: 1), width: presets.penWidth)
        case .highlighter:
            return PKInkingTool(.marker, color: presets.highlighterColor.platformColor, width: presets.highlighterWidth)
        case .eraser:
            return PKEraserTool(.vector)
        }
    }
    #endif

    public init() {}
}
