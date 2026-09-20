import Foundation
import InkEngine
import SwiftUI

/// What the pointer does on the page while drawing: Excalidraw's row of
/// tools, with the pen, the highlighter and the eraser the iPad already has
/// in the same row. Each has its one-letter key.
enum SketchTool: String, CaseIterable, Identifiable, Sendable {
    case select, pen, highlighter, eraser, rectangle, ellipse, arrow, line, text

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .select: "cursorarrow"
        case .pen: "pencil.tip"
        case .highlighter: "highlighter"
        case .eraser: "eraser"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .arrow: "arrow.up.right"
        case .line: "line.diagonal"
        case .text: "textformat"
        }
    }

    var label: String {
        switch self {
        case .select: L("선택", "Select")
        case .pen: L("펜", "Pen")
        case .highlighter: L("형광펜", "Highlighter")
        case .eraser: L("지우개", "Eraser")
        case .rectangle: L("네모", "Rectangle")
        case .ellipse: L("동그라미", "Ellipse")
        case .arrow: L("화살표", "Arrow")
        case .line: L("선", "Line")
        case .text: L("글", "Text")
        }
    }

    /// The key that picks it, with nothing held down — while drawing, the
    /// keyboard is a tool rack, as it is in Excalidraw and in Figma.
    var key: Character {
        switch self {
        case .select: "v"
        case .pen: "p"
        case .highlighter: "h"
        case .eraser: "e"
        case .rectangle: "r"
        case .ellipse: "o"
        case .arrow: "a"
        case .line: "l"
        case .text: "t"
        }
    }

    static func tool(for key: Character) -> SketchTool? {
        allCases.first { $0.key == key }
    }

    /// The pencil tool this one is, when it is one of the pencil's.
    var inkTool: InkTool? {
        switch self {
        case .pen: .pen
        case .highlighter: .highlighter
        case .eraser: .eraser
        default: nil
        }
    }

    /// The kind of element this tool draws, when it draws one.
    var makes: SketchElement.Kind? {
        switch self {
        case .rectangle: .rectangle
        case .ellipse: .ellipse
        case .arrow: .arrow
        case .line: .line
        case .text: .text
        default: nil
        }
    }

    /// Whether the style panel has anything to say for this tool.
    var hasStyle: Bool { makes != nil || inkTool != nil }
}

/// What the sketch's controls act on: the view over the page that holds the
/// selection and knows how to change it.
@MainActor
protocol SketchEditing: AnyObject {
    var hasSelection: Bool { get }
    /// Changes the style of everything selected, as one undoable step.
    func applyStyle(_ change: @escaping (inout SketchStyle) -> Void)
    func deleteSelection()
    func duplicateSelection()
    /// Draws a box round whatever is selected — shapes, text, handwriting.
    func frameSelection()
    func bringSelectionToFront()
    func sendSelectionToBack()
    func selectAllOnPage()
    /// Opens the words of the one selected element for editing.
    func editSelectedText()
}

/// The drawing mode's state, shared between the tool strip, the style panel
/// and the view on the page that does the drawing.
@Observable
final class SketchState {
    var tool: SketchTool = .select {
        didSet { if tool != oldValue { selectionChanged() } }
    }

    /// The style the next shape is drawn in. Kept on the device, like the
    /// pen's presets, so tomorrow's arrows look like today's.
    var style: SketchStyle = SketchState.loadStyle() {
        didSet { SketchState.save(style) }
    }

    /// What is selected on the page, as copies for the panel to read.
    private(set) var selectedElements: [SketchElement] = []
    /// How many pen strokes are selected alongside them.
    private(set) var selectedStrokeCount = 0
    /// True while words are being typed into an element.
    var isEditingText = false

    /// The view doing the drawing, while there is one.
    weak var editor: (any SketchEditing)?

    var hasSelection: Bool { !selectedElements.isEmpty || selectedStrokeCount > 0 }

    /// The style the panel shows: the selection's, when there is one, and
    /// the tool's otherwise.
    var shownStyle: SketchStyle {
        selectedElements.first?.style ?? style
    }

    /// The kinds selected, for the panel to know which controls apply.
    var selectedKinds: Set<SketchElement.Kind> {
        Set(selectedElements.map(\.kind))
    }

    func setSelection(_ elements: [SketchElement], strokes: Int) {
        selectedElements = elements
        selectedStrokeCount = strokes
    }

    private func selectionChanged() {}

    /// Applies a style change: to the selection when there is one, and to
    /// the style the next shape gets either way — choosing red with a box
    /// selected means "this one red, and the next ones too".
    @MainActor
    func change(_ edit: @escaping (inout SketchStyle) -> Void) {
        edit(&style)
        if hasSelection { editor?.applyStyle(edit) }
    }

    static let key = "sketchStyle"

    static func loadStyle() -> SketchStyle {
        guard let data = UserDefaults.standard.data(forKey: key),
              let style = try? JSONDecoder().decode(SketchStyle.self, from: data) else { return SketchStyle() }
        return style
    }

    static func save(_ style: SketchStyle) {
        if let data = try? JSONEncoder().encode(style) { UserDefaults.standard.set(data, forKey: key) }
    }
}
