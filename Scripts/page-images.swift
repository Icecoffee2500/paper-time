import AppKit

// The pictures the landing page carries but does not show: the card a
// messenger unfurls when the link is pasted (og:image), and the favicons.
// Drawn from the app icon, in the page's own grammar — the cool ground,
// the wordmark with "Time" in the accent, the lede with its one highlighter
// stroke — so the card and the page it opens are one thing.
//
//   swiftc -O Scripts/page-images.swift -o /tmp/page-images && /tmp/page-images
//
// Writes Website/img/preview.jpg (1200×630 at 2×), icon-32.png, icon-180.png.

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconURL = root.appendingPathComponent("App/Resources/Assets.xcassets/AppIcon.appiconset/icon-mac-1024.png")
let out = root.appendingPathComponent("Website/img")
guard let icon = NSImage(contentsOf: iconURL) else { fatalError("no icon at \(iconURL.path)") }

func png(_ image: NSImage, pixels: Int, to url: URL) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

// Favicons: the icon as it is. The macOS icon carries its own margin, so
// the 32 is cut a little tighter to read at that size.
png(icon, pixels: 180, to: out.appendingPathComponent("icon-180.png"))
do {
    let tight = NSImage(size: NSSize(width: 100, height: 100), flipped: false) { rect in
        icon.draw(in: rect.insetBy(dx: -10, dy: -10)); return true
    }
    png(tight, pixels: 64, to: out.appendingPathComponent("icon-32.png"))
}

// The card. 1200×630 is what every unfurler expects; drawn at 2× for the
// retina ones, which is all of them now.
let size = NSSize(width: 1200, height: 630)
let scale: CGFloat = 2
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high

// The window's ground, the same two blues the page floats its panels on.
let ground = NSGradient(starting: NSColor(srgbRed: 0.906, green: 0.925, blue: 0.961, alpha: 1),
                        ending: NSColor(srgbRed: 0.867, green: 0.898, blue: 0.945, alpha: 1))!
ground.draw(in: NSRect(origin: .zero, size: size), angle: -70)

// The icon, large, on the left; its own shadow is in the file.
let iconSide: CGFloat = 372
icon.draw(in: NSRect(x: 88, y: (size.height - iconSide) / 2 - 6, width: iconSide, height: iconSide))

let ink = NSColor(srgbRed: 0.086, green: 0.086, blue: 0.102, alpha: 1)
let ink2 = NSColor(srgbRed: 0.333, green: 0.333, blue: 0.369, alpha: 1)
let ink3 = NSColor(srgbRed: 0.545, green: 0.545, blue: 0.580, alpha: 1)
let accent = NSColor(srgbRed: 0.039, green: 0.424, blue: 1.0, alpha: 1)
let markSoft = NSColor(srgbRed: 1.0, green: 0.882, blue: 0.302, alpha: 0.55)

let textX: CGFloat = 520
// Wordmark: "Paper" in ink, "Time" in the accent, set tight like the page.
let wordmark = NSMutableAttributedString()
let wordFont = NSFont.systemFont(ofSize: 92, weight: .bold)
wordmark.append(NSAttributedString(string: "Paper ", attributes: [.font: wordFont, .foregroundColor: ink, .kern: -2.6]))
wordmark.append(NSAttributedString(string: "Time", attributes: [.font: wordFont, .foregroundColor: accent, .kern: -2.6]))
wordmark.draw(at: NSPoint(x: textX, y: 372))

// The lede, two lines, with the highlighter under the words the page marks.
let ledeFont = NSFont.systemFont(ofSize: 36, weight: .regular)
let boldLede = NSFont.systemFont(ofSize: 36, weight: .semibold)
let line1 = NSAttributedString(string: "논문에만 집중할 수 있게.", attributes: [.font: ledeFont, .foregroundColor: ink2])
line1.draw(at: NSPoint(x: textX, y: 290))
let before = NSAttributedString(string: "나머지는 ", attributes: [.font: ledeFont, .foregroundColor: ink2])
let marked = NSAttributedString(string: "앱이 알아서", attributes: [.font: boldLede, .foregroundColor: ink])
let after = NSAttributedString(string: " 한다.", attributes: [.font: ledeFont, .foregroundColor: ink2])
let y2: CGFloat = 236
before.draw(at: NSPoint(x: textX, y: y2))
let markX = textX + before.size().width
// The stroke: from a little above the baseline to under the descenders,
// the way the page's .mark sits — a band, not a box.
let band = NSRect(x: markX - 2, y: y2 + 4, width: marked.size().width + 5, height: 20)
markSoft.setFill()
NSBezierPath(roundedRect: band, xRadius: 3, yRadius: 3).fill()
marked.draw(at: NSPoint(x: markX, y: y2))
after.draw(at: NSPoint(x: markX + marked.size().width, y: y2))

// Where it runs, and where it comes from — the small line every card has.
let foot = NSAttributedString(string: "macOS 14 이상 · iPad · iPhone      icecoffee2500.github.io/paper-time",
                              attributes: [.font: NSFont.systemFont(ofSize: 21, weight: .medium), .foregroundColor: ink3])
foot.draw(at: NSPoint(x: textX, y: 116))

NSGraphicsContext.restoreGraphicsState()
// JPEG, not PNG: the ground is a gradient, which PNG stores byte for byte —
// a megabyte and a half — and unfurlers have their limits and their patience.
try! rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])!
    .write(to: out.appendingPathComponent("preview.jpg"))
print("wrote preview.jpg, icon-180.png, icon-32.png")
