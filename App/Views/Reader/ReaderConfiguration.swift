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
            case .continuous: L("이어서 보기", "Continuous")
            case .singlePage: L("한 쪽씩 보기", "Single Page")
            case .book: L("책처럼 보기", "Book")
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

    /// A tint for long reading sessions: a ground for the page to sit on,
    /// and with it how the paper is drawn — as printed, multiplied away so
    /// the ink sits on the ground, or turned to night. Which of the three is
    /// decided by the ground (`rendering`), not by the case: a light ground
    /// can take the ink by multiplying, a dark one cannot, and Glass has no
    /// ground of its own but the panel's.
    public enum PageTint: String, CaseIterable, Identifiable, Sendable {
        case none, sepia, dim, glass, custom
        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .none: L("종이 흰색", "Paper White")
            case .sepia: L("세피아", "Sepia")
            case .dim: L("어둡게", "Dimmed")
            case .glass: L("유리", "Glass")
            case .custom: L("직접 고른 색", "Custom Color")
            }
        }

        /// Whether the paper itself is glass — nothing of its own behind the
        /// page, so the panel shows through it, leaving the ink.
        ///
        /// Its own tint rather than a setting of its own, because it is a way
        /// of tinting the page and because the others are what it has to be
        /// chosen instead of: a page cannot be both dimmed and see-through.
        public var isGlass: Bool { self == .glass }
    }

    /// How the paper is drawn under a tint.
    public enum PageRendering: String, Equatable, Sendable {
        /// As printed: white paper on the window's ground, with its shadow.
        case plain
        /// The paper's white multiplied away, so the ink sits on the ground
        /// — sepia paper, a pale colour, or the panel itself.
        case multiply
        /// Night: the page's luminance inverted with every hue put back, and
        /// its black screened away into the ground — so the ink is light on
        /// the ground with no edge where the page ends, colours keep their
        /// hue, and the pictures are drawn again as printed (`PageImages`).
        /// The way Obsidian's «Adapt to theme» reads a paper at night.
        case night
    }

    /// A ground colour, in sRGB, kept as `#rrggbb` in the defaults.
    public struct TintColor: Equatable, Sendable {
        public var red: Double
        public var green: Double
        public var blue: Double

        public init(_ red: Double, _ green: Double, _ blue: Double) {
            self.red = red; self.green = green; self.blue = blue
        }

        public init?(hex: String) {
            var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix("#") { text.removeFirst() }
            guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
            self.init(Double((value >> 16) & 0xff) / 255, Double((value >> 8) & 0xff) / 255, Double(value & 0xff) / 255)
        }

        public var hex: String {
            let r = Int((red * 255).rounded()), g = Int((green * 255).rounded()), b = Int((blue * 255).rounded())
            return String(format: "#%02x%02x%02x", max(0, min(255, r)), max(0, min(255, g)), max(0, min(255, b)))
        }

        /// Relative luminance, 0 black to 1 white: what decides whether the
        /// ink can be multiplied onto this ground or the page must go to night.
        public var luminance: Double {
            func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin(red) + 0.7152 * lin(green) + 0.0722 * lin(blue)
        }

        public var color: Color { Color(red: red, green: green, blue: blue) }

        /// Sepia paper.
        public static let sepia = TintColor(0.96, 0.93, 0.86)
        /// The dimmed tint's ground, and the starting colour of a custom one:
        /// the app's own dark panel, not black.
        public static let night = TintColor(0.149, 0.153, 0.169)
    }

    public var mode: Mode = .read
    /// Whether the window is in the dark appearance. Set by the reader from
    /// the environment; what Glass does depends on it.
    public var isDarkAppearance = false

    /// How the page is drawn for the tint — see `PageRendering`.
    public var rendering: PageRendering {
        switch tint {
        case .none: .plain
        case .sepia: .multiply
        case .dim: .night
        // The panel behind it is light or dark with the appearance.
        case .glass: isDarkAppearance ? .night : .multiply
        case .custom: customTintColor.luminance >= 0.5 ? .multiply : .night
        }
    }

    /// The ground the page sits on, or nil for the panel itself.
    public var groundColor: TintColor? {
        switch tint {
        case .none, .glass: nil
        case .sepia: .sepia
        case .dim: .night
        case .custom: customTintColor
        }
    }

    /// Everything the reader has to redraw for: the tint, how it draws and
    /// on what.
    public var tintKey: String { "\(tint.rawValue) \(rendering.rawValue) \(groundColor?.hex ?? "panel")" }

    /// Both start from the setting, so what Settings says is what the reader
    /// does — the picker there used to write a preference nothing read.
    /// A probe run can ask for a tint of its own (`--papertime-tint=dim`,
    /// `--papertime-tint-color=#rrggbb`) without touching the defaults.
    public var layout: PageLayout = PageLayout(
        rawValue: UserDefaults.standard.string(forKey: "readerPageMode") ?? ""
    ) ?? .continuous
    public var tint: PageTint = PageTint(
        rawValue: Boot.setting("PAPERTIME_TINT") ?? UserDefaults.standard.string(forKey: "readerTint") ?? ""
    ) ?? .none
    /// The custom tint's ground: chosen in Settings, which keeps it in the
    /// defaults; read back whenever the defaults change, so the open paper
    /// follows the colour well as it is dragged.
    public var customTintColor: TintColor = TintColor(
        hex: Boot.setting("PAPERTIME_TINT_COLOR") ?? UserDefaults.standard.string(forKey: ReaderConfiguration.customTintKey) ?? ""
    ) ?? .night
    public static let customTintKey = "readerTintColor"
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
    /// The Mac's drawing mode: which of Excalidraw's tools the pointer is,
    /// the style the next shape gets, and what is selected on the page.
    let sketch = SketchState()
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

    /// Takes the custom ground from the defaults, as Settings or the colour
    /// panel writes it — the reader calls this whenever the stored value
    /// changes, so the page follows the colour as it is dragged. A probe's
    /// own colour (`--papertime-tint-color`) is kept.
    public func adoptCustomTint(hex: String) {
        guard Boot.setting("PAPERTIME_TINT_COLOR") == nil,
              let colour = TintColor(hex: hex), colour != customTintColor else { return }
        customTintColor = colour
    }
}
