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
    // Below about forty pixels the byline and the gaps between words are
    // smaller than a pixel, and drawing them anyway turns the sheet to mush.
    // Apple draws small icons as their own picture; so does this one.
    let simple = size <= 40

    let margin = sheet.width * (simple ? 0.16 : 0.135)
    let inner = sheet.insetBy(dx: margin, dy: 0)
    let ruleHeight = sheet.height * (simple ? 0.062 : 0.036)
    let step = sheet.height * (simple ? 0.165 : 0.096)
    var y = sheet.maxY - sheet.height * (simple ? 0.17 : 0.135)

    let titleHeight = sheet.height * (simple ? 0.10 : 0.060)
    context.setFillColor(Palette.title)
    context.addPath(CGPath(
        roundedRect: CGRect(x: inner.minX, y: y - titleHeight,
                            width: inner.width * 0.72, height: titleHeight),
        cornerWidth: titleHeight / 2, cornerHeight: titleHeight / 2, transform: nil
    ))
    context.fillPath()
    y -= titleHeight + sheet.height * (simple ? 0.115 : 0.042)

    if !simple {
        let bylineHeight = sheet.height * 0.030
        context.setFillColor(Palette.byline)
        context.addPath(CGPath(
            roundedRect: CGRect(x: inner.minX, y: y - bylineHeight,
                                width: inner.width * 0.42, height: bylineHeight),
            cornerWidth: bylineHeight / 2, cornerHeight: bylineHeight / 2, transform: nil
        ))
        context.fillPath()
        y -= bylineHeight + sheet.height * 0.075
    }

    let widths: [CGFloat] = simple ? [1.0, 0.95, 0.78] : [1.0, 0.94, 0.99, 0.87, 0.68]
    let marked = simple ? 1 : 2
    for (index, width) in widths.enumerated() {
        let line = CGRect(x: inner.minX, y: y - ruleHeight,
                          width: inner.width * width, height: ruleHeight)
        if index == marked {
            // A highlighter stroke over words, not a ring around a bar: the
            // colour has to show between the words or it reads as an outline.
            let band = CGRect(
                x: line.minX - ruleHeight * 0.5,
                y: line.midY - ruleHeight * 1.35,
                width: line.width + ruleHeight,
                height: ruleHeight * 2.7
            )
            context.setFillColor(Palette.highlight)
            context.addPath(CGPath(
                roundedRect: band,
                cornerWidth: ruleHeight * 0.55, cornerHeight: ruleHeight * 0.55, transform: nil
            ))
            context.fillPath()

            context.setFillColor(Palette.markedRule)
            let gap = ruleHeight * 0.85
            let shares: [CGFloat] = simple ? [1.0] : [0.36, 0.22, 0.42]
            let text = line.width - gap * CGFloat(shares.count - 1)
            var x = line.minX
            for share in shares {
                let word = CGRect(x: x, y: line.midY - ruleHeight * 0.42,
                                  width: text * share, height: ruleHeight * 0.84)
                context.addPath(CGPath(
                    roundedRect: word,
                    cornerWidth: word.height / 2, cornerHeight: word.height / 2, transform: nil
                ))
                context.fillPath()
                x = word.maxX + gap
            }
        } else {
            context.setFillColor(Palette.rule)
            context.addPath(CGPath(
                roundedRect: line,
                cornerWidth: ruleHeight / 2, cornerHeight: ruleHeight / 2, transform: nil
            ))
            context.fillPath()
        }
        y -= step
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
