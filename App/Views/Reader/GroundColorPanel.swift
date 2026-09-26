#if os(macOS)
import AppKit

/// The system colour panel, choosing the Custom tint's ground.
///
/// A colour well cannot live in a menu, and the tint is chosen from one, so
/// the panel is what the menu opens. It writes the colour where Settings
/// does — the defaults, as `#rrggbb` — and every open reader hears it there
/// (`ReaderScreen`'s `@AppStorage`), so the page follows the colour as it is
/// dragged.
@MainActor
final class GroundColorPanel: NSObject {
    static let shared = GroundColorPanel()

    func show(hex: String) {
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.isContinuous = true
        let colour = ReaderConfiguration.TintColor(hex: hex) ?? .night
        panel.color = NSColor(srgbRed: colour.red, green: colour.green, blue: colour.blue, alpha: 1)
        panel.setTarget(self)
        panel.setAction(#selector(changed(_:)))
        panel.orderFront(nil)
    }

    @objc private func changed(_ sender: NSColorPanel) {
        guard let resolved = sender.color.usingColorSpace(.sRGB) else { return }
        let colour = ReaderConfiguration.TintColor(
            Double(resolved.redComponent), Double(resolved.greenComponent), Double(resolved.blueComponent)
        )
        let key = ReaderConfiguration.customTintKey
        if UserDefaults.standard.string(forKey: key) != colour.hex {
            UserDefaults.standard.set(colour.hex, forKey: key)
        }
    }
}
#endif
