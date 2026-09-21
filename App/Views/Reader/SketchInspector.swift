#if os(macOS)
import AppKit
import InkEngine
import SwiftUI

/// The panel down the right while the pencil is out — Figma's design panel,
/// for what a reader draws on a paper.
///
/// Position, layout, appearance, fill, stroke, text: each a section, each
/// with the numbers in it, so a box can be put at exactly 40 from the top
/// and made exactly 120 wide, two things lined up on their left edges, a
/// frame given a row with a gap of 6. A change with something selected
/// changes it and sets the default for the next; with nothing selected it
/// sets the default alone.
struct SketchInspector: View {
    @Bindable var configuration: ReaderConfiguration
    /// In the window's inspector column rather than floating over the page:
    /// no glass of its own, and as wide as the column.
    var docked = false

    private var state: SketchState { configuration.sketch }

    /// The kinds the controls are about: the selection's, or the tool's.
    private var kinds: Set<SketchElement.Kind> {
        if state.hasSelection { return state.selectedKinds }
        return state.tool.makes.map { [$0] } ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            Divider()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    if let ink = state.tool.inkTool, !state.hasSelection {
                        section(state.tool.label) { inkControls(ink) }
                    } else if state.hasSelection || state.tool.makes != nil {
                        if state.hasSelection {
                            positionSection
                            Divider().padding(.horizontal, 12)
                        }
                        layoutSection
                        Divider().padding(.horizontal, 12)
                        appearanceSection
                        if hasFill {
                            Divider().padding(.horizontal, 12)
                            fillSection
                        }
                        if !onlyStrokes {
                            Divider().padding(.horizontal, 12)
                            strokeSection
                        }
                        if hasWords {
                            Divider().padding(.horizontal, 12)
                            textSection
                        }
                    } else {
                        Text(L("무엇을 고르거나 그리면 여기서 고칠 수 있어요.", "Select or draw something to edit it here."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(12)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            if state.hasSelection {
                Divider()
                actions.padding(.horizontal, 8).padding(.vertical, 6)
            }
        }
        .frame(width: docked ? nil : 236)
        .frame(maxWidth: docked ? .infinity : nil, maxHeight: docked ? .infinity : nil, alignment: .top)
        .background {
            if !docked {
                RoundedRectangle(cornerRadius: Corner.popover, style: .continuous)
                    .fill(.clear)
                    .liquidGlass(.floating, in: RoundedRectangle(cornerRadius: Corner.popover, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Corner.popover, style: .continuous).strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
            }
        }
    }

    // MARK: - What it is about

    private var hasBoxes: Bool { !kinds.isDisjoint(with: [.rectangle, .ellipse, .text, .frame]) }
    private var hasConnectors: Bool { !kinds.isDisjoint(with: [.arrow, .line]) }
    private var hasFill: Bool { hasBoxes || kinds.contains(.group) || kinds.isEmpty }
    private var hasWords: Bool { kinds.contains(.text) || state.selectedElements.contains { !$0.text.isEmpty } || (!state.hasSelection && state.tool == .text) }
    private var onlyStrokes: Bool { state.hasSelection && state.selectedElements.isEmpty }

    private var header: some View {
        HStack(spacing: 8) {
            if let one = state.selectedOne, one.isContainer {
                // A frame or a group has a name, and this is where it is given.
                TextField(one.kind == .frame ? L("프레임", "Frame") : L("묶음", "Group"), text: Binding(
                    get: { one.name ?? "" },
                    set: { text in
                        let trimmed = text.trimmingCharacters(in: .whitespaces)
                        state.editor?.editSelection(named: L("이름", "Rename")) { $0.name = trimmed.isEmpty ? nil : trimmed }
                    }
                ))
                .textFieldStyle(.plain)
                .font(.callout.weight(.semibold))
            } else if state.hasSelection {
                let count = state.selectedElements.count + state.selectedStrokeCount
                Text(count == 1
                     ? (state.selectedOne.map(kindName) ?? L("손글씨", "Handwriting"))
                     : L("\(count)개 선택", "\(count) selected"))
                    .font(.callout.weight(.semibold))
            } else {
                Text(state.tool.label).font(.callout.weight(.semibold))
            }
            Spacer()
        }
    }

    private func kindName(_ element: SketchElement) -> String {
        switch element.kind {
        case .rectangle: L("네모", "Rectangle")
        case .ellipse: L("동그라미", "Ellipse")
        case .line: L("선", "Line")
        case .arrow: L("화살표", "Arrow")
        case .text: L("글", "Text")
        case .frame: L("프레임", "Frame")
        case .group: L("묶음", "Group")
        }
    }

    // MARK: - Position

    private var positionSection: some View {
        section(L("위치", "Position")) {
            HStack(spacing: 2) {
                ForEach(SketchAlignment.allCases, id: \.self) { alignment in
                    Button { state.editor?.align(alignment) } label: {
                        Image(systemName: alignment.symbolName)
                            .font(.system(size: 11))
                            .frame(width: 28, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help(alignment.label)
                    .background(RoundedRectangle(cornerRadius: Corner.control - 3, style: .continuous).fill(Color.primary.opacity(0.05)))
                }
            }
            .disabled(state.selectedElements.isEmpty)
            if let box = state.selectionBox, let page = state.pageBox {
                HStack(spacing: 8) {
                    NumberField(label: "X", value: box.minX - page.minX) { value in
                        state.editor?.setSelectionOrigin(x: page.minX + value, top: nil)
                    }
                    NumberField(label: "Y", value: page.maxY - box.maxY) { value in
                        state.editor?.setSelectionOrigin(x: nil, top: value)
                    }
                }
                .disabled(state.selectedElements.isEmpty)
            }
        }
    }

    // MARK: - Layout

    private var layoutSection: some View {
        let frame = state.selectedFrame
        let one = state.selectedOne
        return section(L("레이아웃", "Layout")) {
            if state.hasSelection, !state.selectedElements.isEmpty {
                HStack(spacing: 6) {
                    Text(L("흐름", "Flow")).font(.caption2).foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
                    flowButton(nil, symbol: "square.dashed", help: L("없음", "None"), chosen: frame?.layout == nil)
                    flowButton(.vertical, symbol: "arrow.down", help: L("세로", "Vertical"), chosen: frame?.layout?.direction == .vertical)
                    flowButton(.horizontal, symbol: "arrow.right", help: L("가로", "Horizontal"), chosen: frame?.layout?.direction == .horizontal)
                }
            }
            if let box = state.selectionBox, let one, !one.isConnector {
                HStack(spacing: 8) {
                    NumberField(label: "W", value: box.width) { state.editor?.setSelectionSize(width: $0, height: nil) }
                    NumberField(label: "H", value: box.height) { state.editor?.setSelectionSize(width: nil, height: $0) }
                }
            }
            if let frame, let layout = frame.layout {
                HStack(spacing: 8) {
                    NumberField(label: L("간격", "Gap"), value: layout.gap, wide: true) { value in
                        state.editor?.editSelection(named: L("간격", "Gap")) { $0.layout?.gap = max(0, value) }
                    }
                    NumberField(label: L("여백", "Pad"), value: layout.padding, wide: true) { value in
                        state.editor?.editSelection(named: L("안쪽 여백", "Padding")) { $0.layout?.padding = max(0, value) }
                    }
                }
                HStack(spacing: 6) {
                    Text(L("정렬", "Align")).font(.caption2).foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
                    ForEach(SketchLayout.Align.allCases, id: \.self) { align in
                        option(chosen: layout.align == align) {
                            state.editor?.editSelection(named: L("정렬", "Align")) { $0.layout?.align = align }
                        } label: {
                            Image(systemName: alignSymbol(align, layout.direction)).font(.system(size: 10))
                        }
                    }
                    Spacer()
                    Toggle(L("내용에 맞춤", "Hug"), isOn: Binding(
                        get: { layout.hugs },
                        set: { on in state.editor?.editSelection(named: L("크기", "Sizing")) { $0.layout?.hugs = on } }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.caption)
                }
            }
            if let frame {
                Toggle(L("넘친 내용 숨기기", "Clip content"), isOn: Binding(
                    get: { frame.clips },
                    set: { on in state.editor?.editSelection(named: L("넘친 내용", "Clip")) { $0.clips = on } }
                ))
                .toggleStyle(.checkbox)
                .font(.caption)
            }
        }
    }

    private func alignSymbol(_ align: SketchLayout.Align, _ direction: SketchLayout.Direction) -> String {
        switch (direction, align) {
        case (.vertical, .start): "align.horizontal.left"
        case (.vertical, .center): "align.horizontal.center"
        case (.vertical, .end): "align.horizontal.right"
        case (.horizontal, .start): "align.vertical.top"
        case (.horizontal, .center): "align.vertical.center"
        case (.horizontal, .end): "align.vertical.bottom"
        }
    }

    /// None, a column, a row. On a frame it sets the frame's layout; on
    /// anything else it puts a frame with that layout round the selection,
    /// as Figma's ⇧A does.
    private func flowButton(_ direction: SketchLayout.Direction?, symbol: String, help: String, chosen: Bool) -> some View {
        option(chosen: chosen) {
            guard let editor = state.editor else { return }
            if let frame = state.selectedFrame {
                if let direction {
                    editor.editSelection(named: L("오토 레이아웃", "Auto Layout")) { element in
                        var layout = element.layout ?? SketchLayout()
                        layout.direction = direction
                        element.layout = layout
                    }
                } else if frame.layout != nil {
                    editor.editSelection(named: L("오토 레이아웃 빼기", "Remove Auto Layout")) { $0.layout = nil }
                }
            } else if let direction {
                editor.toggleAutoLayout()
                editor.editSelection(named: L("오토 레이아웃", "Auto Layout")) { $0.layout?.direction = direction }
            }
        } label: {
            Image(systemName: symbol).font(.system(size: 11))
        }
        .help(help)
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        let style = state.shownStyle
        let one = state.selectedOne
        return section(L("외형", "Appearance")) {
            HStack(spacing: 8) {
                NumberField(label: L("투명도", "Opacity"), value: (style.opacity * 100).rounded(), unit: "%", wide: true) { value in
                    state.change { $0.opacity = min(max(CGFloat(value) / 100, 0.05), 1) }
                }
                if hasBoxes || kinds.isEmpty {
                    NumberField(
                        label: L("모서리", "Radius"),
                        value: style.cornerRadius ?? one?.cornerRadius ?? 0,
                        placeholder: style.cornerRadius == nil ? L("자동", "Auto") : nil,
                        wide: true
                    ) { value in
                        state.change { $0.cornerRadius = max(0, value) }
                    }
                }
            }
            if hasBoxes || kinds.isEmpty, style.cornerRadius != nil {
                Button(L("모서리 자동으로", "Automatic corners")) { state.change { $0.cornerRadius = nil } }
                    .buttonStyle(.plain)
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    // MARK: - Fill

    private var fillSection: some View {
        let style = state.shownStyle
        return section(L("채우기", "Fill"), trailing: {
            if style.fill == nil {
                smallButton("plus") { state.change { $0.fill = .paleYellow } }
            } else {
                smallButton("minus") { state.change { $0.fill = nil } }
            }
        }) {
            if let fill = style.fill {
                colorRow(fill, alpha: true) { color in state.change { $0.fill = color } }
            }
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

    // MARK: - Stroke

    /// Whether the selection's edge is drawn: `border` for text, the other
    /// way round for everything else, and both at once when both are chosen.
    private var strokeOn: Bool {
        let style = state.shownStyle
        if kinds == [.text] { return style.border }
        if kinds.contains(.text), state.selectedElements.count == kinds.count { return style.border || !style.strokeHidden }
        return !style.strokeHidden
    }

    private func setStroke(on: Bool) {
        state.change { style in
            style.border = on
            style.strokeHidden = !on
        }
    }

    private var strokeSection: some View {
        let style = state.shownStyle
        let on = strokeOn || hasConnectors
        return section(L("외곽선", "Stroke"), trailing: {
            if !hasConnectors {
                smallButton(on ? "minus" : "plus") { setStroke(on: !on) }
            }
        }) {
            if on {
                colorRow(style.stroke, alpha: false) { color in state.change { $0.stroke = color } }
                HStack(spacing: 5) {
                    ForEach(SketchColor.strokes.indices, id: \.self) { i in
                        let color = SketchColor.strokes[i]
                        Button { state.change { $0.stroke = color } } label: {
                            Circle()
                                .fill(Color(cgColor: color.cgColor))
                                .frame(width: 14, height: 14)
                                .overlay(Circle().strokeBorder(.primary.opacity(0.15), lineWidth: 0.5))
                                .padding(3)
                                .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: color.matches(style.stroke) ? 2 : 0))
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack(spacing: 8) {
                    NumberField(label: L("굵기", "Width"), value: style.width, wide: true) { value in
                        state.change { $0.width = min(max(value, 0.5), 20) }
                    }
                    HStack(spacing: 4) {
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
                if hasConnectors {
                    VStack(alignment: .leading, spacing: 4) {
                        heads(style.startHead, flipped: true) { head in state.change { $0.startHead = head } }
                        heads(style.endHead, flipped: false) { head in state.change { $0.endHead = head } }
                    }
                }
            }
        }
    }

    // MARK: - Text

    private var textSection: some View {
        let style = state.shownStyle
        let one = state.selectedOne
        return section(L("글", "Text")) {
            fontMenu(style.fontName)
            HStack(spacing: 8) {
                NumberField(label: L("크기", "Size"), value: style.points, wide: true) { value in
                    state.change { $0.fontSize = min(max(value, 4), 96) }
                }
                HStack(spacing: 4) {
                    ForEach(SketchStyle.TextSize.allCases, id: \.self) { size in
                        option(chosen: style.fontSize == nil && style.textSize == size) {
                            state.change { $0.textSize = size; $0.fontSize = nil }
                        } label: {
                            Text("A").font(.system(size: size == .small ? 9 : size == .medium ? 12 : 15, weight: .medium))
                        }
                    }
                }
            }
            HStack(spacing: 6) {
                ForEach(SketchStyle.TextAlign.allCases, id: \.self) { align in
                    option(chosen: style.textAlign == align) {
                        state.change { $0.textAlign = align }
                    } label: {
                        Image(systemName: align == .left ? "text.alignleft" : align == .center ? "text.aligncenter" : "text.alignright")
                            .font(.system(size: 11))
                    }
                }
                Spacer()
                if let one, one.kind == .text {
                    // As wide as its words, or as wide as it was made.
                    option(chosen: one.sizing == .autoWidth) {
                        state.editor?.editSelection(named: L("글 크기 맞춤", "Text Sizing")) { $0.textSizing = .autoWidth }
                    } label: {
                        Image(systemName: "arrow.left.and.right.text.vertical").font(.system(size: 11))
                    }
                    .help(L("글 너비에 맞춤", "Auto width"))
                    option(chosen: one.sizing == .autoHeight) {
                        state.editor?.editSelection(named: L("글 크기 맞춤", "Text Sizing")) { $0.textSizing = .autoHeight }
                    } label: {
                        Image(systemName: "arrow.up.and.down.text.horizontal").font(.system(size: 11))
                    }
                    .help(L("너비는 그대로, 높이만 맞춤", "Auto height"))
                }
            }
        }
    }

    /// The families this Mac has, with the system's own face first. A menu
    /// rather than the font panel: the panel is a window, and this is a row.
    private func fontMenu(_ chosen: String?) -> some View {
        Menu {
            Button {
                state.change { $0.fontName = nil }
            } label: {
                Label(L("시스템 글꼴", "System Font"), systemImage: chosen == nil ? "checkmark" : "")
            }
            Divider()
            ForEach(Self.fontFamilies, id: \.self) { family in
                Button {
                    state.change { $0.fontName = family }
                } label: {
                    Label(family, systemImage: chosen == family ? "checkmark" : "")
                }
            }
        } label: {
            HStack {
                Text(chosen ?? L("시스템 글꼴", "System Font"))
                    .font(.caption)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .frame(height: 22)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: Corner.control - 3, style: .continuous).fill(Color.primary.opacity(0.05)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }

    private static let fontFamilies: [String] = {
        NSFontManager.shared.availableFontFamilies
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }()

    // MARK: - The pen's

    @ViewBuilder
    private func inkControls(_ ink: InkTool) -> some View {
        switch ink {
        case .pen:
            caption(L("색", "Colour"))
            swatches(PenColor.allCases, chosen: configuration.presets.penColor, color: \.color) { color in
                configuration.presets.penColors[configuration.presets.penColorIndex] = color
            }
            caption(L("굵기", "Width"))
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
        case .highlighter:
            caption(L("색", "Colour"))
            swatches(MarkupColor.allCases, chosen: configuration.presets.highlighterColor, color: { Color($0.platformColor) }) { color in
                configuration.presets.highlighterColors[configuration.presets.highlighterColorIndex] = color
            }
            caption(L("굵기", "Width"))
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

    // MARK: - Actions

    private var actions: some View {
        let containers = state.selectedElements.contains(where: \.isContainer)
        return HStack(spacing: 2) {
            actionButton("rectangle.3.group", L("묶기 (⌘G)", "Group (⌘G)")) { state.editor?.groupSelection() }
                .disabled(state.selectedElements.isEmpty)
            actionButton("rectangle.3.group.bubble", L("묶음 풀기 (⇧⌘G)", "Ungroup (⇧⌘G)")) { state.editor?.ungroupSelection() }
                .disabled(!containers)
            actionButton("number.square", L("프레임으로 감싸기 (⌥⌘G)", "Frame Selection (⌥⌘G)")) { state.editor?.frameSelection() }
            actionButton("rectangle.split.3x1", L("오토 레이아웃 (⇧A)", "Auto Layout (⇧A)")) { state.editor?.toggleAutoLayout() }
                .disabled(state.selectedElements.isEmpty)
            Spacer(minLength: 0)
            actionButton("plus.square.on.square", L("복제 (⌘D)", "Duplicate (⌘D)")) { state.editor?.duplicateSelection() }
                .disabled(state.selectedElements.isEmpty)
            actionButton("square.3.layers.3d.top.filled", L("맨 앞으로 (⇧⌘])", "Bring to Front (⇧⌘])")) { state.editor?.bringSelectionToFront() }
                .disabled(state.selectedElements.isEmpty)
            actionButton("square.3.layers.3d.bottom.filled", L("맨 뒤로 (⇧⌘[)", "Send to Back (⇧⌘[)")) { state.editor?.sendSelectionToBack() }
                .disabled(state.selectedElements.isEmpty)
            actionButton("trash", L("지우기 (⌫)", "Delete (⌫)")) { state.editor?.deleteSelection() }
        }
        .buttonStyle(.borderless)
    }

    private func actionButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11)).frame(width: 22, height: 22)
        }
        .help(help)
    }

    // MARK: - Pieces

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        section(title, trailing: { EmptyView() }, content: content)
    }

    private func section(_ title: String, @ViewBuilder trailing: () -> some View, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                trailing()
            }
            content()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption2).foregroundStyle(.secondary)
    }

    private func smallButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).frame(width: 18, height: 16)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    /// A swatch that opens the colour panel, the hex beside it, and — for a
    /// fill — how much of it shows.
    private func colorRow(_ color: SketchColor, alpha: Bool, set: @escaping (SketchColor) -> Void) -> some View {
        HStack(spacing: 8) {
            // The swatch is the colour panel's well, held to one width so the
            // hex beside it always starts in the same place — it was drawn
            // over the first two digits.
            ColorPicker("", selection: Binding(
                get: { Color(cgColor: color.withAlpha(1).cgColor) },
                set: { picked in
                    guard let ns = NSColor(picked).usingColorSpace(.sRGB) else { return }
                    set(SketchColor(ns.redComponent, ns.greenComponent, ns.blueComponent, alpha: color.alpha))
                }
            ), supportsOpacity: false)
            .labelsHidden()
            .frame(width: 30, height: 22)
            .clipped()
            HexField(hex: color.hex) { text in
                if let next = SketchColor(hex: text, alpha: color.alpha) { set(next) }
            }
            if alpha {
                NumberField(label: "", value: (color.alpha * 100).rounded(), unit: "%") { value in
                    set(color.withAlpha(min(max(CGFloat(value) / 100, 0.05), 1)))
                }
            }
        }
    }

    private func swatches<C: Hashable>(
        _ all: [C], chosen: C, color: @escaping (C) -> Color,
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
                        .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: item == chosen ? 2 : 0))
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
                    RoundedRectangle(cornerRadius: Corner.control - 2, style: .continuous)
                        .fill(Color.accentColor.opacity(chosen ? 0.18 : 0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Corner.control - 2, style: .continuous)
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

/// A number with a label in front of it, the way a design tool's panel has
/// them: type, press Return or leave, and it takes.
private struct NumberField: View {
    let label: String
    let value: CGFloat
    var unit: String? = nil
    var placeholder: String? = nil
    var wide = false
    let commit: (CGFloat) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    init(label: String, value: CGFloat, unit: String? = nil, placeholder: String? = nil, wide: Bool = false, commit: @escaping (CGFloat) -> Void) {
        self.label = label
        self.value = value
        self.unit = unit
        self.placeholder = placeholder
        self.wide = wide
        self.commit = commit
    }

    var body: some View {
        HStack(spacing: 4) {
            if !label.isEmpty {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: wide ? nil : 12, alignment: .leading)
                    .lineLimit(1)
            }
            TextField(placeholder ?? "", text: $text)
                .textFieldStyle(.plain)
                .font(.caption.monospacedDigit())
                .multilineTextAlignment(.trailing)
                .focused($focused)
                .onSubmit(take)
                .onChange(of: focused) { _, now in if !now { take() } }
            if let unit {
                Text(unit).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 22)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: Corner.control - 3, style: .continuous).fill(Color.primary.opacity(0.05)))
        .onAppear { text = shown(value) }
        .onChange(of: value) { _, now in if !focused { text = shown(now) } }
    }

    private func shown(_ value: CGFloat) -> String {
        if placeholder != nil { return "" }
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
    }

    private func take() {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !trimmed.isEmpty, let number = Double(trimmed) else { text = shown(value); return }
        commit(CGFloat(number))
    }
}

/// Six hex digits, as a design tool shows a colour.
private struct HexField: View {
    let hex: String
    let commit: (String) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(.caption.monospaced())
            .focused($focused)
            .onSubmit(take)
            .onChange(of: focused) { _, now in if !now { take() } }
            .padding(.horizontal, 6)
            .frame(height: 22)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: Corner.control - 3, style: .continuous).fill(Color.primary.opacity(0.05)))
            .onAppear { text = hex }
            .onChange(of: hex) { _, now in if !focused { text = now } }
    }

    private func take() {
        let candidate = text.trimmingCharacters(in: .whitespaces)
        if SketchColor(hex: candidate) != nil { commit(candidate) } else { text = hex }
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
