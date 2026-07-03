import AppKit

extension NSTextLayoutFragment {
    /// Width of the centered writing column (the text container tracks it).
    var columnWidth: CGFloat {
        textLayoutManager?.textContainer?.size.width ?? 760
    }
}

/// Column-wide background band behind code lines; glyphs draw as usual.
/// The block's first/last lines round their outer corners (the band color is
/// opaque, so extending a rounded band into the neighbor line hides the
/// unrounded edge seamlessly).
final class CodeBandFragment: NSTextLayoutFragment {
    private let theme: EditorTheme
    private let roundTop: Bool
    private let roundBottom: Bool
    private let radius: CGFloat = 4 // matches the inline-code chips

    init(textElement: NSTextElement, range: NSTextRange?, theme: EditorTheme,
         roundTop: Bool = false, roundBottom: Bool = false) {
        self.theme = theme
        self.roundTop = roundTop
        self.roundBottom = roundBottom
        super.init(textElement: textElement, range: range)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var renderingSurfaceBounds: CGRect {
        super.renderingSurfaceBounds.union(bandRect)
    }

    private var bandRect: CGRect {
        // Band edges sit on the text column, flush with the other components;
        // the code text itself indents inside (paragraph head indent, which
        // also shifts the fragment origin — compensate so the band stays put).
        // The opening line leaves an 8pt gap above the band, clear of the
        // preceding text (the fence's paragraphSpacingBefore covers it).
        let pad = textLayoutManager?.textContainer?.lineFragmentPadding ?? 5
        let topGap: CGFloat = roundTop ? 8 : 0
        return CGRect(x: pad - layoutFragmentFrame.minX, y: topGap,
                      width: columnWidth - pad * 2,
                      height: layoutFragmentFrame.height - topGap)
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        context.saveGState()
        context.setFillColor(theme.codeBackground.cgColor)
        var rect = bandRect.offsetBy(dx: point.x, dy: point.y)
        if !roundTop, !roundBottom {
            context.fill(rect)
        } else {
            if !roundBottom { rect.size.height += radius } // corners hide under the next band
            if !roundTop {
                rect.origin.y -= radius
                rect.size.height += radius
            }
            context.addPath(CGPath(roundedRect: rect, cornerWidth: radius,
                                   cornerHeight: radius, transform: nil))
            context.fillPath()
        }
        context.restoreGState()
        super.draw(at: point, in: context)
    }
}

/// Replaces an image-only (or display-math) line with the rendered image.
/// The source text stays in the buffer; entering the line reverts to source.
final class ImageLineFragment: NSTextLayoutFragment {
    private let theme: EditorTheme
    private let image: NSImage
    private let isMath: Bool
    private let padding: CGFloat = 8

