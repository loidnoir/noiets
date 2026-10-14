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
class OverlayLineFragment: NSTextLayoutFragment {
    enum OverlayKind {
        case image(NSImage)
        case bullet
        case checkbox(checked: Bool)
        case chip(range: NSRange) // content range, relative to the text element
        case tag(range: NSRange, colour: NSColor)
    }

    nonisolated static let chipPadding: CGFloat = InlineChipStyle.horizontalPadding

    struct Span {
        let relativeLocation: Int // span start, relative to the element start
        let kind: OverlayKind
    }

    private let theme: EditorTheme
    let spans: [Span]

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

    /// One chip rect per visual row. Using TextKit's character positions keeps
    /// the background aligned with actual glyphs and lets long code spans wrap
    /// without painting across the editor column.
    func chipRects(for range: NSRange, at point: CGPoint) -> [CGRect] {
        textLineFragments.compactMap { line in
            let segment = NSIntersectionRange(range, line.characterRange)
            guard segment.length > 0 else { return nil }

            let bounds = line.typographicBounds
            let start = line.locationForCharacter(at: segment.location).x
            let end = line.locationForCharacter(at: NSMaxRange(segment)).x
            let height = bounds.height - 3
            return CGRect(
                x: point.x + bounds.origin.x + min(start, end) - Self.chipPadding,
                y: point.y + bounds.origin.y + (bounds.height - height) / 2,
                width: max(abs(end - start), 1) + Self.chipPadding * 2,
                height: height
            )
        }
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        // Chip backgrounds go under the glyphs.
        for span in spans {
            let range: NSRange
            let colour: NSColor
            switch span.kind {
            case .chip(let content): range = content; colour = theme.codeBackground
            case .tag(let content, let identity): range = content; colour = InlineChipStyle.tagBackground(identity)
            default: continue
            }
            for rect in chipRects(for: range, at: point) {
                colour.setFill()
                NSBezierPath(roundedRect: rect, xRadius: InlineChipStyle.cornerRadius, yRadius: InlineChipStyle.cornerRadius).fill()
            }
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
            let font = AppFonts.font(ofSize: theme.baseFontSize)
            let baseline = bounds.origin.y + line.glyphOrigin.y
            let textMidline = baseline - font.xHeight / 2

            switch span.kind {
            case .chip, .tag:
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
                    .size(withAttributes: [.font: AppFonts.font(ofSize: theme.baseFontSize,
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
                    .size(withAttributes: [.font: AppFonts.font(ofSize: theme.baseFontSize,
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
