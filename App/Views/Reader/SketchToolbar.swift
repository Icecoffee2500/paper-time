#if os(macOS)
import AppKit
import InkEngine
import SwiftUI

/// The tool rack while the pencil is out on the Mac, laid out the way
/// Figma's is: one button for each kind of tool — select, frame, a shape,
/// the pen, text — and the kinds that come in several (the shapes; the pen,
/// the highlighter and the eraser) behind a chevron beside their button. The
/// button shows the member last used, so the rack stays five buttons wide
/// however many tools it holds. The chosen tool is a filled square with its
/// icon in white; the icons are drawn here, in Figma's own line weight.
/// Every tool keeps its one-letter key, listed beside its name in the menu.
///
/// There is no Done button. The pencil goes away with Escape, or with the
/// pencil on the paper's title row — and comes back on its own when a shape
/// on the page is clicked.
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
                Image(systemName: "arrow.uturn.backward").frame(width: 28, height: 28)
            }
            .help(L("되돌리기 (⌘Z)", "Undo (⌘Z)"))
            Button { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) } label: {
                Image(systemName: "arrow.uturn.forward").frame(width: 28, height: 28)
            }
            .help(L("다시 하기 (⇧⌘Z)", "Redo (⇧⌘Z)"))
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, Self.inset)
        .padding(.vertical, Self.inset)
        .liquidGlass(.floating, in: RoundedRectangle(cornerRadius: Corner.bar, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Corner.bar, style: .continuous).strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
    }

    /// The gap between the rack's edge and its buttons; the buttons' own
    /// corners follow from it, so the two curves are concentric.
    private static let inset: CGFloat = 5
    private static var buttonCorner: CGFloat { Corner.inner(Corner.bar, inset: inset) }

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
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 32)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 14)
        }
    }

    private func toolButton(_ tool: SketchTool, chosen: Bool) -> some View {
        Button {
            state.tool = tool
        } label: {
            FigmaIcon(tool: tool)
                .frame(width: 20, height: 20)
                .foregroundStyle(chosen ? Color.white : Color.primary)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: Self.buttonCorner, style: .continuous)
                        .fill(chosen ? Color.accentColor : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: Self.buttonCorner, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("\(tool.label) (\(String(tool.key).uppercased()))")
    }
}

/// The tools drawn as Figma draws them: one and a half points of line,
/// round joins, no fill — the outline of a pointer, a hash for a frame, a
/// square, a nib, a serif T. Drawn rather than borrowed from SF Symbols so
/// the five read as one set, and so the pointer is the design tool's pointer
/// rather than the desktop's.
struct FigmaIcon: View {
    let tool: SketchTool

    var body: some View {
        Canvas { context, size in
            let s = size.width / 20
            var path = Path()
            let stroke = StrokeStyle(lineWidth: 1.6 * s, lineCap: .round, lineJoin: .round)
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
            switch tool {
            case .select:
                // The pointer, outlined.
                path.move(to: p(4.5, 2.5))
                path.addLine(to: p(16.5, 10.5))
                path.addLine(to: p(11, 11.8))
                path.addLine(to: p(14, 17.4))
                path.addLine(to: p(11.6, 18.5))
                path.addLine(to: p(8.7, 12.9))
                path.addLine(to: p(4.5, 16.5))
                path.closeSubpath()
                context.stroke(path, with: .foreground, style: stroke)
            case .frame:
                for x in [7.0, 13.0] { path.move(to: p(x, 3)); path.addLine(to: p(x, 17)) }
                for y in [7.0, 13.0] { path.move(to: p(3, y)); path.addLine(to: p(17, y)) }
                context.stroke(path, with: .foreground, style: stroke)
            case .rectangle:
                path.addRoundedRect(in: CGRect(x: 3.5 * s, y: 4.5 * s, width: 13 * s, height: 11 * s), cornerSize: CGSize(width: 1.5 * s, height: 1.5 * s))
                context.stroke(path, with: .foreground, style: stroke)
            case .ellipse:
                path.addEllipse(in: CGRect(x: 3.5 * s, y: 3.5 * s, width: 13 * s, height: 13 * s))
                context.stroke(path, with: .foreground, style: stroke)
            case .line:
                path.move(to: p(4, 16)); path.addLine(to: p(16, 4))
                context.stroke(path, with: .foreground, style: stroke)
            case .arrow:
                path.move(to: p(4, 16)); path.addLine(to: p(16, 4))
                path.move(to: p(9, 4)); path.addLine(to: p(16, 4)); path.addLine(to: p(16, 11))
                context.stroke(path, with: .foreground, style: stroke)
            case .pen:
                // The nib: a pointed body, a hole, and the tail it sits on.
                path.move(to: p(10, 2.5))
                path.addLine(to: p(15.5, 10.5))
                path.addLine(to: p(13, 15.5))
                path.addLine(to: p(7, 15.5))
                path.addLine(to: p(4.5, 10.5))
                path.closeSubpath()
                path.move(to: p(10, 15.5)); path.addLine(to: p(10, 18.5))
                context.stroke(path, with: .foreground, style: stroke)
                var hole = Path()
                hole.addEllipse(in: CGRect(x: 8.5 * s, y: 9 * s, width: 3 * s, height: 3 * s))
                context.stroke(hole, with: .foreground, style: StrokeStyle(lineWidth: 1.3 * s))
            case .highlighter:
                // A marker: a slanted body and a flat tip.
                path.move(to: p(12.5, 3)); path.addLine(to: p(17, 7.5)); path.addLine(to: p(9, 15.5)); path.addLine(to: p(4.5, 11)); path.closeSubpath()
                path.move(to: p(4.5, 11)); path.addLine(to: p(3, 15.5)); path.addLine(to: p(7.5, 17)); path.addLine(to: p(9, 15.5))
                path.move(to: p(3, 18.5)); path.addLine(to: p(17, 18.5))
                context.stroke(path, with: .foreground, style: stroke)
            case .eraser:
                path.move(to: p(11.5, 3.5)); path.addLine(to: p(17, 9)); path.addLine(to: p(9.5, 16.5)); path.addLine(to: p(5, 16.5)); path.addLine(to: p(3, 14.5)); path.addLine(to: p(3, 12)); path.closeSubpath()
                path.move(to: p(7.5, 7.5)); path.addLine(to: p(13, 13))
                path.move(to: p(9, 18.5)); path.addLine(to: p(17, 18.5))
                context.stroke(path, with: .foreground, style: stroke)
            case .text:
                // A serif T.
                path.move(to: p(4, 5.5)); path.addLine(to: p(4, 3.5)); path.addLine(to: p(16, 3.5)); path.addLine(to: p(16, 5.5))
                path.move(to: p(10, 3.5)); path.addLine(to: p(10, 16.5))
                path.move(to: p(7, 16.5)); path.addLine(to: p(13, 16.5))
                context.stroke(path, with: .foreground, style: stroke)
            }
        }
    }
}
#endif
