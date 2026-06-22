import SwiftUI

/// Monochrome, distraction-free tokens. Everything is grayscale (semantic
/// system colors) so the app stays calm in light and dark; the only "accent"
/// is contrast and weight, never hue.
enum Theme {
    static let readerMaxWidth: CGFloat = 760
    static let corner: CGFloat = 10
    static let cardCorner: CGFloat = 12
}

extension Color {
    static let ink = Color.primary
    static let subtle = Color.secondary
    static let hairline = Color.primary.opacity(0.10)
    static let cardFill = Color.primary.opacity(0.04)
    static let selectionFill = Color.primary.opacity(0.09)
}
