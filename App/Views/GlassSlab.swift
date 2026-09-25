import SwiftUI
#if os(macOS)
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
#endif

/// A slab of Liquid Glass laid over a picture of what is behind it.
///
/// What tells the eye "glass" is not blur but *lensing*: a transparent
/// body bends the light passing through its edges, so the rim shows what
/// lies just outside it, pulled in and stretched — Apple's session on the
/// material says so in as many words, and every faithful imitation is a
/// displacement map at the edge. Scattering (blur) belongs to the body,
/// which frosts what is behind it and keeps text on top readable. Between
/// them a hairline of light lies along the rim where a fixed lamp would
/// catch it, and a faint fringe of colour where the bend splits the light.
/// The body carries a thin tint — white in the light, black in the dark —
/// which is the "regular" variant's adaptive backing, and a soft shadow
/// sits under it all, growing with the slab.
///
/// The ground is a picture handed in, not the live view, so this draws
/// the same in a probe's photograph as on screen, on Sonoma as on 26, and
/// asks no permission of anyone. The lens is computed pixel by pixel here,
/// because a card is a few hundred thousand pixels and the whole look is
/// in the numbers below, where they can be read.
struct GlassSlab: View {
    #if os(macOS)
    /// The slab, already rendered by `render` — the ground seen through
    /// it, edges and all — or nil when nothing is behind it.
    var picture: NSImage?
    #endif
    var cornerRadius: CGFloat

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            #if os(macOS)
            if let picture {
                Image(nsImage: picture).resizable()
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(scheme == .dark ? Color.black.opacity(0.6) : Color.white.opacity(0.85))
            }
            #endif
        }
        // The shadow of a thick slab: soft, low, growing with the size —
        // and a tighter one right under the edge so it sits, not floats.
        .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.10), radius: 2, y: 1)
        .shadow(color: .black.opacity(scheme == .dark ? 0.45 : 0.16), radius: 16, y: 7)
    }

    #if os(macOS)
    /// How far outside the slab the ground is needed, in points: the rim
    /// samples that far out, and the shadow lies there.
    static let margin: CGFloat = 16

    /// Renders the slab.
    ///
    /// `ground` is a picture of what lies under and around the slab —
    /// `margin` points beyond it on every side — painted on the paper it
    /// sits on (a clear ground has nothing to bend). `size` is the slab's
    /// own size in points. The result is the slab alone, rounded, with
    /// nothing outside its shape.
    static func render(ground: NSImage, size: CGSize, cornerRadius: CGFloat, dark: Bool, scale: CGFloat = 2) -> NSImage? {
        let s = scale
        let gw = Int((size.width + 2 * margin) * s), gh = Int((size.height + 2 * margin) * s)
        let w = Int(size.width * s), h = Int(size.height * s)
        guard gw > 0, gh > 0, w > 0, h > 0 else { return nil }

        // The ground, twice: as it is (for the rim, which shows it bent
        // but clear) and frosted (for the body).
        guard let sharp = pixels(of: ground, width: gw, height: gh),
              let frosted = pixels(of: frost(ground, dark: dark), width: gw, height: gh) else { return nil }

        // The slab in ground pixels.
        let m = margin * s
        let cx = Double(m) + Double(w) / 2, cy = Double(m) + Double(h) / 2
        let hx = Double(w) / 2, hy = Double(h) / 2
        let r = Double(min(cornerRadius * s, CGFloat(min(hx, hy))))
        // The band the lens works in, and how far it reaches out.
        let band = Double(min(11 * s, CGFloat(min(hx, hy)) * 0.6))
        let reach = 9.0 * Double(s)
        let hairline = 1.4 * Double(s)
        // The lamp: above and a little to the left.
        let lx = -0.35, ly = 0.94
        // The shadow the slab casts on the ground, seen through the rim.
        let shadowDrop = 5.0 * Double(s), shadowSoft = 9.0 * Double(s), shadowDark = 0.38

        var out = [UInt8](repeating: 0, count: w * h * 4)
        @inline(__always) func sdf(_ px: Double, _ py: Double, _ ox: Double, _ oy: Double) -> (d: Double, nx: Double, ny: Double) {
            // Signed distance to the rounded rectangle centred at (cx+ox, cy+oy): negative inside.
            let dx = px - (cx + ox), dy = py - (cy + oy)
            let qx = abs(dx) - (hx - r), qy = abs(dy) - (hy - r)
            let mx = max(qx, 0), my = max(qy, 0)
            let outside = (mx * mx + my * my).squareRoot()
            let d = outside + min(max(qx, qy), 0) - r
            var nx: Double, ny: Double
            if qx > 0 && qy > 0 {
                nx = mx / max(outside, 1e-6) * (dx < 0 ? -1 : 1)
                ny = my / max(outside, 1e-6) * (dy < 0 ? -1 : 1)
            } else if qx > qy {
                nx = dx < 0 ? -1 : 1; ny = 0
            } else {
                nx = 0; ny = dy < 0 ? -1 : 1
            }
            return (d, nx, ny)
        }
        @inline(__always) func sample(_ buf: [UInt8], _ x: Double, _ y: Double, _ c: Int) -> Double {
            let fx = min(max(x, 0), Double(gw - 1)), fy = min(max(y, 0), Double(gh - 1))
            let x0 = Int(fx), y0 = Int(fy)
            let x1 = min(x0 + 1, gw - 1), y1 = min(y0 + 1, gh - 1)
            let tx = fx - Double(x0), ty = fy - Double(y0)
            let a = Double(buf[(y0 * gw + x0) * 4 + c]), b = Double(buf[(y0 * gw + x1) * 4 + c])
            let cc = Double(buf[(y1 * gw + x0) * 4 + c]), dd = Double(buf[(y1 * gw + x1) * 4 + c])
            return (a * (1 - tx) + b * tx) * (1 - ty) + (cc * (1 - tx) + dd * tx) * ty
        }
        @inline(__always) func smooth(_ t: Double) -> Double { let u = min(max(t, 0), 1); return u * u * (3 - 2 * u) }

        let tintR: Double = dark ? 0 : 255, tintA: Double = dark ? 0.20 : 0.20
        for y in 0..<h {
            for x in 0..<w {
                // Pixel centre in ground coordinates; y up, as the lamp is.
                let px = Double(m) + Double(x) + 0.5
                let py = Double(m) + Double(h - 1 - y) + 0.5
                let (d, nx, ny) = sdf(px, py, 0, 0)
                // Coverage: a one-pixel soft edge.
                let cover = min(max(-d + 0.5, 0), 1)
                if cover <= 0 { continue }
                let inside = -d
                // How deep into the lens band this pixel is: 0 in the body, 1 at the rim.
                let t = smooth(1 - inside / band)
                let lens = t * t
                // The rim looks outward, and the three colours bend by
                // slightly different amounts — the fringe of a real edge.
                let pull = reach * lens
                var rgb = [0.0, 0.0, 0.0]
                for c in 0..<3 {
                    let k = pull * (c == 0 ? 1.10 : c == 2 ? 0.90 : 1.0)
                    let sx = px + nx * k, sy = py + ny * k
                    let bent = sample(sharp, sx, Double(gh) - sy, c)
                    let body = sample(frosted, px, Double(gh) - py, c)
                    // The shadow on the ground beyond the edge, where the rim looks.
                    let (sd, _, _) = sdf(sx, sy, 0, -shadowDrop)
                    let shade = sd > 0 ? shadowDark * exp(-(sd / shadowSoft) * (sd / shadowSoft)) : shadowDark
                    let seen = bent * (1 - shade * lens)
                    rgb[c] = body * (1 - lens) + seen * lens
                }
                // Light caught on the curve: the near side of the rim
                // brightens toward the lamp, the far side goes a shade
                // darker, and a hairline of white lies on the very edge.
                let lit = max(0, nx * lx + ny * ly)
                let unlit = max(0, -(nx * lx + ny * ly))
                let curve = 1 + lens * (0.10 * lit - 0.07 * unlit)
                let edge = smooth(1 - inside / hairline)
                let gleam = edge * (dark ? 0.70 : 0.85) * (0.22 + 0.78 * lit * lit) + edge * 0.22 * unlit * unlit
                for c in 0..<3 {
                    var v = rgb[c] * curve
                    v = v * (1 - tintA) + tintR * tintA
                    v = v + (255 - v) * gleam
                    rgb[c] = v
                }
                let i = (y * w + x) * 4
                let a = cover
                out[i] = UInt8(min(255, max(0, rgb[0] * a)))
                out[i + 1] = UInt8(min(255, max(0, rgb[1] * a)))
                out[i + 2] = UInt8(min(255, max(0, rgb[2] * a)))
                out[i + 3] = UInt8(a * 255)
            }
        }
        guard let provider = CGDataProvider(data: Data(out) as CFData),
              let image = CGImage(
                width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
              ) else { return nil }
        return NSImage(cgImage: image, size: size)
    }

    /// The ground frosted: diffused hard, a shade richer, lifted a little.
    private static func frost(_ image: NSImage, dark: Bool) -> NSImage {
        guard let tiff = image.tiffRepresentation, let input = CIImage(data: tiff) else { return image }
        let extent = input.extent
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = input.clampedToExtent()
        blur.radius = 24
        let colour = CIFilter.colorControls()
        colour.inputImage = blur.outputImage
        colour.saturation = 1.6
        colour.brightness = dark ? -0.02 : 0.03
        guard let output = colour.outputImage?.cropped(to: extent),
              let made = GlassSlabContext.shared.createCGImage(output, from: extent) else { return image }
        return NSImage(cgImage: made, size: image.size)
    }

    /// The picture's pixels, RGBA, top row first, at exactly `width` × `height`.
    private static func pixels(of image: NSImage, width: Int, height: Int) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            var rect = CGRect(x: 0, y: 0, width: width, height: height)
            guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return false }
            context.interpolationQuality = .high
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? buffer : nil
    }
    #endif
}

#if os(macOS)
enum GlassSlabContext {
    nonisolated(unsafe) static let shared = CIContext(options: [.useSoftwareRenderer: false])
}
#endif
