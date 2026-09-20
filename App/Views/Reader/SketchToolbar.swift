#if os(macOS)
import AppKit
import InkEngine
import SwiftUI

/// The tool rack while the pencil is out on the Mac: Excalidraw's row —
/// select, the pen, the highlighter, the eraser, the shapes, text — floating
/// over the top of the page, each tool with its one-letter key. System
/// buttons on the app's glass; the letters are there because a tool you
/// reach for with a key is a tool you actually use while reading.
struct SketchToolbar: View {
    @Bindable var configuration: ReaderConfiguration

    private var state: SketchState { configuration.sketch }

    var body: some View {
        HStack(spacing: 2) {
            Button { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) } label: {
                Image(systemName: "arrow.uturn.backward").frame(width: 26, height: 26)
            }
            .help(L("되돌리기 (⌘Z)", "Undo (⌘Z)"))
            Button { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) } label: {
                Image(systemName: "arrow.uturn.forward").frame(width: 26, height: 26)
            }
            .help(L("다시 하기 (⇧⌘Z)", "Redo (⇧⌘Z)"))

            divider

            ForEach(SketchTool.allCases) { tool in
                toolButton(tool)
                if tool == .eraser { divider }
            }

            divider

            Button(L("끝", "Done")) { configuration.mode = .read }
                .fontWeight(.medium)
                .help(L("펜 내려놓기 (esc)", "Put the Pencil Down (esc)"))
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .liquidGlass(.floating)
        .overlay(Capsule().strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
    }

    private var divider: some View {
        Divider().frame(height: 18).padding(.horizontal, 5)
    }

    private func toolButton(_ tool: SketchTool) -> some View {
        let chosen = state.tool == tool
        return Button {
            state.tool = tool
        } label: {
            VStack(spacing: 0) {
                Image(systemName: tool.symbolName)
                    .font(.system(size: 14, weight: .medium))
                    .symbolVariant(chosen && tool != .select ? .fill : .none)
                    .frame(width: 26, height: 20)
                Text(String(tool.key).uppercased())
                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                    .foregroundStyle(chosen ? Color.accentColor : .secondary)
            }
            .frame(width: 30, height: 30)
        }
        .tint(chosen ? Color.accentColor : .primary)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.accentColor.opacity(chosen ? 0.16 : 0))
        )
        .help("\(tool.label) (\(String(tool.key).uppercased()))")
    }
}

/// What the chosen tool draws with, or what the selection is drawn with —
/// Excalidraw's side panel: colour, fill, width, dash, corners, heads, size.
/// A change with something selected changes it and sets the default for the
/// next; with nothing selected it sets the default alone.
struct SketchStylePanel: View {
    @Bindable var configuration: ReaderConfiguration

    private var state: SketchState { configuration.sketch }

    /// The kinds the controls are about: the selection's, or the tool's.
    private var kinds: Set<SketchElement.Kind> {
        if state.hasSelection { return state.selectedKinds }
        return state.tool.makes.map { [$0] } ?? []
    }

    private var shows: Bool {
        state.hasSelection || state.tool.hasStyle
    }

