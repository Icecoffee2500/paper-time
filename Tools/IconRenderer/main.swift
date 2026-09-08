import AppKit
import CoreGraphics
import Foundation

// Draws the app icon and writes every size the asset catalog asks for.
//
// Vector, rendered natively at each size rather than downscaled from one big
// image: a 16-point icon drawn at 16 points keeps its edges, and the small
// sizes are where a downscaled icon turns to mush.

struct Palette {
    static let backgroundTop = CGColor(red: 0.996, green: 0.992, blue: 0.984, alpha: 1)
    static let backgroundBottom = CGColor(red: 0.867, green: 0.859, blue: 0.839, alpha: 1)
    static let sheet = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    static let sheetEdge = CGColor(red: 0.1, green: 0.09, blue: 0.08, alpha: 0.10)
    static let title = CGColor(red: 0.129, green: 0.286, blue: 0.451, alpha: 1)
    static let byline = CGColor(red: 0.780, green: 0.776, blue: 0.792, alpha: 1)
    static let rule = CGColor(red: 0.706, green: 0.702, blue: 0.725, alpha: 1)
    static let markedRule = CGColor(red: 0.294, green: 0.259, blue: 0.176, alpha: 1)
    static let highlight = CGColor(red: 1.0, green: 0.812, blue: 0.243, alpha: 1)
    static let shadow = CGColor(red: 0.180, green: 0.161, blue: 0.129, alpha: 0.34)
    static let sheen = CGColor(red: 1, green: 1, blue: 1, alpha: 0.55)
}

/// The rounded shape macOS icons live in. Apple's grid puts the artwork in a
/// square 80.5% of the canvas with a corner radius just over a fifth of that.
func squirclePath(in rect: CGRect) -> CGPath {
    CGPath(
        roundedRect: rect,
        cornerWidth: rect.width * 0.2245,
        cornerHeight: rect.height * 0.2245,
        transform: nil
    )
}

func draw(size: CGFloat, rounded: Bool, into context: CGContext) {
    let canvas = CGRect(x: 0, y: 0, width: size, height: size)
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high

    // The plate the artwork sits on: the whole canvas on iOS, where the system
    // applies its own mask, and an inset rounded square on the Mac, which
    // expects the icon to carry its own shape and shadow.
    let plate = rounded
        ? canvas.insetBy(dx: size * 0.0977, dy: size * 0.0977)
            .offsetBy(dx: 0, dy: size * 0.0195)
        : canvas
    let platePath = rounded ? squirclePath(in: plate) : CGPath(rect: canvas, transform: nil)

    if rounded {
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -size * 0.012),
            blur: size * 0.028,
            color: Palette.shadow
        )
        context.addPath(platePath)
        context.setFillColor(Palette.backgroundBottom)
        context.fillPath()
        context.restoreGState()
    }

    context.saveGState()
    context.addPath(platePath)
    context.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let gradient = CGGradient(
        colorsSpace: space,
        colors: [Palette.backgroundTop, Palette.backgroundBottom] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: plate.midX, y: plate.maxY),
        end: CGPoint(x: plate.midX, y: plate.minY),
        options: []
    )
    // A hint of light along the top edge, the way every icon on the dock has.
    if rounded {
        context.setStrokeColor(Palette.sheen)
        context.setLineWidth(max(size * 0.006, 0.75))
        context.addPath(squirclePath(in: plate.insetBy(dx: size * 0.004, dy: size * 0.004)))
        context.strokePath()
    }
    context.restoreGState()

    // The paper.
    let side = plate.width
    // Nudged up a touch: a shape with a shadow under it looks low when it is
    // measured to the middle.
    let sheet = CGRect(
        x: plate.midX - side * 0.285,
        y: plate.midY - side * 0.355 + side * 0.018,
        width: side * 0.57,
        height: side * 0.71
    )
    let sheetPath = CGPath(
        roundedRect: sheet,
        cornerWidth: side * 0.028,
        cornerHeight: side * 0.028,
        transform: nil
    )

    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -side * 0.022),
        blur: side * 0.062,
        color: Palette.shadow
    )
    context.addPath(sheetPath)
    context.setFillColor(Palette.sheet)
    context.fillPath()
    context.restoreGState()

    context.addPath(sheetPath)
    context.setStrokeColor(Palette.sheetEdge)
    context.setLineWidth(max(size * 0.004, 0.5))
    context.strokePath()

    // What is written on it: a title, some lines, and one of them marked —
    // which is the whole point of the app.
    // Below about forty pixels the finer strokes are smaller than a pixel, so
    // the small icon is drawn as its own, plainer picture.
    let simple = size <= 40

    let margin = sheet.width * (simple ? 0.17 : 0.155)
    let inner = sheet.insetBy(dx: margin, dy: 0)

    // Four marks on a page: a title, two lines of text, and one line struck
    // through with a highlighter. Anything more reads as clutter at the size
    // an icon is actually looked at.
    let ruleHeight = sheet.height * (simple ? 0.052 : 0.034)
    let titleHeight = ruleHeight * (simple ? 1.5 : 1.75)
    let markHeight = ruleHeight * (simple ? 2.0 : 2.3)
    let afterTitle = sheet.height * (simple ? 0.135 : 0.105)
    let between = sheet.height * (simple ? 0.135 : 0.100)

    // The marked line is simply the marked colour, and thicker: a highlighter
    // stroke is broader than the words it covers, and saying it that way needs
    // no second shape stacked on the first.
    let lines: [(width: CGFloat, marked: Bool)] = simple
        ? [(0.96, false), (0.88, true)]
        : [(0.96, false), (0.88, true), (0.72, false)]

    let block = titleHeight + afterTitle
        + lines.reduce(0) { $0 + ($1.marked ? markHeight : ruleHeight) }
        + between * CGFloat(lines.count - 1)
    // Centred on the page, nudged up: type set dead centre reads low.
    var y = sheet.midY + block / 2 + sheet.height * 0.012

    context.setFillColor(Palette.title)
    context.addPath(CGPath(
        roundedRect: CGRect(x: inner.minX, y: y - titleHeight,
                            width: inner.width * 0.70, height: titleHeight),
        cornerWidth: titleHeight / 2, cornerHeight: titleHeight / 2, transform: nil
    ))
    context.fillPath()
    y -= titleHeight + afterTitle

    for (index, line) in lines.enumerated() {
        let height = line.marked ? markHeight : ruleHeight
        context.setFillColor(line.marked ? Palette.highlight : Palette.rule)
        context.addPath(CGPath(
            roundedRect: CGRect(x: inner.minX, y: y - height,
                                width: inner.width * line.width, height: height),
            cornerWidth: height / 2, cornerHeight: height / 2, transform: nil
        ))
        context.fillPath()
        y -= height
        if index < lines.count - 1 { y -= between }
    }
}

func render(size: Int, rounded: Bool, to url: URL) throws {
    let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    draw(size: CGFloat(size), rounded: rounded, into: context)
    let image = context.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: size, height: size)
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

// iOS: full bleed, the system rounds it.
try render(size: 1024, rounded: false, to: output.appending(path: "icon-ios-1024.png"))
// macOS: carries its own rounded shape and shadow.
for pixels in [16, 32, 64, 128, 256, 512, 1024] {
    try render(size: pixels, rounded: true, to: output.appending(path: "icon-mac-\(pixels).png"))
}
print("wrote icons to \(output.path)")
