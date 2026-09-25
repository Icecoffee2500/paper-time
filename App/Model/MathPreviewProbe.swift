import Foundation
import PaperCore
#if os(macOS)
import AppKit
import SwiftUI

/// Types into a formula in a note and photographs the card that sets it:
/// `--papertime-math-preview=<png in the container>`.
///
/// The same window as the Latex Suite typing probe — a real `NoteEditor` in
/// a window of the probe's own, off every display — and the same keys, typed
/// through the text view's own `insertText` and `keyDown`. Nothing goes to
/// the system. Two pictures come out: `<png>` with the caret in an inline
/// `$…$`, and `<png>` with `-block` before the extension with the caret in
/// a `$$` that spans lines. The card is a child window, which the editor's
/// own picture does not hold, so it is drawn into the picture at its place.
/// Where it is and what it shows go to stderr either way.
@MainActor
enum MathPreviewProbe {
    static func runIfAsked() {
        guard let path = Boot.setting("PAPERTIME_MATH_PREVIEW"), !path.isEmpty else { return }
        say("math preview: starting")
        Task { @MainActor in await run(path) }
    }

    private static func say(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    private static func run(_ path: String) async {
        try? await Task.sleep(for: .seconds(1))
        let displays = NSScreen.screens.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: displays.minX - 60_000, y: displays.minY - 60_000))
        let note = LatexSuiteTypingProbe.Note()
        let hosting = NSHostingView(rootView: LatexSuiteTypingProbe.NoteHost(note: note))
        hosting.frame = NSRect(x: 0, y: 0, width: 560, height: 360)
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(600))
        guard let text = LatexSuiteTypingProbe.noteTextView(in: hosting), let coordinator = text.coordinator else {
            return say("math preview: no note text view in the window")
        }

        // Inline: the caret inside `$…$`, then `x1` typed — Latex Suite makes
        // it `x_{1}`, and the card sets that.
        await type(into: text, coordinator: coordinator, note: note, window: window,
                   source: "평균은 $\\bar{|}$ 이에요", keys: ["x", "1"])
        await settle()
        say(coordinator.mathPreview.report)
        say("math preview: note holds \(LatexSuiteTypingProbe.marked(text).debugDescription)")
        write(text, card: coordinator.mathPreview, to: path)

        // A block: `$$`, a line of LaTeX, `$$`, the caret on the middle line.
        let blockPath = (path as NSString).deletingPathExtension + "-block." + ((path as NSString).pathExtension.isEmpty ? "png" : (path as NSString).pathExtension)
        await type(into: text, coordinator: coordinator, note: note, window: window,
                   source: "분산은\n$$\n\\frac{1}{n}\\sum_{i=1}^{n}(x_i - \\bar{x})^{|}\n$$\n이에요", keys: ["2"])
        await settle()
        say(coordinator.mathPreview.report)
        say("math preview: note holds \(LatexSuiteTypingProbe.marked(text).debugDescription)")
        write(text, card: coordinator.mathPreview, to: blockPath)

        // Leaving the formula takes the card away.
        LatexSuiteTypingProbe.set([NSRange(location: 0, length: 0)], in: text)
        await settle()
        say("math preview: after leaving — \(coordinator.mathPreview.report)")
        NSApp.terminate(nil)
    }

    private static func type(
        into text: NoteTextView, coordinator: NoteEditor.Coordinator, note: LatexSuiteTypingProbe.Note,
        window: NSWindow, source marked: String, keys: [String]
    ) async {
        guard let (source, selection) = LatexSuiteTypingProbe.parse(marked) else { return say("math preview: cannot read \(marked)") }
        coordinator.lastKnownMarkdown = source
        note.markdown = source
        coordinator.restyle(text, source: source, caretSource: selection.first?.location ?? 0)
        text.latexSuite.reset()
        LatexSuiteTypingProbe.set(selection, in: text)
        window.makeFirstResponder(text)
        try? await Task.sleep(for: .milliseconds(40))
        for key in keys {
            _ = await LatexSuiteTypingProbe.press(key, in: text, window: window)
            await LatexSuiteTypingProbe.endOfEvent(window)
        }
    }

    /// Past the card's 80 ms and its fade.
    private static func settle() async {
        try? await Task.sleep(for: .milliseconds(400))
    }

    /// The editor's pixels with the card drawn where it floats.
    private static func write(_ text: NoteTextView, card: MathPreviewCard, to path: String) {
        guard let window = text.window,
              let bitmap = text.bitmapImageRepForCachingDisplay(in: text.bounds) else { return }
        text.display()
        text.cacheDisplay(in: text.bounds, to: bitmap)
        let image = NSImage(size: text.bounds.size)
        image.addRepresentation(bitmap)
        let composed = NSImage(size: text.bounds.size, flipped: false) { rect in
            image.draw(in: rect)
            if let picture = card.picture(), let frame = card.frame {
                // The card's screen frame, into the text view's own coordinates.
                let local = text.convert(window.convertFromScreen(frame), from: nil)
                // The text view is flipped and the picture is not.
                picture.draw(in: NSRect(x: local.minX, y: rect.height - local.maxY,
                                        width: local.width, height: local.height))
            }
            return true
        }
        guard let tiff = composed.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
        say("math preview: wrote \(path)")
    }
}
#endif
