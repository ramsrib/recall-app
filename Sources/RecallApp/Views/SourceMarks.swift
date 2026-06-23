import SwiftUI

// Monochrome, vector recreations of the Claude and Codex marks for the sidebar —
// drawn in-app (no bundled brand assets) so they stay on the grayscale theme and
// render crisply at any size. As Shapes used directly, they fill/stroke with the
// current foreground style, so they tint with the row like an SF Symbol does.

/// Claude — a radial "spark": evenly spaced rays around a center gap. Drawn as
/// line segments and STROKED (not filled): a plain filled Shape in an unselected
/// sidebar row resolves to a lighter, secondary-ish style, whereas a stroked
/// shape gets full-primary ink (matching the SF Symbols and the Codex mark).
struct ClaudeMark: Shape {
    var spokes = 12

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        let inner = r * 0.26          // empty center
        let outer = r * 1.0
        var path = Path()
        for i in 0..<spokes {
            let a = (Double(i) / Double(spokes)) * 2 * .pi - .pi / 2  // first ray points up
            let dx = cos(a), dy = sin(a)
            path.move(to: CGPoint(x: c.x + dx * inner, y: c.y + dy * inner))
            path.addLine(to: CGPoint(x: c.x + dx * outer, y: c.y + dy * outer))
        }
        return path
    }
}

/// Codex — a terminal window with a `>` prompt + cursor. A simplified stand-in
/// for the OpenAI mark (too intricate to read at ~15pt). Meant to be stroked.
struct CodexMark: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height)
        let ox = rect.midX - s / 2, oy = rect.midY - s / 2
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }
        var p = Path()
        p.addRoundedRect(
            in: CGRect(x: ox + s * 0.05, y: oy + s * 0.12, width: s * 0.90, height: s * 0.76),
            cornerSize: CGSize(width: s * 0.18, height: s * 0.18))
        // ">" prompt
        p.move(to: pt(0.30, 0.34)); p.addLine(to: pt(0.49, 0.50)); p.addLine(to: pt(0.30, 0.66))
        // cursor underscore
        p.move(to: pt(0.55, 0.66)); p.addLine(to: pt(0.72, 0.66))
        return p
    }
}

/// The sidebar icon for a source, sized to sit alongside the SF Symbol rows.
struct SourceIcon: View {
    let source: SessionSource
    var size: CGFloat = 15

    var body: some View {
        switch source {
        case .claude:
            ClaudeMark()
                .stroke(style: StrokeStyle(lineWidth: size * 0.12, lineCap: .round))
                .frame(width: size, height: size)
        case .codex:
            CodexMark()
                .stroke(style: StrokeStyle(lineWidth: size * 0.10, lineCap: .round, lineJoin: .round))
                .frame(width: size, height: size)
        }
    }
}
