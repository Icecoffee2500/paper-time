#if os(iOS)
import InkEngine
import SwiftUI

/// The pencil's tools, as a notebook lays them out: undo and redo, then the
/// pen, the highlighter and the eraser, then the chosen tool's three quick
/// colours and three widths. Tap a tool to pick it; tap it again for its
/// options. Tap a colour or a width to use it; tap the one already in use
/// to change what it is. System controls throughout — the strip is the
/// reader's toolbar, not a palette floating over the page.
struct MarkingToolbar: View {
    @Bindable var configuration: ReaderConfiguration
    @State private var options: InkTool?
    @State private var slot: Slot?

    /// Which quick slot's options are open: a colour or a width, by index.
    private struct Slot: Identifiable, Hashable {
        enum Kind { case color, width }
        var kind: Kind
        var index: Int
        var id: String { "\(kind)-\(index)" }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Button {
                    NotificationCenter.default.post(name: .paperTimeInkUndo, object: nil)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .help("Undo")
                Button {
                    NotificationCenter.default.post(name: .paperTimeInkRedo, object: nil)
                } label: {
                    Image(systemName: "arrow.uturn.forward")
                }
                .help("Redo")

                divider

                ForEach(InkTool.allCases) { tool in
                    Button {
                        if configuration.tool == tool {
                            options = tool
                        } else {
                            configuration.tool = tool
                        }
                    } label: {
                        Image(systemName: tool.symbolName)
                            .symbolVariant(configuration.tool == tool ? .fill : .none)
                            .frame(width: 22, height: 22)
                    }
                    .tint(configuration.tool == tool ? Color.accentColor : .primary)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.accentColor.opacity(configuration.tool == tool ? 0.14 : 0))
                    )
                    .help(tool.label)
                    .popover(isPresented: Binding(get: { options == tool }, set: { if !$0 { options = nil } })) {
                        ToolOptions(tool: tool, configuration: configuration)
                            .presentationCompactAdaptation(.popover)
                    }
                }

                if configuration.tool != .eraser {
                    divider
                    ForEach(0..<3, id: \.self) { index in colorDot(index) }
                    divider
                    ForEach(0..<3, id: \.self) { index in widthDot(index) }
                }

                Spacer(minLength: 12)

                Button("Done") { configuration.mode = .read }
                    .fontWeight(.medium)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var divider: some View {
        Divider().frame(height: 20).padding(.horizontal, 4)
    }

    private var isPen: Bool { configuration.tool == .pen }

