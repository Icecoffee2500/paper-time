import SwiftUI

#if os(macOS)
import AppKit

/// A field that shows a shortcut and, when clicked, takes the next one pressed.
///
/// The way every Mac app that lets you change a shortcut does it: click, press
/// the keys, done. Typing the name of a key into a text field is the other way
/// and nobody has ever enjoyed it.
struct ShortcutRecorder: View {
    let shortcut: Shortcut
    /// True when another pane has taken this one's key.
    var isUnset = false
    let onRecord: (Shortcut) -> Void

    @State private var isRecording = false

    var body: some View {
        Button {
            isRecording.toggle()
        } label: {
            Text(isRecording ? "Press a key…" : (isUnset ? "—" : shortcut.display))
                .font(.body.monospaced())
                .foregroundStyle(isRecording ? .secondary : (isUnset ? .tertiary : .primary))
                .frame(minWidth: 74)
                .padding(.vertical, 3)
                .padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: Corner.row, style: .continuous)
                        .fill(isRecording ? Color.accentColor.opacity(0.14) : Color(nsColor: .quaternarySystemFill))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Corner.row, style: .continuous)
                        .strokeBorder(
                            isRecording ? Color.accentColor : .clear,
                            lineWidth: 1.5
                        )
                )
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(
            KeyCatcher(isRecording: $isRecording) { key, modifiers in
                onRecord(Shortcut(key, modifiers))
                isRecording = false
            }
            .frame(width: 0, height: 0)
        )
        .help("Click, then press the keys you want")
    }
}

/// The bit that actually hears the keyboard.
private struct KeyCatcher: NSViewRepresentable {
    @Binding var isRecording: Bool
    let onKey: (Character, EventModifiers) -> Void

    func makeNSView(context: Context) -> CatchingView {
        let view = CatchingView()
        view.onKey = onKey
        view.onCancel = { isRecording = false }
        return view
    }

    func updateNSView(_ view: CatchingView, context: Context) {
        view.onKey = onKey
        view.onCancel = { isRecording = false }
        if isRecording, view.window?.firstResponder !== view {
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        } else if !isRecording, view.window?.firstResponder === view {
            DispatchQueue.main.async { view.window?.makeFirstResponder(nil) }
        }
    }

    final class CatchingView: NSView {
        var onKey: ((Character, EventModifiers) -> Void)?
        var onCancel: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            // Escape gives up without changing anything.
            guard event.keyCode != 53 else {
                onCancel?()
                return
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            var modifiers = EventModifiers()
            if flags.contains(.command) { modifiers.insert(.command) }
            if flags.contains(.shift) { modifiers.insert(.shift) }
            if flags.contains(.option) { modifiers.insert(.option) }
            if flags.contains(.control) { modifiers.insert(.control) }

            // A shortcut with no modifier would swallow ordinary typing, and
            // shift alone is not a modifier for this purpose.
            guard !modifiers.intersection([.command, .control, .option]).isEmpty,
                  let character = event.charactersIgnoringModifiers?.lowercased().first,
                  !character.isWhitespace
            else {
                NSSound.beep()
                return
            }
            onKey?(character, modifiers)
        }

        override func resignFirstResponder() -> Bool {
            onCancel?()
            return true
        }
    }
}
#endif
