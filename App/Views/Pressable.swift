import SwiftUI
#if os(macOS)
import AppKit
#endif

extension View {
    /// Says "this can be pressed" before it is.
    ///
    /// A row that opens something and a row that merely lists something look
    /// the same at rest, and nothing about a mark in the inspector or a note
    /// in the slip-box says it will take you anywhere. Two things tell a Mac
    /// user otherwise, and this adds both: the pointer becomes a hand over it,
    /// and the row lifts a shade while the pointer is there. The lift is
    /// faint on purpose — the row is not a button, it is a row that happens
    /// to go somewhere.
    func pressable(cornerRadius: CGFloat = Corner.row, inset: CGFloat = 0) -> some View {
        modifier(Pressable(cornerRadius: cornerRadius, inset: inset))
    }
}

private struct Pressable: ViewModifier {
    let cornerRadius: CGFloat
    let inset: CGFloat
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.055 : 0))
                    .padding(-inset)
            )
            .animation(Motion.tap, value: isHovering)
            .onHover { hovering in
                isHovering = hovering
                #if os(macOS)
                // Set, not pushed: a push with no matching pop — a row that
                // scrolled away under the pointer — leaves the hand on for
                // good. Setting is stateless, and AppKit puts the arrow back
                // the moment the pointer reaches something with its own idea.
                (hovering ? NSCursor.pointingHand : NSCursor.arrow).set()
                #endif
            }
    }
}