    private func colorDot(_ index: Int) -> some View {
        let selected = isPen ? configuration.presets.penColorIndex == index : configuration.presets.highlighterColorIndex == index
        let color: Color = isPen
            ? configuration.presets.penColors[index].color
            : Color(configuration.presets.highlighterColors[index].platformColor)
        return Button {
            if selected {
                slot = Slot(kind: .color, index: index)
            } else if isPen {
                configuration.presets.penColorIndex = index
            } else {
                configuration.presets.highlighterColorIndex = index
            }
        } label: {
            Circle()
                .fill(color)
                .frame(width: 18, height: 18)
                .overlay(Circle().strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
                .padding(3)
                .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: selected ? 2 : 0))
        }
        .popover(isPresented: Binding(get: { slot == Slot(kind: .color, index: index) }, set: { if !$0 { slot = nil } })) {
            SlotOptions(kind: .color, index: index, configuration: configuration)
                .presentationCompactAdaptation(.popover)
        }
    }

    private func widthDot(_ index: Int) -> some View {
        let widths = isPen ? configuration.presets.penWidths : configuration.presets.highlighterWidths
        let selected = isPen ? configuration.presets.penWidthIndex == index : configuration.presets.highlighterWidthIndex == index
        let size = isPen ? 4 + widths[index] * 1.4 : 5 + widths[index] * 0.45
        return Button {
            if selected {
                slot = Slot(kind: .width, index: index)
            } else if isPen {
                configuration.presets.penWidthIndex = index
            } else {
                configuration.presets.highlighterWidthIndex = index
            }
        } label: {
            Circle()
                .fill(.primary.opacity(selected ? 1 : 0.55))
                .frame(width: size, height: size)
                .frame(width: 24, height: 24)
                .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: selected ? 2 : 0))
        }
        .tint(.primary)
        .popover(isPresented: Binding(get: { slot == Slot(kind: .width, index: index) }, set: { if !$0 { slot = nil } })) {
            SlotOptions(kind: .width, index: index, configuration: configuration)
                .presentationCompactAdaptation(.popover)
        }
    }

    /// One quick slot's options: which colour it holds, or how wide it is.
    private struct SlotOptions: View {
        let kind: Slot.Kind
        let index: Int
        @Bindable var configuration: ReaderConfiguration

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                switch kind {
                case .color:
                    if configuration.tool == .pen {
                        palette(PenColor.allCases, current: configuration.presets.penColors[index], color: \.color) {
                            configuration.presets.penColors[index] = $0
                        }
                    } else {
                        palette(MarkupColor.allCases, current: configuration.presets.highlighterColors[index], color: { Color($0.platformColor) }) {
                            configuration.presets.highlighterColors[index] = $0
                        }
                    }
                case .width:
                    if configuration.tool == .pen {
                        widthSlider($configuration.presets.penWidths[index], range: 0.5...8)
                    } else {
                        widthSlider($configuration.presets.highlighterWidths[index], range: 6...36)
                    }
                }
            }
            .padding(14)
            .frame(minWidth: 220)
        }

        private func palette<C: Hashable>(_ all: [C], current: C, color: @escaping (C) -> Color, choose: @escaping (C) -> Void) -> some View {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(34)), count: min(all.count, 5)), spacing: 8) {
                ForEach(all, id: \.self) { item in
                    Button { choose(item) } label: {
                        Circle()
                            .fill(color(item))
                            .frame(width: 26, height: 26)
                            .overlay(Circle().strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
                            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: item == current ? 2.5 : 0).padding(-3))
                    }
                    .buttonStyle(.plain)
                }
            }
        }

        private func widthSlider(_ value: Binding<CGFloat>, range: ClosedRange<CGFloat>) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                Text("Thickness")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Slider(value: value, in: range)
                    Circle()
                        .fill(.primary)
                        .frame(width: min(value.wrappedValue, 26), height: min(value.wrappedValue, 26))
                        .frame(width: 28, height: 28)
                }
            }
        }
    }
}

/// A tool's own settings — the popover behind a second tap on it.
private struct ToolOptions: View {
    let tool: InkTool
    @Bindable var configuration: ReaderConfiguration

    var body: some View {
        Form {
            switch tool {
            case .pen:
                Toggle("Draw with Finger", isOn: $configuration.fingerDrawing)
            case .highlighter:
                Toggle("Fit to Text", isOn: $configuration.presets.fitsToText)
                Text("Over words, a stroke becomes a highlight fitted to them; under them, an underline. Off, it stays as drawn.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Toggle("Draw with Finger", isOn: $configuration.fingerDrawing)
            case .eraser:
                Toggle("Erase Highlights Too", isOn: $configuration.presets.eraserErasesMarks)
                Text("Strokes are erased whole. With this on, running the eraser over a highlight or an underline removes it as well.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        // Tall enough for the last row of the form: at 190 the "Draw with
        // Finger" switch under the highlighter's explanation was cut in half
        // by the popover's edge, and a switch you cannot reach is a setting
        // that does not exist.
        .frame(minWidth: 320, minHeight: tool == .pen ? 150 : 300)
    }
}

extension Notification.Name {
    static let paperTimeInkUndo = Notification.Name("PaperTimeInkUndo")
    static let paperTimeInkRedo = Notification.Name("PaperTimeInkRedo")
}
#endif
