import Foundation
import InkEngine
import SwiftUI

/// What the pointer does on the page while drawing: Figma's rack — select,
/// frame, the shapes, the pen, text — with the pencil's own highlighter and
/// eraser in the pen's group. Each has its one-letter key.
enum SketchTool: String, CaseIterable, Identifiable, Sendable {
    case select, frame, pen, highlighter, eraser, rectangle, ellipse, arrow, line, text

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .select: "cursorarrow"
        case .frame: "number"
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
        case .frame: L("프레임", "Frame")
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
        case .frame: "f"
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
        case .frame: .frame
        case .rectangle: .rectangle
        case .ellipse: .ellipse
        case .arrow: .arrow
        case .line: .line
        case .text: .text
        default: nil
        }
    }

    /// Whether the panel has anything to say for this tool.
    var hasStyle: Bool { makes != nil || inkTool != nil }

    /// The toolbar's groups, as Figma has them: one button each, the group's
    /// members behind a chevron.
    static let shapes: [SketchTool] = [.rectangle, .ellipse, .line, .arrow]
    static let inks: [SketchTool] = [.pen, .highlighter, .eraser]
}

/// Which edge of the selection lines up with which edge of what holds it.
enum SketchAlignment: CaseIterable {
    case left, centerX, right, top, centerY, bottom

    var symbolName: String {
        switch self {
        case .left: "align.horizontal.left"
        case .centerX: "align.horizontal.center"
        case .right: "align.horizontal.right"
        case .top: "align.vertical.top"
        case .centerY: "align.vertical.center"
        case .bottom: "align.vertical.bottom"
        }
    }

    var label: String {
        switch self {
        case .left: L("왼쪽 맞춤", "Align Left")
        case .centerX: L("가로 가운데", "Align Horizontal Centers")
        case .right: L("오른쪽 맞춤", "Align Right")
        case .top: L("위 맞춤", "Align Top")
        case .centerY: L("세로 가운데", "Align Vertical Centers")
        case .bottom: L("아래 맞춤", "Align Bottom")
        }
    }
}

/// What the sketch's controls act on: the view over the page that holds the
/// selection and knows how to change it.
@MainActor
protocol SketchEditing: AnyObject {
    var hasSelection: Bool { get }
    /// Changes the style of everything selected, as one undoable step.
    func applyStyle(_ change: @escaping (inout SketchStyle) -> Void)
    /// Changes the selected elements themselves — a name, a layout, whether
    /// a frame clips — as one undoable step under the given name.
    func editSelection(named name: String, _ change: @escaping (inout SketchElement) -> Void)
    func deleteSelection()
    func duplicateSelection()
    /// Puts a frame round whatever is selected — shapes, text, handwriting.
    func frameSelection()
    /// Makes the selected elements one thing, and takes one apart again.
    func groupSelection()
    func ungroupSelection()
    /// Gives the selected frame a row or a column to lay its children in,
    /// or takes it away; several loose elements are put in a new frame that
    /// has one.
    func toggleAutoLayout()
    func bringSelectionToFront()
    func sendSelectionToBack()
    func selectAllOnPage()
    /// Opens the words of the one selected element for editing.
    func editSelectedText()
    /// Lines the selection up: several things with each other, one thing
    /// with the frame it is in, or with the page.
    func align(_ alignment: SketchAlignment)
    /// Moves the selection so its box starts here — `top` measured down
    /// from the top of the page, as a design tool counts it.
    func setSelectionOrigin(x: CGFloat?, top: CGFloat?)
    func setSelectionSize(width: CGFloat?, height: CGFloat?)
}

/// The drawing mode's state, shared between the tool strip, the inspector
/// and the view on the page that does the drawing.
@Observable
final class SketchState {
    var tool: SketchTool = .select {
        didSet { if tool != oldValue { selectionChanged() } }
    }

    /// The shape tool last used, which is the one the shapes button shows.
    var lastShape: SketchTool = .rectangle
    /// The pen-group tool last used.
    var lastInk: SketchTool = .pen

    /// The style the next shape is drawn in. Kept on the device, like the
    /// pen's presets, so tomorrow's arrows look like today's.
    var style: SketchStyle = SketchState.loadStyle() {
        didSet { SketchState.save(style) }
    }

    /// What is selected on the page, as copies for the panel to read: the
    /// outermost elements, not what lies inside them.
    private(set) var selectedElements: [SketchElement] = []
    /// How many pen strokes are selected alongside them.
    private(set) var selectedStrokeCount = 0
    /// The box round everything selected, in page coordinates.
    private(set) var selectionBox: CGRect?
    /// The page the selection is on, in its own coordinates — what X and Y
    /// are measured against.
    private(set) var pageBox: CGRect?
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

    /// The one frame selected, when exactly one thing is and it is a frame.
    var selectedFrame: SketchElement? {
        guard selectedElements.count == 1, selectedStrokeCount == 0,
              let only = selectedElements.first, only.kind == .frame else { return nil }
        return only
    }

    /// The one element selected, when exactly one is.
    var selectedOne: SketchElement? {
        guard selectedElements.count == 1, selectedStrokeCount == 0 else { return nil }
        return selectedElements.first
    }

    func setSelection(_ elements: [SketchElement], strokes: Int, box: CGRect?, page: CGRect?) {
        selectedElements = elements
        selectedStrokeCount = strokes
        selectionBox = box
        pageBox = page
    }

    private func selectionChanged() {
        if SketchTool.shapes.contains(tool) { lastShape = tool }
        if SketchTool.inks.contains(tool) { lastInk = tool }
    }

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
