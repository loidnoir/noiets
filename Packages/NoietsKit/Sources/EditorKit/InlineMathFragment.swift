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

/// Draws its line of text normally, with typeset math painted over the
/// collapsed, width-reserved `$…$` spans. Entering the line reverts to source.
final class InlineMathFragment: NSTextLayoutFragment {
    struct MathSpan {
        let relativeLocation: Int // span start, relative to the element start
        let image: NSImage
    }

    private let spans: [MathSpan]

    init(textElement: NSTextElement, range: NSTextRange?, spans: [MathSpan]) {
        self.spans = spans
        super.init(textElement: textElement, range: range)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var renderingSurfaceBounds: CGRect {
        // Tall images (fractions, sums) can exceed the line box.
        let maxHeight = spans.map(\.image.size.height).max() ?? 0
        return super.renderingSurfaceBounds.insetBy(dx: 0, dy: -maxHeight)
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        super.draw(at: point, in: context)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        for span in spans {
            guard let line = textLineFragments.first(where: {
                $0.characterRange.contains(span.relativeLocation)
            }) else { continue }
            let anchor = line.locationForCharacter(at: span.relativeLocation)
            let bounds = line.typographicBounds
            let size = span.image.size
            let rect = CGRect(
                x: point.x + bounds.origin.x + anchor.x + InlineMath.horizontalPadding,
                y: point.y + bounds.origin.y + (bounds.height - size.height) / 2,
                width: size.width, height: size.height
            )
            span.image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                            respectFlipped: true,
                            hints: [.interpolation: NSImageInterpolation.high.rawValue])
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}
