import SwiftUI

#if os(macOS)
import AppKit
import Carbon.HIToolbox

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
            .allowsHitTesting(false)
        )
        .help("Click, then press the keys you want")
    }
}

/// The bit that actually hears the keyboard.
///
/// It listens through `performKeyEquivalent`, not `keyDown`. A combination
/// with Command in it never reaches `keyDown`: the window offers it to its
/// views as a key equivalent first, and whatever does not claim it there goes
/// to the menu bar — which is exactly where ⌘P and ⌘\\ already live. Listening
/// for `keyDown` meant listening for something that had already been taken.
struct KeyCatcher: NSViewRepresentable {
    @Binding var isRecording: Bool
    /// Takes whatever is pressed, without judging it.
    ///
    /// Recording a shortcut refuses a combination it must not assign — ⌘Q and
    /// the rest — and beeps. Searching for one has to accept them: asking
    /// "what is on ⌘Q?" is a fair question, and the answer is "nothing of
    /// ours", which is only sayable if the key gets through.
    var capturesAnything = false
    /// What Escape should do instead of cancelling a recording.
    ///
    /// It has to be handled here rather than left to the window. A focused
    /// text field swallows Escape — AppKit sends it to the field editor as
    /// `cancelOperation:`, which consumes it and does nothing — so a window
    /// that closes on Escape does not close while you are typing in one.
    var onEscape: (() -> Void)?
    let onKey: (Character, SwiftUI.EventModifiers) -> Void

    func makeNSView(context: Context) -> CatchingView {
        let view = CatchingView()
        view.recorder = self
        return view
    }

    func updateNSView(_ view: CatchingView, context: Context) {
        view.recorder = self
    }

    /// The combinations the system needs more than we do. Taking ⌘Q for a pane
    /// would leave no way to quit.
    static let reserved: Set<String> = ["q", "w", "h", "m", ",", "`"]

    /// Let through even by a search that is catching everything else.
    ///
    /// A field that swallowed ⌘Q and ⌘W would be a field you could not leave,
    /// which is a worse bargain than not being able to ask what those two
    /// keys do.
    static let escapeHatches: Set<String> = ["q", "w"]

    final class CatchingView: NSView {
        var recorder: KeyCatcher?

        /// Which key was pressed, as the key *is* rather than as it types.
        ///
        /// `charactersIgnoringModifiers` still goes through the input source,
        /// so pressing J with a Korean layout on gives back "ㅓ" — and a menu
        /// shortcut on "ㅓ" only fires while that layout is active. The key
        /// has to be read through a layout that can spell ASCII, which is
        /// what every Mac app that records shortcuts does.
        static func key(for event: NSEvent) -> Character? {
            if let translated = asciiKey(for: event.keyCode) { return translated }
            return event.charactersIgnoringModifiers?.lowercased().first
        }

        private static func asciiKey(for keyCode: UInt16) -> Character? {
            guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?
                .takeRetainedValue(),
                let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
            else { return nil }
            let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
            return data.withUnsafeBytes { buffer -> Character? in
                guard let layout = buffer.baseAddress?
                    .assumingMemoryBound(to: UCKeyboardLayout.self)
                else { return nil }
                var deadKeys: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(
                    layout, keyCode, UInt16(kUCKeyActionDisplay), 0,
                    UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeys, characters.count, &length, &characters
                )
                guard status == noErr, length > 0 else { return nil }
                return String(utf16CodeUnits: characters, count: length).lowercased().first
            }
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard let recorder, recorder.isRecording else { return false }

            // Escape gives up without changing anything, unless the caller
            // has said what it means here.
            if event.keyCode == 53 {
                if let onEscape = recorder.onEscape {
                    onEscape()
                } else {
                    recorder.isRecording = false
                }
                return true
            }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            var modifiers = SwiftUI.EventModifiers()
            if flags.contains(.command) { modifiers.insert(.command) }
            if flags.contains(.shift) { modifiers.insert(.shift) }
            if flags.contains(.option) { modifiers.insert(.option) }
            if flags.contains(.control) { modifiers.insert(.control) }

            // A shortcut with no modifier would swallow ordinary typing, and
            // Shift alone is not a modifier for this purpose.
            guard !modifiers.intersection([.command, .control, .option]).isEmpty,
                  let character = CatchingView.key(for: event),
                  !character.isWhitespace
            else {
                // Ordinary typing comes through here too — AppKit offers
                // every key down as a key equivalent first — so a search that
                // catches combinations must hand the plain keys back, or the
                // field it is attached to can never be typed in.
                if recorder.capturesAnything { return false }
                NSSound.beep()
                return true
            }
            if recorder.capturesAnything,
               modifiers == .command,
               KeyCatcher.escapeHatches.contains(String(character)) {
                return false
            }
            if !recorder.capturesAnything,
               modifiers == .command,
               KeyCatcher.reserved.contains(String(character)) {
                NSSound.beep()
                return true
            }

            recorder.onKey(character, modifiers)
            return true
        }
    }
}
#endif
