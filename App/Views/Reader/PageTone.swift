import CoreGraphics

/// Whether a picture on a page is a picture, or ink on white paper.
///
/// Night keeps pictures as printed so a photograph is not a negative — but a
/// scanned page is an image too, and so is a line drawing or a chart saved as
/// one, and kept as printed each is the white rectangle night exists to take
/// away (a scanned textbook read at night as a column of white cards). So an
/// image that is paper and ink and little else goes to night with the words.
///
/// The same rule, and the same numbers, as Portable's `shared/pageImages.ts`
/// (`tones`, `isInkOnWhite`), measured there on the corpus at 64 × 64 single
/// pixels (averaged, a line of type is a tone): the textbook's text blocks are
/// 78–94% paper with 1–12% tone and no colour; the light grey robot photograph
/// in V-JEPA 2's Figure 1 is 32% paper and 67% tone; photographs and coloured
/// figures have colour in a fifth to all of them.
enum PageTone {
    /// A pixel this light (of 255, by luma) is paper.
    static let paperLuma = 224.0
    /// Between this and paper, a pixel is a tone — what a photograph is made
    /// of and type is not. Below it, ink.
    static let toneLuma = 96.0
    /// A pixel whose channels are this far apart (of 255) has a colour.
    static let colouredChroma = 64.0

    struct Shares: Equatable {
        var paper: Double
        var tone: Double
        var coloured: Double
        var seen: Int
    }

    /// What the image's pixels are, as shares of the opaque ones, sampled on
    /// a `side` × `side` grid of single pixels.
    static func shares(of image: CGImage, side: Int = 64) -> Shares? {
        guard side > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data else { return nil }
        let bytes = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        var seen = 0, paper = 0, tone = 0, coloured = 0
        for index in 0..<(side * side) {
            let alpha = bytes[index * 4 + 3]
            guard alpha >= 128 else { continue }
            let r = Double(bytes[index * 4]), g = Double(bytes[index * 4 + 1]), b = Double(bytes[index * 4 + 2])
            seen += 1
            let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
            if luma >= paperLuma { paper += 1 } else if luma >= toneLuma { tone += 1 }
            if max(r, g, b) - min(r, g, b) >= colouredChroma { coloured += 1 }
        }
        guard seen > 0 else { return Shares(paper: 0, tone: 0, coloured: 0, seen: 0) }
        let n = Double(seen)
        return Shares(paper: Double(paper) / n, tone: Double(tone) / n, coloured: Double(coloured) / n, seen: seen)
    }

    /// At least three fifths paper, at most a fifth tone, at most a twentieth
    /// colour (a yellowed page is still paper).
    static func isInkOnWhite(_ image: CGImage) -> Bool {
        guard let shares = shares(of: image), shares.seen > 0 else { return false }
        return shares.paper >= 0.6 && shares.tone <= 0.2 && shares.coloured <= 0.05
    }
}
