import AppKit
import RenderKit

/// Shared math-image lookup so the highlighter (which reserves the span's
/// width) and the layout fragment (which draws) always agree on the image.
@MainActor
enum InlineMath {
    nonisolated static let horizontalPadding: CGFloat = 3

    static func image(latex: String, display: Bool, theme: EditorTheme) -> NSImage? {
        let trimmed = latex.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return MathRenderer.image(
            latex: trimmed,
            fontSize: display ? theme.baseFontSize + 1 : theme.baseFontSize,
            textColor: theme.textColor,
            display: display
        )
    }

    static func reservedWidth(for image: NSImage) -> CGFloat {
        image.size.width + horizontalPadding * 2
    }
}

/// Draws its line of text normally, then paints overlays on top of collapsed
/// markup runs: typeset math over `$…$` spans, a round dot over a hidden list
/// dash. Entering the line reverts to source.
final class OverlayLineFragment: NSTextLayoutFragment {
    enum OverlayKind {
        case image(NSImage)
        case bullet
        case checkbox(checked: Bool)
        case chip(width: CGFloat) // rounded background behind an inline-code span
    }

    nonisolated static let chipPadding: CGFloat = 4.5

    struct Span {
        let relativeLocation: Int // span start, relative to the element start
        let kind: OverlayKind
    }

    private let theme: EditorTheme
    private let spans: [Span]

    init(textElement: NSTextElement, range: NSTextRange?, theme: EditorTheme, spans: [Span]) {
        self.theme = theme
        self.spans = spans
        super.init(textElement: textElement, range: range)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var renderingSurfaceBounds: CGRect {
        // Tall math images (fractions, sums) can exceed the line box, and a
        // check circle can poke slightly left of the fragment.
        let maxHeight = spans.compactMap { span -> CGFloat? in
            if case .image(let image) = span.kind { return image.size.height }
            return nil
        }.max() ?? 0
        return super.renderingSurfaceBounds.insetBy(dx: -8, dy: -maxHeight)
    }

    private func lineFragment(containing location: Int) -> NSTextLineFragment? {
        textLineFragments.first { $0.characterRange.contains(location) }
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        // Chip backgrounds go under the glyphs.
        for span in spans {
            guard case .chip(let width) = span.kind,
                  let line = lineFragment(containing: span.relativeLocation) else { continue }
            let anchor = line.locationForCharacter(at: span.relativeLocation)
            let bounds = line.typographicBounds
            let height = bounds.height - 3
            // The collapsed backtick has ~zero width, so the anchor is the
            // code text itself; the chip pads out into the whitespace around
            // it rather than pushing the text off the shared column.
            let rect = CGRect(
                x: point.x + bounds.origin.x + anchor.x - Self.chipPadding,
                y: point.y + bounds.origin.y + (bounds.height - height) / 2,
                width: width, height: height
            )
            theme.codeBackground.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        }
        NSGraphicsContext.restoreGraphicsState()

        super.draw(at: point, in: context)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        for span in spans {
            guard let line = lineFragment(containing: span.relativeLocation) else { continue }
            let anchor = line.locationForCharacter(at: span.relativeLocation)
            let bounds = line.typographicBounds
            // Markers center on the x-height midline (where a strikethrough
            // sits), anchored to the real rendered baseline.
            let font = NSFont.systemFont(ofSize: theme.baseFontSize)
            let baseline = bounds.origin.y + line.glyphOrigin.y
            let textMidline = baseline - font.xHeight / 2

            switch span.kind {
            case .chip:
                break // drawn above, under the glyphs
            case .image(let image):
                let size = image.size
                let rect = CGRect(
                    x: point.x + bounds.origin.x + anchor.x + InlineMath.horizontalPadding,
                    y: point.y + bounds.origin.y + (bounds.height - size.height) / 2,
                    width: size.width, height: size.height
                )
                image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                           respectFlipped: true,
                           hints: [.interpolation: NSImageInterpolation.high.rawValue])
            case .bullet:
                // Same disc as a done checkbox, accent-colored, centered
                // where the "-" glyph sat.
                let dashWidth = ("-" as NSString)
                    .size(withAttributes: [.font: NSFont.systemFont(ofSize: theme.baseFontSize,
                                                                    weight: .bold)]).width
                let radius: CGFloat = theme.baseFontSize * 0.2015
                let center = CGPoint(
                    x: point.x + bounds.origin.x + anchor.x + dashWidth / 2,
                    y: point.y + textMidline
                )
                theme.accentColor.setFill()
                NSBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius,
                                            width: radius * 2, height: radius * 2)).fill()
            case .checkbox(let checked):
                // Centered exactly where a bullet dot sits, so the marker
                // column and text starts line up across list styles.
                let dashWidth = ("-" as NSString)
                    .size(withAttributes: [.font: NSFont.systemFont(ofSize: theme.baseFontSize,
                                                                    weight: .bold)]).width
                let radius: CGFloat = theme.baseFontSize * 0.2015
                let center = CGPoint(
                    x: point.x + bounds.origin.x + anchor.x + dashWidth / 2,
                    y: point.y + textMidline
                )
                let rect = CGRect(x: center.x - radius, y: center.y - radius,
                                  width: radius * 2, height: radius * 2)
                if checked {
                    theme.mutedColor.setFill()
                    NSBezierPath(ovalIn: rect).fill()
                } else {
                    theme.accentColor.setStroke()
                    let path = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
                    path.lineWidth = 1.5
                    path.stroke()
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}