    init(textElement: NSTextElement, range: NSTextRange?, theme: EditorTheme,
         image: NSImage, isMath: Bool = false) {
        self.theme = theme
        self.image = image
        self.isMath = isMath
        super.init(textElement: textElement, range: range)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var drawSize: CGSize {
        let natural = image.size
        guard natural.width > 0, natural.height > 0 else { return .zero }
        let maxWidth: CGFloat = isMath ? 640 : 560
        let maxHeight: CGFloat = isMath ? 200 : 420
        let scale = min(1, min(maxWidth / natural.width, maxHeight / natural.height))
        return CGSize(width: natural.width * scale, height: natural.height * scale)
    }

    override var layoutFragmentFrame: CGRect {
        var frame = super.layoutFragmentFrame
        frame.size.height = drawSize.height + padding * 2
        return frame
    }

    override var renderingSurfaceBounds: CGRect {
        let size = drawSize
        return super.renderingSurfaceBounds.union(
            CGRect(x: 0, y: 0, width: size.width + padding, height: size.height + padding * 2)
        )
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        // No super.draw: the raw source stays hidden; only the image renders.
        let size = drawSize
        guard size.width > 0 else { return }
        let rect = CGRect(x: point.x, y: point.y + padding, width: size.width, height: size.height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                   respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// One table row drawn on a shared column grid (widths computed table-wide).
final class TableRowFragment: NSTextLayoutFragment {
    private let theme: EditorTheme
    private let cells: [String]
    private let isHeader: Bool
    private let columns: [CGFloat]
    private let rowHeight: CGFloat = 30

    init(textElement: NSTextElement, range: NSTextRange?, theme: EditorTheme,
         cells: [String], isHeader: Bool, columns: [CGFloat]) {
        self.theme = theme
        self.cells = cells
        self.isHeader = isHeader
        self.columns = columns
        super.init(textElement: textElement, range: range)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var layoutFragmentFrame: CGRect {
        var frame = super.layoutFragmentFrame
        frame.size.height = rowHeight
        return frame
    }

    override var renderingSurfaceBounds: CGRect {
        let width = columns.reduce(0, +) + 16
        return super.renderingSurfaceBounds.union(
            CGRect(x: 0, y: 0, width: max(width, 200), height: rowHeight)
        )
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        // Custom grid rendering only — no raw glyphs.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)

        let font = isHeader
            ? NSFont.systemFont(ofSize: theme.baseFontSize - 1, weight: .semibold)
            : NSFont.systemFont(ofSize: theme.baseFontSize - 1)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: isHeader ? theme.textColor : theme.textColor.withAlphaComponent(0.92),
        ]

        var x = point.x + 2
        for (index, cell) in cells.enumerated() {
            let width = index < columns.count ? columns[index] : 100
            let cellRect = CGRect(x: x + 8, y: point.y + 6, width: width - 20, height: rowHeight - 10)
            (cell as NSString).draw(in: cellRect, withAttributes: attrs)
            x += width
        }

        // Hairline under the row (stronger under the header).
        let totalWidth = max(columns.reduce(0, +), 120)
        let lineRect = CGRect(x: point.x + 2, y: point.y + rowHeight - 1,
                              width: totalWidth, height: isHeader ? 1.5 : 1)
        theme.mutedColor.withAlphaComponent(isHeader ? 0.55 : 0.25).setFill()
        lineRect.fill()

        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Accent bar alongside blockquote lines (glyphs still draw).
final class QuoteBarFragment: NSTextLayoutFragment {
    private let theme: EditorTheme

    init(textElement: NSTextElement, range: NSTextRange?, theme: EditorTheme) {
        self.theme = theme
        super.init(textElement: textElement, range: range)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var renderingSurfaceBounds: CGRect {
        super.renderingSurfaceBounds.union(
            CGRect(x: -24, y: 0, width: 28, height: layoutFragmentFrame.height))
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        context.saveGState()
        // The fragment origin follows the paragraph indent, so anchor the bar
        // to the bullet-dot column; span exactly the text's visual extent
        // (caps to descenders) off the real rendered baseline, so bar and
        // text are centered on each other by construction.
        let font = NSFont.systemFont(ofSize: theme.baseFontSize)
        let dashHalf = ("-" as NSString)
            .size(withAttributes: [.font: NSFont.systemFont(ofSize: theme.baseFontSize,
                                                            weight: .bold)]).width / 2
        let padding = textLayoutManager?.textContainer?.lineFragmentPadding ?? 5
        // Wrapped quotes span several visual lines — run the bar from the
        // first line's caps to the last line's descenders.
        let firstLine = textLineFragments.first
        let lastLine = textLineFragments.last
        let firstBaseline = (firstLine?.typographicBounds.origin.y ?? 0)
            + (firstLine?.glyphOrigin.y ?? font.ascender)
        let lastBaseline = (lastLine?.typographicBounds.origin.y ?? 0)
            + (lastLine?.glyphOrigin.y ?? font.ascender)
        let top = firstBaseline - font.capHeight - 1.5
        let bottom = lastBaseline - font.descender + 1.5 // descender is negative
        let bar = CGRect(x: point.x - layoutFragmentFrame.minX + padding + dashHalf - 1.5,
                         y: point.y + top, width: 3, height: bottom - top)
        context.addPath(CGPath(roundedRect: bar, cornerWidth: 1.5, cornerHeight: 1.5,
                               transform: nil))
        context.setFillColor(theme.mutedColor.withAlphaComponent(0.5).cgColor)
        context.fillPath()
        context.restoreGState()
        super.draw(at: point, in: context)
    }
}

/// A horizontal rule renders as an actual thin line.
final class RuleFragment: NSTextLayoutFragment {
    private let theme: EditorTheme

    init(textElement: NSTextElement, range: NSTextRange?, theme: EditorTheme) {
        self.theme = theme
        super.init(textElement: textElement, range: range)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var layoutFragmentFrame: CGRect {
        var frame = super.layoutFragmentFrame
        frame.size.height = 24
        return frame
    }

    override var renderingSurfaceBounds: CGRect {
        super.renderingSurfaceBounds.union(CGRect(x: 0, y: 0, width: columnWidth, height: 24))
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        context.saveGState()
        context.setFillColor(theme.mutedColor.withAlphaComponent(0.35).cgColor)
        context.fill(CGRect(x: point.x, y: point.y + 12, width: columnWidth, height: 1))
        context.restoreGState()
    }
}

/// The |---|---| row collapses to a small gap (the header hairline stands in).
final class TableDelimiterFragment: NSTextLayoutFragment {
    private let theme: EditorTheme

    init(textElement: NSTextElement, range: NSTextRange?, theme: EditorTheme) {
        self.theme = theme
        super.init(textElement: textElement, range: range)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var layoutFragmentFrame: CGRect {
        var frame = super.layoutFragmentFrame
        frame.size.height = 4
        return frame
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        // Intentionally empty.
    }
}
