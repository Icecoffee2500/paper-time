import SwiftUI
#if os(macOS)
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
#endif

/// A slab of glass laid over a picture of what is behind it.
///
/// The system's glass on this SDK is a black box: it bends what is behind
/// it, but its body is set for a window's chrome, and over a white page it
/// reads as a white card. This is the material as iOS 27 tuned it, built
/// from its parts so each can be seen and set: the ground behind, diffused
/// hard and made a little richer so shapes survive as colour rather than
/// as edges; a thin body over that, so the slab is a thing and not a hole;
/// a darkened band at the rim, which is what a thick edge does to light
/// passing through it; and a specular line along the top, brightest where
/// the light would fall, fading to nothing underneath. The shadow is soft
/// and low. Nothing here is a filter on the live view — the ground is a
/// picture handed in — so it draws the same in a probe's photograph as on
/// screen, and on Sonoma as on 26.
struct GlassSlab<S: InsettableShape>: View {
    #if os(macOS)
    /// What is behind the slab, already diffused (`GlassSlab.diffuse`).
    var ground: NSImage?
    #endif
    var shape: S

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            #if os(macOS)
            if let ground {
                Image(nsImage: ground)
                    .resizable()
                    .scaledToFill()
            }
            #endif
            // The body: thin. Enough that the slab is not a hole, not so
            // much that it is a card.
            shape.fill(scheme == .dark ? Color.black.opacity(0.22) : Color.white.opacity(0.36))
            // The rim, darkened: the edge of a thick slab bends the light
            // away and goes a shade darker than the middle.
            shape
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.black.opacity(0.03), Color.black.opacity(0.09)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 4
                )
                .blur(radius: 2.5)
                .clipShape(shape)
            // The specular line: light caught on the top edge, fading down
            // the sides to nothing at the bottom.
            shape
                .strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: Color.white.opacity(scheme == .dark ? 0.55 : 0.95), location: 0),
                            .init(color: Color.white.opacity(0.35), location: 0.35),
                            .init(color: Color.white.opacity(0.0), location: 1)
                        ],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 1
                )
            // The outline that keeps the slab from melting into a pale ground.
            shape.strokeBorder(Color.black.opacity(scheme == .dark ? 0.35 : 0.10), lineWidth: 0.5)
        }
        .clipShape(shape)
        .shadow(color: .black.opacity(0.10), radius: 3, y: 1)
        .shadow(color: .black.opacity(0.16), radius: 18, y: 8)
    }

    #if os(macOS)
    /// The ground as the glass shows it: diffused hard, a shade richer.
    /// `image` is a picture of what lies under the slab, at the slab's size.
    static func diffuse(_ image: NSImage) -> NSImage? {
        let context = GlassSlabContext.shared
        guard let tiff = image.tiffRepresentation, let input = CIImage(data: tiff) else { return nil }
        let extent = input.extent
        // Clamp so the blur does not fade to transparent at the edges.
        let clamped = input.clampedToExtent()
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = clamped
        blur.radius = 22
        let colour = CIFilter.colorControls()
        colour.inputImage = blur.outputImage
        colour.saturation = 1.55
        colour.brightness = 0.02
        guard let output = colour.outputImage?.cropped(to: extent),
                let made = context.createCGImage(output, from: extent) else { return nil }
        return NSImage(cgImage: made, size: image.size)
    }
    #endif
}

#if os(macOS)
enum GlassSlabContext {
    nonisolated(unsafe) static let shared = CIContext(options: [.useSoftwareRenderer: false])
}
#endif
