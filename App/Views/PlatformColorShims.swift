#if canImport(UIKit)
import UIKit

/// AppKit's names for the system colours, on UIKit, so that code written for
/// the Mac reads the same on the iPad.
extension UIColor {
    static var labelColor: UIColor { .label }
    static var secondaryLabelColor: UIColor { .secondaryLabel }
    static var tertiaryLabelColor: UIColor { .tertiaryLabel }
    static var quaternaryLabelColor: UIColor { .quaternaryLabel }
    static var controlAccentColor: UIColor { .tintColor }
    static var windowBackgroundColor: UIColor { .systemBackground }
    static var textBackgroundColor: UIColor { .systemBackground }
    static var textColor: UIColor { .label }
}
import SwiftUI

extension Color {
    /// `Color(nsColor:)`, on UIKit — the same platform colour by the other name.
    init(nsColor: UIColor) { self.init(uiColor: nsColor) }
}
#endif
