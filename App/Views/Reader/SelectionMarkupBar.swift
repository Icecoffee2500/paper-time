import InkEngine
import SwiftUI

/// The markup controls, floating just above the text the user selected.
///
/// Putting them at the selection rather than in the window's toolbar is the
/// difference between an action you reach for and one you have to go looking
/// for — and it is what every app that marks up text does, from Books to
/// Preview.
struct SelectionMarkupBar: View {
    var onMark: (MarkupDescriptor.Kind, MarkupColor) -> Void
    var onNote: () -> Void
    var onCopy: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ForEach(MarkupColor.allCases, id: \.self) { color in
                Button {
                    onMark(.highlight, color)
                } label: {
                    Circle()
                        .fill(swatch(for: color))
                        .frame(width: 20, height: 20)
                        .overlay(
                            Circle().strokeBorder(.primary.opacity(0.12), lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
                .help(L("\(color.displayName) 형광펜", "Highlight \(color.displayName)"))
                .accessibilityLabel(L("\(color.displayName) 형광펜", "Highlight \(color.displayName)"))
            }

            Divider().frame(height: 18)

            Button {
                onMark(.underline, .yellow)
            } label: {
                Image(systemName: "underline")
            }
            .buttonStyle(.plain)
            .help(L("밑줄", "Underline"))
            .accessibilityLabel(L("밑줄", "Underline"))

            Button {
                onMark(.strikethrough, .yellow)
            } label: {
                Image(systemName: "strikethrough")
            }
            .buttonStyle(.plain)
            .help(L("취소선", "Strikethrough"))
            .accessibilityLabel(L("취소선", "Strikethrough"))

            Divider().frame(height: 18)

            Button(action: onNote) {
                Image(systemName: "note.text.badge.plus")
            }
            .buttonStyle(.plain)
            .help(L("이 구절에 노트 달기", "Add a note about this passage"))
            .accessibilityLabel(L("노트 더하기", "Add Note"))

            Button(action: onCopy) {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.plain)
            .help(L("복사", "Copy"))
            .accessibilityLabel(L("복사", "Copy"))
        }
        .font(.body)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .liquidGlass(.floating)
        .overlay(Capsule().strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
        .shadow(radius: 10, y: 3)
        .fixedSize()
    }

    private func swatch(for color: MarkupColor) -> Color {
        switch color {
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .pink: .pink
        case .purple: .purple
        }
    }
}

/// Writing a note about the passage that is selected.
///
/// It opens where the markup bar was, showing the sentence it will be attached
/// to, because a note written about text you can no longer see is a note about
/// nothing.
struct NoteComposer: View {
    let quotedText: String
    @Binding var text: String
    var onCancel: () -> Void
    var onSave: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !quotedText.isEmpty {
                Text(quotedText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.leading, 8)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(.tint)
                            .frame(width: 3)
                    }
            }

            TextField(L("노트", "Note"), text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(2...6)
                .focused($isFocused)
                .onSubmit(onSave)

            HStack {
                Spacer()
                Button(L("취소", "Cancel"), role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(L("저장", "Save"), action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.small)
        }
        .padding(12)
        .liquidGlass(.floating)
        .overlay(Capsule().strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
        .shadow(radius: 12, y: 4)
        .onAppear { isFocused = true }
    }
}

/// One of the two strips at the edges of a paged reader that turn the page.
struct PageTurnZone: View {
    enum Edge { case leading, trailing }

    let edge: Edge
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Rectangle()
                .fill(.clear)
                .contentShape(.rect)
                .overlay {
                    Image(systemName: edge == .leading ? "chevron.left" : "chevron.right")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(10)
                        .background(.regularMaterial, in: .circle)
                        .opacity(isHovering ? 1 : 0)
                }
        }
        .buttonStyle(.plain)
        .frame(width: 64)
        .onHover { isHovering = $0 }
        .animation(.snappy(duration: 0.18), value: isHovering)
        .accessibilityLabel(edge == .leading ? L("이전 쪽", "Previous Page") : L("다음 쪽", "Next Page"))
    }
}

extension View {
    /// Places a floating control next to a selection, kept inside the reader.
    ///
    /// Above the text when there is room, below it when the selection starts at
    /// the top of the view — the control must never cover what it is about.
    func offset(anchoredTo frame: CGRect, width: CGFloat, below: Bool = false) -> some View {
        modifier(AnchoredToSelection(frame: frame, width: width, below: below))
    }
}

private struct AnchoredToSelection: ViewModifier {
    let frame: CGRect
    let width: CGFloat
    var below = false

    func body(content: Content) -> some View {
        GeometryReader { proxy in
            let maxX = max(8, proxy.size.width - width - 8)
            let x = min(max(8, frame.midX - width / 2), maxX)
            let above = frame.minY - 56
            let under = frame.maxY + 14
            let y = below
                ? (under < proxy.size.height - 60 ? under : max(8, above))
                : (above > 8 ? above : min(under, max(8, proxy.size.height - 180)))
            content.offset(x: x, y: y)
        }
    }
}
