import CoreGraphics
import Foundation
import ImageIO
import InkEngine
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

/// The picture that comes with a report: taken for you, drawn on with the
/// app's own pen, and yours to throw away.
///
/// Taking it for them is the whole idea. The hardest part of a bug report is
/// not writing it — it is explaining *where you were*. The app already knows
/// where you were, so it answers that part itself and leaves the reader with
/// one sentence to write.
///
/// Marks are kept in the image's own pixel coordinates with the origin at the
/// top left, which is the space the sheet draws in and the space the flattened
/// copy is composed in. One space, no conversions to get wrong.
public enum FeedbackImage {
    /// The app's own window, drawn by the app.
    ///
    /// `cacheDisplay` rather than a screen capture: it needs no screen-
    /// recording permission, cannot catch anything outside this app, and
    /// cannot catch whatever else is on the desktop. A reporting tool that
    /// asks to record the screen has already lost the argument this app makes.
    @MainActor
    public static func captureWindow() -> CGImage? {
        #if os(macOS)
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey }),
              let view = window.contentView
        else { return nil }
        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1,
              let rep = view.bitmapImageRepForCachingDisplay(in: bounds)
        else { return nil }
        view.cacheDisplay(in: bounds, to: rep)
        return rep.cgImage
        #else
        return nil
        #endif
    }

    /// The default width for a mark's line, so a stroke on a big Retina shot
    /// looks the same weight as one on a small window.
    public static func strokeWidth(for image: CGImage) -> CGFloat {
        max(2, CGFloat(image.width) / 420)
    }

    /// The shot with the marks burned in — what actually gets sent, so what is
    /// sent is exactly what was on screen in the sheet.
    @MainActor
    public static func flattened(_ draft: FeedbackDraft) -> CGImage? {
        guard let shot = draft.shot else { return nil }
        let width = shot.width
        let height = shot.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        context.draw(shot, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Marks are written with the origin at the top left; CoreGraphics puts
        // it at the bottom. Flip once here rather than at every point.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        SketchRenderer.draw(draft.marks, in: context, options: .init(flipsText: true))
        return context.makeImage()
    }

    public static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Downscaled if it is enormous: a 6K window is four megabytes of PNG and
    /// nobody reading the report needs that many pixels to see the arrow.
    public static func trimmed(_ image: CGImage, maxWidth: Int = 2200) -> CGImage {
        guard image.width > maxWidth else { return image }
        let scale = CGFloat(maxWidth) / CGFloat(image.width)
        let width = maxWidth
        let height = Int((CGFloat(image.height) * scale).rounded())
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    @MainActor
    public static func dataURL(of draft: FeedbackDraft) -> String? {
        guard let flat = flattened(draft),
              let data = pngData(trimmed(flat))
        else { return nil }
        return "data:image/png;base64," + data.base64EncodedString()
    }

    /// When the send does not go through. Everything the report held, in a
    /// folder on the desktop, so nothing anybody wrote is lost to a bad
    /// network and they can send it themselves.
    @MainActor
    public static func writeBundle(_ draft: FeedbackDraft) -> URL? {
        #if os(macOS)
        let stamp = Date.now.formatted(.iso8601.year().month().day().dateSeparator(.omitted))
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Desktop", directoryHint: .isDirectory)
            .appending(path: "Paper Time feedback \(stamp)", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var text = draft.message + "\n\n"
            text += "— \(draft.creditName)\n"
            if !draft.reply.isEmpty { text += "\(draft.reply)\n" }
            text += "\n"
            for (key, value) in draft.diagnostics.rows {
                text += "\(key): \(value)\n"
            }
            if let crash = draft.crash {
                text += "\n---- crash ----\n\(crash)\n"
            }
            try text.write(to: folder.appending(path: "message.txt"), atomically: true, encoding: .utf8)
            if draft.includesShot, let flat = flattened(draft), let png = pngData(trimmed(flat)) {
                try png.write(to: folder.appending(path: "screen.png"))
            }
            NSWorkspace.shared.activateFileViewerSelecting([folder])
            return folder
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }
}
