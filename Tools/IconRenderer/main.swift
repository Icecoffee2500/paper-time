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
//
// Black and white only: the tile is the sheet, the two grey bars are lines of
// text, and the black one is the line that was marked.

enum Palette {
    static let strokeInk = CGColor(red: 0.110, green: 0.110, blue: 0.118, alpha: 1)
    static let textLine = CGColor(red: 0.557, green: 0.557, blue: 0.576, alpha: 1)
    // Black and white, the way a page is: a white sheet, grey lines of text,
    // and the one line that was marked in solid black.
    static let top = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    static let bottom = CGColor(red: 0.949, green: 0.949, blue: 0.969, alpha: 1)
    static let line = CGColor(red: 0.557, green: 0.557, blue: 0.576, alpha: 1)
    static let mark = CGColor(red: 0.110, green: 0.110, blue: 0.118, alpha: 1)
    static let rim = CGColor(red: 0.780, green: 0.780, blue: 0.800, alpha: 0.55)
    static let shadow = CGColor(red: 0, green: 0, blue: 0, alpha: 0.28)
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
        // A hairline along the edge, so a white tile still has a shape of its
        // own against a light background.
        context.setStrokeColor(Palette.rim)
        context.setLineWidth(max(size * 0.006, 0.75))
        context.addPath(squircle(in: plate.insetBy(dx: size * 0.004, dy: size * 0.004)))
        context.strokePath()
    }
    context.restoreGState()

    // Two lines of text and, across them, the stroke of a marker. The line the
    // stroke covers is not drawn at all: a line nobody can see is a line that
    // should not be there.
    let side = plate.width
    let small = size <= 40
    let inner = plate.insetBy(dx: side * 0.185, dy: 0)
    let lineHeight = side * (small ? 0.080 : 0.068)
    let gap = side * 0.115
    let block = lineHeight * 3 + gap * 2
    var y = plate.midY + block / 2

    // Three slots, of which the middle one is left empty for the stroke.
    for width in [1.0, nil, 0.70] as [CGFloat?] {
        if let width {
            context.setFillColor(Palette.textLine)
            context.addPath(CGPath(
                roundedRect: CGRect(x: inner.minX, y: y - lineHeight,
                                    width: inner.width * width, height: lineHeight),
                cornerWidth: lineHeight / 2, cornerHeight: lineHeight / 2, transform: nil
            ))
            context.fillPath()
        }
        y -= lineHeight + gap
    }

    context.saveGState()
    context.translateBy(x: plate.midX, y: plate.midY)
    context.rotate(by: -0.20)
    let strokeHalf = side * (small ? 0.090 : 0.0815)
    context.setFillColor(Palette.strokeInk)
    context.addPath(CGPath(
        roundedRect: CGRect(x: -inner.width * 0.51, y: -strokeHalf,
                            width: inner.width * 1.02, height: strokeHalf * 2),
        cornerWidth: strokeHalf, cornerHeight: strokeHalf, transform: nil
    ))
    context.fillPath()
    context.restoreGState()
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
