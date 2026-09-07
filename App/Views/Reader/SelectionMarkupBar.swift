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
                .help("Highlight \(color.displayName)")
                .accessibilityLabel("Highlight \(color.displayName)")
            }

            Divider().frame(height: 18)

            Button {
                onMark(.underline, .yellow)
            } label: {
                Image(systemName: "underline")
            }
            .buttonStyle(.plain)
            .help("Underline")
            .accessibilityLabel("Underline")

            Button {
                onMark(.strikethrough, .yellow)
            } label: {
                Image(systemName: "strikethrough")
            }
            .buttonStyle(.plain)
            .help("Strikethrough")
            .accessibilityLabel("Strikethrough")

            Divider().frame(height: 18)

            Button(action: onCopy) {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.plain)
            .help("Copy")
            .accessibilityLabel("Copy")
        }
        .font(.body)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: .capsule)
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
