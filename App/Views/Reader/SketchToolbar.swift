#if os(macOS)
import AppKit
import InkEngine
import SwiftUI

/// The tool rack while the pencil is out on the Mac, laid out the way
/// Figma's is: one button for each kind of tool — select, frame, a shape,
/// the pen, text — and the kinds that come in several (the shapes; the pen,
/// the highlighter and the eraser) behind a chevron beside their button. The
/// button shows the member last used, so the rack stays five buttons wide
/// however many tools it holds. Every tool keeps its one-letter key, listed
/// beside its name in the menu.
struct SketchToolbar: View {
    @Bindable var configuration: ReaderConfiguration

    private var state: SketchState { configuration.sketch }

    var body: some View {
        HStack(spacing: 2) {
            single(.select)
            single(.frame)
            grouped(SketchTool.shapes, showing: state.lastShape)
            grouped(SketchTool.inks, showing: state.lastInk)
            single(.text)

            divider

            Button { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) } label: {
                Image(systemName: "arrow.uturn.backward").frame(width: 26, height: 26)
            }
            .help(L("되돌리기 (⌘Z)", "Undo (⌘Z)"))
            Button { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) } label: {
                Image(systemName: "arrow.uturn.forward").frame(width: 26, height: 26)
            }
            .help(L("다시 하기 (⇧⌘Z)", "Redo (⇧⌘Z)"))

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

    private func single(_ tool: SketchTool) -> some View {
        toolButton(tool, chosen: state.tool == tool)
    }

    /// A button for the member last used, and beside it a chevron that
    /// lists the group.
    private func grouped(_ tools: [SketchTool], showing shown: SketchTool) -> some View {
        let chosen = tools.contains(state.tool)
        return HStack(spacing: 0) {
            toolButton(shown, chosen: chosen)
            Menu {
                ForEach(tools) { tool in
                    Button {
                        state.tool = tool
                    } label: {
                        Label {
                            Text(tool.label) + Text("   \(String(tool.key).uppercased())").foregroundStyle(.secondary)
                        } icon: {
                            Image(systemName: tool.symbolName)
                        }
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12, height: 30)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 12)
        }
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.accentColor.opacity(chosen ? 0.16 : 0))
        )
    }

    private func toolButton(_ tool: SketchTool, chosen: Bool) -> some View {
        Button {
            state.tool = tool
        } label: {
            Image(systemName: tool.symbolName)
                .font(.system(size: 14, weight: .medium))
                .symbolVariant(chosen && tool != .select && tool != .frame ? .fill : .none)
                .frame(width: 30, height: 30)
        }
        .tint(chosen ? Color.accentColor : .primary)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.accentColor.opacity(chosen && !SketchTool.shapes.contains(tool) && !SketchTool.inks.contains(tool) ? 0.16 : 0))
        )
        .help("\(tool.label) (\(String(tool.key).uppercased()))")
    }
}
#endif