    var body: some View {
        if shows {
            VStack(alignment: .leading, spacing: 10) {
                header
                if let ink = state.tool.inkTool, !state.hasSelection {
                    inkControls(ink)
                } else {
                    shapeControls
                }
                if state.hasSelection { actions }
            }
            .padding(12)
            // As wide as its widest row and no wider: a fixed width cut the
            // seventh fill swatch in half.
            .fixedSize()
            .liquidGlass(.floating, in: RoundedRectangle(cornerRadius: Corner.popover, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Corner.popover, style: .continuous).strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
        }
    }

    private var header: some View {
        HStack {
            if state.hasSelection {
                let count = state.selectedElements.count + state.selectedStrokeCount
                Text(count == 1
                     ? L("선택한 것", "Selection")
                     : L("선택한 것 \(count)개", "\(count) selected"))
            } else {
                Text(state.tool.label)
            }
            Spacer()
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
    }

    // MARK: - The pen's

    @ViewBuilder
    private func inkControls(_ ink: InkTool) -> some View {
        switch ink {
        case .pen:
            section(L("색", "Colour")) {
                swatches(PenColor.allCases, chosen: configuration.presets.penColor, color: \.color) { color in
                    configuration.presets.penColors[configuration.presets.penColorIndex] = color
                }
            }
            section(L("굵기", "Width")) {
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { index in
                        let width = configuration.presets.penWidths[index]
                        option(chosen: configuration.presets.penWidthIndex == index) {
                            configuration.presets.penWidthIndex = index
                        } label: {
                            Circle().fill(.primary).frame(width: 3 + width * 1.6, height: 3 + width * 1.6)
                        }
                    }
                }
            }
        case .highlighter:
            section(L("색", "Colour")) {
                swatches(MarkupColor.allCases, chosen: configuration.presets.highlighterColor, color: { Color($0.platformColor) }) { color in
                    configuration.presets.highlighterColors[configuration.presets.highlighterColorIndex] = color
                }
            }
            section(L("굵기", "Width")) {
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { index in
                        let width = configuration.presets.highlighterWidths[index]
                        option(chosen: configuration.presets.highlighterWidthIndex == index) {
                            configuration.presets.highlighterWidthIndex = index
                        } label: {
                            Capsule().fill(.primary).frame(width: 16, height: 3 + width * 0.35)
                        }
                    }
                }
            }
            Toggle(L("글자에 맞추기", "Fit to Text"), isOn: $configuration.presets.fitsToText)
                .toggleStyle(.checkbox)
                .font(.caption)
        case .eraser:
            Toggle(L("하이라이트도 지우기", "Erase Highlights Too"), isOn: $configuration.presets.eraserErasesMarks)
                .toggleStyle(.checkbox)
                .font(.caption)
            Text(L("지우개는 선과 모양을 통째로 지워요.", "The eraser removes a stroke or shape whole."))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - The shapes'

    @ViewBuilder
    private var shapeControls: some View {
        let style = state.shownStyle
        let hasBoxes = !kinds.isDisjoint(with: [.rectangle, .ellipse, .text])
        let hasConnectors = !kinds.isDisjoint(with: [.arrow, .line])
        let hasWords = kinds.contains(.text) || state.selectedElements.contains { !$0.text.isEmpty }
        let onlyStrokes = state.hasSelection && state.selectedElements.isEmpty

        if !onlyStrokes {
            section(L("선", "Stroke")) {
                swatches(SketchColor.strokes, chosen: style.stroke, color: { Color(cgColor: $0.cgColor) }, matches: { $0.matches($1) }) { color in
                    state.change { $0.stroke = color }
                }
            }
            if hasBoxes || kinds.isEmpty {
                section(L("채우기", "Fill")) {
                    HStack(spacing: 5) {
                        option(chosen: style.fill == nil) {
                            state.change { $0.fill = nil }
                        } label: {
                            Image(systemName: "slash.circle").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        ForEach(Array(SketchColor.fills.enumerated()), id: \.offset) { _, fill in
                            option(chosen: style.fill.map { $0.matches(fill) } ?? false) {
                                state.change { $0.fill = fill }
                            } label: {
                                Circle().fill(Color(cgColor: fill.flattenedOnWhite.cgColor))
                                    .overlay(Circle().strokeBorder(.primary.opacity(0.15), lineWidth: 0.5))
                                    .frame(width: 14, height: 14)
                            }
                        }
                    }
                }
            }
            section(L("굵기", "Width")) {
                HStack(spacing: 6) {
                    ForEach(SketchStyle.widths, id: \.self) { width in
                        option(chosen: abs(style.width - width) < 0.01) {
                            state.change { $0.width = width }
                        } label: {
                            Capsule().fill(.primary).frame(width: 16, height: max(width, 1.5))
                        }
                    }
                }
            }
            section(L("선 모양", "Dash")) {
                HStack(spacing: 6) {
                    ForEach(SketchStyle.Dash.allCases, id: \.self) { dash in
                        option(chosen: style.dash == dash) {
                            state.change { $0.dash = dash }
                        } label: {
                            DashSample(dash: dash).stroke(.primary, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: dashPattern(dash)))
                                .frame(width: 16, height: 8)
                        }
                    }
                }
            }
            if hasBoxes || kinds.isEmpty {
                section(L("모서리", "Corners")) {
                    HStack(spacing: 6) {
                        option(chosen: style.corners == .sharp) { state.change { $0.corners = .sharp } } label: {
                            Rectangle().strokeBorder(.primary, lineWidth: 1.5).frame(width: 14, height: 12)
                        }
                        option(chosen: style.corners == .round) { state.change { $0.corners = .round } } label: {
                            RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.primary, lineWidth: 1.5).frame(width: 14, height: 12)
                        }
                    }
                }
            }
            if hasConnectors {
                section(L("화살표 끝", "Arrowheads")) {
                    VStack(alignment: .leading, spacing: 4) {
                        heads(style.startHead, flipped: true) { head in state.change { $0.startHead = head } }
                        heads(style.endHead, flipped: false) { head in state.change { $0.endHead = head } }
                    }
                }
            }
            if hasWords || kinds.contains(.text) || kinds.isEmpty {
                section(L("글자 크기", "Text Size")) {
                    HStack(spacing: 6) {
                        ForEach(SketchStyle.TextSize.allCases, id: \.self) { size in
                            option(chosen: style.textSize == size) {
                                state.change { $0.textSize = size }
                            } label: {
                                Text("A").font(.system(size: size == .small ? 9 : size == .medium ? 12 : 15, weight: .medium))
                            }
                        }
                    }
                }
            }
            if kinds.contains(.text) {
                Toggle(L("테두리", "Border"), isOn: Binding(
                    get: { style.border },
                    set: { on in state.change { $0.border = on } }
                ))
                .toggleStyle(.checkbox)
                .font(.caption)
            }
            section(L("투명도", "Opacity")) {
                Slider(value: Binding(
                    get: { Double(style.opacity) },
                    set: { value in state.change { $0.opacity = CGFloat(value) } }
                ), in: 0.2...1)
                .controlSize(.mini)
            }
        }
    }

    /// The row of buttons for what to do with the selection.
    private var actions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(spacing: 4) {
                actionButton("rectangle.dashed", L("테두리 두르기 (B)", "Frame (B)")) { state.editor?.frameSelection() }
                actionButton("plus.square.on.square", L("복제 (⌘D)", "Duplicate (⌘D)")) { state.editor?.duplicateSelection() }
                    .disabled(state.selectedElements.isEmpty)
                actionButton("square.3.layers.3d.top.filled", L("맨 앞으로 (⇧⌘])", "Bring to Front (⇧⌘])")) { state.editor?.bringSelectionToFront() }
                    .disabled(state.selectedElements.isEmpty)
                actionButton("square.3.layers.3d.bottom.filled", L("맨 뒤로 (⇧⌘[)", "Send to Back (⇧⌘[)")) { state.editor?.sendSelectionToBack() }
                    .disabled(state.selectedElements.isEmpty)
                Spacer(minLength: 0)
                actionButton("trash", L("지우기 (⌫)", "Delete (⌫)")) { state.editor?.deleteSelection() }
            }
            .buttonStyle(.borderless)
        }
    }

    private func actionButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12)).frame(width: 24, height: 22)
        }
        .help(help)
    }

    // MARK: - Pieces

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            content()
        }
    }

    private func swatches<C: Hashable>(
        _ all: [C], chosen: C, color: @escaping (C) -> Color,
        matches: @escaping (C, C) -> Bool = { $0 == $1 },
        choose: @escaping (C) -> Void
    ) -> some View {
        HStack(spacing: 5) {
            ForEach(Array(all.enumerated()), id: \.offset) { _, item in
                Button { choose(item) } label: {
                    Circle()
                        .fill(color(item))
                        .frame(width: 14, height: 14)
                        .overlay(Circle().strokeBorder(.primary.opacity(0.15), lineWidth: 0.5))
                        .padding(3)
                        .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: matches(item, chosen) ? 2 : 0))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func option(chosen: Bool, action: @escaping () -> Void, @ViewBuilder label: () -> some View) -> some View {
        Button(action: action) {
            label()
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.accentColor.opacity(chosen ? 0.18 : 0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(chosen ? 0.8 : 0), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func heads(_ chosen: SketchStyle.Head, flipped: Bool, choose: @escaping (SketchStyle.Head) -> Void) -> some View {
        HStack(spacing: 4) {
            ForEach(SketchStyle.Head.allCases, id: \.self) { head in
                option(chosen: chosen == head) { choose(head) } label: {
                    HeadSample(head: head)
                        .frame(width: 16, height: 10)
                        .scaleEffect(x: flipped ? -1 : 1, y: 1)
                }
            }
        }
    }

    private func dashPattern(_ dash: SketchStyle.Dash) -> [CGFloat] {
        switch dash {
        case .solid: []
        case .dashed: [4, 3]
        case .dotted: [0.1, 3.2]
        }
    }
}

private struct DashSample: Shape {
    let dash: SketchStyle.Dash
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

/// A line ending, small, as the option shows it.
private struct HeadSample: View {
    let head: SketchStyle.Head

    var body: some View {
        Canvas { context, size in
            let y = size.height / 2
            var shaft = Path()
            shaft.move(to: CGPoint(x: 1, y: y))
            shaft.addLine(to: CGPoint(x: size.width - 2, y: y))
            context.stroke(shaft, with: .color(.primary), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
            let tip = CGPoint(x: size.width - 1, y: y)
            var path = Path()
            switch head {
            case .none:
                return
            case .arrow:
                path.move(to: CGPoint(x: tip.x - 5, y: y - 4))
                path.addLine(to: tip)
                path.addLine(to: CGPoint(x: tip.x - 5, y: y + 4))
                context.stroke(path, with: .color(.primary), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
            case .triangle:
                path.move(to: tip)
                path.addLine(to: CGPoint(x: tip.x - 6, y: y - 3.5))
                path.addLine(to: CGPoint(x: tip.x - 6, y: y + 3.5))
                path.closeSubpath()
                context.fill(path, with: .color(.primary))
            case .bar:
                path.move(to: CGPoint(x: tip.x, y: y - 4))
                path.addLine(to: CGPoint(x: tip.x, y: y + 4))
                context.stroke(path, with: .color(.primary), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            case .dot:
                path.addEllipse(in: CGRect(x: tip.x - 3.5, y: y - 2.5, width: 5, height: 5))
                context.fill(path, with: .color(.primary))
            }
        }
    }
}
#endif
