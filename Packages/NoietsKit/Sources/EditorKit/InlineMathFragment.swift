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
    }

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
        // Tall math images (fractions, sums) can exceed the line box.
        let maxHeight = spans.compactMap { span -> CGFloat? in
            if case .image(let image) = span.kind { return image.size.height }
            return nil
        }.max() ?? 0
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

            switch span.kind {
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
                // Centered where the "-" glyph sat.
                let dashWidth = ("-" as NSString)
                    .size(withAttributes: [.font: NSFont.systemFont(ofSize: theme.baseFontSize,
                                                                    weight: .bold)]).width
                let radius: CGFloat = theme.baseFontSize * 0.16
                let center = CGPoint(
                    x: point.x + bounds.origin.x + anchor.x + dashWidth / 2,
                    y: point.y + bounds.origin.y + bounds.height / 2
                )
                theme.accentColor.setFill()
                NSBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius,
                                            width: radius * 2, height: radius * 2)).fill()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}
