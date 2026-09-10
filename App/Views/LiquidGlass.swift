import SwiftUI

/// The app's glass surfaces.
///
/// This SDK's SwiftUI ships the glass *button* styles and nothing else — there
/// is no `glassEffect`, no `GlassEffectContainer`, no `Glass` — so the app's
/// surfaces are assembled here: a blurred backdrop so what is behind shows
/// through out of focus, a pale body over it so the surface is a thing rather
/// than a hole, and a soft shadow so it sits above the ground rather than in
/// it.
///
/// There was an edge on these once — a bright stroke round the rim, and a
/// sheen across the top, meant to be the specular highlight that separates
/// glass from frosted plastic. Both are gone. Drawn as a stroke the highlight
/// does not read as light caught on a curve, it reads as a white outline round
/// every panel, and a wrong highlight is worse than none: the eye takes it for
/// a border and stops looking for glass. Doing it properly needs the thing
/// this SDK does not expose, which bends what is behind the surface instead of
/// painting a line on top of it. Until then the blur and the shadow carry it,
/// and they do that honestly.
enum Glass {
    /// A large surface: a column, a panel, a sheet.
    case pane
    /// A small surface that sits on a pane: a button, a chip, a bar.
    case control
    /// A surface floating over the page, which needs to be read through.
    case floating

    /// How much of its own body the glass has. Lower is more transparent.
    ///
    /// Low enough that what is behind still reads through it. A pane keeps
    /// more than the rest because it is what long passages of text are read
    /// on, and glass you cannot read through is a window in the wrong place.
    var body: Double {
        switch self {
        case .pane: 0.5
        case .control: 0.14
        case .floating: 0.3
        }
    }

    /// Whether the surface blurs what is behind it for itself.
    ///
    /// A pane does not, and this matters more than it sounds. The window's
    /// ground is already a material, and a material laid over a material
    /// blurs the same desktop twice: the panes came out milky while the gaps
    /// between them and the strip above them — blurred once — stayed clear and
    /// a different colour. The seam between the two ran round every rounded
    /// corner, which is what put that flare in the join between two panels.
    /// One blur for the window, and the panes are lighter patches on it.
    ///
    /// Something floating over the page is a separate piece of glass laid on
    /// top of text, and needs its own blur to be read through.
    var blursOwnBackdrop: Bool {
        switch self {
        case .pane: false
        case .control, .floating: true
        }
    }

    /// What lifts it off whatever it is lying on, in two layers: one tight
    /// against the edge and one spread wide beneath it.
    ///
    /// With no edge drawn on these, the shadow is the only thing saying where
    /// one surface stops and the next begins — and one wide shadow could not
    /// do it. Over a dark desktop it looked like plenty; over a white app it
    /// spread so far that it was no edge at all, and every panel dissolved
    /// into the white behind it. The tight layer is what draws the boundary. A
    /// line would too, but a line is a line, and this is the shadow the panel
    /// would actually cast.
    var shadows: [(opacity: Double, radius: CGFloat, y: CGFloat)] {
        switch self {
        case .pane: [(0.11, 2.5, 0.5), (0.05, 16, 4)]
        case .control: [(0.1, 1.5, 0.5), (0.06, 6, 2)]
        case .floating: [(0.14, 3, 1), (0.12, 20, 6)]
        }
    }
}

extension View {
    /// Draws the view as a piece of glass.
    func liquidGlass(_ kind: Glass = .pane, in shape: some InsettableShape) -> some View {
        modifier(LiquidGlass(kind: kind, shape: shape))
    }

    /// The same, on a capsule — what every control in the app is.
    func liquidGlass(_ kind: Glass = .control) -> some View {
        modifier(LiquidGlass(kind: kind, shape: Capsule(style: .continuous)))
    }
}

private extension View {
    /// Casts several shadows, tightest first.
    func shadows(_ layers: [(opacity: Double, radius: CGFloat, y: CGFloat)]) -> some View {
        layers.reduce(AnyView(self)) { view, layer in
            AnyView(
                view.shadow(
                    color: .black.opacity(layer.opacity),
                    radius: layer.radius,
                    y: layer.y
                )
            )
        }
    }
}

private struct LiquidGlass<S: InsettableShape>: ViewModifier {
    let kind: Glass
    let shape: S

    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content.background { glass }
    }

    private var glass: some View {
        ZStack {
            // What is behind, out of focus — for the surfaces that own their
            // own backdrop.
            if kind.blursOwnBackdrop {
                shape.fill(.ultraThinMaterial)
            }
            // The glass's own body. White in the light, and a lifted grey in
            // the dark — a dark surface tinted white goes milky, not glassy.
            shape.fill(
                scheme == .dark
                    ? Color.white.opacity(kind.body * 0.14)
                    : Color.white.opacity(kind.body)
            )
        }
        .compositingGroup()
        .shadows(kind.shadows)
    }
}

#if os(macOS)
import AppKit

extension View {
    /// Lets the desktop up through the window.
    ///
    /// A material blurs whatever is behind it, and behind a window is either
    /// the desktop or the window's own opaque background. By default it is the
    /// second, which blurs a flat grey and comes out as flat grey — the glass
    /// had nothing to be glass against. Clearing the window's background is
    /// what the apps this is modelled on do, and what turns the panels from
    /// white cards into something with the wallpaper moving behind it.
    func translucentWindow() -> some View {
        background(TranslucentWindow().frame(width: 0, height: 0).allowsHitTesting(false))
    }
}

private struct TranslucentWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Opener() }
    func updateNSView(_ view: NSView, context: Context) {}

    final class Opener: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            // Without this the window loses the shadow that separates it from
            // whatever it is sitting on, and a translucent window with no
            // shadow is a smudge.
            window.hasShadow = true
        }
    }
}
#endif
