import AppKit
import CoreGraphics
import Foundation

/// Photographs one app's window and cuts it out of its background.
///
///     swiftc -O Scripts/window-shot.swift -o /tmp/shot
///     /tmp/shot "Paper Time" Website/img/mac-window.png
///
/// `screencapture -l<window>` would do the cutting itself, but it needs a
/// screen-recording right this process does not have, and a landing page full
/// of somebody's desktop — their wallpaper, their other windows, the corner of
/// their calendar — is a page about their Mac rather than about the app. So
/// the window's own frame is asked for, that rectangle of the screen is taken,
/// and the corners are rounded away to transparency, which is what the window
/// looks like with nothing behind it.
enum WindowShot {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count >= 2 else {
            print("usage: window-shot <app name> <out.png> [radius] [x,y,w,h]")
            exit(2)
        }
        let app = arguments[0]
        let out = URL(fileURLWithPath: arguments[1])
        let radius = Double(arguments.count > 2 ? arguments[2] : "12") ?? 12

        // The window's own frame, or one given outright. Asking the window
        // server for it works until two copies of the app are running, when
        // the one it answers with is whichever it likes; System Events can be
        // asked for a particular process's window instead, and the shell
        // script that drives this does exactly that.
        let given = arguments.count > 3 ? rect(from: arguments[3]) : nil
        guard let frame = given ?? frame(ofLargestWindowOf: app) else {
            print("no window of \(app) on screen")
            exit(3)
        }

        let raw = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("window-shot-raw.png")
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = [
            "-x", "-R",
            "\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height))",
            raw.path,
        ]
        try? capture.run()
        capture.waitUntilExit()
        guard capture.terminationStatus == 0,
              let image = NSImage(contentsOf: raw),
              let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            print("capture failed")
            exit(4)
        }

        // The screen is drawn at two pixels to the point; the radius is given
        // in points, so it grows with it.
        let scale = Double(source.width) / Double(frame.width)
        let width = source.width
        let height = source.height
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { exit(5) }

        let box = CGRect(x: 0, y: 0, width: Double(width), height: Double(height))
        let path = CGPath(
            roundedRect: box, cornerWidth: radius * scale, cornerHeight: radius * scale,
            transform: nil
        )
        context.addPath(path)
        context.clip()
        context.draw(source, in: box)

        guard let cut = context.makeImage() else { exit(6) }
        let rep = NSBitmapImageRep(cgImage: cut)
        rep.size = NSSize(width: Double(width) / scale, height: Double(height) / scale)
        guard let data = rep.representation(using: .png, properties: [:]) else { exit(7) }
        try? data.write(to: out)
        print("\(out.lastPathComponent) — \(width)×\(height)")
    }

    private static func rect(from text: String) -> CGRect? {
        let parts = text.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 4 else { return nil }
        return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    }

    private static func frame(ofLargestWindowOf app: String) -> CGRect? {
        let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] ?? []
        var best: CGRect?
        for entry in list {
            guard let owner = entry[kCGWindowOwnerName as String] as? String, owner == app,
                  let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                  let x = bounds["X"] as? Double, let y = bounds["Y"] as? Double,
                  let w = bounds["Width"] as? Double, let h = bounds["Height"] as? Double,
                  h > 300
            else { continue }
            let rect = CGRect(x: x, y: y, width: w, height: h)
            if best == nil || rect.width * rect.height > best!.width * best!.height { best = rect }
        }
        return best
    }
}

WindowShot.main()
