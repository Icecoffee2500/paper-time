import AppKit
import CoreGraphics
import Foundation

// Draws the app icon and writes every size the asset catalog asks for.
//
// Vector, rendered natively at each size rather than downscaled from one big
// image: a 16-point icon drawn at 16 points keeps its edges, and the small
// sizes are where a downscaled icon turns to mush.
//
// Three bars on a tile: two lines of a paper and one struck through with a
// highlighter. No sheet, no border, no text — at the size an icon is looked at,
// the mark is the whole idea and everything else is noise around it.

enum Palette {
    static let top = CGColor(red: 0.180, green: 0.365, blue: 0.549, alpha: 1)
    static let bottom = CGColor(red: 0.090, green: 0.216, blue: 0.361, alpha: 1)
    static let line = CGColor(red: 1, green: 1, blue: 1, alpha: 0.92)
    static let mark = CGColor(red: 1.0, green: 0.812, blue: 0.243, alpha: 1)
    static let rim = CGColor(red: 1, green: 1, blue: 1, alpha: 0.22)
    static let shadow = CGColor(red: 0.055, green: 0.098, blue: 0.157, alpha: 0.38)
}

/// The rounded shape macOS icons live in. Apple's grid puts the artwork in a
/// square 80.5% of the canvas with a corner radius just over a fifth of that.
func squircle(in rect: CGRect) -> CGPath {
    CGPath(
        roundedRect: rect,
        cornerWidth: rect.width * 0.2245,
        cornerHeight: rect.height * 0.2245,
        transform: nil
    )
}

func draw(size: CGFloat, rounded: Bool, into context: CGContext) {
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high
    let canvas = CGRect(x: 0, y: 0, width: size, height: size)

    // The whole canvas on iOS, where the system applies its own mask; an inset
    // rounded square on the Mac, which expects the icon to carry its own shape.
    let plate = rounded
        ? canvas.insetBy(dx: size * 0.0977, dy: size * 0.0977)
            .offsetBy(dx: 0, dy: size * 0.0195)
        : canvas
    let platePath = rounded ? squircle(in: plate) : CGPath(rect: canvas, transform: nil)

    if rounded {
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -size * 0.014),
            blur: size * 0.030,
            color: Palette.shadow
        )
        context.addPath(platePath)
        context.setFillColor(Palette.bottom)
        context.fillPath()
        context.restoreGState()
    }

    context.saveGState()
    context.addPath(platePath)
    context.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [Palette.top, Palette.bottom] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: plate.midX, y: plate.maxY),
        end: CGPoint(x: plate.midX, y: plate.minY),
        options: []
    )
    if rounded {
        // A hint of light along the edge, the way every icon on the dock has.
        context.setStrokeColor(Palette.rim)
        context.setLineWidth(max(size * 0.006, 0.75))
        context.addPath(squircle(in: plate.insetBy(dx: size * 0.004, dy: size * 0.004)))
        context.strokePath()
    }
    context.restoreGState()

    // Two lines and the mark. The marked one is shorter, thicker and the only
    // thing that is not white: one point of colour, which is what it is for.
    let side = plate.width
    let small = size <= 40
    let inner = plate.insetBy(dx: side * (small ? 0.175 : 0.19), dy: 0)
    let lineHeight = side * (small ? 0.085 : 0.075)
    let markHeight = lineHeight * 1.55
    let gap = side * (small ? 0.115 : 0.105)

    let rows: [(width: CGFloat, marked: Bool)] = [(1.0, false), (0.80, true), (0.62, false)]
    let block = rows.reduce(0) { $0 + ($1.marked ? markHeight : lineHeight) }
        + gap * CGFloat(rows.count - 1)
    var y = plate.midY + block / 2

    for row in rows {
        let height = row.marked ? markHeight : lineHeight
        context.setFillColor(row.marked ? Palette.mark : Palette.line)
        context.addPath(CGPath(
            roundedRect: CGRect(x: inner.minX, y: y - height,
                                width: inner.width * row.width, height: height),
            cornerWidth: height / 2, cornerHeight: height / 2, transform: nil
        ))
        context.fillPath()
        y -= height + gap
    }
}

func render(size: Int, rounded: Bool, to url: URL) throws {
    let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    draw(size: CGFloat(size), rounded: rounded, into: context)
    let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
    rep.size = NSSize(width: size, height: size)
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
try render(size: 1024, rounded: false, to: output.appending(path: "icon-ios-1024.png"))
for pixels in [16, 32, 64, 128, 256, 512, 1024] {
    try render(size: pixels, rounded: true, to: output.appending(path: "icon-mac-\(pixels).png"))
}
print("wrote icons to \(output.path)")
