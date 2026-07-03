import AppKit

extension NSTextLayoutFragment {
    /// Width of the centered writing column (the text container tracks it).
    var columnWidth: CGFloat {
        textLayoutManager?.textContainer?.size.width ?? 760
    }
}

/// Column-wide background band behind code lines; glyphs draw as usual.
final class CodeBandFragment: NSTextLayoutFragment {
    private let theme: EditorTheme

    init(textElement: NSTextElement, range: NSTextRange?, theme: EditorTheme) {
        self.theme = theme
        super.init(textElement: textElement, range: range)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var renderingSurfaceBounds: CGRect {
        super.renderingSurfaceBounds.union(bandRect)
    }

    private var bandRect: CGRect {
        // Band spans the writing column only — never past it to the window edge.
        CGRect(x: -8, y: 0, width: columnWidth + 16, height: layoutFragmentFrame.height)
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        context.saveGState()
        context.setFillColor(theme.codeBackground.cgColor)
        context.fill(bandRect.offsetBy(dx: point.x, dy: point.y))
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
        // to the column start; center it on the glyphs' visual extent
        // (mirrors theme.baseFont, which is MainActor-bound).
        let font = NSFont.systemFont(ofSize: theme.baseFontSize)
        let height = layoutFragmentFrame.height - theme.lineSpacing - 2
        let top = point.y + (font.ascender - font.capHeight / 2) - height / 2
        let bar = CGRect(x: point.x - layoutFragmentFrame.minX,
                         y: max(point.y, top), width: 3, height: height)
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
