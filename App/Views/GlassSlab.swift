import SwiftUI
#if os(macOS)
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
#endif

/// A slab of Liquid Glass laid over a picture of what is behind it.
///
/// Apple's session on the material ("Meet Liquid Glass", WWDC25) says what
/// makes it read as glass: *lensing* — the material "dynamically bends,
/// shapes, and concentrates light" where earlier materials only scattered
/// it — plus highlights from lights "inside an environment that behaves
/// like the world around us", and a shadow that answers what lies under
/// it. So the slab is computed as an optical body, pixel by pixel, from
/// the same model the faithful replicas converged on:
///
/// - a **thickness field** over the rounded shape: flat plateau in the
///   middle, a circular bevel `bevel` wide falling to nothing at the rim,
///   `height` high — both sized to the slab (30 % of its short side, as the
///   small controls are), so a thin card is mostly rim;
/// - a **surface normal** from that profile, tilted *inward* at the rim —
///   the liquid meniscus that squeezes the surroundings into the edge (a
///   convex lens would magnify the inside instead);
/// - **Snell refraction** of the view ray through that surface, IOR 2.0
///   with a little dispersion so red and blue land apart (the fringe);
///   the bent ray's exit point is where the ground is sampled, so what
///   lies just outside the slab is pulled into the rim, compressed;
/// - **scattering** that varies with thickness: a light frost on the
///   plateau (what keeps a formula readable on top), nearly clear at the
///   rim (what keeps the bent picture crisp), saturation lifted on the
///   transmitted light as the system materials do;
/// - **Fresnel reflection** (Schlick, F0 = 4 %) of an environment at the
///   grazing rim — the ground around the slab and a room with a lamp above
///   and to the left, which is what a real slab on a white page reflects;
/// - **specular** lobes from that lamp, a crisp inner highlight line where
///   the plateau meets the bevel on the lit side, and a hair of darkening
///   at the silhouette where the rim reflects instead of transmitting;
/// - a thin **absorption** through the body (glass is not perfectly clear,
///   and pure white on white is a card, not a slab) and the adaptive tint
///   of the "regular" variant, light or dark with the note;
/// - the **drop shadow** the slab casts, which the rim refracts as it does
///   everything else on the page.
///
/// The ground is a picture handed in, not the live view, so this draws the
/// same in a probe's photograph as on screen, on Sonoma as on 26, and asks
/// no permission of anyone. The whole look is in the numbers below, where
/// they can be read.
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
        // The shadow of a thick slab: a contact shadow right under the
        // edge so it sits, and a soft, low one that grows with the slab.
        // `Shadow` below is the same two, as the rim sees them.
        .shadow(color: .black.opacity(scheme == .dark ? Shadow.contactDark : Shadow.contact),
                radius: Shadow.contactRadius, y: Shadow.contactDrop)
        .shadow(color: .black.opacity(scheme == .dark ? Shadow.softDark : Shadow.soft),
                radius: Shadow.softRadius, y: Shadow.softDrop)
    }

    /// The two shadows, in points; the view draws them and the renderer
    /// bends them into the rim.
    nonisolated enum Shadow {
        static let contact = 0.10, contactDark = 0.35
        static let contactRadius: CGFloat = 2, contactDrop: CGFloat = 1
        static let soft = 0.12, softDark = 0.45
        static let softRadius: CGFloat = 10, softDrop: CGFloat = 7
    }

    #if os(macOS)
    /// How far outside the slab the ground is needed, in points: the rim
    /// pulls the ground in from that far out, and the shadow lies there.
    nonisolated static let margin: CGFloat = 24

    /// Renders the slab.
    ///
    /// `ground` is a picture of what lies under and around the slab —
    /// `margin` points beyond it on every side — painted on the paper it
    /// sits on (a clear ground has nothing to bend). `size` is the slab's
    /// own size in points. The result is the slab alone, rounded, with
    /// nothing outside its shape.
    nonisolated static func render(ground: NSImage, size: CGSize, cornerRadius: CGFloat, dark: Bool, scale: CGFloat = 2) -> NSImage? {
        let s = Double(scale)
        let gw = Int((size.width + 2 * margin) * scale), gh = Int((size.height + 2 * margin) * scale)
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard gw > 0, gh > 0, w > 0, h > 0 else { return nil }

        // ---- the material, in points -------------------------------------
        // The replica's lengths are authored for a large control (bevel 34,
        // height 21) and fitted to small ones at 30 % of the short side; a
        // card is small, so its rim is a third of its height each side.
        let short = Double(min(size.width, size.height))
        let bevelPt = min(max(0.30 * short, 5), 18)
        let opticalScale = bevelPt / 34
        let heightPt = 21 * opticalScale
        let ior = 2.0, dispersion = 0.14, refractScale = 4.5
        let plateauBlurPt = 7.0, midBlurPt = 3.5, rimBlurPt = 1.5, envBlurPt = 14.0
        let saturation = 1.35
        let fresnelGain = 0.65
        let specular = 0.89, specPower = 10.0, highlightWidth = 0.87, highlightBase = 0.80
        let edgeLine = 0.30, edgeDark = 0.0
        let tintAmount = 0.35
        // The "regular" variant's backing: a light grey, not white — over a
        // white page the system's material sits a shade under the paper.
        let tint: (Double, Double, Double) = dark ? (0.050, 0.055, 0.065) : (0.74, 0.76, 0.79)
        // What the body takes out of the light on its way through — in the
        // light a cool few percent, in the dark a little scattered lift.
        let absorb: (Double, Double, Double) = dark ? (-0.06, -0.06, -0.055) : (0.065, 0.055, 0.040)
        // The lamp: above and to the left, in the plane of the page.
        let lampX = -0.5, lampY = 0.866
        let roomBright = dark ? 0.40 : 1.0, roomDark = dark ? 0.10 : 1.0
        // Light the lamp scatters inside the frosted body: brighter where it
        // enters, on the lamp's side, fading across the slab.
        let scatter = dark ? 0.020 : 0.035

        // ---- the ground, three ways ---------------------------------------
        guard let rimBuf = linearPixels(of: blur(ground, radius: rimBlurPt * s), width: gw, height: gh),
              let midBuf = linearPixels(of: blur(ground, radius: midBlurPt * s), width: gw, height: gh),
              let bodyBuf = linearPixels(of: blur(ground, radius: plateauBlurPt * s), width: gw, height: gh),
              let envBuf = linearPixels(of: blur(ground, radius: envBlurPt * s), width: gw, height: gh) else { return nil }

        // ---- the slab in ground pixels ------------------------------------
        let m = Double(margin) * s
        let cx = m + Double(w) / 2, cy = m + Double(h) / 2
        let hx = Double(w) / 2, hy = Double(h) / 2
        let r = min(Double(cornerRadius) * s, min(hx, hy))
        let bevel = max(bevelPt * s, 1), height = heightPt * s
        let maxDisplacement = max(1.15 * bevel, max(12 * opticalScale * s, 3))
        let lineW = max(0.5 * s, 0.5)
        let probe = max(0.55 * bevel, max(6 * opticalScale * s, 2))
        let adaptProbe = max(1.35 * bevel, max(18 * opticalScale * s, 3))

        @inline(__always) func sdf(_ px: Double, _ py: Double, _ ox: Double, _ oy: Double) -> (d: Double, gx: Double, gy: Double) {
            // Signed distance to the rounded rectangle centred at (cx+ox, cy+oy), negative inside,
            // and the outward direction of its surface.
            let dx = px - (cx + ox), dy = py - (cy + oy)
            let qx = abs(dx) - (hx - r), qy = abs(dy) - (hy - r)
            let mx = max(qx, 0), my = max(qy, 0)
            let outside = (mx * mx + my * my).squareRoot()
            let d = outside + min(max(qx, qy), 0) - r
            var gx: Double, gy: Double
            if qx > 0 && qy > 0 {
                gx = mx / max(outside, 1e-6) * (dx < 0 ? -1 : 1)
                gy = my / max(outside, 1e-6) * (dy < 0 ? -1 : 1)
            } else if qx > qy {
                gx = dx < 0 ? -1 : 1; gy = 0
            } else {
                gx = 0; gy = dy < 0 ? -1 : 1
            }
            return (d, gx, gy)
        }
        @inline(__always) func sample(_ buf: [Float], _ x: Double, _ y: Double, _ c: Int) -> Double {
            let fx = min(max(x, 0), Double(gw - 1)), fy = min(max(y, 0), Double(gh - 1))
            let x0 = Int(fx), y0 = Int(fy)
            let x1 = min(x0 + 1, gw - 1), y1 = min(y0 + 1, gh - 1)
            let tx = fx - Double(x0), ty = fy - Double(y0)
            let a = Double(buf[(y0 * gw + x0) * 3 + c]), b = Double(buf[(y0 * gw + x1) * 3 + c])
            let cc = Double(buf[(y1 * gw + x0) * 3 + c]), dd = Double(buf[(y1 * gw + x1) * 3 + c])
            return (a * (1 - tx) + b * tx) * (1 - ty) + (cc * (1 - tx) + dd * tx) * ty
        }
        @inline(__always) func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
            let u = min(max((x - a) / (b - a), 0), 1); return u * u * (3 - 2 * u)
        }
        @inline(__always) func lum(_ r: Double, _ g: Double, _ b: Double) -> Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
        @inline(__always) func luminance(_ buf: [Float], _ x: Double, _ y: Double) -> Double {
            lum(sample(buf, x, y, 0), sample(buf, x, y, 1), sample(buf, x, y, 2))
        }
        // The shadow the slab casts on the page, as drawn by the view:
        // nowhere under the slab itself (the slab covers it there).
        @inline(__always) func shadow(_ x: Double, _ y: Double) -> Double {
            let (own, _, _) = sdf(x, y, 0, 0)
            let outside = smoothstep(-0.75 * s, 0.75 * s, own)
            if outside <= 0 { return 0 }
            let (dc, _, _) = sdf(x, y, 0, -Double(Shadow.contactDrop) * s)
            let rc = Double(Shadow.contactRadius) * s
            let (ds, _, _) = sdf(x, y, 0, -Double(Shadow.softDrop) * s)
            let rs = Double(Shadow.softRadius) * s
            let contact = (dark ? Shadow.contactDark : Shadow.contact) * (1 - smoothstep(-rc, rc, dc))
            let soft = (dark ? Shadow.softDark : Shadow.soft) * (1 - smoothstep(-rs, rs, ds))
            return outside * min(1, contact + soft)
        }

        // ---- what the lamp finds to light ---------------------------------
        // The highlight grows with the contrast of the ground around the
        // slab (a flat page gets the base amount); measured once, at the
        // centre, so one slab has one highlight.
        let gyMid = Double(gh) - cy
        let adaptGradX = luminance(envBuf, cx + adaptProbe, gyMid) - luminance(envBuf, cx - adaptProbe, gyMid)
        let adaptGradY = luminance(envBuf, cx, gyMid - adaptProbe) - luminance(envBuf, cx, gyMid + adaptProbe)
        let contrast = (adaptGradX * adaptGradX + adaptGradY * adaptGradY).squareRoot()
        let lightAdapt = 0.91 * smoothstep(0.025, 0.22, contrast)
        let sourceStrength = highlightBase + (1 - highlightBase) * lightAdapt
        let l1len = (lampX * lampX + lampY * lampY + 0.58 * 0.58).squareRoot()
        let l1 = (lampX / l1len, lampY / l1len, 0.58 / l1len)
        let l2len = (lampX * lampX + lampY * lampY + 0.48 * 0.48).squareRoot()
        let l2 = (-lampX / l2len, -lampY / l2len, 0.48 / l2len)
        let riseEnd = min(0.10, 0.25 * highlightWidth)

        var out = [UInt8](repeating: 0, count: w * h * 4)
        var rgb = [0.0, 0.0, 0.0]
        for y in 0..<h {
            for x in 0..<w {
                // Pixel centre in ground coordinates; y up, as the lamp is.
                let px = m + Double(x) + 0.5
                let py = m + Double(h - 1 - y) + 0.5
                let (d, gx, gy) = sdf(px, py, 0, 0)
                let cover = min(max(-d + 0.5, 0), 1)
                if cover <= 0 { continue }

                // The thickness field: 0 at the rim, 1 on the plateau, a
                // quarter circle between, and the slope of that surface.
                let t = min(max(-d / bevel, 0), 1)
                let ct = 1 - t
                let hh = max(1 - ct * ct, 0).squareRoot()
                let slope = (height / bevel) * (ct / max(hh, 0.10))
                // The meniscus: the normal leans inward at the rim.
                let nlen = (slope * slope + 1).squareRoot()
                let nx = -gx * slope / nlen, ny = -gy * slope / nlen, nz = 1 / nlen

                // Snell, once per colour: the view ray straight down through
                // the surface, then along the body to the page. Where it
                // lands is what this pixel shows.
                let path = height * (0.25 + 0.75 * hh) * refractScale
                // Scattering grows with thickness: clear at the rim, frosted
                // on the plateau, through three diffusions so the change is
                // gradual rather than a ring where sharp meets soft.
                let frostA = smoothstep(0.02, 0.40, t), frostB = smoothstep(0.40, 0.90, t)
                for c in 0..<3 {
                    let eta = 1 / max(ior + (c == 0 ? -dispersion : c == 2 ? dispersion : 0), 1)
                    let cosi = nz
                    let k = 1 - eta * eta * (1 - cosi * cosi)
                    var ox = 0.0, oy = 0.0
                    if k >= 0 {
                        let f = eta * cosi - k.squareRoot()
                        let rz = -eta + f * nz
                        let scale = path / max(-rz, 0.25)
                        ox = f * nx * scale; oy = f * ny * scale
                        let mag = (ox * ox + oy * oy).squareRoot()
                        if mag > 1e-4 {
                            let limited = tanh(mag / maxDisplacement) * maxDisplacement
                            ox *= limited / mag; oy *= limited / mag
                        }
                    }
                    let sx = px + ox, sy = py + oy
                    let gyy = Double(gh) - sy
                    let seen: Double
                    if frostB > 0 {
                        let mid = sample(midBuf, sx, gyy, c), body = sample(bodyBuf, sx, gyy, c)
                        seen = mid + (body - mid) * frostB
                    } else {
                        let clear = sample(rimBuf, sx, gyy, c), mid = sample(midBuf, sx, gyy, c)
                        seen = clear + (mid - clear) * frostA
                    }
                    rgb[c] = seen * (1 - shadow(sx, sy))
                }
                // Saturation, on the transmitted light only.
                let grey = lum(rgb[0], rgb[1], rgb[2])
                for c in 0..<3 { rgb[c] = grey + (rgb[c] - grey) * saturation }

                // Fresnel: at the grazing rim the surface reflects its
                // surroundings — the page around the slab, and the room.
                let fres = 0.04 + 0.96 * pow(1 - nz, 5)
                if fres > 0.045 {
                    let ex = px + gx * probe, ey = Double(gh) - (py + gy * probe)
                    var er = sample(envBuf, ex, ey, 0), eg = sample(envBuf, ex, ey, 1), eb = sample(envBuf, ex, ey, 2)
                    // The mirror at the rim faces inward (n.xy = -g), so it
                    // shows the room in that direction.
                    let toward = -(gx * lampX + gy * lampY)
                    let room = roomDark + (roomBright - roomDark) * (0.5 + 0.5 * toward)
                    er = 0.5 * er + 0.5 * room; eg = 0.5 * eg + 0.5 * room; eb = 0.5 * eb + 0.5 * room
                    let el = lum(er, eg, eb)
                    er = er * 0.9 + el * 0.1; eg = eg * 0.9 + el * 0.1; eb = eb * 0.9 + el * 0.1
                    let strength = 0.58 + 0.42 * smoothstep(0.08, 0.75, el)
                    let mix = min(fres * fresnelGain * strength, 0.82)
                    rgb[0] += (er - rgb[0]) * mix; rgb[1] += (eg - rgb[1]) * mix; rgb[2] += (eb - rgb[2]) * mix
                }

                // Two specular lobes on the bevel, the second faint and
                // opposite — light travelling around the material.
                let band = smoothstep(0.015, riseEnd, t) * (1 - smoothstep(0.61 * highlightWidth, highlightWidth, t))
                if band > 0 {
                    let d1 = max(nx * l1.0 + ny * l1.1 + nz * l1.2, 0)
                    let d2 = max(nx * l2.0 + ny * l2.1 + nz * l2.2, 0)
                    let s1 = pow(d1, max(specPower, 1))
                    let s2 = pow(d2, max(specPower * 0.78, 1)) * 0.5
                    let spec = specular * (s1 + s2) * band * sourceStrength
                    for c in 0..<3 { rgb[c] += spec }
                }

                // The silhouette: a hair darker where the rim only reflects,
                // and a crisp line of light just inside it on the lit side.
                let contour = smoothstep(lineW, 0, abs(d + 0.55 * lineW))
                // The line of light sits on the silhouette itself: nothing
                // darker lies outside it (a contour there read as a fourth
                // layer, and a moat between it and the body as a fifth).
                let line = smoothstep(2.2 * lineW, 0, abs(d + 1.4 * lineW))
                let lit = 0.26 + 0.74 * max(gx * lampX + gy * lampY, 0)
                let lineLight = edgeLine * line * lit * (dark ? 0.8 : 1)
                let across = ((px - cx) * lampX + (py - cy) * lampY) / max(abs(hx * lampX) + abs(hy * lampY), 1)
                let glow = scatter * across * hh
                for c in 0..<3 {
                    var v = rgb[c] * (1 - edgeDark * contour) + lineLight + glow
                    // Through the body: absorption with thickness, then the tint.
                    let a = c == 0 ? absorb.0 : c == 1 ? absorb.1 : absorb.2
                    v *= 1 - a * hh
                    let tc = c == 0 ? tint.0 : c == 1 ? tint.1 : tint.2
                    v += (tc - v) * tintAmount
                    rgb[c] = v
                }

                let i = (y * w + x) * 4
                out[i] = encode(rgb[0] * cover)
                out[i + 1] = encode(rgb[1] * cover)
                out[i + 2] = encode(rgb[2] * cover)
                out[i + 3] = UInt8(cover * 255)
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

    /// Linear light to an sRGB byte.
    @inline(__always) nonisolated private static func encode(_ v: Double) -> UInt8 {
        let c = min(max(v, 0), 1)
        let e = c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
        return UInt8(min(255, max(0, (e * 255).rounded())))
    }

    /// The ground diffused by `radius` pixels.
    nonisolated private static func blur(_ image: NSImage, radius: Double) -> NSImage {
        guard radius > 0.05, let tiff = image.tiffRepresentation, let input = CIImage(data: tiff) else { return image }
        let extent = input.extent
        let filter = CIFilter.gaussianBlur()
        filter.inputImage = input.clampedToExtent()
        filter.radius = Float(radius)
        guard let output = filter.outputImage?.cropped(to: extent),
              let made = GlassSlabContext.shared.createCGImage(output, from: extent) else { return image }
        return NSImage(cgImage: made, size: image.size)
    }

    /// The picture's pixels as linear light, RGB, top row first, at
    /// exactly `width` × `height`.
    nonisolated private static func linearPixels(of image: NSImage, width: Int, height: Int) -> [Float]? {
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
        guard ok else { return nil }
        var linear = [Float](repeating: 0, count: width * height * 3)
        for i in 0..<(width * height) {
            linear[i * 3] = toLinear[Int(buffer[i * 4])]
            linear[i * 3 + 1] = toLinear[Int(buffer[i * 4 + 1])]
            linear[i * 3 + 2] = toLinear[Int(buffer[i * 4 + 2])]
        }
        return linear
    }

    nonisolated private static let toLinear: [Float] = (0..<256).map { i in
        let c = Double(i) / 255
        return Float(c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4))
    }
    #endif
}

#if os(macOS)
enum GlassSlabContext {
    nonisolated(unsafe) static let shared = CIContext(options: [.useSoftwareRenderer: false])
}
#endif
